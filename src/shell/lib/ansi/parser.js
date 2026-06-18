// src/shell/lib/ansi/parser.js
//
// AnsiParser — Subsystem's own terminal control-sequence parser.
//
// A terminal speaks a control grammar: printable runs interleaved with C0/C1 controls and
// CSI / OSC / DCS sequences (the language PowerShell, ssh, vim, less all emit). This parses that
// grammar. We did not import a terminal and we are not abiding by anyone's reference engine — the
// protocol is the protocol; the implementation is ours, and it's leaner than the 276 KB we deleted.
//
// It is a state machine because the grammar is one (a control byte's meaning depends on what came
// before it) — but the shape is ours: explicit, auditable states, and printable text BATCHED so a
// whole run lands in one print() call instead of crawling a char at a time.
//
// It consumes a JS string (UTF-16, already byte-decoded upstream by the WS lane) and drives a
// handler object — the buffer is the handler:
//
//   print(str)                          a run of printable characters to put at the cursor
//   execute(code)                       a single C0 (0x00-0x1F) / C1 (0x80-0x9F) control
//   csi(params, intermediates, final)   CSI … <final>   params:number[][]  (outer = ';' , inner = ':')
//   esc(intermediates, final)           ESC … <final>
//   osc(data)                           OSC string body, e.g. "0;the title"
//   dcs(params, intermediates, final, data)   DCS passthrough (optional — safe to omit)
//
// First-principles choices:
//   * One explicit switch per state — readable and auditable; correctness before micro-opt.
//   * ESC / CAN / SUB / a fresh C1 abort whatever sequence is in flight, exactly like the hardware.
//   * Printable runs are BATCHED — print() receives a whole string, never one char at a time, so the
//     buffer can fast-path an entire run. That batching is the single biggest throughput win over a
//     naive per-codepoint dispatch, and it's why a 276 KB import was never the thing standing between
//     us and a fast terminal.

const S = {
  GROUND: 0,
  ESCAPE: 1,
  ESCAPE_INTERMEDIATE: 2,
  CSI_ENTRY: 3,
  CSI_PARAM: 4,
  CSI_INTERMEDIATE: 5,
  CSI_IGNORE: 6,
  OSC_STRING: 7,
  DCS_ENTRY: 8,
  DCS_PARAM: 9,
  DCS_INTERMEDIATE: 10,
  DCS_PASSTHROUGH: 11,
  DCS_IGNORE: 12,
  SOS_PM_APC: 13,
};

const MAX_PARAMS = 32;       // the protocol leaves it open; 32 is well past anything real (SGR truecolor needs 5)
const MAX_OSC = 8192;        // a title/hyperlink; cap so a runaway string can't grow unbounded

export class AnsiParser {
  constructor(handler) {
    this.h = handler;
    this.reset();
  }

  reset() {
    this.state = S.GROUND;
    this._clear();
    this.str = '';            // OSC / DCS string accumulator
    this.dcsFinal = 0;
  }

  // Begin a fresh control sequence (called on every ESC / CSI / DCS entry).
  _clear() {
    this.params = [];         // number[][] — outer = ';'-separated, inner = ':'-separated sub-params
    this.cur = 0;
    this.subs = [];
    this.hasParam = false;
    this.interm = '';
    this.str = '';
  }

  _param(digit) {
    this.cur = this.cur * 10 + digit;
    if (this.cur > 0x7fffffff) this.cur = 0x7fffffff;
    this.hasParam = true;
  }
  _subSep() { this.subs.push(this.hasParam ? this.cur : 0); this.cur = 0; this.hasParam = false; }
  _pushParam() {
    this.subs.push(this.hasParam ? this.cur : 0);
    if (this.params.length < MAX_PARAMS) this.params.push(this.subs);
    this.cur = 0; this.hasParam = false; this.subs = [];
  }

