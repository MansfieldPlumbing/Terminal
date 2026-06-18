/* themes.js — the chrome theme engine. Owns the OS-wide look as NAMED THEMES.
 *
 * A "theme" is a bundle of the canonical CSS vars (see theme.css). themes.js writes them onto <html>,
 * persists the active theme name (+ any user overrides) to localStorage, and live-syncs across every
 * iframe via the storage event (change it in Settings → every open surface re-skins instantly).
 *
 * Naming (Cutler-clean, no "edgy hacker" signal):
 *   'Light' — clean neutral light, blue highlight.
 *   'Dark'  — clean neutral dark, blue highlight.
 *   'XP'    — retro Windows XP / luna: blue taskbar, GREEN start, cloud-glass over the sky shader.
 *             THE PRERELEASE DEFAULT (owner call; themes.json seed agrees).
 *   'Zune'  — flavored dark, Zune orange.
 *   'Auto'  — not a bundle: resolves to Dark/Light from the OS prefers-color-scheme, live.
 * Rule (SHELL-SPEC §6): blue is the chrome accent; --accent-2 defaults to a solid blue in the
 * Light/Dark base bundles (magenta survives only as flavor in the XP skin). Don't reintroduce
 * magenta-on-black as a theme.
 *
 * Authority note: theme is pure presentation / zero authority, so it lives client-side. The backend
 * /theme endpoint is OPTIONAL — if it 404s we fall back to localStorage → the OOBE default, silently.
 * We NEVER surface a 404 (project rule). schemes.js owns the terminal ANSI palette — separate concern.
 */
