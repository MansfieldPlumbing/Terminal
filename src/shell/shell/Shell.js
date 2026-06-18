// Shell.js — the assembler. `shell.obp` does nothing but boot this. The Shell reads the registry's
// ORDERS (which chrome objects to mount) and assembles them; it holds NO truth (no app list, no paths).
// It owns the WINDOW OBJECTS (open surfaces) — the taskbar presents them, the menu launches them, the
// red-X closes the active one. Everything resolves BY ID through the Registry. Religiously NT.

import { Registry } from './Registry.js';
import { launchIcon } from './icons.js';
import { Taskbar } from '../objects/Taskbar/Taskbar.js';
import { Menu } from '../objects/Menu/Menu.js';
import { Charms } from '../objects/Charms/Charms.js';
import { TaskView } from '../objects/TaskView/TaskView.js';

// The object-TYPE table — the only compile-time coupling: a type name -> its class. New object TYPES
// register here; new object INSTANCES come from the registry (data), never code.
const OBJECT_TYPES = { taskbar: Taskbar, menu: Menu, charms: Charms, taskview: TaskView };

export class Shell {
  constructor(root) {
    this.root = root;
    this.registry = new Registry();
    this.chrome = new Map();          // id -> chrome UiObject (taskbar, menu)
    this.windows = new Map();         // id -> { id, rec, frame, title, icon }  (open window objects)
    this.order = [];                  // window id order (the taskbar renders this)
    this.activeId = null;
    this.stage = null;
    this._backNav = false;
    this._popups = new Set();         // { shown(), contains(el), hide() } — see registerPopup()
  }

