// dg.js — the shell's diagnostic sink + BUGCHECK (the frontend Dg; mirrors backend Subsystem.Dg).
//
// ONE sink, many writers. A presenter that hits trouble calls Dg.warn/Dg.error here instead of
// swallowing into an empty catch. Records are tagged + leveled, held in a bounded ring AND mirrored to
// the console (filter by the [tag] prefix at read time) — so "it's a nightmare to diagnose" becomes a
// query, not an autopsy.
//
// The terminal level is Dg.bugcheck(codeName, module, detail) — the NT KeBugCheckEx analog. When the
// shell loses truth it CANNOT degrade through (a theme bundle that never loaded; a required projection
// that came back empty; a security gate that can't read its own state), there is no fallback for lost
// truth. It HALTS and shows the stop screen with the code. This is the fault handler that REPLACES every
// `var(--x,#lit)` fallback and every silent catch: lost truth faults loudly, it never papers over.
//
// The bluescreen is the ONE component that carries literal colors, by necessity — it must render when all
// theme truth is gone, exactly as the NT bugcheck runs without the rest of the OS. That is not a fallback;
// it is the fault itself, wearing the only colors that do not depend on the thing that failed.
(function () {
  'use strict';
  if (window.Dg) return;                                   // single instance per window

  var RING = 300, ring = [];

  function rec(level, tag, msg) {
    var r = { t: Date.now(), level: level, tag: tag || '?', msg: String(msg == null ? '' : msg) };
    ring.push(r); if (ring.length > RING) ring.shift();
    var line = '[' + r.tag + '] ' + r.msg;                 // filterable by the [tag] prefix
    if (level === 'fatal' || level === 'error') console.error(line);
    else if (level === 'warn') console.warn(line);
    else console.log(line);
    return r;
  }

  // STOP codes — mechanism-named (NT-style symbolic + hex). Each marks a class of LOST TRUTH the shell
  // cannot degrade through. Add a code when a new structural invariant becomes violable.
  var STOP = {
    THEME_TRUTH_MISSING:        0x00000050,   // the theme var bundle never loaded; no colors to paint
    REGISTRY_PROJECTION_LOST:   0x000000C5,   // a required Cm projection came back empty / unreachable
    PRESENTER_HELD_TRUTH:       0x0000006B,   // a presenter was caught holding its own truth at runtime
    CONSENT_GATE_INDETERMINATE: 0x000000CA,   // a security gate could not read its state -> fail closed
    SHELL_UNHANDLED_FAULT:      0x0000007E    // an uncaught fault escalated to a halt
  };

  var halted = false;
  function hex(n) { return '0x' + ('00000000' + (n >>> 0).toString(16).toUpperCase()).slice(-8); }

  function bluescreen(codeName, code, module, detail) {
    // Self-contained: NO theme vars, NO external CSS, NO registry. Classic NT blue, white monospace, the
    // STOP line front and centre, then the diagnostic ring tail (the report that makes it diagnosable).
    var tail = ring.slice(-14).map(function (r) {
      var ts = new Date(r.t).toISOString().slice(11, 23);
      return ts + '  ' + r.level.toUpperCase().padEnd(5) + '  [' + r.tag + '] ' + r.msg;
    }).join('\n');

    var report =
      'A problem has been detected and the Subsystem has been halted to prevent loss of truth.\n\n' +
      codeName + '\n\n' +
      'The failing object below lost the state it is a projection of. There is no fallback for lost\n' +
      'truth — the shell faults instead of rendering a stale default.\n\n' +
      '*** STOP: ' + hex(code) + '  (' + codeName + ')\n' +
      '*** Module:  ' + (module || 'shell') + '\n' +
      (detail ? '*** Detail:  ' + detail + '\n' : '') +
      '\n--- diagnostic ring (most recent) ---\n' +
      (tail || '(empty)') +
      '\n\n[ tap to copy this report ]      [ press R to reload the shell ]';

    var el = document.createElement('div');
    el.id = 'ss-bugcheck';
    el.setAttribute('role', 'alertdialog');
    el.style.cssText = [
      'position:fixed', 'inset:0', 'z-index:2147483647', 'background:#0000AA', 'color:#FFFFFF',
      'font:13px/1.55 "Cascadia Code","Cascadia Mono",Consolas,"Courier New",monospace',
      'padding:6vh 6vw', 'margin:0', 'overflow:auto', 'white-space:pre-wrap', 'word-break:break-word',
      'cursor:pointer', '-webkit-user-select:text', 'user-select:text'
    ].join(';');
    el.textContent = report;
    el.addEventListener('click', function () { try { navigator.clipboard.writeText(report); } catch (_) {} });

    var reload = function (e) { if (e.key === 'r' || e.key === 'R') location.reload(); };
    window.addEventListener('keydown', reload);
    document.body.appendChild(el);                          // fixed + max z-index: the fault owns the screen
  }

  function bugcheck(codeName, module, detail) {
    var code = STOP[codeName]; if (code == null) { codeName = 'SHELL_UNHANDLED_FAULT'; code = STOP.SHELL_UNHANDLED_FAULT; }
    rec('fatal', 'bugcheck', codeName + ' ' + hex(code) + (module ? ' @' + module : '') + (detail ? ' — ' + detail : ''));
    if (halted) return;                                    // first bugcheck owns the screen; later ones still record
    halted = true;
    try { bluescreen(codeName, code, module, detail); }
    catch (e) { console.error('BUGCHECK render failed', codeName, e); }   // last resort: even the fault screen failed
  }

  // Global faults RECORD (loud, diagnosable) but do NOT auto-bugcheck — not every error is a lost-truth
  // halt. A bugcheck is reserved for a violated structural invariant a writer declares explicitly.
  window.addEventListener('error', function (e) {
    rec('error', 'window', (e && e.message ? e.message : 'script error') + (e && e.filename ? ' @' + e.filename + ':' + e.lineno : ''));
  });
  window.addEventListener('unhandledrejection', function (e) {
    rec('error', 'promise', (e && e.reason && (e.reason.message || e.reason)) || 'unhandled rejection');
  });

  window.Dg = {
    STOP: STOP,
    info:  function (tag, msg) { return rec('info',  tag, msg); },
    warn:  function (tag, msg) { return rec('warn',  tag, msg); },
    error: function (tag, msg) { return rec('error', tag, msg); },
    fault: function (tag, msg) { return rec('error', tag, msg); },     // alias — a recorded fault
    recent: function (n) { return ring.slice(-(n || 50)); },
    bugcheck: bugcheck,
    halted: function () { return halted; }
  };

  rec('info', 'dg', 'frontend diagnostic sink up');
})();