(function () {
  'use strict';
  var KEY = 'ss-theme';

  // --- Named themes = var bundles. Add a theme by appending an entry. --------------------------
  var THEMES = {
    'Light': {          // clean neutral light — blue highlight, blue secondary
      label: 'Light', mode: 'light', wallpaper: 'solid', desc: 'Clean light',
      bg: '#ffffff', surface: '#f4f5f7', fg: '#1a1a1a', muted: '#6b7280',
      accent: '#2563eb', accent2: '#3b82f6', accentFg: '#ffffff',
      border: 'rgba(26,26,26,0.12)',
      taskbarRgb: '240,241,243', taskbarFg: '#1a1a1a',        // light glass bar, dark chips
      neon: '#2563eb', neonFg: '#ffffff',                     // blue start
      success: '#16a34a', error: '#dc2626',
      micaRgb: '250,250,252', micaOpacity: 0.66, micaStrongOpacity: 0.84, micaBlur: '30px', bgOpacity: 0.04,
      micaOffOpacity: 1, micaOffStrongOpacity: 1,
    },
    'Dark': {           // clean neutral dark, blue highlight (the matched pair to Light)
      label: 'Dark', mode: 'dark', wallpaper: 'solid', desc: 'Clean dark',
      bg: '#0e0f12', surface: '#15171c', fg: '#f2f2f2', muted: '#8b93a3',
      accent: '#2563eb', accent2: '#3b82f6', accentFg: '#ffffff',
      border: 'rgba(255,255,255,0.10)',
      taskbarRgb: '20,22,26', taskbarFg: '#f2f2f2',
      neon: '#2563eb', neonFg: '#ffffff',                     // blue start
      success: '#10b981', error: '#ef4444',
      micaRgb: '20,22,26', micaOpacity: 0.58, micaStrongOpacity: 0.82, micaBlur: '32px', bgOpacity: 0.22,
      micaOffOpacity: 1, micaOffStrongOpacity: 1,
    },
    'XP': {             // retro Windows XP / luna: BLUE taskbar, GREEN start (green highlight)
      label: 'XP', mode: 'light', wallpaper: 'sky', desc: 'Windows XP', custom: true,
      bg: '#ffffff', surface: '#f2f3f6', fg: '#15243f', muted: '#5a6b88',
      accent: '#2a6cf0', accent2: '#d80073', accentFg: '#ffffff',
      border: 'rgba(21,36,63,0.12)',
      taskbarRgb: '38,97,201', taskbarFg: '#ffffff',          // luna-blue bar, white chips
      neon: '#4ea72e', neonFg: '#ffffff',                     // the XP green start (the swatch shows green)
      success: '#2e7d32', error: '#d32f2f',
      micaRgb: '248,249,251', micaOpacity: 0.66, micaStrongOpacity: 0.84, micaBlur: '30px', bgOpacity: 0.04,
      micaOffOpacity: 1, micaOffStrongOpacity: 1,
    },
    'Zune': {           // flavored dark — Zune orange (orange highlight)
      label: 'Zune', mode: 'dark', wallpaper: 'solid', desc: 'Dark · orange', custom: true,
      bg: '#141414', surface: '#1c1c1c', fg: '#f2f2f2', muted: '#8a8a8a',
      accent: '#f7630c', accent2: '#ff9248', accentFg: '#ffffff',
      border: 'rgba(255,255,255,0.10)',
      taskbarRgb: '20,20,20', taskbarFg: '#f2f2f2',
      neon: '#f7630c', neonFg: '#ffffff',                     // orange Zune start button
      success: '#10b981', error: '#ef4444',
      micaRgb: '20,20,20', micaOpacity: 0.58, micaStrongOpacity: 0.82, micaBlur: '32px', bgOpacity: 0.22,
      micaOffOpacity: 1, micaOffStrongOpacity: 1,
    },
  };
  var DEFAULT_THEME = 'XP';                            // prerelease default: the XP/luna skin (owner call); Auto stays selectable
  var DEFAULTS = { theme: DEFAULT_THEME, transparency: 1 };

  function read() {
    try { return Object.assign({}, DEFAULTS, JSON.parse(localStorage.getItem(KEY) || '{}')); }
    catch (_) { return Object.assign({}, DEFAULTS); }
  }
  function write(t) { try { localStorage.setItem(KEY, JSON.stringify(t)); } catch (_) {} }
  function setVar(k, v) { document.documentElement.style.setProperty(k, v); }
  // 'Auto' follows the OS appearance (prefers-color-scheme) → the clean Dark/Light base bundle.
  function resolveName(name) {
    if (name === 'Auto') { try { return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'Dark' : 'Light'; } catch (_) { return 'Dark'; } }
    return name;
  }
  function bundle(name) { return THEMES[resolveName(name)] || THEMES[DEFAULT_THEME]; }

  // Paint the active theme (+ any user overrides) onto :root. This is the ONLY place vars are set.
  function apply(t) {
    t = t || read();
    var b = bundle(t.theme);
    // Lost truth, not a fallback: if the theme bundle never loaded (registry /themes empty and no seed),
    // there are no colors to paint — painting literals would be the silent paper-over the doctrine forbids.
    // Fault loudly instead. (With a seed bundle present this never fires; it is the fail-closed guard for
    // when the embedded copy is gone and /themes is the only truth.)
    if (!b || typeof b !== 'object' || b.bg == null) {
      if (window.Dg) { window.Dg.bugcheck('THEME_TRUTH_MISSING', 'themes.js', 'theme bundle "' + (t && t.theme) + '" not loaded (registry /themes empty?)'); return; }
    }
    var ov = t.overrides || {};            // optional per-var user tweaks
    var pick = function (k, d) { return (ov[k] != null) ? ov[k] : (b[k] != null ? b[k] : d); };

    setVar('--bg',        pick('bg', '#000'));
    setVar('--surface',   pick('surface', '#111'));
    setVar('--panel',     pick('surface', '#111'));
    setVar('--fg',        pick('fg', '#f2f2f2'));
    setVar('--text',      pick('fg', '#f2f2f2'));
    setVar('--muted',     pick('muted', '#878787'));
    setVar('--border',    pick('border', 'rgba(255,255,255,0.10)'));
    setVar('--line',      pick('border', 'rgba(255,255,255,0.10)'));
    var accent = pick('accent', '#0084ff');
    var accentFg = pick('accentFg', '#ffffff');
    setVar('--accent',    accent);
    setVar('--accent-2',  pick('accent2', '#0078D4'));
    setVar('--accent-fg', accentFg);
    // The start button's color. ATOMIC knob, but LINKED TO ACCENT by default (a theme/user can override —
    // 98-2002 sets it green). Its text defaults to the on-accent color so the glyph always contrasts.
    setVar('--neon',      pick('neon', accent));
    setVar('--neon-fg',   pick('neonFg', accentFg));
    setVar('--success',   pick('success', '#10b981'));
    setVar('--error',     pick('error', '#ef4444'));

    // Mica (the frosted-glass material) can be switched OFF. The OFF values are REGISTRY-DEFINED per
    // theme (micaOff*), so "solid surfaces" is a property of the theme object — not a UI magic literal.
    var micaOn = (t.mica !== false);
    var micaRgb = pick('micaRgb', '12,12,12');
    setVar('--mica-rgb',            micaRgb);
    setVar('--taskbar-rgb',         pick('taskbarRgb', micaRgb));   // taskbar tints independently; default=glass
    setVar('--taskbar-fg',          pick('taskbarFg', pick('fg', '#f2f2f2')));
    setVar('--mica-opacity',        String(micaOn ? pick('micaOpacity', 0.55) : pick('micaOffOpacity', 1)));
    setVar('--mica-strong-opacity', String(micaOn ? pick('micaStrongOpacity', 0.90) : pick('micaOffStrongOpacity', 1)));
    setVar('--mica-blur',           micaOn ? pick('micaBlur', '24px') : '0px');
    setVar('--bg-opacity',          String(pick('bgOpacity', 0.25)));
    // Presenter-surface mica: theme.css's html[data-mica="on"] rule color-mixes --surface down to
    // --mica-alpha and adds backdrop blur. OFF → 100% (solid) and the rule never matches. The
    // attribute repaints in every iframe because apply() runs there (boot + storage event).
    // --mica-strong-alpha is the floating-chrome tier (modals/menus/charms) — same derivation off the
    // theme's strong opacity so dialogs read a touch more opaque than docked panels but stay glass.
    // --transparency (the Settings slider, 0..1) actually modulates the glass now: it scales the surface
    // alpha the panels are color-mixed down to. mica OFF → solid (the slider is disabled there). At 1 this
    // is the theme's full glass (no change from before); lower it and panels thin out, revealing the
    // backdrop behind. Before, the slider moved a var nothing read.
    var tx = (t.transparency == null ? 1 : Math.max(0, Math.min(1, +t.transparency)));
    setVar('--mica-alpha',        Math.round((micaOn ? pick('micaOpacity', 0.8) * tx : 1) * 100) + '%');
    setVar('--mica-strong-alpha', Math.round((micaOn ? pick('micaStrongOpacity', 0.9) * tx : 1) * 100) + '%');
    document.documentElement.setAttribute('data-mica', micaOn ? 'on' : 'off');

    setVar('--transparency', String(t.transparency == null ? 1 : t.transparency));

    document.documentElement.setAttribute('data-theme', b.mode || 'dark');
    document.documentElement.setAttribute('data-theme-name', t.theme || DEFAULT_THEME);
    // (The in-app live wallpaper was retired 2026-06-11 — the system wallpaper (Wp/\Capability\Shader\*)
    // owns the animated layer now; a theme's `wallpaper` field is ignored if present.)
  }

  // --- Public API ---------------------------------------------------------------------------
  function set(patch) { var t = Object.assign(read(), patch || {}); write(t); apply(t); return t; }
  function get() { return read(); }
  function list() { return Object.keys(THEMES).map(function (k) { return { id: k, label: THEMES[k].label || k, mode: THEMES[k].mode, custom: !!THEMES[k].custom }; }); }
  function setTheme(name) { if (name !== 'Auto' && !THEMES[name]) return read(); return set({ theme: name }); }
  function setTransparency(v) { return set({ transparency: Math.max(0, Math.min(1, +v)) }); }
  // Mica on/off — a first-class engine state. OFF makes panels solid using the active theme's
  // registry-defined micaOff* values (apply() reads them). Persisted in ss-theme like the rest.
  function setMica(on) { return set({ mica: !!on }); }
  function getMica() { return read().mica !== false; }
  // Override a single var on top of the active theme (e.g. a custom accent). Pass null to clear one.
  function override(key, value) {
    var t = read(); t.overrides = t.overrides || {};
    if (value == null) delete t.overrides[key]; else t.overrides[key] = value;
    write(t); apply(t); return t;
  }
  // Back-compat shims (older surfaces call these) — now expressed as overrides.
  function setAccent(hex, hex2) { var t = read(); t.overrides = t.overrides || {}; t.overrides.accent = hex; if (hex2) t.overrides.accent2 = hex2; write(t); apply(t); return t; }
  function setMode(/* m */) { return read(); }  // mode is a property of the named theme now; no-op kept for safety

  // The theme GALLERY is a Cm query (\Capability\Theme\* → GET /themes). The registry is the source of
  // truth; the embedded THEMES above are the OFFLINE FALLBACK only (REGISTRY-SPEC §4 / THEMES.md). Each
  // /themes row is a var-bundle whose field names already match our bundle keys (id/label/mode/wallpaper/
  // bg/surface/fg/muted/accent/accent2/accentFg/border/mica*…), so we merge by id (registry wins). After
  // a successful load we repaint the active theme and fire 'themes-changed' so galleries (Settings) refresh.
  var loaded = false;
  function loadGallery() {
    try {
      fetch('/themes', { cache: 'no-store' }).then(function (r) { if (!r.ok) return null; return r.json(); })
        .then(function (rows) {
          if (!Array.isArray(rows) || !rows.length) return;     // 404 / empty → keep embedded fallback
          rows.forEach(function (b) {
            var id = b && (b.id || b.label);
            if (!id) return;
            THEMES[id] = Object.assign({}, THEMES[id], b, { label: b.label || id });
          });
          loaded = true;
          apply();                                              // repaint (active bundle may have refined)
          try { window.dispatchEvent(new CustomEvent('themes-changed', { detail: list() })); } catch (_) {}
        }).catch(function () {});
    } catch (_) {}
  }

  // Optional backend sync of the ACTIVE selection — never throws, never shows a 404; augments localStorage.
  function syncBackend() {
    try {
      fetch('/theme', { cache: 'no-store' }).then(function (r) { if (!r.ok) return; return r.json(); })
        .then(function (data) {
          if (!data) return;
          var patch = {};
          if (data.theme && (data.theme === 'Auto' || THEMES[data.theme])) patch.theme = data.theme;
          if (data.transparency != null) patch.transparency = data.transparency;
          if (Object.keys(patch).length) { var t = Object.assign(read(), patch); write(t); apply(t); }
        }).catch(function () {});
    } catch (_) {}
  }

  // Cross-frame live re-skin: Settings writes localStorage → every other surface repaints.
  window.addEventListener('storage', function (e) { if (e.key === KEY) apply(read()); });

  // 'Auto' follows the OS appearance — repaint when the system light/dark setting flips. themes.js
  // runs in EVERY presenter iframe, so each frame hosts its own listener and the flip re-skins them
  // all; the storage event above covers explicit theme writes (Settings → every open surface).
  try {
    var mq = window.matchMedia('(prefers-color-scheme: dark)');
    var onSchemeFlip = function () { if (read().theme === 'Auto') apply(); };
    if (mq.addEventListener) mq.addEventListener('change', onSchemeFlip);
    else if (mq.addListener) mq.addListener(onSchemeFlip);   // older WebView MediaQueryList
  } catch (_) {}

  apply();          // paint immediately from embedded/OOBE default, before first frame
  loadGallery();    // then hydrate the gallery from the Cm registry (/themes) — registry is the truth
  syncBackend();    // and opportunistically reconcile the active selection if the backend serves /theme

  window.Themes = {
    THEMES: THEMES, DEFAULT_THEME: DEFAULT_THEME,
    get: get, set: set, apply: apply, list: list,
    setTheme: setTheme, setTransparency: setTransparency, override: override,
    setMica: setMica, getMica: getMica,
    setAccent: setAccent, setMode: setMode,
    reload: loadGallery, loaded: function () { return loaded; },
  };
})();
