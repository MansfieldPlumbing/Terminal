// codeedit.js — a vanilla, dependency-free, monaco-LIKE code editor.
//
// WHY IT EXISTS: Monaco is 12 MB / 113 files (a whole TypeScript language service in a web worker) —
// pointless on a phone and the antithesis of the home-roll doctrine. This is ~1 file of vanilla JS:
// gutter line numbers, regex syntax highlighting, active-line, auto-indent, bracket-close, Ctrl+S.
//
// THE TECHNIQUE (react-simple-code-editor / CodeJar lineage): a transparent native <textarea> over a
// syntax-highlighted <pre>, scroll-synced, with a gutter column. The textarea owns input — so the
// caret, selection, IME composition, touch handles, and undo/redo are the OS's own (Monaco hand-rolls
// all of these and they are the exact things that misbehave on Android). The <pre> only paints color.
//
// Colors come from CSS vars (theme contract) with sane fallbacks, so it re-skins with the shell.
//
// API:
//   const ed = new CodeEdit(hostEl, { value, language, readOnly, tabSize });
//   ed.value            // get/set text
//   ed.language         // get/set language id ('powershell'|'json'|'markdown'|'javascript'|'csharp'|'css'|'html'|'xml'|'text')
//   ed.dirty            // true once edited since the last markSaved()
//   ed.markSaved()      // reset the dirty baseline (call after Save/Open)
//   ed.selectionText    // the selected text ('' if none)
//   ed.focus()          // focus the input (pops the IME)
//   ed.blur()
//   ed.onChange(fn)     // fn(value)
//   ed.onSave(fn)       // fn(value) — Ctrl/Cmd+S
//   ed.find(q)          // select the next occurrence of q from the caret (wraps)
//   ed.layout()         // recompute sizes (call on container resize)
//   ed.destroy()

