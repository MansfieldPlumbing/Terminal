/* /schemes-editor.js — the Windows-Terminal-style color-scheme picker/editor UI.
 *
 * Consumes the schemes.js engine; holds the DOM. Mount it anywhere:
 *     SchemesEditor.mount(containerEl, { appId: 'terminal' });
 * LIST mode = the swatch-card list + "Add new" (the Settings>Personalization screenshot).
 * EDIT mode = live preview + per-color pickers + Save/Discard (+ Delete for user schemes).
 *
 * STRUCTURE is the point here; visual polish is intentionally light (theme-var driven).
 * Styling hooks off the global theme tokens (--accent, --surface, --border, --fg, --muted).
 */
(function () {
  'use strict';
  const S = window.Schemes;
  if (!S) { console.warn('schemes-editor: schemes.js not loaded'); }

  const COLOR_NAMES = ['Black','Red','Green','Yellow','Blue','Purple','Cyan','White'];
  const UI_NAMES = ['Foreground','Background','Cursor color','Selection background'];

  let STYLE_INJECTED = false;
  function injectStyle() {
    if (STYLE_INJECTED) return; STYLE_INJECTED = true;
    const css = `
    .sce-wrap { color: var(--fg, #f2f2f2); font-family: var(--font-sans, system-ui, sans-serif); }
    .sce-surface { background: var(--surface, #1a1a1a); border: 1px solid var(--border, rgba(255,255,255,.1)); border-radius: 8px; overflow: hidden; }
    .sce-head { padding: 16px 20px; border-bottom: 1px solid var(--border, rgba(255,255,255,.1)); font-size: 14px; font-weight: 600; }
    .sce-body { padding: 24px; }
    .sce-note { font-size: 13px; color: var(--muted, #9ca3af); margin: 0 0 24px; }
    .sce-btn { display: inline-flex; align-items: center; gap: 8px; padding: 8px 16px; border: 1px solid var(--border, rgba(255,255,255,.15));
               background: rgba(255,255,255,.06); color: var(--fg, #fff); font: inherit; font-size: 13px; font-weight: 500;
               border-radius: 6px; cursor: pointer; transition: background .15s; }
    .sce-btn:hover { background: rgba(255,255,255,.12); }
    .sce-btn.primary { background: var(--accent, #0084ff); border-color: transparent; color: #fff; }
    .sce-btn.danger:hover { background: rgba(239,68,68,.25); border-color: rgba(239,68,68,.5); }

    .sce-card { display: flex; align-items: center; gap: 16px; padding: 12px; border-radius: 8px; cursor: pointer;
                border: 1px solid transparent; transition: background .15s, border-color .15s; }
    .sce-card:hover { background: rgba(255,255,255,.04); }
    .sce-card.active { border-color: var(--accent, #0084ff); background: rgba(255,255,255,.04); }
    .sce-swatch { display: flex; flex-direction: column; gap: 2px; padding: 8px; border-radius: 6px; background: #000; width: max-content; }
    .sce-row { display: flex; gap: 2px; }
    .sce-sq { width: 14px; height: 14px; border-radius: 2px; }
    .sce-info { flex: 1; display: flex; align-items: center; justify-content: space-between; font-size: 15px; font-weight: 500; }
    .sce-badge { font-size: 11px; padding: 2px 6px; border: 1px solid var(--border, #4b5563); border-radius: 4px; margin-left: 8px; font-weight: 400; color: var(--muted, #9ca3af); }
    .sce-edit { opacity: 0; font-size: 12px; padding: 4px 12px; }
    .sce-card:hover .sce-edit { opacity: 1; }

    .sce-pickrow { display: flex; justify-content: space-between; align-items: center; padding: 10px 0; }
    .sce-pickrow span { font-size: 13px; font-weight: 500; color: var(--fg, #d1d5db); }
    .sce-pick { width: 32px; height: 32px; border-radius: 4px; border: 1px solid rgba(0,0,0,.5); overflow: hidden; position: relative; cursor: pointer; }
    .sce-pick input { position: absolute; top: -8px; left: -8px; width: 56px; height: 56px; opacity: 0; cursor: pointer; border: none; }
    .sce-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 48px; }
    .sce-preview { border-radius: 6px; padding: 20px; margin-bottom: 24px; border: 1px solid var(--border, rgba(255,255,255,.05)); }
    .sce-preview-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; font-family: var(--font-mono, monospace); font-size: 14px; }
    .sce-footer { display: flex; justify-content: flex-end; gap: 12px; margin-top: 24px; }
    `;
    const el = document.createElement('style');
    el.textContent = css;
    document.head.appendChild(el);
  }

  function mount(container, opts) {
    opts = opts || {};
    const appId = opts.appId || null;
    injectStyle();
    container.classList.add('sce-wrap');

    let mode = 'LIST';     // 'LIST' | 'EDIT'
    let draft = null;      // scheme being edited (working copy)
    let draftIsNew = false;

    function swatch(scheme) {
      const top = S.SLOTS.map(k => `<div class="sce-sq" style="background:${scheme.colors[k] || '#000'}"></div>`).join('');
      const bot = S.SLOTS.map(k => `<div class="sce-sq" style="background:${scheme.colors[S.brightOf(k)] || scheme.colors[k] || '#000'}"></div>`).join('');
      return `<div class="sce-swatch"><div class="sce-row">${top}</div><div class="sce-row">${bot}</div></div>`;
    }

    function renderList() {
      const activeName = S.activeName(appId);
      const cards = S.list().map(s => `
        <div class="sce-card ${s.name === activeName ? 'active' : ''}" data-name="${s.name}" data-act="select">
          ${swatch(s)}
          <div class="sce-info">
            <div>${s.name}${s.isDefault ? '<span class="sce-badge">default</span>' : ''}${s.name === activeName ? '<span class="sce-badge">active</span>' : ''}</div>
            <button class="sce-btn sce-edit" data-name="${s.name}" data-act="edit">Edit</button>
          </div>
        </div>`).join('');
      container.innerHTML = `
        <div class="sce-surface">
          <div class="sce-head">Terminal Color Schemes</div>
          <div class="sce-body">
            <p class="sce-note">Schemes defined here apply to the terminal${appId ? '' : ' (global default)'}. Pick one to activate it.</p>
            <button class="sce-btn" data-act="add" style="margin-bottom:24px;">+ Add new</button>
            <div>${cards}</div>
          </div>
        </div>`;
    }

    function renderEdit() {
      const c = draft.colors;
      const preview = S.SLOTS.map((k, i) => `
        <div style="color:${c[k]}">${COLOR_NAMES[i]}</div>
        <div style="color:${c[S.brightOf(k)] || c[k]}">Bright ${COLOR_NAMES[i]}</div>`).join('');

      const colorPickers = S.SLOTS.map((k, i) => {
        const bk = S.brightOf(k);
        return `<div class="sce-pickrow">
          <span>${COLOR_NAMES[i]}</span>
          <div style="display:flex; gap:12px;">
            <div class="sce-pick" style="background:${c[k]}"><input type="color" value="${c[k]}" data-key="${k}"></div>
            <div class="sce-pick" style="background:${c[bk] || c[k]}"><input type="color" value="${c[bk] || c[k]}" data-key="${bk}"></div>
          </div></div>`;
      }).join('');

      const uiPickers = S.UI_SLOTS.map((k, i) => `
        <div class="sce-pickrow">
          <span>${UI_NAMES[i]}</span>
          <div class="sce-pick" style="background:${c[k]}"><input type="color" value="${(c[k] || '#000000').slice(0,7)}" data-key="${k}"></div>
        </div>`).join('');

      const canDelete = !draftIsNew && !(S.get(draft.name) && S.get(draft.name).isDefault);
      container.innerHTML = `
        <div class="sce-preview" style="background:${c.background}; color:${c.foreground}">
          <div style="font-size:14px; font-weight:600; margin-bottom:16px;">Preview</div>
          <div class="sce-preview-grid">${preview}</div>
        </div>
        <div class="sce-surface">
          <div class="sce-head">
            <input data-act="name" value="${draft.name.replace(/"/g,'&quot;')}"
              style="background:transparent; border:none; color:var(--fg,#fff); font:inherit; font-weight:600; outline:none; width:60%;">
          </div>
          <div class="sce-body sce-grid">
            <div>${colorPickers}</div>
            <div>${uiPickers}</div>
          </div>
        </div>
        <div class="sce-footer">
          ${canDelete ? `<button class="sce-btn danger" data-act="delete">Delete</button>` : ''}
          <button class="sce-btn" data-act="cancel">Discard changes</button>
          <button class="sce-btn primary" data-act="save">Save</button>
        </div>`;
    }

    function render() { (mode === 'EDIT' ? renderEdit : renderList)(); }

    // Single delegated handler — structural, easy to re-skin.
    container.addEventListener('click', (e) => {
      const t = e.target.closest('[data-act]');
      if (!t) return;
      const act = t.dataset.act;
      if (act === 'select') { S.setActive(t.dataset.name, appId); render(); }
      else if (act === 'add') { draft = S.blank(S.activeName(appId)); draftIsNew = true; mode = 'EDIT'; render(); }
      else if (act === 'edit') { e.stopPropagation(); draft = S.get(t.dataset.name); draftIsNew = false; mode = 'EDIT'; render(); }
      else if (act === 'cancel') { mode = 'LIST'; draft = null; render(); }
      else if (act === 'save') {
        S.save(draft);
        S.setActive(draft.name, appId);
        mode = 'LIST'; draft = null; render();
      }
      else if (act === 'delete') { S.remove(draft.name); mode = 'LIST'; draft = null; render(); }
    });

    container.addEventListener('input', (e) => {
      if (mode !== 'EDIT' || !draft) return;
      const inp = e.target;
      if (inp.dataset.key) { draft.colors[inp.dataset.key] = inp.value.toUpperCase(); renderEdit(); }
      else if (inp.dataset.act === 'name') { draft.name = inp.value; }
    });

    render();
    return { refresh: render };
  }

  window.SchemesEditor = { mount };
})();
