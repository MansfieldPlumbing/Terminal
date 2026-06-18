// accontrols.js — the shell's custom Adaptive Card INPUTS, registered ONCE with the vendored
// renderer and reused by every AC host (REGISTRY-SPEC §5: "Two custom inputs (Input.Slider,
// Input.Rocker) registered once, reused everywhere" — this file is that registration, plus the
// d-pad and stepper the control cards need).
//
//   Input.Rocker   — a two-state rocker switch (the SCM/`enabled` toggle; REGISTRY-SPEC §2)
//   Input.Slider   — a min/max/step range (volume, levels)
//   Input.DPad     — a 5-way directional pad (remote/navigation verbs), hold-to-repeat
//   Input.Stepper  — a − value + stepper (durations, counts)
//
// THE OBJECT LOOP STAYS INTACT: each control is a real AC Input (id → value, gathered by
// Action.Submit), and a control with a `verb` property AUTO-SUBMITS on interaction — it mints a
// SubmitAction `{ verb }`, so the press lands in the host's onExecuteAction → the card manifest's
// actions[verb].command → pwsh with $CardInputs. The control never names a command, never holds
// truth: behaviors stay verbs on the card object (invariant #5), this file only renders + raises.
//
// Classic script (no module): load AFTER vendor/adaptivecards/adaptivecards.min.js. Missing or
// incompatible renderer → warn and no-op; the host's existing error-card path covers the rest.
// Theme: every pixel comes from the theme vars (REGISTRY-SPEC §8.1) — no hardcoded color.

