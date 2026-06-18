// src/shell/lib/ansi/buffer.js
//
// ScreenBuffer — the cell grid the parser writes into; it IS the AnsiParser's handler. Cursor,
// scroll region (DECSTBM), SGR pen, scrollback ring, and the alternate screen. First principles,
// PowerShell/PSReadLine-correct on the common path; the exotic tail (full charset shift, DCS,
// mouse) is deferred behind clear seams, never faked.
//
// A line is plain parallel arrays — chars + per-cell fg/bg/attr — chosen for splice-simplicity on
// insert/delete-char/line ops (off-road first; the typed-array pave is a later perf pass, noted in
// the engine handoff). 80×40 of these on a phone is nothing.
//
// Color encoding (shared with the renderer): a 32-bit int.
//   0                         = default (renderer substitutes the theme's fg/bg)
//   (1<<24) | idx             = palette index 0..255
//   (2<<24) | (r<<16|g<<8|b)  = 24-bit truecolor
export const COLOR_DEFAULT = 0;
export const COLOR_PALETTE = 1 << 24;
export const COLOR_RGB = 2 << 24;

// attr bitmask
export const A_BOLD = 1, A_DIM = 2, A_ITALIC = 4, A_UNDERLINE = 8,
             A_BLINK = 16, A_INVERSE = 32, A_INVISIBLE = 64, A_STRIKE = 128;

const DEFAULT_TABS = 8;

function blankLine(cols) {
  const chars = new Array(cols), fg = new Array(cols), bg = new Array(cols), attr = new Array(cols);
  for (let i = 0; i < cols; i++) { chars[i] = ' '; fg[i] = 0; bg[i] = 0; attr[i] = 0; }
  return { chars, fg, bg, attr, wrapped: false };
}

class Screen {
  constructor(cols, rows, scrollback) {
    this.cols = cols; this.rows = rows; this.scrollback = scrollback;
    this.lines = []; for (let i = 0; i < rows; i++) this.lines.push(blankLine(cols));
    this.ybase = 0;   // index in `lines` of the top visible row when scrolled to the bottom
    this.ydisp = 0;   // index currently shown at the top (== ybase unless scrolled back)
    this.x = 0; this.y = 0;
    this.top = 0; this.bottom = rows - 1;   // scroll region (DECSTBM), screen-relative
    this.saved = null;                      // DECSC cursor+pen
    this.wrapNext = false;                  // deferred wrap: last column written, wrap on next print
  }
  line(yScreen) { return this.lines[this.ybase + yScreen]; }
}

export class ScreenBuffer {
  constructor(cols, rows, opts = {}) {
    this.cols = Math.max(2, cols | 0);
    this.rows = Math.max(1, rows | 0);
    this.scrollback = opts.scrollback ?? 5000;
    this.normal = new Screen(this.cols, this.rows, this.scrollback);
    this.alt = new Screen(this.cols, this.rows, 0);
    this.s = this.normal;
    this.isAlt = false;

    // pen
    this.fg = 0; this.bg = 0; this.attr = 0;
    // modes
    this.wrap = true;          // DECAWM
    this.origin = false;       // DECOM
    this.insert = false;       // IRM
    this.cursorVisible = true; // DECTCEM (?25)
    this.appCursorKeys = false;// DECCKM (?1) — input encoding, read by terminal.js
    this.title = '';
    this.onBell = opts.onBell || null;
    this.onTitle = opts.onTitle || null;

    this.tabs = {};
    for (let i = 0; i < this.cols; i += DEFAULT_TABS) this.tabs[i] = true;
    this.dirty = true;
  }

  // ---- geometry --------------------------------------------------------------------------------
  resize(cols, rows) {
    cols = Math.max(2, cols | 0); rows = Math.max(1, rows | 0);
    if (cols === this.cols && rows === this.rows) return false;
    for (const scr of [this.normal, this.alt]) this._resizeScreen(scr, cols, rows);
    this.cols = cols; this.rows = rows;
    this.tabs = {};
    for (let i = 0; i < cols; i += DEFAULT_TABS) this.tabs[i] = true;
    this.dirty = true;
    return true;
  }
  _resizeScreen(scr, cols, rows) {
    // No reflow in v1: clip/extend each line, then add/trim rows at the bottom (cursor-anchored).
    for (const ln of scr.lines) {
      if (cols < ln.chars.length) { ln.chars.length = ln.fg.length = ln.bg.length = ln.attr.length = cols; }
      else for (let i = ln.chars.length; i < cols; i++) { ln.chars[i] = ' '; ln.fg[i] = 0; ln.bg[i] = 0; ln.attr[i] = 0; }
    }
    const haveRows = scr.lines.length - scr.ybase;
    if (rows > haveRows) for (let i = 0; i < rows - haveRows; i++) scr.lines.push(blankLine(cols));
    scr.cols = cols; scr.rows = rows;
    scr.top = 0; scr.bottom = rows - 1;
    scr.ybase = Math.max(0, scr.lines.length - rows);
    scr.ydisp = scr.ybase;
    scr.x = Math.min(scr.x, cols - 1);
    scr.y = Math.min(scr.y, rows - 1);
    scr.wrapNext = false;
  }

