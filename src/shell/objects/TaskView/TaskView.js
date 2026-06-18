import { UiObject } from '../../shell/UiObject.js';

// TaskView — the full-screen Start-with-tasks (\Shell\TaskView). Windows-8 ergonomics: one surface
// that IS both the task switcher and the launcher — open window objects on top (tap = focus,
// ✕ = close), the registry's presenter grid beneath (tap = open). It renders live objects on every
// reveal and holds nothing (REGISTRY-SPEC §9) — with Charms, this can make the taskbar a
// desktop-view-only personality; which chrome mounts stays a Cm layout decision, not code.
export class TaskView extends UiObject {
  async mount(host, ctx) {
    await super.mount(host, ctx);
    this.shown = false;
    host.innerHTML =
      '<div class="taskview" hidden>' +
        '<div class="taskview-head">' +
          '<span class="taskview-title">Tasks</span>' +
          '<button class="taskview-close" type="button" title="Back">&#x2715;</button>' +
        '</div>' +
        '<div class="taskview-tasks"></div>' +
        '<div class="taskview-title taskview-apps-title">Start</div>' +
        '<div class="taskview-apps"></div>' +
      '</div>';
    this._panel = host.querySelector('.taskview');
    this._tasks = host.querySelector('.taskview-tasks');
    this._apps = host.querySelector('.taskview-apps');
    host.querySelector('.taskview-close').addEventListener('click', () => this.hide());
    // The one outside-tap/blur law (Shell.boot): full-screen, so outside-tap can't land — registering
    // adds dismissal on focus-loss. The opening affordance (the Start charm) fires while we're hidden,
    // so host containment alone is sufficient.
    this._unregister = ctx.shell.registerPopup({
      shown: () => this.shown,
      contains: (el) => !!(this.host && this.host.contains(el)),
      hide: () => this.hide(),
    });
  }

  toggle() { if (this.shown) this.hide(); else this.show(); }
  hide() { this.shown = false; this._panel.hidden = true; }

  async show() {
    await this._render();
    this.shown = true;
    this._panel.hidden = false;
  }

  _card(label, icon, onTap, onClose) {
    const card = document.createElement('div');
    card.className = 'taskview-card';
    const ic = document.createElement('span'); ic.className = 'taskview-card-icon'; ic.textContent = icon || '';
    const lb = document.createElement('span'); lb.className = 'taskview-card-label'; lb.textContent = label;
    card.append(ic, lb);
    card.addEventListener('click', () => { this.hide(); onTap(); });
    if (onClose) {
      const x = document.createElement('button');
      x.className = 'taskview-card-x'; x.type = 'button'; x.innerHTML = '&#x2715;';
      x.addEventListener('click', (e) => { e.stopPropagation(); onClose(); card.remove(); });
      card.appendChild(x);
    }
    return card;
  }

  async _render() {
    const shell = this.ctx.shell;

    // Open window objects — the task half. Empty = the head just says Start.
    const windows = shell.openWindows ? shell.openWindows() : [];
    this._tasks.replaceChildren(
      ...windows.map(w => this._card(
        w.title || w.id,
        w.icon || (w.rec && w.rec.icon) || '',
        () => shell.focus(w.id),
        () => shell.close(w.id))));
    this._tasks.parentElement.querySelector('.taskview-title').textContent =
      windows.length ? 'Tasks' : 'No open tasks';

    // The launcher half — every granted presenter from the registry, grouped order as served.
    // (Desktop-role records are the resting layer, not launchable apps.)
    try {
      const apps = (await this.ctx.registry.list()).filter(a => a.role !== 'desktop');
      this._apps.replaceChildren(
        ...apps.map(a => this._card(a.name || a.id, a.icon || '', () => shell.open(a.id))));
    } catch (e) {
      this._apps.replaceChildren();
    }
  }

  unmount() {
    if (this._unregister) { this._unregister(); this._unregister = null; }
    super.unmount();
    this._panel = this._tasks = this._apps = null;
  }
}