  async boot() {
    // Backdrop — the bottom layer (z:0): a static themed gradient floor (.shell-backdrop, Shell.css).
    // The in-WebView WebGL shader backdrop was removed — a continuous-GPU render is a resource hog on a
    // terminal, and the native live wallpaper (WpService) is gone too. The gradient is the whole floor now.
    const bd = document.createElement('div');
    bd.className = 'shell-backdrop';
    this.root.appendChild(bd);

    // Stage — where each open window object's Content (iframe) lives.
    this.stage = document.createElement('div');
    this.stage.className = 'shell-stage';
    this.root.appendChild(this.stage);

    // THE DESKTOP — the resting layer (the Surface, resolved BY ROLE from the registry — never a
    // path). A persistent iframe at stage-bottom: windows are later siblings that paint above it;
    // when the last one closes, the desktop is simply what remains. NOT a window object (no chip,
    // no history entry, can't be closed). Replaces the old "Tap ▦ to start" start screen.
    this.desktop = null;
    try {
      const drec = await this.registry.desktop();
      if (drec) {
        const d = document.createElement('iframe');
        d.className = 'shell-desktop';
        d.dataset.objectId = drec.id;
        d.setAttribute('sandbox', 'allow-scripts allow-forms allow-same-origin allow-downloads allow-popups allow-modals');
        d.src = this.registry.contentUrl(drec);
        this.stage.appendChild(d);
        this.desktop = d;
      }
    } catch (e) { console.warn('Shell: desktop failed to mount', e); }
    this.startIcon = null;

    // Red-X — the active window's Close verb, surfaced as fixed top-right chrome (always top-right,
    // independent of taskbar dock). Shown only while a window is active (the verb has a target).
    this.closeBtn = document.createElement('button');
    this.closeBtn.className = 'shell-close';
    this.closeBtn.type = 'button';
    this.closeBtn.title = 'Close';
    this.closeBtn.innerHTML = '&#10005;';
    this.closeBtn.addEventListener('click', () => this._confirmClose());
    this.root.appendChild(this.closeBtn);

    // Chrome objects per the registry's layout orders.
    for (const spec of await this.registry.layout()) {
      const Type = OBJECT_TYPES[spec.type];
      if (!Type) { console.warn('Shell: unknown object type', spec.type); continue; }
      const hostEl = document.createElement('div');
      hostEl.className = 'ui-object object-' + spec.type;
      hostEl.dataset.objectId = spec.id;
      this.root.appendChild(hostEl);
      const obj = new Type(spec.id, spec.type);
      try {
        await obj.mount(hostEl, { registry: this.registry, shell: this, spec });
        this.chrome.set(spec.id, obj);
      } catch (e) {
        // Resilience (SHELL-SPEC §3): a failed object degrades, never crashes the Shell.
        console.error('Shell: object failed to mount', spec.id, e);
        hostEl.replaceChildren();
      }
    }

    // Dock the bar: a saved user choice (ss-barstyle) wins; else the registry's layout spec; else BOTTOM.
    // Bottom is the default — the top edge is awkward to reach and this device's top digitizer is flaky.
    const _tb = this.chrome.get('taskbar');
    let _saved = null; try { _saved = localStorage.getItem('ss-barstyle'); } catch (_) {}
    const _spec = _tb && _tb.host && _tb.host.dataset.position;
    this.setBarPosition(_saved ? (_saved === 'tabbar' ? 'top' : 'bottom') : (_spec || 'bottom'));

    // Chrome rule (owner directive 2026-06-11): the taskbar shows in EVERY posture — no
    // portrait/landscape auto-switching, no auto-hide. The charm bar is always AVAILABLE but opens
    // only from an explicit affordance (the Menu's 'Charms' entry → toggleCharms()); the UI owns
    // no edge gesture.

    // Android hardware back button -> history API (1:1 with ui-final's App.tsx). Back is CONTEXT-AWARE
    // and consumes exactly ONE nesting level (owner directive): a focused IME first, then a presenter's
    // own internal nesting, then the window, then the desktop — it NEVER exits the app (the red-X is the
    // one exit). The native predictive-back arrow on edge-swipe is a system overlay we can't paint over
    // from the web layer; we DEFANG it by consuming the gesture ourselves (see _bindBackGesture) so it
    // resolves to our one-level back instead of an app exit.
    if (!window.history.state) window.history.replaceState({ id: null, isRoot: true }, '');
    window.addEventListener('popstate', (e) => {
      this._backNav = true;
      const st = e.state;
      if (st && st.id && this.windows.has(st.id)) this.focus(st.id);
      else this.back();                                   // back with no window target -> one level back
      this._backNav = false;
    });
    this._bindBackGesture();

    // We own input. Suppress the browser/WebView default context menu (right-click / long-press) — our own
    // context menu is the Menu object's context root (REGISTRY-SPEC §6, the IContextMenu analog), never
    // the engine's chrome. (Presenters suppress their own per the §8 conformance contract.)
    window.addEventListener('contextmenu', (e) => e.preventDefault());

    // POPUPS DIE ON BLUR — one law, ONE listener (no popup carries its own document hook): any
    // registered popup (the Menu's cascade, the charm bar, the task view, future context sheets)
    // dismisses when a pointerdown lands outside it. Taps inside a content iframe never bubble to
    // this document — the window 'blur' (focus crossing into the frame) covers that lane.
    document.addEventListener('pointerdown', (e) => {
      for (const p of this._popups) { try { if (p.shown() && !p.contains(e.target)) p.hide(); } catch (_) {} }
    });
    window.addEventListener('blur', () => {
      for (const p of this._popups) { try { if (p.shown()) p.hide(); } catch (_) {} }
    });

    window.addEventListener('message', (e) => this._onMessage(e));
    this._bindViewport();
    this._sync();
  }

  // Soft-keyboard handling. The WebView doesn't reliably honor interactive-widget=resizes-content (esp.
  // edge-to-edge + immersive), so the IME overlays and the browser pans the page — flinging the fixed
  // chrome off-screen. We instead pin #shell-root to the VISUAL viewport: when the keyboard opens, the
  // shell shrinks to the area ABOVE it so the active presenter's input stays visible, and restores when
  // it closes. The BOTTOM-DOCKED TASKBAR deliberately does NOT ride this pin (owner directive): it must
  // stay at the PHYSICAL screen bottom — UNDER the IME is acceptable, a bar floating mid-screen on top of
  // the keyboard is not. Pinning the root alone is NOT enough: position:fixed children anchor to the
  // LAYOUT viewport, which `interactive-widget=resizes-content` shrinks when the IME opens — so the fixed
  // taskbar would still ride up to sit above the keyboard. We therefore PUSH the taskbar host back DOWN by
  // the IME overlap (a CSS var the bar reads) so it returns to the true physical bottom, behind the IME.
  _bindViewport() {
    const vv = window.visualViewport;
    if (!vv) return;
    const fit = () => {
      // Pin ONLY when the IME overlays the layout viewport (visual < layout). When the window
      // manager already resized the window for the keyboard (AdjustResize — observed on the Razr+
      // COVER display), innerHeight tracks vv.height and pinning again DOUBLE-lifts the chrome:
      // the taskbar/menu float on top of the keyboard. In that case leave CSS inset:0 in charge.
      const overlap = Math.round(window.innerHeight - vv.height);
      this._imeOpen = overlap > 40;
      if (this._imeOpen) {
        this.root.style.bottom = 'auto';
        this.root.style.top = vv.offsetTop + 'px';
        this.root.style.height = vv.height + 'px';
        // The bottom taskbar (position:fixed) anchors to the layout viewport, which `resizes-content`
        // has shrunk to sit above the IME. Offset it back down by the keyboard height so it rests at
        // the physical bottom edge, under the keyboard. Taskbar.css consumes --ime-offset.
        this.root.style.setProperty('--ime-offset', overlap + 'px');
      } else {
        this.root.style.bottom = '';
        this.root.style.top = '';
        this.root.style.height = '';
        this.root.style.removeProperty('--ime-offset');
      }
      this.root.dataset.ime = this._imeOpen ? '1' : '0';
    };
    vv.addEventListener('resize', fit);
    vv.addEventListener('scroll', fit);
    fit();
  }