(function () {
  'use strict';
  var AC = typeof AdaptiveCards !== 'undefined' ? AdaptiveCards : null;
  if (!AC || !AC.Input || !AC.GlobalRegistry || !AC.StringProperty) {
    if (typeof console !== 'undefined') console.warn('accontrols: AdaptiveCards renderer unavailable — custom inputs not registered');
    return;
  }
  if (window.SSControls && window.SSControls.registered) return;   // once means once

  var V = AC.Versions.v1_0;

  // ---- shared: auto-submit a control's `verb` through the card's normal action pipeline --------
  // A minted SubmitAction parented to the input: prepareForExecution gathers EVERY input on the
  // card (id → value) and merges { verb }, so the host's runCardAction sees exactly the same shape
  // as a declared Action.Submit. No bespoke event channel — the one loop, raised programmatically.
  function fireVerb(input, verb) {
    if (!verb) return;
    try {
      var a = new AC.SubmitAction();
      a.setParent(input);
      a.data = { verb: verb };
      if (typeof a.execute === 'function') { a.execute(); return; }
      // older-renderer fallback: prepare + raise by hand
      if (!a.prepareForExecution || a.prepareForExecution()) {
        var root = input.getRootElement && input.getRootElement();
        var handler = (root && root.onExecuteAction) || AC.AdaptiveCard.onExecuteAction;
        if (handler) handler(a);
      }
    } catch (e) { console.warn('accontrols: verb submit failed (' + verb + ')', e); }
  }

  function changed(input) {
    try { if (typeof input.valueChanged === 'function') input.valueChanged(); } catch (e) { /* renderer variance */ }
  }

  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

  // The Surface host captures the pointer on pointerdown (pan/long-press) — capture RETARGETS
  // pointerup, so a `click` never composes on a card control under a real pointer. Every control
  // root stops pointerdown propagation (the same contract the PS card's inputs follow), keeping
  // taps on the control and pans on the wallpaper.
  function ownPointer(el) { el.addEventListener('pointerdown', function (e) { e.stopPropagation(); }); }

  // ---- Input.Rocker ----------------------------------------------------------------------------
  // value: boolean · onText/offText: the two faces · verb: auto-submit on flip.
  class RockerInput extends AC.Input {
    static valueProperty = new AC.BoolProperty(V, 'value', false);
    static onTextProperty = new AC.StringProperty(V, 'onText');
    static offTextProperty = new AC.StringProperty(V, 'offText');
    static verbProperty = new AC.StringProperty(V, 'verb');

    getJsonTypeName() { return 'Input.Rocker'; }

    internalRender() {
      var self = this;
      this._on = !!this.getValue(RockerInput.valueProperty);
      var root = document.createElement('div');
      root.className = 'ss-rocker';
      root.setAttribute('role', 'switch');
      root.tabIndex = 0;
      ownPointer(root);

      var off = document.createElement('button');
      off.type = 'button'; off.className = 'ss-rocker-half ss-rocker-off';
      off.textContent = this.getValue(RockerInput.offTextProperty) || 'OFF';
      var on = document.createElement('button');
      on.type = 'button'; on.className = 'ss-rocker-half ss-rocker-on';
      on.textContent = this.getValue(RockerInput.onTextProperty) || 'ON';
      root.append(off, on);

      var paint = function () {
        root.setAttribute('aria-checked', self._on ? 'true' : 'false');
        on.classList.toggle('active', self._on);
        off.classList.toggle('active', !self._on);
      };
      var set = function (next) {
        if (self._on === next) return;
        self._on = next;
        paint();
        changed(self);
        fireVerb(self, self.getValue(RockerInput.verbProperty));
      };
      off.onclick = function () { set(false); };
      on.onclick = function () { set(true); };
      root.onkeydown = function (e) { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); set(!self._on); } };
      paint();
      return root;
    }

    isSet() { return true; }
    get value() { return !!this._on; }
  }

  // ---- Input.Slider ----------------------------------------------------------------------------
  // value/min/max/step numeric · suffix: readout unit · verb: auto-submit on RELEASE (change),
  // never per-pixel — a level set is one verb, not a firehose.
  class SliderInput extends AC.Input {
    static valueProperty = new AC.NumProperty(V, 'value', 0);
    static minProperty = new AC.NumProperty(V, 'min', 0);
    static maxProperty = new AC.NumProperty(V, 'max', 100);
    static stepProperty = new AC.NumProperty(V, 'step', 1);
    static suffixProperty = new AC.StringProperty(V, 'suffix');
    static verbProperty = new AC.StringProperty(V, 'verb');

    getJsonTypeName() { return 'Input.Slider'; }

    internalRender() {
      var self = this;
      var min = Number(this.getValue(SliderInput.minProperty)) || 0;
      var max = Number(this.getValue(SliderInput.maxProperty));
      if (!isFinite(max)) max = 100;
      var suffix = this.getValue(SliderInput.suffixProperty) || '';
      this._num = clamp(Number(this.getValue(SliderInput.valueProperty)) || 0, min, max);

      var root = document.createElement('div');
      root.className = 'ss-slider';
      ownPointer(root);
      var range = document.createElement('input');
      range.type = 'range';
      range.min = String(min);
      range.max = String(max);
      range.step = String(Number(this.getValue(SliderInput.stepProperty)) || 1);
      range.value = String(this._num);
      var out = document.createElement('span');
      out.className = 'ss-slider-out';
      var paint = function () { out.textContent = String(self._num) + suffix; };
      range.oninput = function () { self._num = Number(range.value); paint(); };
      range.onchange = function () {            // release = commit
        self._num = Number(range.value);
        paint();
        changed(self);
        fireVerb(self, self.getValue(SliderInput.verbProperty));
      };
      root.append(range, out);
      paint();
      return root;
    }

    isSet() { return true; }
    get value() { return this._num || 0; }
  }

  // ---- Input.DPad -------------------------------------------------------------------------------
  // value: the LAST pressed direction (up/down/left/right/ok) · verb: auto-submit per press ·
  // repeatMs > 0 = hold-to-repeat after a 350ms arm (scroll remotes) · showCenter/centerText.
  class DPadInput extends AC.Input {
    static verbProperty = new AC.StringProperty(V, 'verb');
    static repeatMsProperty = new AC.NumProperty(V, 'repeatMs', 0);
    static showCenterProperty = new AC.BoolProperty(V, 'showCenter', true);
    static centerTextProperty = new AC.StringProperty(V, 'centerText');

    getJsonTypeName() { return 'Input.DPad'; }

    internalRender() {
      var self = this;
      this._dir = '';
      var verb = function () { return self.getValue(DPadInput.verbProperty); };
      var repeatMs = Number(this.getValue(DPadInput.repeatMsProperty)) || 0;

      var root = document.createElement('div');
      root.className = 'ss-dpad';
      ownPointer(root);

      var press = function (dir) {
        self._dir = dir;
        changed(self);
        fireVerb(self, verb());
      };

      var mk = function (dir, glyph, area) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'ss-dpad-btn ss-dpad-' + dir;
        b.style.gridArea = area;
        b.textContent = glyph;
        b.setAttribute('aria-label', dir);
        var hold = null, arm = null;
        var stop = function () {
          if (arm) { clearTimeout(arm); arm = null; }
          if (hold) { clearInterval(hold); hold = null; }
          window.removeEventListener('pointerup', stop, true);
          window.removeEventListener('pointercancel', stop, true);
        };
        b.addEventListener('pointerdown', function (e) {
          e.preventDefault();
          press(dir);
          if (repeatMs > 0) {
            arm = setTimeout(function () { hold = setInterval(function () { press(dir); }, Math.max(120, repeatMs)); }, 350);
            // window-level release guard: if the host re-renders the card mid-hold the button can
            // detach before its own pointerup ever fires — the capture-phase listeners make sure a
            // release ALWAYS clears the repeat timers (no orphaned interval pressing forever).
            window.addEventListener('pointerup', stop, true);
            window.addEventListener('pointercancel', stop, true);
          }
        });
        ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (ev) { b.addEventListener(ev, stop); });
        return b;
      };

      root.appendChild(mk('up', '▲', 'up'));
      root.appendChild(mk('left', '◀', 'left'));
      if (this.getValue(DPadInput.showCenterProperty)) {
        var c = mk('ok', this.getValue(DPadInput.centerTextProperty) || '●', 'mid');
        c.classList.add('ss-dpad-center');
        root.appendChild(c);
      }
      root.appendChild(mk('right', '▶', 'right'));
      root.appendChild(mk('down', '▼', 'down'));
      return root;
    }

    isSet() { return !!this._dir; }
    get value() { return this._dir || ''; }
  }

  // ---- Input.Stepper ----------------------------------------------------------------------------
  // value/min/max/step · suffix · verb: auto-submit, DEBOUNCED (400ms trailing) so a tap-burst
  // lands as one verb with the final value.
  class StepperInput extends AC.Input {
    static valueProperty = new AC.NumProperty(V, 'value', 0);
    static minProperty = new AC.NumProperty(V, 'min', 0);
    static maxProperty = new AC.NumProperty(V, 'max', 100);
    static stepProperty = new AC.NumProperty(V, 'step', 1);
    static suffixProperty = new AC.StringProperty(V, 'suffix');
    static verbProperty = new AC.StringProperty(V, 'verb');

    getJsonTypeName() { return 'Input.Stepper'; }

    internalRender() {
      var self = this;
      var min = Number(this.getValue(StepperInput.minProperty)) || 0;
      var max = Number(this.getValue(StepperInput.maxProperty));
      if (!isFinite(max)) max = 100;
      var step = Number(this.getValue(StepperInput.stepProperty)) || 1;
      var suffix = this.getValue(StepperInput.suffixProperty) || '';
      this._num = clamp(Number(this.getValue(StepperInput.valueProperty)) || 0, min, max);

      var root = document.createElement('div');
      root.className = 'ss-stepper';
      ownPointer(root);
      var out = document.createElement('span');
      out.className = 'ss-stepper-out';
      var paint = function () { out.textContent = String(self._num) + suffix; };
      var debounce = null;
      var bump = function (d) {
        self._num = clamp(self._num + d * step, min, max);
        paint();
        changed(self);
        if (debounce) clearTimeout(debounce);
        debounce = setTimeout(function () { debounce = null; fireVerb(self, self.getValue(StepperInput.verbProperty)); }, 400);
      };
      var mk = function (glyph, d) {
        var b = document.createElement('button');
        b.type = 'button'; b.className = 'ss-stepper-btn'; b.textContent = glyph;
        b.onclick = function () { bump(d); };
        return b;
      };
      root.append(mk('−', -1), out, mk('+', +1));
      paint();
      return root;
    }

    isSet() { return true; }
    get value() { return this._num || 0; }
  }

  // ---- register once ----------------------------------------------------------------------------
  AC.GlobalRegistry.elements.register('Input.Rocker', RockerInput);
  AC.GlobalRegistry.elements.register('Input.Slider', SliderInput);
  AC.GlobalRegistry.elements.register('Input.DPad', DPadInput);
  AC.GlobalRegistry.elements.register('Input.Stepper', StepperInput);

  // ---- the controls' chrome, themed entirely from the vars (REGISTRY-SPEC §8.1) -----------------
  var css = document.createElement('style');
  css.id = 'ss-accontrols';
  css.textContent =
    '.ss-rocker { display:inline-flex; border:1px solid var(--border); border-radius:10px; overflow:hidden; outline:none; }' +
    '.ss-rocker:focus-visible { border-color: var(--accent); }' +
    '.ss-rocker-half { border:none; background:transparent; color:var(--muted); font:600 12px var(--font-sans);' +
    '  letter-spacing:.5px; padding:8px 16px; cursor:pointer; transition: background .12s ease, color .12s ease; }' +
    '.ss-rocker-half.active { background:var(--accent); color:var(--accent-fg); }' +
    '.ss-rocker-off.active { background:rgba(127,127,127,.28); color:var(--fg); }' +
    '.ss-slider { display:flex; align-items:center; gap:10px; width:100%; }' +
    '.ss-slider input[type=range] { flex:1; min-width:0; accent-color: var(--accent); }' +
    '.ss-slider-out { flex:0 0 auto; min-width:3.5ch; text-align:right; color:var(--fg);' +
    '  font:600 13px var(--font-mono); font-variant-numeric: tabular-nums; }' +
    '.ss-dpad { display:grid; grid-template-areas:". up ." "left mid right" ". down ."; gap:6px;' +
    '  width:max-content; margin:2px auto; }' +
    '.ss-dpad-btn { width:46px; height:46px; border:1px solid var(--border); border-radius:12px;' +
    '  background:rgba(127,127,127,.16); color:var(--fg); font:16px var(--font-sans); cursor:pointer;' +
    '  touch-action:none; user-select:none; -webkit-user-select:none; }' +
    '.ss-dpad-btn:active { background:var(--accent); color:var(--accent-fg); }' +
    '.ss-dpad-center { border-radius:50%; color:var(--accent); }' +
    '.ss-stepper { display:inline-flex; align-items:center; gap:10px; }' +
    '.ss-stepper-btn { width:34px; height:34px; border:1px solid var(--border); border-radius:10px;' +
    '  background:rgba(127,127,127,.16); color:var(--fg); font:600 16px var(--font-sans); cursor:pointer; }' +
    '.ss-stepper-btn:active { background:var(--accent); color:var(--accent-fg); }' +
    '.ss-stepper-out { min-width:5ch; text-align:center; color:var(--fg);' +
    '  font:600 13px var(--font-mono); font-variant-numeric: tabular-nums; }';
  (document.head || document.documentElement).appendChild(css);

  window.SSControls = { registered: true, types: ['Input.Rocker', 'Input.Slider', 'Input.DPad', 'Input.Stepper'] };
})();