  // Public entry: feed a chunk. Printable runs in GROUND are sliced out and flushed as one print().
  parse(str) {
    let printStart = -1;
    const n = str.length;
    for (let i = 0; i < n; i++) {
      const c = str.charCodeAt(i);
      if (this.state === S.GROUND) {
        // Printable: 0x20..0x7E and anything >= 0xA0 (surrogate halves included → emoji stay intact).
        if ((c >= 0x20 && c <= 0x7e) || c >= 0xa0) {
          if (printStart < 0) printStart = i;
          continue;
        }
        if (printStart >= 0) { this.h.print(str.slice(printStart, i)); printStart = -1; }
      }
      this._step(c);
    }
    if (printStart >= 0) this.h.print(str.slice(printStart));
  }

  _step(c) {
    // ESC, CAN and SUB abort from (almost) anywhere — handle them before the per-state switch so we
    // never have to repeat them in every case.
    if (c === 0x1b) {                       // ESC
      // Terminates an OSC/DCS string (ST = ESC \) AND starts a new sequence; dispatch then re-enter.
      if (this.state === S.OSC_STRING) this.h.osc(this.str);
      else if (this.state === S.DCS_PASSTHROUGH && this.h.dcs) this.h.dcs(this.params, this.interm, this.dcsFinal, this.str);
      this.state = S.ESCAPE; this._clear(); return;
    }
    if ((c === 0x18 || c === 0x1a) &&       // CAN / SUB → abort to GROUND
        this.state !== S.OSC_STRING && this.state !== S.DCS_PASSTHROUGH) {
      this.state = S.GROUND; this._clear(); return;
    }

    switch (this.state) {
      case S.GROUND:
        this._ground(c);
        break;

      case S.ESCAPE:
        if (c <= 0x1f) { this.h.execute(c); }
        else if (c >= 0x20 && c <= 0x2f) { this.interm += String.fromCharCode(c); this.state = S.ESCAPE_INTERMEDIATE; }
        else if (c === 0x7f) { /* ignore */ }
        else { this._escFinal(c); }
        break;

      case S.ESCAPE_INTERMEDIATE:
        if (c <= 0x1f) { this.h.execute(c); }
        else if (c >= 0x20 && c <= 0x2f) { this.interm += String.fromCharCode(c); }
        else if (c === 0x7f) { /* ignore */ }
        else { this.h.esc(this.interm, c); this.state = S.GROUND; }
        break;

      case S.CSI_ENTRY:
        if (c <= 0x1f) { this.h.execute(c); }
        else if (c >= 0x30 && c <= 0x39) { this._param(c - 0x30); this.state = S.CSI_PARAM; }
        else if (c === 0x3a) { this._subSep(); this.state = S.CSI_PARAM; }
        else if (c === 0x3b) { this._pushParam(); this.state = S.CSI_PARAM; }
        else if (c >= 0x3c && c <= 0x3f) { this.interm += String.fromCharCode(c); this.state = S.CSI_PARAM; } // private '?<=>'
        else if (c >= 0x20 && c <= 0x2f) { this.interm += String.fromCharCode(c); this.state = S.CSI_INTERMEDIATE; }
        else if (c >= 0x40 && c <= 0x7e) { this._csiFinal(c); }
        else { /* 0x7f */ }
        break;

      case S.CSI_PARAM:
        if (c <= 0x1f) { this.h.execute(c); }
        else if (c >= 0x30 && c <= 0x39) { this._param(c - 0x30); }
        else if (c === 0x3a) { this._subSep(); }
        else if (c === 0x3b) { this._pushParam(); }
        else if (c >= 0x3c && c <= 0x3f) { this.state = S.CSI_IGNORE; }   // private marker out of place
        else if (c >= 0x20 && c <= 0x2f) { this.interm += String.fromCharCode(c); this.state = S.CSI_INTERMEDIATE; }
        else if (c >= 0x40 && c <= 0x7e) { this._csiFinal(c); }
        else { /* 0x7f */ }
        break;

      case S.CSI_INTERMEDIATE:
        if (c <= 0x1f) { this.h.execute(c); }
        else if (c >= 0x20 && c <= 0x2f) { this.interm += String.fromCharCode(c); }
        else if (c >= 0x30 && c <= 0x3f) { this.state = S.CSI_IGNORE; }
        else if (c >= 0x40 && c <= 0x7e) { this._csiFinal(c); }
        else { /* 0x7f */ }
        break;

      case S.CSI_IGNORE:
        if (c >= 0x40 && c <= 0x7e) { this.state = S.GROUND; }
        else if (c <= 0x1f) { this.h.execute(c); }
        break;

      case S.OSC_STRING:
        if (c === 0x07) { this.h.osc(this.str); this.state = S.GROUND; }   // BEL terminator
        else if (c >= 0x20 || c >= 0xa0) { if (this.str.length < MAX_OSC) this.str += String.fromCharCode(c); }
        // other C0 inside OSC are ignored (ESC handled at the top as ST)
        break;

      case S.DCS_ENTRY:
      case S.DCS_PARAM:
      case S.DCS_INTERMEDIATE:
        this._dcsCollect(c);
        break;

      case S.DCS_PASSTHROUGH:
        if (c === 0x07) { if (this.h.dcs) this.h.dcs(this.params, this.interm, this.dcsFinal, this.str); this.state = S.GROUND; }
        else if (this.str.length < MAX_OSC) this.str += String.fromCharCode(c);
        break;

      case S.DCS_IGNORE:
      case S.SOS_PM_APC:
        /* swallow until ST (ESC handled at the top) */
        break;
    }
  }

