import { UiObject } from '../../shell/UiObject.js';

// Menu — a NAMESPACE PRESENTER, not a list. It renders objects resolved from the registry. ONE object,
// TWO dock personalities (REGISTRY-SPEC §9 "N presenters, differing only by root + chrome", SHELL-SPEC §2):
//
//   • docked TOP  → the HAMBURGER = the desktop MENU BAR. Root shows the active object's File / Edit / View
//                   TOP-LEVEL (a menu bar shows them directly), then the Apps list. "What would Windows do."
//   • docked LOW  → the START button = the LAUNCHER. Root IS the app list (a Start menu shows apps, not a
//                   submenu to apps); File/Edit/View move under a secondary "Menu" entry.
//
// Same tree, same cascade chrome (lifted from the android-terminal predecessor) — only the ROOT differs by
// dock. There are no items, only objects: every entry is a view of a capability / verb / namespace node.
const GROUPS = [
  { key: 'file', label: 'File' },
  { key: 'edit', label: 'Edit' },
  { key: 'view', label: 'View' },
  { key: 'tools', label: 'Tools' },
];

// Launcher groups that render FLAT in the Apps panel (the registry's core/tools/system rhythm, served
// order). Every OTHER group key (e.g. 'applets') cascades as a folder AFTER the flat list, labeled via
// GROUP_LABELS — else the group key, capitalized. The keys stay registry truth; only labels live here.
const FLAT_GROUPS = new Set(['core', 'tools', 'system', '']);
const GROUP_LABELS = { applets: 'Applets' };
const groupLabel = (g) => GROUP_LABELS[g] || (g.charAt(0).toUpperCase() + g.slice(1));

export class Menu extends UiObject {
  async mount(host, ctx) {
    await super.mount(host, ctx);
    this.shown = false;
    this.panel = 'root';
    host.innerHTML =
      '<div class="menu-flyout" hidden>' +
        '<div class="menu-stack"></div>' +
      '</div>';
    this._flyout = host.querySelector('.menu-flyout');
    this._stack = host.querySelector('.menu-stack');
    // Outside-tap/blur dismissal is the Shell's ONE popup law (Shell.boot) — no own document listener.
    // The launch button is our opening affordance: its pointerdown must not count as "outside".
    this._unregister = ctx.shell.registerPopup({
      shown: () => this.shown,
      contains: (el) => !!(this.host && this.host.contains(el)) || !!(el && el.closest && el.closest('.taskbar-launch')),
      hide: () => this.hide(),
    });
  }

  async toggle() { if (this.shown) this.hide(); else await this.show(); }
  hide() { this.shown = false; if (this._flyout) this._flyout.hidden = true; }

  async show() {
    this.panel = 'root';
    await this._navigate('root', 'right');
    this.shown = true;
    this._flyout.hidden = false;
  }

  // Navigate the cascade. `dir` = enter-from ('right' = drilling in, 'left' = back).
  async _navigate(panel, dir) {
    this.panel = panel;
    const el = document.createElement('div');
    el.className = 'menu-panel ' + (dir === 'left' ? 'enter-left' : 'enter-right');
    if (panel === 'root') el.appendChild(await this._root());
    else if (panel === 'presenters') el.appendChild(await this._presenters());
    else if (panel === 'context') el.appendChild(await this._context());
    else if (panel.indexOf('apps:') === 0) el.appendChild(await this._appGroup(panel.slice(5)));
    else el.appendChild(await this._group(panel));
    this._stack.replaceChildren(el);
  }

  _dock() { return this.ctx.shell.barPosition || 'top'; }
  // The active object's scope = its type (HKCR\<type> analog). The Shell resolves it; no hardcoded map.
  async _scope() { return (this.ctx.shell.activeScope && (await this.ctx.shell.activeScope())) || ''; }

