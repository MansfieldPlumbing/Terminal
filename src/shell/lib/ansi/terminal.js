// src/shell/lib/ansi/terminal.js
//
// Terminal — the orchestrator that ties parser + buffer + renderer into one object, and exposes the
// SAME surface the presenters already call on xterm (write / onData / onResize / focus / clear /
// scrollLines + a built-in fit) so ansi.obp and psrp.obp are a near drop-in swap. It owns NO backend:
// the presenter wires onData→its lane (WS / PSRP) and feeds responses to write(), exactly like before.
//
// Input is JOYSTICK-PRIMARY (owner decision): the hidden textarea defaults to inputmode="none" so a
// tap focuses WITHOUT summoning the soft keyboard (that was the bug — and what hid the taskbar). The
// d-pad drives the terminal through input(seq); the real keyboard is raised ON DEMAND via setKeyboard.

import { AnsiParser } from './parser.js';
import { ScreenBuffer } from './buffer.js';
import { CanvasRenderer } from './renderer.js';

const BLINK_MS = 530;

export class Terminal {
  constructor(opts = {}) {
    this.opts = opts;
    this.cols = opts.cols || 80;
    this.rows = opts.rows || 24;
    this.buffer = new ScreenBuffer(this.cols, this.rows, {
      scrollback: opts.scrollback ?? 5000,
      onTitle: (t) => this._emit(this._onTitle, t),
      onBell: () => this._emit(this._onBell),
    });
    this.parser = new AnsiParser(this.buffer);
    this.renderer = new CanvasRenderer(document.createElement('div'), {
      fontFamily: opts.fontFamily || 'monospace',
      fontSize: opts.fontSize || 14,
      cursorInactiveStyle: opts.cursorInactiveStyle || 'bar',
    });

    this._dataCbs = []; this._resizeCbs = []; this._titleCbs = []; this._bellCbs = [];
    this._onData = this._dataCbs; this._onResize = this._resizeCbs;
    this._onTitle = this._titleCbs; this._onBell = this._bellCbs;
    this._focused = false; this._blinkOn = true; this._lastBlink = 0; this._needsPaint = true;
    this._keyboardOn = false;     // joystick-primary: IME suppressed until explicitly raised
    this._composing = false;
  }

  // ---- mount ----------------------------------------------------------------------------------
  open(container) {
    this.container = container;
    container.style.position = container.style.position || 'relative';
    container.appendChild(this.renderer.canvas);

    // The focus sink: a real but invisible textarea. inputmode="none" keeps the soft keyboard down
    // while still letting it hold focus and receive hardware/injected keys.
    const ta = document.createElement('textarea');
    ta.setAttribute('autocapitalize', 'off');
    ta.setAttribute('autocomplete', 'off');
    ta.setAttribute('autocorrect', 'off');
    ta.setAttribute('spellcheck', 'false');
    ta.inputMode = 'none';
    Object.assign(ta.style, {
      position: 'absolute', left: '0', top: '0', width: '2px', height: '2px',
      opacity: '0', border: '0', padding: '0', margin: '0', resize: 'none',
      outline: 'none', zIndex: '-5', whiteSpace: 'nowrap', overflow: 'hidden',
    });
    container.appendChild(ta);
    this.textarea = ta;

    ta.addEventListener('keydown', (e) => this._onKeyDown(e));
    ta.addEventListener('compositionstart', () => { this._composing = true; });
    ta.addEventListener('compositionend', (e) => { this._composing = false; if (e.data) this._fire(e.data); ta.value = ''; });
    ta.addEventListener('input', (e) => {
      if (this._composing) return;
      if (ta.value) { this._fire(ta.value); ta.value = ''; }
    });
    ta.addEventListener('focus', () => { this._focused = true; this._needsPaint = true; });
    ta.addEventListener('blur', () => { this._focused = false; this._needsPaint = true; });

    this.fit();
    this._raf = requestAnimationFrame((t) => this._loop(t));
    if (window.ResizeObserver) { this._ro = new ResizeObserver(() => this.fit()); this._ro.observe(container); }
  }

  // ---- write / parse --------------------------------------------------------------------------
  write(data) {
    if (data == null) return;
    const wasBottom = this.buffer.atBottom();
    this.parser.parse(typeof data === 'string' ? data : String(data));
    if (wasBottom) this.buffer.scrollToBottom();
  }

  // ---- input: the ONE outbound path. d-pad/joystick and key encoders all land here. -----------
  input(seq) { if (seq) this._fire(seq); }
  _fire(seq) { this.buffer.scrollToBottom(); for (const cb of this._dataCbs) { try { cb(seq); } catch (e) {} } }

