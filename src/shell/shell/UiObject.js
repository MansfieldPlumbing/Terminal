// UiObject.js — the base contract every visible object honors.
//
// An object holds NO truth. It is handed a host element + a context (the Registry + the Shell), it
// resolves whatever it needs BY ID through the Registry, and it renders. Objects compose objects.
// Disambiguation is by `type` + a namespace `path` (NT model). See docs/REGISTRY-SPEC.md §0.
//
// Subclasses override mount()/unmount(). The base enforces only the shape, never behaviour.

export class UiObject {
  constructor(id, type) {
    this.id = id;             // stable identity (resolved from the registry)
    this.type = type;         // taskbar | menu | compositor | wallpaper | cards | ...
    this.path = null;         // namespace path, e.g. "\\Shell\\Taskbar" (set by the Shell at mount)
    this.host = null;         // the element the Shell allotted this object
    this.ctx = null;          // { registry, shell, spec }
  }

  // Render into `host` using `ctx`. Override. Always call super.mount first.
  async mount(host, ctx) {
    this.host = host;
    this.ctx = ctx;
    this.path = ctx && ctx.spec && ctx.spec.path ? ctx.spec.path : ('\\Shell\\' + this.type);
  }

  // Tear down cleanly (capability retirement: leave nothing behind). Override if you hold listeners.
  unmount() {
    if (this.host) this.host.replaceChildren();
    this.host = null;
    this.ctx = null;
  }
}
