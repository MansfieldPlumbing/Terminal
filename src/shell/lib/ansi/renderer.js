// src/shell/lib/ansi/renderer.js
//
// CanvasRenderer — paints a ScreenBuffer to a single 2D canvas. The WebView half of the ONE cell
// truth: its cell (char + fg/bg/attr) is the same shape as the console renderer's
// (C:\tui-dwm TuiDwm.Core/Cell.cs + TuiDwm.Engine/VtRenderer.cs). One model, three surfaces
// (WebView canvas / GPU / TUI cells) — no second truth.
//
// One canvas, DPR-aware, repaint-on-dirty. xterm stacked five canvases (text/selection/link/cursor/
// decoration); a phone terminal does not need the layering — one buffer, one paint, batched by run.

import {
  COLOR_PALETTE, COLOR_RGB,
  A_BOLD, A_DIM, A_ITALIC, A_UNDERLINE, A_INVERSE, A_INVISIBLE, A_STRIKE,
} from './buffer.js';

// The xterm-256 palette indices 16..255 are protocol-fixed (6×6×6 cube + 24 greys); only 0..15 are
// theme-driven. Build the fixed tail once.
const CUBE = [0, 95, 135, 175, 215, 255];
const hex2 = (n) => n.toString(16).padStart(2, '0');
function fixedTail() {
  const out = [];
  for (let i = 0; i < 216; i++) {
    const r = CUBE[Math.floor(i / 36) % 6], g = CUBE[Math.floor(i / 6) % 6], b = CUBE[i % 6];
    out.push('#' + hex2(r) + hex2(g) + hex2(b));
  }
  for (let i = 0; i < 24; i++) { const v = 8 + i * 10; out.push('#' + hex2(v) + hex2(v) + hex2(v)); }
  return out;   // length 240 (indices 16..255)
}
const TAIL_256 = fixedTail();

export class CanvasRenderer {
  constructor(container, opts = {}) {
    this.fontFamily = opts.fontFamily || 'monospace';
    this.fontSize = opts.fontSize || 14;
    this.lineHeight = opts.lineHeight || 1.2;
    this.cursorStyleBlur = opts.cursorInactiveStyle || 'bar';   // 'bar' | 'block' | 'none'
    this.dpr = Math.max(1, window.devicePixelRatio || 1);

    this.canvas = document.createElement('canvas');
    this.canvas.style.display = 'block';
    container.appendChild(this.canvas);
    this.ctx = this.canvas.getContext('2d', { alpha: false });

    this.cellW = 8; this.cellH = 16;       // measured in _measure()
    this.theme = { background: '#000000', foreground: '#f2f2f2', cursor: '#f2f2f2' };
    this.palette = this._buildPalette(this.theme);
    this._measure();
  }

  // theme: xterm-shape ({ background, foreground, cursor, black..white, brightBlack..brightWhite }).
  setTheme(theme) {
    if (!theme) return;
    this.theme = Object.assign({}, this.theme, theme);
    this.palette = this._buildPalette(this.theme);
  }
  _buildPalette(t) {
    const base16 = [
      t.black, t.red, t.green, t.yellow, t.blue, t.magenta, t.cyan, t.white,
      t.brightBlack, t.brightRed, t.brightGreen, t.brightYellow,
      t.brightBlue, t.brightMagenta, t.brightCyan, t.brightWhite,
    ].map((c, i) => c || (i < 8 ? '#808080' : '#ffffff'));
    return base16.concat(TAIL_256);   // [0..15 theme] + [16..255 fixed]
  }

  // Pixel size of one cell from the current font. Width = advance of a monospace glyph; height tracks
  // the line box. This is what fit() divides the container by to get cols/rows.
  _measure() {
    this.ctx.font = `${this.fontSize}px ${this.fontFamily}`;
    const m = this.ctx.measureText('M');
    this.cellW = Math.max(1, Math.round(m.width));
    this.cellH = Math.max(1, Math.round(this.fontSize * this.lineHeight));
  }

  setFont(family, size) {
    if (family) this.fontFamily = family;
    if (size) this.fontSize = size;
    this._measure();
  }

  // Size the backing store to the (already cell-snapped) pixel box from terminal.fit().
  resize(cssW, cssH) {
    this.dpr = Math.max(1, window.devicePixelRatio || 1);
    this.canvas.style.width = cssW + 'px';
    this.canvas.style.height = cssH + 'px';
    this.canvas.width = Math.round(cssW * this.dpr);
    this.canvas.height = Math.round(cssH * this.dpr);
    const ctx = this.ctx;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.textBaseline = 'top';
    this._measure();
  }