  // Is the soft keyboard currently overlaying the layout viewport? (Drives context-aware backswipe.)
  isImeOpen() { return !!this._imeOpen; }
  // Dismiss the soft keyboard by blurring whatever the active presenter has focused (the IME closes when
  // nothing is focused). We can't reach into a cross-origin iframe's focused node, so we post the verb and
  // let the presenter blur its own field; same-origin frames we blur directly as a belt-and-suspenders.
  dismissKeyboard() {
    const w = this.activeWindow();
    if (!w || !w.frame) return false;
    let handled = false;
    try { w.frame.contentWindow.postMessage({ type: 'dismiss-keyboard' }, '*'); handled = true; } catch (_) {}
    try {
      const ae = w.frame.contentDocument && w.frame.contentDocument.activeElement;
      if (ae && ae.blur) { ae.blur(); handled = true; }
    } catch (_) { /* cross-origin — the postMessage above is the lane */ }
    return handled;
  }

  // One level of context-aware "back" (the hardware-back / right-edge-swipe target). Order of resolution:
  //   1. soft keyboard open       -> dismiss it (and stop)
  //   2. active presenter is nested-> ask it to pop one internal level (it advertised hasBack via message)
  //   3. a window is active        -> close it (reveals the next window or the desktop)
  //   4. nothing                   -> no-op (NEVER exit; the red-X is the only exit)
  back() {
    if (this.isImeOpen() && this.dismissKeyboard()) return;
    const w = this.activeWindow();
    if (w && w.hasBack) {
      try { w.frame.contentWindow.postMessage({ type: 'shell-back' }, '*'); } catch (_) {}
      return;
    }
    if (this.activeId) this.close(this.activeId);
  }

  // Right-edge backswipe (owner directive: context-aware, must DEFANG the OS predictive-back). We claim a
  // pointer that starts within EDGE px of the right edge and travels left past THRESH, then run our own
  // one-level back(). overscroll-behavior:none (Shell.css) already suppresses the WebView's horizontal
  // history-swipe; this adds the intent. A keyboard-open swipe dismisses the IME first (back() handles it).
  _bindBackGesture() {
    const EDGE = 24, THRESH = 48;
    let sx = 0, sy = 0, armed = false;
    this.root.addEventListener('touchstart', (e) => {
      const t = e.touches[0]; if (!t) return;
      armed = t.clientX >= window.innerWidth - EDGE;
      sx = t.clientX; sy = t.clientY;
    }, { passive: true });
    this.root.addEventListener('touchend', (e) => {
      if (!armed) return;
      armed = false;
      const t = e.changedTouches[0]; if (!t) return;
      const dx = t.clientX - sx, dy = t.clientY - sy;
      if (dx < -THRESH && Math.abs(dx) > Math.abs(dy)) this.back();
    }, { passive: true });
  }