  // ---- parser handler: print / execute / csi / esc / osc ---------------------------------------
  print(str) {
    const s = this.s;
    for (const ch of str) {                 // iterate code points (surrogate-safe)
      if (s.wrapNext) {
        s.line(s.y).wrapped = true;
        this._index(); s.x = 0; s.wrapNext = false;
      }
      if (this.insert) this._insertBlanks(1);
      const ln = s.line(s.y);
      ln.chars[s.x] = ch; ln.fg[s.x] = this.fg; ln.bg[s.x] = this.bg; ln.attr[s.x] = this.attr;
      if (s.x === this.cols - 1) { if (this.wrap) s.wrapNext = true; }
      else s.x++;
    }
    this.dirty = true;
  }

  execute(code) {
    const s = this.s;
    switch (code) {
      case 0x07: if (this.onBell) this.onBell(); break;                       // BEL
      case 0x08: s.wrapNext = false; if (s.x > 0) s.x--; break;               // BS
      case 0x09: this._tab(); break;                                          // HT
      case 0x0a: case 0x0b: case 0x0c: this._index(); break;                  // LF/VT/FF
      case 0x0d: s.wrapNext = false; s.x = 0; break;                          // CR
      // SO/SI (charset shift) — intentionally unhandled in v1; PS doesn't lean on it.
    }
    this.dirty = true;
  }

  esc(interm, final) {
    const s = this.s;
    if (interm === '') {
      switch (final) {
        case 0x37: s.saved = this._penSnapshot(); return;                     // DECSC (ESC 7)
        case 0x38: this._penRestore(s.saved); return;                         // DECRC (ESC 8)
        case 0x44: this._index(); return;                                     // IND
        case 0x4d: this._reverseIndex(); return;                              // RI
        case 0x45: this._index(); s.x = 0; return;                            // NEL
        case 0x63: this.fullReset(); return;                                  // RIS
      }
    }
    if (interm === '#' && final === 0x38) { this._decaln(); return; }         // DECALN (fill 'E')
    // charset designations (ESC ( B etc.) — accepted and ignored in v1.
  }

  osc(data) {
    const semi = data.indexOf(';');
    const id = semi < 0 ? data : data.slice(0, semi);
    const body = semi < 0 ? '' : data.slice(semi + 1);
    if (id === '0' || id === '2') { this.title = body; if (this.onTitle) this.onTitle(body); }
    // 8 (hyperlink), 4/104 (palette), 52 (clipboard) — seams for later.
  }