  _ground(c) {
    if (c <= 0x1f) { this.h.execute(c); return; }
    // C1 (0x80-0x9F): a handful open sequences, the rest execute. PowerShell emits 7-bit ESC forms,
    // so this path is rare, but honoring it keeps us a real terminal, not a 90%-one.
    switch (c) {
      case 0x90: this.state = S.DCS_ENTRY; this._clear(); break;   // DCS
      case 0x98: case 0x9e: case 0x9f: this.state = S.SOS_PM_APC; break;   // SOS/PM/APC
      case 0x9b: this.state = S.CSI_ENTRY; this._clear(); break;   // CSI
      case 0x9d: this.state = S.OSC_STRING; this._clear(); break;  // OSC
      case 0x9c: break;                                            // ST — bare, nothing open
      default:   this.h.execute(c);
    }
  }

  _escFinal(c) {
    switch (c) {
      case 0x5b: this.state = S.CSI_ENTRY; this._clear(); return;   // '[' CSI
      case 0x5d: this.state = S.OSC_STRING; this._clear(); return;  // ']' OSC
      case 0x50: this.state = S.DCS_ENTRY; this._clear(); return;   // 'P' DCS
      case 0x58: case 0x5e: case 0x5f: this.state = S.SOS_PM_APC; return;   // X/^/_ SOS/PM/APC
      default:   this.h.esc(this.interm, c); this.state = S.GROUND;
    }
  }

  _csiFinal(c) { this._pushParam(); this.h.csi(this.params, this.interm, c); this.state = S.GROUND; }

  _dcsCollect(c) {
    if (c >= 0x30 && c <= 0x39) { this._param(c - 0x30); this.state = S.DCS_PARAM; }
    else if (c === 0x3a) { this._subSep(); this.state = S.DCS_PARAM; }
    else if (c === 0x3b) { this._pushParam(); this.state = S.DCS_PARAM; }
    else if (c >= 0x3c && c <= 0x3f) { this.interm += String.fromCharCode(c); this.state = S.DCS_PARAM; }
    else if (c >= 0x20 && c <= 0x2f) { this.interm += String.fromCharCode(c); this.state = S.DCS_INTERMEDIATE; }
    else if (c >= 0x40 && c <= 0x7e) { this._pushParam(); this.dcsFinal = c; this.str = ''; this.state = S.DCS_PASSTHROUGH; }
    else { this.state = S.DCS_IGNORE; }
  }
}
