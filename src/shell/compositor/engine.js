// engine.js — the vanilla WebGPU compositor (focused port of ui-endlesscanvas's main.ts).
//
// The infinite canvas: a single fullscreen WebGPU pass renders every element in `this.scene` (packed into a
// float texture, read by shaders.js). A free-pan camera (camX, camY in world units) lets you "scroll
// wherever you want" — there are no pages. Elements live at world coordinates; pan moves the view.
//
// This is the new source-of-truth (no TS, no build step, no mock-NT VOM flavor — the real registry is Cm).
// First slice: GPU garden + free pan. Next: the live-DOM-over-quad synchronizer, Cm-sourced cards,
// long-press wallpaper menu (Add new / Arrange to grid), bounded/unbounded toggle, map wallpapers.

import { SHADER } from './shaders.js';

const MAX_ELEMENTS = 256;
const STRIDE_PX = 4;            // 4 rgba32f texels per element
const EL = {                   // elementType ids (carried from the prototype's dispatch table)
  CARD: 2.0,                   // a world-space card/tile (obeys the camera)
  CHROME: 3.0,                 // screen-fixed chrome (ignores the camera)
};

export class Compositor {
  constructor() {
    this.scene = [];           // [{x,y,w,h, r,g,b,a, z, rotation, elementType, colorId, texBlend, active}]
    this.camera = { x: 0, y: 0 };   // world units; pan moves this
    this._raf = 0;
    this._t0 = performance.now();
    this._drag = null;
    this._listeners = [];      // worldChanged callbacks (the DOM synchronizer subscribes here)
  }

  // ---- lifecycle ----------------------------------------------------------------------------
  async mount(host) {
    this.host = host;
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'compositor-canvas';
    this.canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block;touch-action:none;';
    host.appendChild(this.canvas);

    if (!navigator.gpu) { this._fail('WebGPU not supported on this WebView'); return false; }
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) { this._fail('No GPU adapter'); return false; }
    this.device = await adapter.requestDevice();
    this.format = navigator.gpu.getPreferredCanvasFormat();
    this.ctx = this.canvas.getContext('webgpu');
    this.ctx.configure({ device: this.device, format: this.format, alphaMode: 'premultiplied' });