  csi(params, interm, final) {
    const s = this.s;
    const priv = interm.indexOf('?') >= 0;
    const p = (i, d) => { const v = params[i] && params[i][0]; return (v === undefined || v === 0) ? (d === undefined ? 0 : d) : v; };
    const ch = String.fromCharCode(final);

    if (priv && (ch === 'h' || ch === 'l')) { this._privateMode(params, ch === 'h'); this.dirty = true; return; }

    switch (ch) {
      case '@': this._insertBlanks(p(0, 1)); break;                                   // ICH
      case 'A': s.y = Math.max(this._regTop(), s.y - p(0, 1)); s.wrapNext = false; break; // CUU
      case 'B': case 'e': s.y = Math.min(this._regBottom(), s.y + p(0, 1)); s.wrapNext = false; break; // CUD
      case 'C': case 'a': s.x = Math.min(this.cols - 1, s.x + p(0, 1)); s.wrapNext = false; break; // CUF
      case 'D': s.x = Math.max(0, s.x - p(0, 1)); s.wrapNext = false; break;          // CUB
      case 'E': s.y = Math.min(this._regBottom(), s.y + p(0, 1)); s.x = 0; break;     // CNL
      case 'F': s.y = Math.max(this._regTop(), s.y - p(0, 1)); s.x = 0; break;        // CPL
      case 'G': case '`': s.x = Math.min(this.cols - 1, Math.max(0, p(0, 1) - 1)); s.wrapNext = false; break; // CHA/HPA
      case 'd': s.y = Math.min(this.rows - 1, Math.max(0, p(0, 1) - 1)); s.wrapNext = false; break; // VPA
      case 'H': case 'f': this._cup(p(0, 1) - 1, p(1, 1) - 1); break;                 // CUP/HVP
      case 'J': this._eraseDisplay(p(0, 0)); break;                                   // ED
      case 'K': this._eraseLine(p(0, 0)); break;                                      // EL
      case 'L': this._insertLines(p(0, 1)); break;                                    // IL
      case 'M': this._deleteLines(p(0, 1)); break;                                    // DL
      case 'P': this._deleteChars(p(0, 1)); break;                                    // DCH
      case 'X': this._eraseChars(p(0, 1)); break;                                     // ECH
      case 'S': this._scrollUp(p(0, 1)); break;                                       // SU
      case 'T': this._scrollDown(p(0, 1)); break;                                     // SD
      case 'r': this._setRegion(params); break;                                       // DECSTBM
      case 'm': this._sgr(params); break;                                             // SGR
      case 'h': if (p(0) === 4) this.insert = true; break;                            // IRM set
      case 'l': if (p(0) === 4) this.insert = false; break;                           // IRM reset
      case 'g': this._tabClear(p(0, 0)); break;                                       // TBC
      case 's': s.saved = this._penSnapshot(); break;                                 // SCOSC
      case 'u': this._penRestore(s.saved); break;                                     // SCORC
      // c (DA), n (DSR) reply over the input lane — wired in terminal.js where the WS write lives.
    }
    this.dirty = true;
  }

  // ---- cursor / region helpers -----------------------------------------------------------------
  _regTop() { return this.origin ? this.s.top : 0; }
  _regBottom() { return this.origin ? this.s.bottom : this.rows - 1; }
  _cup(y, x) {
    const s = this.s;
    s.y = Math.min(this._regBottom(), Math.max(this._regTop(), (this.origin ? this.s.top : 0) + y));
    s.x = Math.min(this.cols - 1, Math.max(0, x));
    s.wrapNext = false;
  }
  _index() {       // LF behavior: down one, scroll the region if at the bottom margin
    const s = this.s;
    if (s.y === s.bottom) this._scrollUp(1);
    else if (s.y < this.rows - 1) s.y++;
    s.wrapNext = false;
  }
  _reverseIndex() {
    const s = this.s;
    if (s.y === s.top) this._scrollDown(1);
    else if (s.y > 0) s.y--;
  }

  // ---- scrolling. Full-region linefeed on the normal screen feeds scrollback; everything else is
  // an in-screen splice (no history), which is exactly what a DECSTBM region wants. ----------------
  _scrollUp(n) {
    const s = this.s;
    const fullScreen = s.top === 0 && s.bottom === this.rows - 1;
    for (let i = 0; i < n; i++) {
      if (fullScreen && !this.isAlt) {
        s.lines.splice(s.ybase + s.bottom + 1, 0, blankLine(this.cols));
        if (s.lines.length - this.rows > this.scrollback) s.lines.shift();
        else { s.ybase++; }
        s.ydisp = s.ybase;
      } else {
        s.lines.splice(s.ybase + s.top, 1);
        s.lines.splice(s.ybase + s.bottom, 0, blankLine(this.cols));
      }
    }
  }
  _scrollDown(n) {
    const s = this.s;
    for (let i = 0; i < n; i++) {
      s.lines.splice(s.ybase + s.bottom, 1);
      s.lines.splice(s.ybase + s.top, 0, blankLine(this.cols));
    }
  }

