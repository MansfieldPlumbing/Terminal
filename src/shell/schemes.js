/* /schemes.js — terminal/ANSI color-scheme engine (the DOM-free source of truth).
 *
 * SHELL-SPEC §6: schemes.js owns the terminal palette, structured for per-app override.
 * Separate concern from themes.js (which owns the OS chrome look). This module holds NO DOM —
 * it is data + persistence + the xterm mapping + a change bus. The picker UI is schemes-editor.js.
 *
 * Scheme shape = Windows Terminal scheme JSON (the lingua franca; maps ~1:1 onto xterm ITheme):
 *   { name, colors: { background, foreground, cursorColor, selectionBackground,
 *                     black, brightBlack, red, brightRed, green, brightGreen,
 *                     yellow, brightYellow, blue, brightBlue, purple, brightPurple,
 *                     cyan, brightCyan, white, brightWhite } }
 * NB: WT uses purple/brightPurple; xterm uses magenta/brightMagenta — toXterm() bridges that.
 */
(function () {
  'use strict';

  // --- Seed schemes (the three from the WT reference; salvaged-canonical values). Frozen. ---
  const SEED = Object.freeze([
    { name: 'Campbell', colors: {
      background:'#0C0C0C', foreground:'#CCCCCC', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#0C0C0C', brightBlack:'#767676', red:'#C50F1F', brightRed:'#E74856',
      green:'#13A10E', brightGreen:'#16C60C', yellow:'#C19C00', brightYellow:'#F9F1A5',
      blue:'#0037DA', brightBlue:'#3B78FF', purple:'#881798', brightPurple:'#B4009E',
      cyan:'#3A96DD', brightCyan:'#61D6D6', white:'#CCCCCC', brightWhite:'#F2F2F2' } },
    { name: 'Campbell Powershell', isDefault: true, colors: {
      background:'#012456', foreground:'#CCCCCC', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#0C0C0C', brightBlack:'#767676', red:'#C50F1F', brightRed:'#E74856',
      green:'#13A10E', brightGreen:'#16C60C', yellow:'#C19C00', brightYellow:'#F9F1A5',
      blue:'#0037DA', brightBlue:'#3B78FF', purple:'#881798', brightPurple:'#B4009E',
      cyan:'#3A96DD', brightCyan:'#61D6D6', white:'#CCCCCC', brightWhite:'#F2F2F2' } },
    { name: 'Dark+', colors: {
      background:'#1E1E1E', foreground:'#CCCCCC', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#000000', brightBlack:'#666666', red:'#CD3131', brightRed:'#F14C4C',
      green:'#0DBC79', brightGreen:'#23D18B', yellow:'#E5E510', brightYellow:'#F5F543',
      blue:'#2472C8', brightBlue:'#3B8EEA', purple:'#BC3FBC', brightPurple:'#D670D6',
      cyan:'#11A8CD', brightCyan:'#29B8DB', white:'#E5E5E5', brightWhite:'#E5E5E5' } },
    // --- Below are stock Windows Terminal defaults (seeded from memory — verify hexes vs defaults.json). ---
    { name: 'Vintage', colors: {
      background:'#000000', foreground:'#C0C0C0', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#000000', brightBlack:'#808080', red:'#800000', brightRed:'#FF0000',
      green:'#008000', brightGreen:'#00FF00', yellow:'#808000', brightYellow:'#FFFF00',
      blue:'#000080', brightBlue:'#0000FF', purple:'#800080', brightPurple:'#FF00FF',
      cyan:'#008080', brightCyan:'#00FFFF', white:'#C0C0C0', brightWhite:'#FFFFFF' } },
    { name: 'One Half Dark', colors: {
      background:'#282C34', foreground:'#DCDFE4', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#282C34', brightBlack:'#5A6374', red:'#E06C75', brightRed:'#E06C75',
      green:'#98C379', brightGreen:'#98C379', yellow:'#E5C07B', brightYellow:'#E5C07B',
      blue:'#61AFEF', brightBlue:'#61AFEF', purple:'#C678DD', brightPurple:'#C678DD',
      cyan:'#56B6C2', brightCyan:'#56B6C2', white:'#DCDFE4', brightWhite:'#DCDFE4' } },
    { name: 'Solarized Dark', colors: {
      background:'#002B36', foreground:'#839496', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#073642', brightBlack:'#002B36', red:'#DC322F', brightRed:'#CB4B16',
      green:'#859900', brightGreen:'#586E75', yellow:'#B58900', brightYellow:'#657B83',
      blue:'#268BD2', brightBlue:'#839496', purple:'#D33682', brightPurple:'#6C71C4',
      cyan:'#2AA198', brightCyan:'#93A1A1', white:'#EEE8D5', brightWhite:'#FDF6E3' } },
    { name: 'Tango Dark', colors: {
      background:'#000000', foreground:'#D3D7CF', cursorColor:'#FFFFFF', selectionBackground:'#FFFFFF',
      black:'#000000', brightBlack:'#555753', red:'#CC0000', brightRed:'#EF2929',
      green:'#4E9A06', brightGreen:'#8AE234', yellow:'#C4A000', brightYellow:'#FCE94F',
      blue:'#3465A4', brightBlue:'#729FCF', purple:'#75507B', brightPurple:'#AD7FA8',
      cyan:'#06989A', brightCyan:'#34E2E2', white:'#D3D7CF', brightWhite:'#EEEEEC' } },
  ]);

  // The default scheme is the one FLAGGED isDefault, not a list position — fallbacks derive from it.
  const DEFAULT_NAME = (SEED.find(s => s.isDefault) || SEED[0]).name;

  const K_USER   = 'ss.schemes.user';      // user-defined/edited schemes (array)
  const K_ACTIVE = 'ss.schemes.active';    // global active scheme name
  const K_APP    = 'ss.schemes.active.';   // + appId  → per-app override

  // The canonical color slots, in display order (matches the swatch strip + editor grid).
  const SLOTS = Object.freeze(['black','red','green','yellow','blue','purple','cyan','white']);
  const UI_SLOTS = Object.freeze(['foreground','background','cursorColor','selectionBackground']);
  const brightOf = (k) => 'bright' + k.charAt(0).toUpperCase() + k.slice(1);

  const listeners = new Set();
  const clone = (o) => JSON.parse(JSON.stringify(o));

  function readUser() {
    try { const s = localStorage.getItem(K_USER); return s ? JSON.parse(s) : []; }
    catch { return []; }
  }
  function writeUser(arr) {
    try { localStorage.setItem(K_USER, JSON.stringify(arr)); } catch {}
  }

  /** All schemes: seed first, then user. A user scheme with the same name shadows the seed. */
  function list() {
    const user = readUser();
    const byName = new Map();
    SEED.forEach(s => byName.set(s.name, clone(s)));
    user.forEach(s => byName.set(s.name, clone(s)));
    return Array.from(byName.values());
  }

  function get(name) { return list().find(s => s.name === name) || null; }

  /** Active scheme NAME for a context: per-app override → global → first seed. */
  function activeName(appId) {
    try {
      if (appId) {
        const a = localStorage.getItem(K_APP + appId);
        if (a && get(a)) return a;
      }
      const g = localStorage.getItem(K_ACTIVE);
      if (g && get(g)) return g;
    } catch {}
    return DEFAULT_NAME;
  }

  function active(appId) { return get(activeName(appId)); }

  /** Set the active scheme. appId set → per-app override; omitted → global default. */
  function setActive(name, appId) {
    if (!get(name)) return false;
    try {
      if (appId) localStorage.setItem(K_APP + appId, name);
      else localStorage.setItem(K_ACTIVE, name);
    } catch {}
    emit({ kind: 'active', name, appId: appId || null });
    return true;
  }

  /** Add or update a user scheme (matched by name), persist, notify. Returns the saved scheme. */
  function save(scheme) {
    if (!scheme || !scheme.name) return null;
    const user = readUser();
    const i = user.findIndex(s => s.name === scheme.name);
    const rec = clone(scheme);
    if (i >= 0) user[i] = rec; else user.push(rec);
    writeUser(user);
    emit({ kind: 'save', name: rec.name });
    return rec;
  }

  /** Remove a user scheme by name (seed schemes cannot be removed). */
  function remove(name) {
    const user = readUser().filter(s => s.name !== name);
    writeUser(user);
    if (activeName() === name && !get(name)) setActive(DEFAULT_NAME);
    emit({ kind: 'remove', name });
  }

  /** Map a scheme (or name) to an xterm.js ITheme. purple→magenta, cursorColor→cursor. */
  function toXterm(schemeOrName) {
    const s = typeof schemeOrName === 'string' ? get(schemeOrName) : schemeOrName;
    if (!s || !s.colors) return null;
    const c = s.colors;
    // WT keeps selectionBackground opaque; xterm paints it OVER the glyphs — bake a 0x40 alpha into
    // 6-digit hexes so selected text stays legible (explicit 8-digit values pass through untouched).
    const sel = /^#[0-9a-fA-F]{6}$/.test(c.selectionBackground || '')
      ? c.selectionBackground + '40' : c.selectionBackground;
    return {
      background: c.background, foreground: c.foreground,
      cursor: c.cursorColor, cursorAccent: c.background,
      selectionBackground: sel,
      black: c.black, brightBlack: c.brightBlack,
      red: c.red, brightRed: c.brightRed,
      green: c.green, brightGreen: c.brightGreen,
      yellow: c.yellow, brightYellow: c.brightYellow,
      blue: c.blue, brightBlue: c.brightBlue,
      magenta: c.purple, brightMagenta: c.brightPurple,
      cyan: c.cyan, brightCyan: c.brightCyan,
      white: c.white, brightWhite: c.brightWhite,
    };
  }

  function onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }
  function emit(evt) { listeners.forEach(fn => { try { fn(evt); } catch {} }); }

  window.Schemes = {
    SEED, SLOTS, UI_SLOTS, brightOf,
    list, get, activeName, active, setActive, save, remove, toXterm, onChange,
    /** Convenience for a fresh user scheme based on a seed (used by the editor's "Add new"). */
    blank(baseName) {
      const base = clone(get(baseName) || get(DEFAULT_NAME));
      base.isDefault = false;
      base.name = 'Custom Scheme';
      return base;
    },
  };
})();