    this._buildPipeline();
    this._bindInput();
    this._resize();
    window.addEventListener('resize', () => this._resize());
    this._raf = requestAnimationFrame((t) => this._frame(t));
    return true;
  }

  unmount() {
    if (this._raf) cancelAnimationFrame(this._raf);
    this._raf = 0;
    if (this.canvas && this.canvas.parentNode) this.canvas.parentNode.removeChild(this.canvas);
  }

  // ---- GPU setup ----------------------------------------------------------------------------
  _buildPipeline() {
    const d = this.device;
    this.uiTexture = d.createTexture({
      size: [MAX_ELEMENTS * STRIDE_PX, 1, 1], format: 'rgba32float', dimension: '1d',
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    this.configBuffer = d.createBuffer({ size: 12 * 4, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.configData = new Float32Array(12);

    const module = d.createShaderModule({ code: SHADER });
    this.pipeline = d.createRenderPipeline({
      layout: 'auto',
      vertex: { module, entryPoint: 'vs_main' },
      fragment: { module, entryPoint: 'fs_main', targets: [{ format: this.format }] },
    });

    // 1×1 transparent fallbacks for the texture bindings we don't use yet (atlases, presenter/DOM texture).
    const blank = this._blankTexture();
    const sampler = d.createSampler({ magFilter: 'linear', minFilter: 'linear' });
    this.bindGroup = d.createBindGroup({
      layout: this.pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: this.uiTexture.createView() },
        { binding: 1, resource: { buffer: this.configBuffer } },
        { binding: 2, resource: sampler },
        { binding: 3, resource: blank.createView() },
        { binding: 4, resource: blank.createView() },
        { binding: 5, resource: blank.createView() },
        { binding: 6, resource: blank.createView() },
        { binding: 7, resource: sampler },
        { binding: 8, resource: blank.createView() },
      ],
    });
  }

  _blankTexture() {
    const d = this.device;
    const t = d.createTexture({ size: [1, 1, 1], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    d.queue.writeTexture({ texture: t }, new Uint8Array([0, 0, 0, 0]), { bytesPerRow: 4, rowsPerImage: 1 }, [1, 1, 1]);
    return t;
  }

  _resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.floor((this.canvas.clientWidth || window.innerWidth) * dpr));
    const h = Math.max(1, Math.floor((this.canvas.clientHeight || window.innerHeight) * dpr));
    this.canvas.width = w; this.canvas.height = h;
    this.dpr = dpr;
  }

  // ---- scene --------------------------------------------------------------------------------
  add(card) {
    const e = Object.assign({ x: 0, y: 0, w: 0.18, h: 0.12, r: 0.3, g: 0.3, b: 0.34, a: 1, z: 0, rotation: 0, elementType: EL.CARD, colorId: 0, texBlend: 0, active: 1 }, card);
    this.scene.push(e);
    return e;
  }

  // ---- camera / coordinate transforms -------------------------------------------------------
  // The shader maps world→screen as: screen = 0.5 + (world - 0.5) - camera   (at z=0). We mirror that on the
  // CPU so the DOM synchronizer can place a node exactly over its quad. Returns screen UV (0..1, y-down).
  worldToScreenUV(wx, wy) { return { u: wx - this.camera.x, v: wy - this.camera.y }; }
  // Screen pixel → world (for "plop a card where my finger is"). cx,cy in CSS px relative to the canvas.
  screenToWorld(cx, cy) {
    const rect = this.canvas.getBoundingClientRect();
    const aspect = rect.width / rect.height;
    const u = cx / rect.width, v = cy / rect.height;
    // undo the aspect-square mapping used in the shader (x scaled by aspect there)
    return { x: this.camera.x + (u - 0.5) /* /aspect handled in shader space */ * 1 + 0.5 * 0, y: this.camera.y + v };
  }
  onWorldChange(cb) { this._listeners.push(cb); }

  // ---- input: free pan ----------------------------------------------------------------------
  _bindInput() {
    const c = this.canvas;
    c.addEventListener('pointerdown', (e) => {
      c.setPointerCapture(e.pointerId);
      this._drag = { px: e.clientX, py: e.clientY, cx: this.camera.x, cy: this.camera.y };
    });
    c.addEventListener('pointermove', (e) => {
      if (!this._drag) return;
      const rect = c.getBoundingClientRect();
      // drag right → world moves right under you → camera decreases. Map px delta to world units (y is 0..1
      // over the canvas height; x shares the same unit because the shader squares x by aspect).
      const dx = (e.clientX - this._drag.px) / rect.height;
      const dy = (e.clientY - this._drag.py) / rect.height;
      this.camera.x = this._drag.cx - dx;
      this.camera.y = this._drag.cy - dy;
    });
    const end = (e) => { try { c.releasePointerCapture(e.pointerId); } catch (_) {} this._drag = null; };
    c.addEventListener('pointerup', end);
    c.addEventListener('pointercancel', end);
  }

  // ---- frame --------------------------------------------------------------------------------
  _commit() {
    const data = new Float32Array(MAX_ELEMENTS * STRIDE_PX * 4);
    // painter's order: far (high z... here all z=0) — keep insertion order for now
    const els = this.scene;
    for (let i = 0; i < MAX_ELEMENTS; i++) {
      const e = i < els.length ? els[i] : null;
      const b = i * STRIDE_PX * 4;
      if (e && e.active) {
        data[b + 0] = e.x; data[b + 1] = e.y; data[b + 2] = e.w; data[b + 3] = e.h;
        data[b + 4] = e.r; data[b + 5] = e.g; data[b + 6] = e.b; data[b + 7] = e.a;
        data[b + 8] = e.z; data[b + 9] = e.rotation; data[b + 10] = e.elementType; data[b + 11] = 1;
        data[b + 12] = e.colorId; data[b + 13] = e.texBlend;
      } else { data[b + 11] = 0; }
    }
    this.device.queue.writeTexture({ texture: this.uiTexture }, data, {}, [MAX_ELEMENTS * STRIDE_PX]);
  }

  _frame(t) {
    if (!this.device) return;
    this.frames = (this.frames || 0) + 1;
    const time = (t - this._t0) / 1000;
    const cd = this.configData;
    cd[0] = this.canvas.width; cd[1] = this.canvas.height;
    cd[2] = time; cd[3] = 0;
    cd[4] = 0.0; cd[5] = 0.52; cd[6] = 1.0; cd[7] = 1.0;   // theme_color (accent-ish)
    cd[8] = this.dpr || 1;
    cd[9] = this.camera.x; cd[10] = this.camera.y; cd[11] = 0;
    this.device.queue.writeBuffer(this.configBuffer, 0, cd);

    this._commit();
    for (const cb of this._listeners) cb(this);   // let the DOM synchronizer reposition its nodes

    const enc = this.device.createCommandEncoder();
    const pass = enc.beginRenderPass({
      colorAttachments: [{ view: this.ctx.getCurrentTexture().createView(), clearValue: { r: 0, g: 0, b: 0, a: 1 }, loadOp: 'clear', storeOp: 'store' }],
    });
    pass.setPipeline(this.pipeline);
    pass.setBindGroup(0, this.bindGroup);
    pass.draw(6);
    pass.end();
    this.device.queue.submit([enc.finish()]);

    this._raf = requestAnimationFrame((tt) => this._frame(tt));
  }

  _fail(msg) {
    const d = document.createElement('div');
    d.style.cssText = 'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#f66;font-family:monospace;text-align:center;padding:20px;';
    d.textContent = 'Compositor: ' + msg;
    this.host.appendChild(d);
    console.error('Compositor:', msg);
  }
}