  // ---- erase / insert / delete -----------------------------------------------------------------
  _eraseCells(ln, start, end) {
    for (let i = start; i <= end && i < this.cols; i++) { ln.chars[i] = ' '; ln.fg[i] = 0; ln.bg[i] = this.bg; ln.attr[i] = 0; }
  }
  _eraseDisplay(mode) {
    const s = this.s;
    if (mode === 0) { this._eraseLine(0); for (let y = s.y + 1; y < this.rows; y++) this._eraseCells(s.line(y), 0, this.cols - 1); }
    else if (mode === 1) { this._eraseLine(1); for (let y = 0; y < s.y; y++) this._eraseCells(s.line(y), 0, this.cols - 1); }
    else { for (let y = 0; y < this.rows; y++) this._eraseCells(s.line(y), 0, this.cols - 1); s.wrapNext = false; }
  }
  _eraseLine(mode) {
    const s = this.s, ln = s.line(s.y);
    if (mode === 0) this._eraseCells(ln, s.x, this.cols - 1);
    else if (mode === 1) this._eraseCells(ln, 0, s.x);
    else this._eraseCells(ln, 0, this.cols - 1);
    s.wrapNext = false;
  }
  _insertBlanks(n) {
    const s = this.s, ln = s.line(s.y);
    for (let i = 0; i < n; i++) { ln.chars.splice(s.x, 0, ' '); ln.fg.splice(s.x, 0, 0); ln.bg.splice(s.x, 0, this.bg); ln.attr.splice(s.x, 0, 0); }
    ln.chars.length = ln.fg.length = ln.bg.length = ln.attr.length = this.cols;
  }
  _deleteChars(n) {
    const s = this.s, ln = s.line(s.y);
    for (let i = 0; i < n; i++) { ln.chars.splice(s.x, 1); ln.fg.splice(s.x, 1); ln.bg.splice(s.x, 1); ln.attr.splice(s.x, 1); }
    while (ln.chars.length < this.cols) { ln.chars.push(' '); ln.fg.push(0); ln.bg.push(this.bg); ln.attr.push(0); }
  }
  _eraseChars(n) { const s = this.s; this._eraseCells(s.line(s.y), s.x, s.x + n - 1); }
  _insertLines(n) {
    const s = this.s; if (s.y < s.top || s.y > s.bottom) return;
    for (let i = 0; i < n; i++) { s.lines.splice(s.ybase + s.bottom, 1); s.lines.splice(s.ybase + s.y, 0, blankLine(this.cols)); }
  }
  _deleteLines(n) {
    const s = this.s; if (s.y < s.top || s.y > s.bottom) return;
    for (let i = 0; i < n; i++) { s.lines.splice(s.ybase + s.y, 1); s.lines.splice(s.ybase + s.bottom, 0, blankLine(this.cols)); }
  }

  // ---- SGR pen ---------------------------------------------------------------------------------
  _sgr(params) {
    if (params.length === 0) params = [[0]];
    for (let i = 0; i < params.length; i++) {
      const sub = params[i]; const n = sub[0] || 0;
      if (n === 0) { this.fg = 0; this.bg = 0; this.attr = 0; }
      else if (n === 1) this.attr |= A_BOLD;
      else if (n === 2) this.attr |= A_DIM;
      else if (n === 3) this.attr |= A_ITALIC;
      else if (n === 4) this.attr |= A_UNDERLINE;
      else if (n === 5) this.attr |= A_BLINK;
      else if (n === 7) this.attr |= A_INVERSE;
      else if (n === 8) this.attr |= A_INVISIBLE;
      else if (n === 9) this.attr |= A_STRIKE;
      else if (n === 22) this.attr &= ~(A_BOLD | A_DIM);
      else if (n === 23) this.attr &= ~A_ITALIC;
      else if (n === 24) this.attr &= ~A_UNDERLINE;
      else if (n === 25) this.attr &= ~A_BLINK;
      else if (n === 27) this.attr &= ~A_INVERSE;
      else if (n === 28) this.attr &= ~A_INVISIBLE;
      else if (n === 29) this.attr &= ~A_STRIKE;
      else if (n >= 30 && n <= 37) this.fg = COLOR_PALETTE | (n - 30);
      else if (n === 38) { const c = this._extColor(sub, params, i); if (c.color !== null) this.fg = c.color; i = c.i; }
      else if (n === 39) this.fg = 0;
      else if (n >= 40 && n <= 47) this.bg = COLOR_PALETTE | (n - 40);
      else if (n === 48) { const c = this._extColor(sub, params, i); if (c.color !== null) this.bg = c.color; i = c.i; }
      else if (n === 49) this.bg = 0;
      else if (n >= 90 && n <= 97) this.fg = COLOR_PALETTE | (n - 90 + 8);
      else if (n >= 100 && n <= 107) this.bg = COLOR_PALETTE | (n - 100 + 8);
    }
  }
  // Handles both the sub-param form (38:2:r:g:b / 38:5:n, inside one ';' group) and the legacy
  // separate-param form (38;2;r;g;b). Returns the new outer index consumed.
  _extColor(sub, params, i) {
    if (sub.length >= 2) {            // colon sub-param form — self-contained
      if (sub[1] === 2) return { color: COLOR_RGB | ((sub[sub.length - 3] & 255) << 16) | ((sub[sub.length - 2] & 255) << 8) | (sub[sub.length - 1] & 255), i };
      if (sub[1] === 5) return { color: COLOR_PALETTE | (sub[2] & 255), i };
      return { color: null, i };
    }
    const mode = params[i + 1] && params[i + 1][0];   // legacy ';' form
    if (mode === 2) return { color: COLOR_RGB | (((params[i + 2] || [0])[0] & 255) << 16) | (((params[i + 3] || [0])[0] & 255) << 8) | ((params[i + 4] || [0])[0] & 255), i: i + 4 };
    if (mode === 5) return { color: COLOR_PALETTE | ((params[i + 2] || [0])[0] & 255), i: i + 2 };
    return { color: null, i };
  }