const LANGS = {
  // PowerShell — the load-bearing one (this is a PowerShell terminal). Order matters: comments and
  // strings (incl. <# block #> and here-strings @"..."@ / @'...'@) win before keywords/vars.
  powershell: {
    aliases: ['ps1', 'psm1', 'psd1', 'ps'],
    rx: String.raw`(?<comment><\#[\s\S]*?\#>|\#[^\n]*)` +
        String.raw`|(?<string>@"[\s\S]*?"@|@'[\s\S]*?'@|"(?:[^"` + '`' + String.raw`]|` + '`' + String.raw`.)*"|'(?:[^']|'')*')` +
        String.raw`|(?<variable>\$(?:\{[^}]*\}|[\w:]+))` +
        String.raw`|(?<keyword>\b(?:if|elseif|else|switch|foreach|for|while|do|until|break|continue|return|function|filter|param|begin|process|end|try|catch|finally|throw|trap|class|enum|using|namespace|in|workflow|configuration|dynamicparam|exit)\b)` +
        String.raw`|(?<operator>-(?:eq|ne|gt|ge|lt|le|like|notlike|match|notmatch|contains|notcontains|in|notin|replace|split|join|is|isnot|as|and|or|not|xor|band|bor|bxor|shl|shr|f)\b)` +
        String.raw`|(?<function>\b[A-Z][a-zA-Z]+-[A-Z][a-zA-Z]+\b)` +
        String.raw`|(?<number>\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[kmgtKMGT]b)?\b)` +
        String.raw`|(?<property>(?<=\.)[A-Za-z_]\w*)`,
  },
  json: {
    rx: String.raw`(?<property>"(?:[^"\\]|\\.)*"(?=\s*:))` +
        String.raw`|(?<string>"(?:[^"\\]|\\.)*")` +
        String.raw`|(?<keyword>\b(?:true|false|null)\b)` +
        String.raw`|(?<number>-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)`,
  },
  javascript: {
    aliases: ['js', 'jsx', 'ts', 'tsx', 'typescript', 'mjs', 'cjs'],
    rx: String.raw`(?<comment>/\*[\s\S]*?\*/|//[^\n]*)` +
        String.raw`|(?<string>` + '`' + String.raw`(?:[^` + '`' + String.raw`\\]|\\.)*` + '`' + String.raw`|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')` +
        String.raw`|(?<keyword>\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|default|break|continue|new|class|extends|super|this|typeof|instanceof|in|of|async|await|yield|import|export|from|as|try|catch|finally|throw|delete|void|null|undefined|true|false)\b)` +
        String.raw`|(?<function>\b[A-Za-z_$][\w$]*(?=\s*\())` +
        String.raw`|(?<number>\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)`,
  },
  csharp: {
    aliases: ['cs'],
    rx: String.raw`(?<comment>/\*[\s\S]*?\*/|//[^\n]*)` +
        String.raw`|(?<string>@"(?:[^"]|"")*"|\$?"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')` +
        String.raw`|(?<keyword>\b(?:using|namespace|class|struct|interface|enum|record|public|private|protected|internal|static|readonly|const|sealed|abstract|virtual|override|async|await|var|new|return|if|else|for|foreach|while|do|switch|case|default|break|continue|try|catch|finally|throw|in|out|ref|is|as|null|true|false|this|base|void|get|set)\b)` +
        String.raw`|(?<type>\b(?:int|long|short|byte|bool|string|char|double|float|decimal|object|void|Task|List|Dictionary|IEnumerable|string\[\])\b)` +
        String.raw`|(?<function>\b[A-Za-z_]\w*(?=\s*\())` +
        String.raw`|(?<number>\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?[fdmFDM]?\b)`,
  },
  css: {
    rx: String.raw`(?<comment>/\*[\s\S]*?\*/)` +
        String.raw`|(?<string>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')` +
        String.raw`|(?<keyword>(?<=[\{;\s])[a-z-]+(?=\s*:))` +
        String.raw`|(?<variable>--[\w-]+|\$[\w-]+)` +
        String.raw`|(?<number>#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b)` +
        String.raw`|(?<type>\.[\w-]+|\#[\w-]+|@[\w-]+)`,
  },
  markdown: {
    aliases: ['md'],
    rx: String.raw`(?<keyword>^\#{1,6}[^\n]*)` +
        String.raw`|(?<string>` + '`{1,3}' + String.raw`[\s\S]*?` + '`{1,3}' + String.raw`)` +
        String.raw`|(?<type>\*\*[^*\n]+\*\*|__[^_\n]+__)` +
        String.raw`|(?<function>\[[^\]\n]*\]\([^)\n]*\))` +
        String.raw`|(?<operator>^\s*(?:[-*+]|\d+\.)\s)` +
        String.raw`|(?<comment>^>\s[^\n]*)`,
    flags: 'gm',
  },
  html: {
    aliases: ['xml', 'svg', 'obp'],
    rx: String.raw`(?<comment><!--[\s\S]*?-->)` +
        String.raw`|(?<tag></?[a-zA-Z][\w:-]*)` +
        String.raw`|(?<string>"(?:[^"]*)"|'(?:[^']*)')` +
        String.raw`|(?<property>\b[a-zA-Z-]+(?=\s*=))`,
  },
  text: { rx: null },
};

// Resolve an id or extension/alias to a language key.
function resolveLang(id) {
  if (!id) return 'text';
  id = String(id).toLowerCase().replace(/^\./, '');
  if (LANGS[id]) return id;
  for (const k of Object.keys(LANGS)) {
    const a = LANGS[k].aliases;
    if (a && a.indexOf(id) >= 0) return k;
  }
  return 'text';
}

const _compiled = {};
function tokenizerFor(langKey) {
  if (langKey in _compiled) return _compiled[langKey];
  const def = LANGS[langKey];
  let re = null;
  if (def && def.rx) { try { re = new RegExp(def.rx, def.flags || 'g'); } catch (_) { re = null; } }
  return (_compiled[langKey] = re);
}

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };
function esc(s) { return s.replace(/[&<>]/g, (c) => ESC[c]); }

// Highlight `code` for `langKey` → HTML string. One sticky-regex pass with named groups; the gap
// between matches is plain escaped text. A trailing newline gets a zero-width filler so the last
// (empty) line still has height and the gutter count matches.
function highlight(code, langKey) {
  const re = tokenizerFor(langKey);
  if (!re) return esc(code) + '\n';
  re.lastIndex = 0;
  let out = '', last = 0, m;
  while ((m = re.exec(code)) !== null) {
    if (m.index < last) { re.lastIndex = last + 1; continue; }   // overlap guard
    if (m.index > last) out += esc(code.slice(last, m.index));
    let type = 'plain';
    for (const g in m.groups) { if (m.groups[g] != null) { type = g; break; } }
    out += '<span class="ce-' + type + '">' + esc(m[0]) + '</span>';
    last = m.index + m[0].length;
    if (m[0].length === 0) re.lastIndex++;                       // never spin on a zero-width match
  }
  out += esc(code.slice(last));
  return out + '\n';
}