  // ---- window objects ----
  // open(id, params?) — params is the OBJECT being handed to the presenter (e.g. {file:'/sdcard/x'}
  // from Files → Edit): a query string on first open, an 'open-params' postMessage when the window
  // already exists (the presenter decides how to take the new object — e.g. dirty-guard first).
  // Still resolve-by-id; params never name a path to another presenter.
  async open(id, params) {
    const rec = await this.registry.resolve(id);
    if (!rec) { console.warn('Shell.open: no such object', id); return; }
    if (!this.windows.has(id)) {
      const frame = document.createElement('iframe');
      frame.className = 'content-frame';
      frame.dataset.objectId = id;
      frame.setAttribute('sandbox', 'allow-scripts allow-forms allow-same-origin allow-downloads allow-popups allow-modals');
      const qs = params ? ('?' + new URLSearchParams(params).toString()) : '';
      frame.src = this.registry.contentUrl(rec) + qs;
      frame.addEventListener('load', () => this._adopt(id, frame));
      this.stage.appendChild(frame);
      this.windows.set(id, { id, rec, frame, title: rec.name || id, icon: rec.icon || '' });
      this.order.push(id);
      this._refreshTaskbar();
    } else if (params) {
      const w = this.windows.get(id);
      try { w.frame.contentWindow.postMessage({ type: 'open-params', params }, '*'); } catch (e) { /* frame mid-load */ }
    }
    this.focus(id);
  }

  focus(id) {
    if (!this.windows.has(id)) return;
    const wasActive = this.activeId === id;
    this.activeId = id;
    for (const [wid, w] of this.windows) w.frame.classList.toggle('active', wid === id);
    this._refreshTaskbarActive();
    this._sync();
    // Re-focusing an already-open presenter chip must NOT auto-pop the soft keyboard (owner directive):
    // tell the presenter this is a focus event, not a fresh open, so it restores its surface WITHOUT
    // calling .focus() on a text field. Presenters that don't listen are unaffected (no field is focused
    // by the Shell — we never call frame.contentWindow.focus()).
    const w = this.windows.get(id);
    if (w && w.frame && w.frame.contentWindow) {
      try { w.frame.contentWindow.postMessage({ type: 'window-focus', refocus: wasActive }, '*'); } catch (_) {}
    }
    if (!this._backNav && (!window.history.state || window.history.state.id !== id))
      window.history.pushState({ id }, '', '#' + id);
  }

  close(id) {
    const w = this.windows.get(id);
    if (!w) return;
    w.frame.remove();
    this.windows.delete(id);
    this.order = this.order.filter(x => x !== id);
    if (this.activeId === id) {
      this.activeId = null;
      const next = this.order[this.order.length - 1] || null;
      if (next) this.focus(next);
    }
    this._refreshTaskbar();
    this._sync();
  }

  reorder(ids) { this.order = ids.slice(); this._refreshTaskbar(); }

  openWindows() { return this.order.map(id => this.windows.get(id)).filter(Boolean); }
  activeWindow() { return this.activeId ? this.windows.get(this.activeId) : null; }
  // The active object's scope = its type (HKCR\<type> analog) — what the context menu groups by. Prefer
  // the scope the presenter advertised at runtime (menu-context), else fall back to its registry record.
  async activeScope() { const w = this.activeWindow(); if (!w) return ''; if (w.scope) return w.scope; const r = w.rec; return (r && (r.type || r.group || r.id)) || w.id; }
  // The active window's runtime-advertised menu items (from its menu-context post); [] if none.
  activeMenuItems() { const w = this.activeWindow(); return (w && w.menuItems) || []; }

  // ---- taskbar dock (top|bottom) — one bar, position is an axis. Drives the stage inset + menu side. ----
  setBarPosition(pos) {
    if (pos !== 'top' && pos !== 'bottom') return;
    this.barPosition = pos;
    this.root.dataset.bar = pos;
    try { localStorage.setItem('ss-barstyle', pos === 'bottom' ? 'taskbar' : 'tabbar'); } catch (_) {}
    const tb = this.chrome.get('taskbar');
    if (tb && tb.setPosition) tb.setPosition(pos);
    else if (tb && tb.host) tb.host.dataset.position = pos;
    this._setStartIcon(pos);   // the start glyph mirrors the launch button — fade hamburger <-> start
  }

  // Cross-fade the start-screen glyph to match the dock (hamburger up top, the 9-dot start down low),
  // the same dock personality the launch button wears. Fades, never cycles.
  _setStartIcon(pos) {
    if (!this.startIcon) return;
    this.startIcon.classList.add('fading');
    setTimeout(() => {
      if (!this.startIcon) return;
      this.startIcon.innerHTML = launchIcon(pos);
      this.startIcon.classList.remove('fading');
    }, 150);
  }
  toggleBarPosition() { this.setBarPosition(this.barPosition === 'bottom' ? 'top' : 'bottom'); }

  // ---- menu / charms / verbs ----
  toggleMenu() { const m = this.chrome.get('menu'); if (m && m.toggle) m.toggle(); }
  // The charm bar's ONE opening affordance (owner directive: no edge gesture, ever).
  toggleCharms() { const c = this.chrome.get('charms'); if (c && c.toggle) c.toggle(); }