  // ---- private modes (DEC ?h / ?l) -------------------------------------------------------------
  _privateMode(params, set) {
    for (const sub of params) {
      const n = sub[0];
      switch (n) {
        case 1: this.appCursorKeys = set; break;                              // DECCKM
        case 7: this.wrap = set; break;                                       // DECAWM
        case 6: this.origin = set; this._cup(0, 0); break;                    // DECOM
        case 25: this.cursorVisible = set; break;                             // DECTCEM
        case 47: case 1047: this._altScreen(set, false); break;
        case 1048: if (set) this.s.saved = this._penSnapshot(); else this._penRestore(this.s.saved); break;
        case 1049: this._altScreen(set, true); break;
      }
    }
  }
  _altScreen(on, saveCursor) {
    if (on === this.isAlt) return;
    if (on) {
      if (saveCursor) this.normal.saved = this._penSnapshot();
      this.alt = new Screen(this.cols, this.rows, 0);
      this.s = this.alt; this.isAlt = true;
      this._eraseDisplay(2);
    } else {
      this.s = this.normal; this.isAlt = false;
      if (saveCursor && this.normal.saved) this._penRestore(this.normal.saved);
    }
    this.s.ydisp = this.s.ybase;
  }

  // ---- tabs / region / pen snapshots -----------------------------------------------------------
  _tab() {
    const s = this.s;
    for (let x = s.x + 1; x < this.cols; x++) { if (this.tabs[x]) { s.x = x; return; } }
    s.x = this.cols - 1;
  }
  _tabClear(mode) { if (mode === 3) this.tabs = {}; else if (mode === 0) delete this.tabs[this.s.x]; }
  _setRegion(params) {
    const s = this.s;
    const top = ((params[0] || [1])[0] || 1) - 1;
    const bot = ((params[1] || [this.rows])[0] || this.rows) - 1;
    if (top < bot && bot < this.rows) { s.top = Math.max(0, top); s.bottom = Math.min(this.rows - 1, bot); this._cup(0, 0); }
  }
  _penSnapshot() { const s = this.s; return { x: s.x, y: s.y, fg: this.fg, bg: this.bg, attr: this.attr }; }
  _penRestore(p) { if (!p) return; const s = this.s; s.x = Math.min(this.cols - 1, p.x); s.y = Math.min(this.rows - 1, p.y); this.fg = p.fg; this.bg = p.bg; this.attr = p.attr; s.wrapNext = false; }
  _decaln() { const s = this.s; for (let y = 0; y < this.rows; y++) { const ln = s.line(y); for (let x = 0; x < this.cols; x++) { ln.chars[x] = 'E'; ln.fg[x] = 0; ln.bg[x] = 0; ln.attr[x] = 0; } } }

  fullReset() {
    this.normal = new Screen(this.cols, this.rows, this.scrollback);
    this.alt = new Screen(this.cols, this.rows, 0);
    this.s = this.normal; this.isAlt = false;
    this.fg = this.bg = this.attr = 0;
    this.wrap = true; this.origin = this.insert = false; this.cursorVisible = true; this.appCursorKeys = false;
    this.dirty = true;
  }

  // ---- read side (renderer / terminal) ---------------------------------------------------------
  // Scrollback view: rows the renderer should paint, top→bottom, honoring scroll-back (ydisp).
  viewport() { const s = this.s, out = []; for (let y = 0; y < this.rows; y++) out.push(s.lines[s.ydisp + y] || blankLine(this.cols)); return out; }
  cursor() { const s = this.s; return { x: s.x, y: s.y, visible: this.cursorVisible && s.ydisp === s.ybase, wrapNext: s.wrapNext }; }
  scrollLines(n) {
    const s = this.s;
    s.ydisp = Math.max(0, Math.min(s.ybase, s.ydisp + n));
    this.dirty = true;
  }
  scrollToBottom() { this.s.ydisp = this.s.ybase; this.dirty = true; }
  atBottom() { return this.s.ydisp === this.s.ybase; }
}