  // color: 0=default, (1<<24)|idx palette, (2<<24)|rgb. isFg picks the theme default.
  _resolve(color, isFg) {
    if (color === 0) return isFg ? this.theme.foreground : this.theme.background;
    const mode = color >>> 24, val = color & 0xffffff;
    if (mode === (COLOR_PALETTE >>> 24)) return this.palette[val & 255] || (isFg ? this.theme.foreground : this.theme.background);
    if (mode === (COLOR_RGB >>> 24)) return '#' + hex2((val >> 16) & 255) + hex2((val >> 8) & 255) + hex2(val & 255);
    return isFg ? this.theme.foreground : this.theme.background;
  }

  // Paint one frame. cur = buffer.cursor(); focused/blinkOn drive the cursor presentation.
  render(buffer, opts = {}) {
    const ctx = this.ctx;
    const rows = buffer.rows, cols = buffer.cols, cw = this.cellW, ch = this.cellH;
    const view = buffer.viewport();
    const focused = !!opts.focused, blinkOn = opts.blinkOn !== false;

    // 1) clear to the scheme background (alpha:false canvas — one fill, no per-cell default bg).
    ctx.fillStyle = this.theme.background;
    ctx.fillRect(0, 0, cols * cw, rows * ch);

    let lastFont = '';
    for (let y = 0; y < rows; y++) {
      const ln = view[y]; if (!ln) continue;
      const py = y * ch;

      // 2) background runs first (batch consecutive same-bg, non-default cells into one rect).
      let x = 0;
      while (x < cols) {
        let bg = this._cellBg(ln, x);
        if (bg === null) { x++; continue; }
        let run = x + 1;
        while (run < cols && this._cellBg(ln, run) === bg) run++;
        ctx.fillStyle = bg;
        ctx.fillRect(x * cw, py, (run - x) * cw, ch);
        x = run;
      }

      // 3) glyphs.
      for (let cx = 0; cx < cols; cx++) {
        const chc = ln.chars[cx];
        const a = ln.attr[cx];
        if (chc === ' ' || chc === '' || (a & A_INVISIBLE)) continue;
        let fgColor = ln.fg[cx], bgColor = ln.bg[cx];
        if (a & A_INVERSE) { const t = fgColor; fgColor = bgColor; bgColor = t; }
        // bold promotes the 8 base colors to their bright pair (the classic terminal convention).
        if ((a & A_BOLD) && (fgColor & 0xffffff) < 8 && (fgColor >>> 24) === (COLOR_PALETTE >>> 24)) fgColor += 8;

        const font = `${a & A_ITALIC ? 'italic ' : ''}${a & A_BOLD ? 'bold ' : ''}${this.fontSize}px ${this.fontFamily}`;
        if (font !== lastFont) { ctx.font = font; lastFont = font; }
        ctx.globalAlpha = (a & A_DIM) ? 0.6 : 1;
        ctx.fillStyle = this._resolve(fgColor, true);
        ctx.fillText(chc, cx * cw, py);
        ctx.globalAlpha = 1;

        if (a & (A_UNDERLINE | A_STRIKE)) {
          ctx.strokeStyle = ctx.fillStyle;
          ctx.lineWidth = Math.max(1, Math.round(this.fontSize / 14));
          if (a & A_UNDERLINE) this._line(cx * cw, py + ch - 1.5, cw);
          if (a & A_STRIKE) this._line(cx * cw, py + ch * 0.55, cw);
        }
      }
    }

    // 4) cursor.
    const cur = buffer.cursor();
    if (cur.visible) this._cursor(buffer, cur, focused, blinkOn);
  }

  _cellBg(ln, x) {
    const a = ln.attr[x];
    let bg = ln.bg[x];
    if (a & A_INVERSE) bg = ln.fg[x];   // inverse: the fg paints the cell
    if (bg === 0 && !(a & A_INVERSE)) return null;   // default bg already cleared
    return this._resolve(bg, false);
  }

  _line(x, y, w) { const c = this.ctx; c.beginPath(); c.moveTo(x, y); c.lineTo(x + w, y); c.stroke(); }

  _cursor(buffer, cur, focused, blinkOn) {
    const ctx = this.ctx, cw = this.cellW, ch = this.cellH;
    const px = cur.x * cw, py = cur.y * ch;
    const col = this.theme.cursor || this.theme.foreground;
    if (focused) {
      if (!blinkOn) return;                       // blink: hidden half-cycle
      ctx.fillStyle = col;
      ctx.fillRect(px, py, cw, ch);               // block
      const ln = buffer.viewport()[cur.y];
      const chc = ln && ln.chars[cur.x];
      if (chc && chc !== ' ') {                    // redraw the glyph under the block in bg color
        ctx.fillStyle = this.theme.background;
        ctx.fillText(chc, px, py);
      }
    } else if (this.cursorStyleBlur === 'block') {
      ctx.fillStyle = col; ctx.globalAlpha = 0.5; ctx.fillRect(px, py, cw, ch); ctx.globalAlpha = 1;
    } else if (this.cursorStyleBlur !== 'none') {  // 'bar' — the subtle blurred cue
      ctx.fillStyle = col;
      ctx.fillRect(px, py, Math.max(1, Math.round(cw / 8)), ch);
    }
  }
}