const STYLE_ID = 'codeedit-style';
function injectStyle() {
  if (document.getElementById(STYLE_ID)) return;
  const css = `
.ce-root{position:relative;display:flex;width:100%;height:100%;overflow:hidden;
  font-family:var(--font-mono,ui-monospace,monospace);font-size:var(--ce-font,13px);
  line-height:var(--ce-line,1.5);background:var(--bg,#111);color:var(--fg,#eee);
  --ce-pad:10px;tab-size:var(--ce-tab,2);-moz-tab-size:var(--ce-tab,2);}
.ce-gutter{flex:0 0 auto;overflow:hidden;text-align:right;user-select:none;
  padding:var(--ce-pad) 6px var(--ce-pad) 10px;color:var(--muted,#777);
  background:color-mix(in srgb,var(--surface,#1a1a1a) 60%,transparent);
  border-right:1px solid var(--border,rgba(255,255,255,.08));white-space:pre;}
.ce-gutter b{display:block;font-weight:400;opacity:.55;}
.ce-gutter b.ce-active{opacity:1;color:var(--fg,#eee);}
.ce-area{position:relative;flex:1 1 auto;overflow:auto;}
.ce-area>pre,.ce-area>textarea{margin:0;padding:var(--ce-pad);border:0;
  font:inherit;line-height:inherit;letter-spacing:0;white-space:pre;
  tab-size:inherit;-moz-tab-size:inherit;overflow-wrap:normal;word-break:normal;}
.ce-hl{position:relative;pointer-events:none;min-width:100%;min-height:100%;
  box-sizing:border-box;color:var(--fg,#eee);}
.ce-active-bg{position:absolute;left:0;right:0;height:calc(var(--ce-line,1.5)*1em);
  background:color-mix(in srgb,var(--fg,#fff) 7%,transparent);pointer-events:none;}
.ce-input{position:absolute;top:0;left:0;width:100%;height:100%;box-sizing:border-box;
  resize:none;outline:none;background:transparent;color:transparent;
  caret-color:var(--accent,#4ea1ff);overflow:hidden;
  -webkit-text-fill-color:transparent;}
.ce-input::selection{background:color-mix(in srgb,var(--accent,#4ea1ff) 35%,transparent);}
/* token palette — theme vars with code-friendly fallbacks; a theme can override any --ce-* */
.ce-comment{color:var(--ce-comment,#6a9955);font-style:italic;}
.ce-string{color:var(--ce-string,#ce9178);}
.ce-keyword{color:var(--ce-keyword,var(--accent,#569cd6));font-weight:600;}
.ce-variable{color:var(--ce-variable,#9cdcfe);}
.ce-function{color:var(--ce-function,#dcdcaa);}
.ce-number{color:var(--ce-number,#b5cea8);}
.ce-type{color:var(--ce-type,#4ec9b0);}
.ce-operator{color:var(--ce-operator,#d4d4d4);}
.ce-property{color:var(--ce-property,#9cdcfe);}
.ce-tag{color:var(--ce-tag,var(--accent,#569cd6));}
.ce-plain{color:inherit;}`;
  const el = document.createElement('style');
  el.id = STYLE_ID; el.textContent = css;
  document.head.appendChild(el);
}

const CLOSERS = { '(': ')', '[': ']', '{': '}', '"': '"', "'": "'", '`': '`' };

