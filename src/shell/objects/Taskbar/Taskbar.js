import { UiObject } from '../../shell/UiObject.js';
import { launchIcon } from '../../shell/icons.js';

// Taskbar — a PRESENTER of running window objects. ONE component; `position` is an axis (top|bottom),
// never a second name (no `tabbar`/`barStyle`). The chips are the Shell's OPEN windows (not the launcher
// app list — that's the Menu's Presenters). Launch creates a window object elsewhere; the taskbar just shows
// what's running and switches focus. Spring drag-reorder lifted from ui-final/src/vanilla. REGISTRY-SPEC §5/§9.
// ALWAYS VISIBLE (owner directive 2026-06-11): no auto-hide, no edge strip, no posture switching.
const CHIP = 52;            // 46px chip + 6px gap
const STIFF = 0.082, DAMP = 0.64;

export class Taskbar extends UiObject {
  async mount(host, ctx) {
    await super.mount(host, ctx);
    this.position = (ctx.spec && ctx.spec.position) || 'bottom';
    host.dataset.position = this.position;
    host.innerHTML =
      '<div class="taskbar">' +
        '<button class="taskbar-launch" type="button" aria-label="Menu">' + launchIcon(this.position) + '</button>' +
        '<div class="taskbar-strip" role="tablist"></div>' +
      '</div>';
    this._strip = host.querySelector('.taskbar-strip');
    this._launch = host.querySelector('.taskbar-launch');
    this._launch.addEventListener('click', () => this.ctx.shell.toggleMenu());
    this._pos = {};            // id -> { currentX, targetX, velX }
    this._dragId = null;
    this.render();
    this._loop();
  }

  // Render one chip per open window object (resolved name/icon from the object, live).
  render() {
    const wins = this.ctx.shell.openWindows();
    this._strip.replaceChildren();
    wins.forEach((w, i) => {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'taskbar-chip' + (w.id === this.ctx.shell.activeId ? ' active' : '');
      chip.dataset.id = w.id;
      chip.title = w.title || w.name || w.id;
      chip.setAttribute('role', 'tab');
      this._icon(chip, w);
      chip.addEventListener('pointerdown', (e) => this._down(e, chip, w.id));
      if (this._pos[w.id] === undefined) this._pos[w.id] = { currentX: i * CHIP, targetX: i * CHIP, velX: 0 };
      else this._pos[w.id].targetX = i * CHIP;
      // Place the chip NOW, not on the next RAF tick — a fresh element carries no inline transform,
      // so it would sit stacked at slot 0 for a frame (the "floaty" jump). At rest the transform is
      // exactly translate(slot,-50%): no residual drag offset, no scale, one shared baseline.
      const s = this._pos[w.id];
      chip.style.transform = `translate(${Math.round(s.currentX)}px,-50%)`;
      this._strip.appendChild(chip);
    });
    for (const id of Object.keys(this._pos)) if (!wins.find(w => w.id === id)) delete this._pos[id];
  }

  // The launch button is ONE presenter with two dock personalities (REGISTRY-SPEC §9): hamburger up top
  // (the menu-bar/context root), the 9-dot grid down low (the Start/launcher root). Same object, the icon
  // (and later the root it opens) switches with the dock. Called by the Shell when the bar is re-docked.
  setPosition(pos) {
    if (pos !== 'top' && pos !== 'bottom') return;
    this.position = pos;
    this.host.dataset.position = pos;
    if (this._launch) {
      this._launch.classList.add('swap');
      this._launch.innerHTML = launchIcon(pos);
      setTimeout(() => this._launch && this._launch.classList.remove('swap'), 200);
    }
  }

  syncActive() {
    const a = this.ctx.shell.activeId;
    for (const chip of this._strip.children) chip.classList.toggle('active', chip.dataset.id === a);
  }

  _icon(chip, w) {
    const icon = w.icon;
    if (icon && /[\/.]/.test(icon)) {
      const img = document.createElement('img');
      img.className = 'taskbar-chip-icon'; img.src = icon; img.alt = '';
      img.addEventListener('error', () => { chip.textContent = this._glyph(w); });
      chip.appendChild(img);
    } else if (icon) chip.textContent = icon;
    else chip.textContent = this._glyph(w);
  }
  _glyph(w) { return ((w.title || w.name || w.id || '?').trim()[0] || '?').toUpperCase(); }

  // --- spring drag-reorder (ui-final tabbar.js) — reorders the Shell's window list ---
  _down(e, el, id) {
    e.preventDefault(); el.setPointerCapture(e.pointerId);
    this._dragId = id; this._moved = false;
    const sx = e.clientX;
    const startX = this._pos[id] ? this._pos[id].currentX : 0;
    const move = (ev) => {
      const d = ev.clientX - sx;
      if (Math.abs(d) > 4) this._moved = true;
      if (!this._moved) return;
      // Clamp to the strip: never below slot 0, never past the last visible slot (ui-final discipline —
      // without the upper clamp a chip flies off the right and the swap thresholds misfire).
      const max = Math.max(0, this._strip.clientWidth - CHIP);
      const x = Math.min(max, Math.max(0, startX + d));
      if (this._pos[id]) { this._pos[id].currentX = x; this._pos[id].targetX = x; }
      this._swap(id, x);
    };
    const up = (ev) => {
      el.releasePointerCapture(ev.pointerId);
      el.removeEventListener('pointermove', move); el.removeEventListener('pointerup', up);
      this._dragId = null;
      if (!this._moved) this.ctx.shell.focus(id);
      else this._retarget();
    };
    el.addEventListener('pointermove', move); el.addEventListener('pointerup', up);
  }

  _order() { return this.ctx.shell.openWindows().map(w => w.id); }
  _swapped(arr, a, b) { const c = arr.slice(); const t = c[a]; c[a] = c[b]; c[b] = t; return c; }
  _swap(id, x) {
    const order = this._order();
    const i = order.indexOf(id);
    if (i < 0) return;
    if (i > 0 && x < (i - 1) * CHIP + CHIP / 2) { this.ctx.shell.reorder(this._swapped(order, i, i - 1)); this._retarget(); return; }
    if (i < order.length - 1 && x > (i + 1) * CHIP - CHIP / 2) { this.ctx.shell.reorder(this._swapped(order, i, i + 1)); this._retarget(); }
  }
  _retarget() { this._order().forEach((id, i) => { if (this._pos[id]) this._pos[id].targetX = i * CHIP; }); }

  _loop() {
    const step = () => {
      if (!this.host) return;
      const active = this.ctx.shell.activeId;
      for (const chip of this._strip.children) {
        const id = chip.dataset.id; const s = this._pos[id]; if (!s) continue;
        if (this._dragId === id) { chip.style.transform = `translate(${s.currentX}px,-50%)`; chip.style.zIndex = '100'; continue; }
        const dx = s.targetX - s.currentX; s.velX += dx * STIFF; s.velX *= DAMP; s.currentX += s.velX;
        if (Math.abs(dx) < 0.5 && Math.abs(s.velX) < 0.5) { s.currentX = s.targetX; s.velX = 0; }  // settle: eliminate sub-pixel jitter
        chip.style.transform = `translate(${Math.round(s.currentX)}px,-50%)`;
        chip.style.zIndex = id === active ? '50' : '10';
      }
      this._raf = requestAnimationFrame(step);
    };
    this._raf = requestAnimationFrame(step);
  }

  unmount() {
    if (this._raf) cancelAnimationFrame(this._raf);
    super.unmount();
    this._strip = this._launch = null;
  }
}