  _btn(label, { icon, chevron, danger, onClick } = {}) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'menu-item' + (danger ? ' menu-item-danger' : '');
    const ic = document.createElement('span'); ic.className = 'menu-item-icon'; ic.textContent = icon || '';
    const lb = document.createElement('span'); lb.className = 'menu-item-label'; lb.textContent = label;
    b.append(ic, lb);
    if (chevron) { const c = document.createElement('span'); c.className = 'menu-item-chevron'; c.textContent = '›'; b.appendChild(c); }
    if (onClick) b.addEventListener('click', onClick);
    return b;
  }

  _back(to = 'root') {
    return this._btn('Back', { icon: '‹', onClick: () => this._navigate(to, 'left') });
  }

  _sep(f) { const s = document.createElement('div'); s.className = 'menu-sep'; f.appendChild(s); }
  _title(f, t) { const d = document.createElement('div'); d.className = 'menu-section-title'; d.textContent = t; f.appendChild(d); }

  // The root — the personality switch. TOP = menu bar (File/Edit/View top-level); LOW = launcher (apps).
  async _root() {
    const f = document.createDocumentFragment();
    const pos = this._dock();
    const groups = await this._nonEmptyGroups();   // File/Edit/View/Tools appear only if they present options
    if (pos === 'top') {
      for (const g of groups) f.appendChild(this._btn(g.label, { chevron: true, onClick: () => this._navigate(g.key, 'right') }));
      f.appendChild(this._btn('Apps', { icon: '▦', chevron: true, onClick: () => this._navigate('presenters', 'right') }));
    } else {
      // START personality (bottom dock): a real Start menu shape — Presenters cascades the whole app list
      // (no flat dump at the root), Menu cascades the active object's File/Edit/View/Tools (only if any exist).
      f.appendChild(this._btn('Apps', { icon: '▦', chevron: true, onClick: () => this._navigate('presenters', 'right') }));
      if (groups.length) f.appendChild(this._btn('Menu', { chevron: true, onClick: () => this._navigate('context', 'right') }));
    }
    this._sep(f);
    this._title(f, 'System');
    f.appendChild(this._btn('Settings', { icon: '⚙', onClick: () => { this.hide(); this.ctx.shell.open('settings'); } }));
    // Charms — the charm bar's ONE explicit opening affordance (owner directive: no edge gesture).
    f.appendChild(this._btn('Charms', { icon: '❖', onClick: () => { this.hide(); this.ctx.shell.toggleCharms(); } }));
    // Taskbar — a contextually-aware arrow in the icon slot points where the bar will GO (↑ when it's at
    // the bottom, ↓ when at the top). Tap to send it there. Icon + label = meaning + function, no verbose
    // text. (User-facing word is "Taskbar" — never "dock"; the identifier below may stay.)
    const dock = this._btn('Taskbar', { icon: pos === 'bottom' ? '↑' : '↓',
      onClick: () => { this.hide(); this.ctx.shell.toggleBarPosition(); } });
    dock.classList.add('menu-dock');     // the arrow glows blue (accent) — see Menu.css
    f.appendChild(dock);
    return f;
  }

  // The context root (File/Edit/View) as a drill-in — used by the LOW/start personality's "Menu" entry.
  async _context() {
    const f = document.createDocumentFragment();
    f.appendChild(this._back('root'));
    for (const g of await this._nonEmptyGroups()) f.appendChild(this._btn(g.label, { chevron: true, onClick: () => this._navigate(g.key, 'right') }));
    return f;
  }

  // The verbs the active object advertises for a menu group, merged: RUNTIME contributions from the active
  // presenter (postMessage menu-context — the live, instance-specific IContextMenu analog) FIRST, then DURABLE
  // verbs from Cm /verbs (the HKCR registration analog), scoped to the active object's type. One menu, both
  // sources, by construction.
  async _groupItems(menuKey) {
    const scope = await this._scope();
    const runtime = (this.ctx.shell.activeMenuItems ? this.ctx.shell.activeMenuItems() : [])
      .filter(v => v && v.menu === menuKey);
    const durable = (await this.ctx.registry.verbs())
      .filter(v => v.menu === menuKey && (v.scope === scope || v.scope === '*' || v.scope === 'system'));
    return runtime.concat(durable);
  }

  // The File/Edit/View/Tools groups that have at least one verb for the active object. A group that would
  // present nothing is NOT shown at all (REGISTRY-SPEC §9: the menu fills from the active object — an empty
  // menu is absent, not a dead top-level entry that drills into "No options").
  async _nonEmptyGroups() {
    const scope = await this._scope();
    const runtime = this.ctx.shell.activeMenuItems ? this.ctx.shell.activeMenuItems() : [];
    const verbs = await this.ctx.registry.verbs();
    return GROUPS.filter(g =>
      runtime.some(v => v && v.menu === g.key) ||
      verbs.some(v => v.menu === g.key && (v.scope === scope || v.scope === '*' || v.scope === 'system')));
  }

  // A File/Edit/View group panel: the active object's verbs for that menu (objects, live).
  async _group(menuKey) {
    const f = document.createDocumentFragment();
    f.appendChild(this._back(this._dock() === 'top' ? 'root' : 'context'));
    const all = await this._groupItems(menuKey);
    if (!all.length) {
      const none = document.createElement('div'); none.className = 'menu-empty'; none.textContent = 'No options';
      f.appendChild(none);
    } else {
      for (const v of all) {
        const enabled = v.enabled !== false;
        const label = v.checked ? '✓ ' + v.label : v.label;
        const b = this._btn(label, { icon: v.icon, onClick: () => { this.hide(); this.ctx.shell.invokeVerb(v.verb || v.command || v.path); } });
        if (!enabled) { b.disabled = true; b.classList.add('menu-item-disabled'); }
        f.appendChild(b);
      }
    }
    return f;
  }

  // The launcher list: every presenter object from /apps. Tapping opens it (a window object is born).
  // Desktop-role records are the Shell's resting layer, not launchable apps — skip them.
  _appBtn(a) {
    return this._btn(a.name || a.id, { icon: a.icon, onClick: () => { this.hide(); this.ctx.shell.open(a.id); } });
  }
  _empty(f) {
    const none = document.createElement('div'); none.className = 'menu-empty'; none.textContent = 'No apps';
    f.appendChild(none);
  }

  // Apps — FLAT groups (core/tools/system) first in served order, then one cascading FOLDER per
  // remaining group (e.g. Applets), in first-appearance order. The grouping is the registry record's
  // `group` field — the menu holds no list of its own.
  async _presenters() {
    const f = document.createDocumentFragment();
    f.appendChild(this._back());
    const apps = (await this.ctx.registry.list()).filter(a => a.role !== 'desktop');
    if (!apps.length) { this._empty(f); return f; }
    for (const a of apps) if (FLAT_GROUPS.has(a.group || '')) f.appendChild(this._appBtn(a));
    const folders = [];
    for (const a of apps) {
      const g = a.group || '';
      if (!FLAT_GROUPS.has(g) && folders.indexOf(g) < 0) folders.push(g);
    }
    for (const g of folders)
      f.appendChild(this._btn(groupLabel(g), { icon: '', chevron: true, onClick: () => this._navigate('apps:' + g, 'right') }));
    return f;
  }

  // One launcher folder (an 'apps:<group>' panel): the group's presenters, back leads to Apps.
  async _appGroup(group) {
    const f = document.createDocumentFragment();
    f.appendChild(this._back('presenters'));
    this._title(f, groupLabel(group));
    const apps = (await this.ctx.registry.list()).filter(a => a.role !== 'desktop' && (a.group || '') === group);
    if (!apps.length) this._empty(f);
    else for (const a of apps) f.appendChild(this._appBtn(a));
    return f;
  }

  unmount() {
    if (this._unregister) { this._unregister(); this._unregister = null; }
    super.unmount();
    this._flyout = this._stack = null;
  }
}