export class CodeEdit {
  constructor(host, opts = {}) {
    injectStyle();
    this.host = host;
    this._lang = resolveLang(opts.language);
    this._changeCbs = [];
    this._saveCbs = [];
    this._cursorCbs = [];
    this._savedValue = opts.value || '';
    this._lineCount = -1;

    host.classList.add('ce-root');
    if (opts.tabSize) host.style.setProperty('--ce-tab', String(opts.tabSize));
    host.innerHTML =
      '<div class="ce-gutter"></div>' +
      '<div class="ce-area">' +
        '<pre class="ce-hl"><div class="ce-active-bg" hidden></div><code></code></pre>' +
        '<textarea class="ce-input" spellcheck="false" autocapitalize="off" ' +
          'autocomplete="off" autocorrect="off" wrap="off"></textarea>' +
      '</div>';
    this.gutter = host.querySelector('.ce-gutter');
    this.area = host.querySelector('.ce-area');
    this.code = host.querySelector('.ce-hl code');
    this.activeBg = host.querySelector('.ce-active-bg');
    this.ta = host.querySelector('.ce-input');
    if (opts.readOnly) this.ta.readOnly = true;

    this.ta.value = opts.value || '';
    this._bind();
    this._render();
  }

  _bind() {
    const ta = this.ta;
    ta.addEventListener('input', () => { this._render(); this._emitChange(); });
    ta.addEventListener('scroll', () => this._syncScroll());
    ta.addEventListener('keyup', () => this._syncActive());
    ta.addEventListener('click', () => this._syncActive());
    ta.addEventListener('keydown', (e) => this._onKey(e));
  }

