// Registry.js — the Shell's client to the capability registry (Cm, via the ProjectionServer API).
//
// This is the ONE place that knows how an object is LOCATED. Every other object resolves strictly
// BY ID through this client and never touches a path. Today the transport is `GET /apps` (a
// ProjectionServer scan); it becomes a `Cm` query with ZERO change to callers — that indirection is
// the whole point (rename/move a file = a non-event). See docs/REGISTRY-SPEC.md §1.
//
// Capability-backed: the id you can resolve IS the authority you hold (VOM-SPEC §6a). Resolve-known,
// never enumerate-blindly.

export class Registry {
  constructor(base = '') {
    this._base = base;          // origin prefix; '' = same origin (the on-device ProjectionServer)
    this._records = null;       // cached record set
  }

  // The full record set the Shell may resolve. [{ group, name, file, firstClass, ... }].
  // (Records gain a stable `id` once the backend registrar seeds Cm; until then `name` is the id.)
  async list() {
    if (this._records) return this._records;
    try {
      const r = await fetch(this._base + '/apps', { cache: 'no-store' });
      this._records = r.ok ? await r.json() : [];
    } catch (_) {
      this._records = [];        // never throw, never surface a 404 (project rule); degrade to empty
    }
    return this._records.map(rec => ({ id: rec.id || (rec.name || '').toLowerCase(), ...rec }));
  }

  // Resolve exactly one object by id (or, transitionally, by name). Null if not granted/known.
  async resolve(id) {
    if (!id) return null;
    const key = String(id).toLowerCase();
    return (await this.list()).find(o => o.id === key || (o.name || '').toLowerCase() === key) || null;
  }

  // The desktop-role record — the Shell's resting layer (role:"desktop" in its manifest).
  // Launcher presenters skip it; the Shell mounts it. Null = no desktop granted (start screen-less
  // shell still works; the stage just rests empty).
  async desktop() { return (await this.list()).find(o => o.role === 'desktop') || null; }

  // The location of an object's content — derived ONLY here from the registry record. Nobody else
  // forms a content path. This confines physical layout to a single function.
  contentUrl(rec) { return rec && rec.file ? (this._base + '/' + rec.file) : null; }

  // The Shell's object layout — which chrome objects to mount, in order. A registry query
  // (\Shell\Layout): served by ProjectionServer (from Cm) on device, a /shell-layout stub in dev.
  // If the registry can't answer, degrade to the irreducible minimum (the Taskbar) — that is
  // resilience (SHELL-SPEC §3), not held truth: the registry remains the source when present.
  async layout() {
    try {
      const r = await fetch(this._base + '/shell-layout', { cache: 'no-store' });
      if (r.ok) { const l = await r.json(); if (Array.isArray(l) && l.length) return l; }
    } catch (_) { /* fall through to the minimum */ }
    return [{ id: 'taskbar', type: 'taskbar', path: '\\Shell\\Taskbar', position: 'top' }];
  }

  // Shell verbs (\Shell\Verb\<scope>\<verb>) — the menu's entries. [{path,scope,menu,label,icon,command}].
  // Served by ProjectionServer (from Cm) on device, a /verbs stub in dev. Degrades to none.
  async verbs() {
    try {
      const r = await fetch(this._base + '/verbs', { cache: 'no-store' });
      return r.ok ? await r.json() : [];
    } catch (_) { return []; }
  }

  // Drop the cache so the next resolve re-reads the registry (after a register/unregister).
  invalidate() { this._records = null; }
}