  // ---- popups (the one outside-tap law — see the document pointerdown in boot()) ----
  // A popup registers { shown(), contains(el), hide() }; `contains` must also cover the popup's
  // opening affordance (else the opening tap dismisses-then-retoggles). Returns the unregister fn.
  registerPopup(popup) { this._popups.add(popup); return () => this._popups.delete(popup); }
  invokeVerb(verb) {
    const w = this.activeWindow();
    if (w && w.frame.contentWindow) w.frame.contentWindow.postMessage({ type: 'app-menu-action', verb }, '*');
  }

  // ---- internals ----
  _adopt(id, frame) {
    // Adopt the presenter's title + favicon as the window object's (1:1 with ui-final handleIframeLoad).
    try {
      const doc = frame.contentDocument || frame.contentWindow.document;
      const w = this.windows.get(id);
      if (!doc || !w) return;
      if (doc.title && doc.title.trim() && doc.title !== 'Untitled') w.title = doc.title;
      const ic = doc.querySelector("link[rel*='icon']");
      const href = ic && ic.getAttribute('href');
      if (href) w.icon = href;
      this._refreshTaskbar();
    } catch (_) { /* cross-origin -> keep the manifest title/icon */ }
  }
  _refreshTaskbar() { const t = this.chrome.get('taskbar'); if (t && t.render) t.render(); }
  _refreshTaskbarActive() { const t = this.chrome.get('taskbar'); if (t && t.syncActive) t.syncActive(); }
  // The red-X always asks first ("are you sure"). On device window.confirm() surfaces the native
  // AlertDialog (CustomWebChromeClient.OnJsConfirm); in dev it's the browser confirm. Closes the active
  // window, or — when nothing is open — exits the app (we own swipe-nav, so the red-X is the only way out).
  _confirmClose() {
    // Closing a window is cheap + reversible (reopen it) → just close, no prompt. Only EXITING the app
    // (nothing open) asks first, since we own swipe-nav and exit is the one truly destructive action.
    if (this.activeId) {
      this.close(this.activeId);
    } else if (window.confirm('Exit Subsystem?')) {
      this.exitApp();
    }
  }
  // Exit the whole app — the red-X's job when nothing is open (we own Android swipe-nav, so this is the
  // only way out). Routes to the native bridge on device; window.close() in the browser/dev.
  exitApp() {
    try { if (window.AndroidBridge && window.AndroidBridge.exitApp) { window.AndroidBridge.exitApp(); return; } } catch (_) {}
    window.close();
  }
  _sync() {
    // The desktop is the resting state — nothing to toggle: windows paint above it and closing the
    // last one simply reveals it. The red-X stays (closes the active window / exits when none open).
  }
  // Presenters advertise their verbs at RUNTIME (REGISTRY-SPEC §6/§9, the IContextMenu analog): a presenter
  // posts { type:'menu-context', scope, items:[{menu,verb,label,enabled,checked}] }; we stash it on the
  // window object so the Menu's File/Edit/View fills itself from the ACTIVE object — by construction. The
  // Shell hardcodes nothing per-presenter. invokeVerb() posts the chosen verb back as 'app-menu-action'.
  _onMessage(e) {
    const d = e.data;
    if (!d || typeof d !== 'object') return;
    if (d.type === 'set-barstyle') { this.setBarPosition(d.value === 'taskbar' ? 'bottom' : 'top'); return; }
    // A presenter asks the Shell to open another object BY ID (e.g. the Surface's "New card with
    // Broker…" → agent with a prefilled prompt). Same resolve-by-id path as every other open.
    if (d.type === 'shell-open' && d.id) { this.open(String(d.id), d.params || undefined); return; }
    if (d.type === 'menu-context') {
      for (const w of this.windows.values()) {
        if (w.frame.contentWindow === e.source) {
          w.menuItems = Array.isArray(d.items) ? d.items : [];
          if (d.scope) w.scope = String(d.scope);
          break;
        }
      }
    }
    // A presenter advertises whether it has internal nesting to pop, so a back press unwinds ITS levels
    // before the Shell closes the window (owner directive: nested back = one level, not exit). Same
    // resolve-by-source-frame stash as menu-context; presenters that never post this keep hasBack falsy.
    if (d.type === 'back-state') {
      for (const w of this.windows.values()) {
        if (w.frame.contentWindow === e.source) { w.hasBack = !!d.hasBack; break; }
      }
    }
  }
}