  _onKey(e) {
    const ta = this.ta;
    // Save
    if ((e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) {
      e.preventDefault(); this._saveCbs.forEach((f) => { try { f(this.value); } catch (_) {} }); return;
    }
    // Tab → indent (spaces from --ce-tab; default 2). Shift+Tab → outdent the line start.
    if (e.key === 'Tab') {
      e.preventDefault();
      const n = parseInt(getComputedStyle(this.host).getPropertyValue('--ce-tab')) || 2;
      const pad = ' '.repeat(n);
      const { selectionStart: s, selectionEnd: en, value: v } = ta;
      if (e.shiftKey) {
        const ls = v.lastIndexOf('\n', s - 1) + 1;
        const cut = v.slice(ls).match(/^[ \t]{1,}/);
        if (cut) { const k = Math.min(cut[0].length, n); ta.value = v.slice(0, ls) + v.slice(ls + k); ta.selectionStart = ta.selectionEnd = Math.max(ls, s - k); }
      } else {
        ta.value = v.slice(0, s) + pad + v.slice(en); ta.selectionStart = ta.selectionEnd = s + pad.length;
      }
      this._render(); this._emitChange(); return;
    }
    // Enter → keep the current line's leading whitespace (auto-indent); +1 level after an opener.
    if (e.key === 'Enter') {
      const { selectionStart: s, value: v } = ta;
      const ls = v.lastIndexOf('\n', s - 1) + 1;
      const lead = (v.slice(ls, s).match(/^[ \t]*/) || [''])[0];
      const prev = v[s - 1];
      const n = parseInt(getComputedStyle(this.host).getPropertyValue('--ce-tab')) || 2;
      const extra = (prev === '{' || prev === '(' || prev === '[') ? ' '.repeat(n) : '';
      if (lead || extra) {
        e.preventDefault();
        const ins = '\n' + lead + extra;
        ta.value = v.slice(0, s) + ins + v.slice(ta.selectionEnd);
        ta.selectionStart = ta.selectionEnd = s + ins.length;
        this._render(); this._emitChange();
      }
      return;
    }
    // Auto-close brackets/quotes around an empty selection.
    if (CLOSERS[e.key] && ta.selectionStart === ta.selectionEnd) {
      const { selectionStart: s, value: v } = ta;
      e.preventDefault();
      const close = CLOSERS[e.key];
      ta.value = v.slice(0, s) + e.key + close + v.slice(s);
      ta.selectionStart = ta.selectionEnd = s + 1;
      this._render(); this._emitChange();
    }
  }

  _render() {
    const v = this.ta.value;
    this.code.innerHTML = highlight(v, this._lang);
    // gutter — only rebuild when the line count changes (cheap on every keystroke otherwise)
    const lines = v.split('\n').length;
    if (lines !== this._lineCount) {
      this._lineCount = lines;
      let g = '';
      for (let i = 1; i <= lines; i++) g += '<b>' + i + '</b>';
      this.gutter.innerHTML = g;
    }
    this._syncScroll();
    this._syncActive();
  }

  _syncScroll() {
    // pre sits under the textarea in the same scroller; the gutter is a separate column we offset.
    this.gutter.scrollTop = this.ta.scrollTop;
    this.gutter.style.transform = 'translateY(' + (-this.ta.scrollTop) + 'px)';
  }

  _syncActive() {
    const v = this.ta.value, pos = this.ta.selectionStart;
    const line = v.slice(0, pos).split('\n').length - 1;       // 0-based
    const lh = parseFloat(getComputedStyle(this.host).getPropertyValue('--ce-line')) || 1.5;
    const fs = parseFloat(getComputedStyle(this.host).fontSize) || 13;
    const pad = 10;
    this.activeBg.hidden = false;
    this.activeBg.style.top = (pad + line * lh * fs) + 'px';
    this.activeBg.style.height = (lh * fs) + 'px';
    const kids = this.gutter.children;
    if (this._activeGut != null && kids[this._activeGut]) kids[this._activeGut].classList.remove('ce-active');
    if (kids[line]) { kids[line].classList.add('ce-active'); this._activeGut = line; }
    if (this._cursorCbs.length) { const c = this.cursor; this._cursorCbs.forEach((f) => { try { f(c); } catch (_) {} }); }
  }

  // 1-based {line, col} of the caret (selectionStart).
  get cursor() {
    const p = this.ta.selectionStart, before = this.ta.value.slice(0, p);
    return { line: before.split('\n').length, col: p - (before.lastIndexOf('\n') + 1) + 1 };
  }

  _emitChange() { const v = this.value; this._changeCbs.forEach((f) => { try { f(v); } catch (_) {} }); }

  // ---- public API ----
  get value() { return this.ta.value; }
  set value(v) { this.ta.value = v == null ? '' : String(v); this._render(); }
  get language() { return this._lang; }
  set language(id) { this._lang = resolveLang(id); this._render(); }
  get dirty() { return this.ta.value !== this._savedValue; }
  markSaved() { this._savedValue = this.ta.value; }
  get selectionText() { return this.ta.value.slice(this.ta.selectionStart, this.ta.selectionEnd); }
  focus() { this.ta.focus(); }
  blur() { this.ta.blur(); }
  onChange(fn) { if (typeof fn === 'function') this._changeCbs.push(fn); }
  onSave(fn) { if (typeof fn === 'function') this._saveCbs.push(fn); }
  onCursor(fn) { if (typeof fn === 'function') this._cursorCbs.push(fn); }

  // ---- view toggles (the subset edit.obp drives) ----
  setGutter(on) { this.gutter.style.display = on ? '' : 'none'; }
  setWrap(on) {
    const ws = on ? 'pre-wrap' : 'pre';
    this.code.style.whiteSpace = ws; this.ta.style.whiteSpace = ws;
    this.ta.wrap = on ? 'soft' : 'off';
  }
  setFontSize(px) { this.host.style.setProperty('--ce-font', (px | 0) + 'px'); this._syncActive(); }
  // Replace the current selection (or insert at the caret) — native setRangeText keeps the undo stack.
  replaceSelection(text) { this.ta.setRangeText(text, this.ta.selectionStart, this.ta.selectionEnd, 'end'); this._render(); this._emitChange(); }
  layout() { this._syncScroll(); this._syncActive(); }

  // Select the next occurrence of `q` from the caret (case-insensitive), wrapping once.
  find(q) {
    if (!q) return false;
    const v = this.ta.value.toLowerCase(), needle = q.toLowerCase();
    let i = v.indexOf(needle, this.ta.selectionEnd);
    if (i < 0) i = v.indexOf(needle, 0);
    if (i < 0) return false;
    this.ta.focus();
    this.ta.setSelectionRange(i, i + q.length);
    this._syncActive();
    // scroll the match into view
    const line = this.ta.value.slice(0, i).split('\n').length - 1;
    const fs = parseFloat(getComputedStyle(this.host).fontSize) || 13;
    const lh = parseFloat(getComputedStyle(this.host).getPropertyValue('--ce-line')) || 1.5;
    this.ta.scrollTop = Math.max(0, line * lh * fs - this.area.clientHeight / 2);
    this._syncScroll();
    return true;
  }

  destroy() { this.host.classList.remove('ce-root'); this.host.replaceChildren(); this._changeCbs = []; this._saveCbs = []; }
}

export default CodeEdit;