  _onKeyDown(e) {
    const seq = this._encodeKey(e);
    if (seq !== null) { e.preventDefault(); this._fire(seq); }
  }
  // Encode the keys a shell needs; printable text comes through the 'input' event, not here.
  _encodeKey(e) {
    const app = this.buffer.appCursorKeys;
    const O = app ? 'O' : '[';
    if (e.ctrlKey && !e.altKey && e.key.length === 1) {
      const c = e.key.toUpperCase().charCodeAt(0);
      if (c >= 64 && c <= 95) return String.fromCharCode(c - 64);   // Ctrl-A..Ctrl-_
      if (e.key === ' ') return '\x00';
    }
    switch (e.key) {
      case 'Enter': return '\r';
      case 'Backspace': return '\x7f';
      case 'Tab': return '\t';
      case 'Escape': return '\x1b';
      case 'ArrowUp': return '\x1b' + O + 'A';
      case 'ArrowDown': return '\x1b' + O + 'B';
      case 'ArrowRight': return '\x1b' + O + 'C';
      case 'ArrowLeft': return '\x1b' + O + 'D';
      case 'Home': return '\x1b' + O + 'H';
      case 'End': return '\x1b' + O + 'F';
      case 'PageUp': return '\x1b[5~';
      case 'PageDown': return '\x1b[6~';
      case 'Delete': return '\x1b[3~';
    }
    return null;   // let printable keys reach the 'input' event
  }

  // ---- the joystick/d-pad sugar (the presenter's on-screen control calls these) ---------------
  key(name) {
    const map = {
      up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight',
      enter: 'Enter', tab: 'Tab', esc: 'Escape', home: 'Home', end: 'End',
    };
    if (name === 'ctrlc') return this._fire('\x03');
    const k = map[name]; if (!k) return;
    const seq = this._encodeKey({ key: k, ctrlKey: false, altKey: false });
    if (seq) this._fire(seq);
  }

  // ---- keyboard on demand (Gboard) ------------------------------------------------------------
  setKeyboard(on) {
    this._keyboardOn = !!on;
    if (!this.textarea) return;
    this.textarea.inputMode = on ? 'text' : 'none';
    if (on) this.textarea.focus(); else { this.textarea.blur(); this.focus(); }
  }
  toggleKeyboard() { this.setKeyboard(!this._keyboardOn); return this._keyboardOn; }

  // ---- geometry -------------------------------------------------------------------------------
  fit() {
    if (!this.container) return;
    const st = getComputedStyle(this.container);
    const w = this.container.clientWidth - (parseFloat(st.paddingLeft) || 0) - (parseFloat(st.paddingRight) || 0);
    const h = this.container.clientHeight - (parseFloat(st.paddingTop) || 0) - (parseFloat(st.paddingBottom) || 0);
    const cw = this.renderer.cellW, ch = this.renderer.cellH;
    const cols = Math.max(2, Math.floor(w / cw)), rows = Math.max(1, Math.floor(h / ch));
    this.renderer.resize(cols * cw, rows * ch);
    if (this.buffer.resize(cols, rows)) { this.cols = cols; this.rows = rows; for (const cb of this._resizeCbs) { try { cb({ cols, rows }); } catch (e) {} } }
    else { this.cols = cols; this.rows = rows; }
    this.buffer.dirty = true;
  }

  // ---- the xterm-compatible surface the presenters call ---------------------------------------
  onData(cb) { this._dataCbs.push(cb); }
  onResize(cb) { this._resizeCbs.push(cb); }
  onTitle(cb) { this._titleCbs.push(cb); }
  onBell(cb) { this._bellCbs.push(cb); }
  focus() { if (this.textarea) this.textarea.focus(); }
  blur() { if (this.textarea) this.textarea.blur(); }
  clear() { this.buffer.fullReset(); this.buffer.dirty = true; }
  scrollLines(n) { this.buffer.scrollLines(n); }
  scrollToBottom() { this.buffer.scrollToBottom(); }
  setTheme(theme) { this.renderer.setTheme(theme); this.buffer.dirty = true; }
  getSelection() { return ''; }        // TODO: touch selection model (next pass)
  clearSelection() {}
  get cellHeight() { return this.renderer.cellH; }

  _emit(list, arg) { if (list) for (const cb of list) { try { cb(arg); } catch (e) {} } }

  // ---- paint loop (dirty-driven, with cursor blink) -------------------------------------------
  _loop(t) {
    if (!this.container) return;
    if (t - this._lastBlink >= BLINK_MS) { this._blinkOn = !this._blinkOn; this._lastBlink = t; this._needsPaint = true; }
    if (this.buffer.dirty || this._needsPaint) {
      this.renderer.render(this.buffer, { focused: this._focused, blinkOn: this._blinkOn });
      this.buffer.dirty = false; this._needsPaint = false;
    }
    this._raf = requestAnimationFrame((tt) => this._loop(tt));
  }

  dispose() {
    if (this._raf) cancelAnimationFrame(this._raf);
    if (this._ro) this._ro.disconnect();
    this.container = null;
  }
}
