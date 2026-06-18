import { UiObject } from '../../shell/UiObject.js';

// Charms — the LEFT-edge CHARM BAR (\Shell\Charms), built to a WPF charm-bar
// prototype study: an 85px bar, a FIXED set of five charms
// (icon-over-label, 32px glyph), the whole cluster vertically centered with START (U+ED04) in the
// middle, slide-in/out. STATIC — no scrolling, no dynamic verb list, or it's not the charm bar.
// (Verbs stay in the Menu; REGISTRY-SPEC §9 presenters don't all have to show every subtree.)
//
// Always AVAILABLE, never a gesture (owner directive 2026-06-11): the UI owns NO edge swipe; the
// bar opens only from an explicit affordance (the Menu's 'Charms' entry → Shell.toggleCharms()).
// NF glyphs are assigned as \uXXXX escapes below — PUA literals don't survive tooling round-trips.
const GLYPH = { broker: '\uf075', terminal: '\uf120', start: '\ued04', settings: '\uf013' };

export class Charms extends UiObject {
  async mount(host, ctx) {
    await super.mount(host, ctx);
    this.shown = false;
    host.innerHTML =
      '<div class="charms-veil" hidden></div>' +
      '<div class="charms-panel" aria-hidden="true"><div class="charms-stack"></div></div>';
    this._veil = host.querySelector('.charms-veil');
    this._panel = host.querySelector('.charms-panel');
    this._stack = host.querySelector('.charms-stack');

    this._veil.addEventListener('pointerdown', () => this.hide());
    // The one outside-tap/blur law (Shell.boot): the veil already eats outside taps; registering
    // adds dismissal on focus-loss (a tap landing inside a content iframe never reaches our document).
    this._unregister = ctx.shell.registerPopup({
      shown: () => this.shown,
      contains: (el) => !!(this.host && this.host.contains(el)),
      hide: () => this.hide(),
    });
    this._build();
  }

  // The FOUR charms (fixed, Start dead-center — the prototype's My PC·Notifications·START·Store·
  // Settings rhythm mapped to this system's objects). Built once; only the Bar charm's pin/hide
  // glyph re-syncs on reveal.
  _build() {
    const shell = this.ctx.shell;
    this._stack.replaceChildren(
      this._charm('Terminal', GLYPH.terminal, () => shell.open('terminal')),
      this._startCharm(),
      this._barCharm(),
      this._charm('Settings', GLYPH.settings, () => shell.open('settings')),
    );
  }

  _charm(label, glyph, onClick, cls) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'charm' + (cls ? ' ' + cls : '');
    b.title = label;
    const ic = document.createElement('span'); ic.className = 'charm-icon'; ic.textContent = glyph;
    const lb = document.createElement('span'); lb.className = 'charm-label'; lb.textContent = label;
    b.append(ic, lb);
    b.addEventListener('click', () => { this.hide(); onClick(); });
    return b;
  }

  // START — U+ED04 (the CaskaydiaCove start-menu glyph) → the FULL-SCREEN start (the object
  // currently classed TaskView; rename to StartScreen is owed — it IS the start menu).
  _startCharm() {
    return this._charm('Start', GLYPH.start, () => {
      const tv = this.ctx.shell.chrome && this.ctx.shell.chrome.get('taskview');
      if (tv && tv.toggle) tv.toggle();
    }, 'charm-start');
  }

  // The Bar charm — the taskbar is ALWAYS VISIBLE (no hide/pin), so this is the dock verb: send the
  // bar to the other edge. The arrow points where it will GO. Glyph re-synced on each reveal.
  _barCharm() {
    const shell = this.ctx.shell;
    this._bar = this._charm('Bar', '↑', () => { shell.toggleBarPosition(); });
    return this._bar;
  }
  _syncBar() {
    if (!this._bar) return;
    const pos = this.ctx.shell.barPosition || 'bottom';
    this._bar.querySelector('.charm-icon').textContent = pos === 'bottom' ? '↑' : '↓';
    this._bar.title = pos === 'bottom' ? 'Move the taskbar to the top' : 'Move the taskbar to the bottom';
  }

  toggle() { if (this.shown) this.hide(); else { this._syncBar(); this._open(); } }

  _open() {
    this.shown = true;
    this._panel.style.transform = 'translateX(0)';
    this._panel.setAttribute('aria-hidden', 'false');
    this._veil.hidden = false;
  }

  hide() {
    this.shown = false;
    this._panel.style.transform = '';
    this._panel.setAttribute('aria-hidden', 'true');
    this._veil.hidden = true;
  }

  unmount() {
    if (this._unregister) { this._unregister(); this._unregister = null; }
    super.unmount();
    this._veil = this._panel = this._stack = this._bar = null;
  }
}
