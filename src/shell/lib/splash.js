/* lib/splash.js — the presenter splash / loading overlay (shared, theme-driven).
 *
 * The Blazor WASM boot pattern (blazor-samples: loading-progress ring driven by a CSS custom
 * property, swapped out when the app takes over) adapted to vanilla presenters: a full-surface
 * overlay with a progress ring, shown until the presenter's first real render, with determinate
 * progress when the caller knows it (downloads) and a slow indeterminate sweep when it doesn't.
 *
 *   import { Splash } from '/lib/splash.js';
 *   Splash.show('Loading editor…');     // overlay on (idempotent)
 *   Splash.progress(42, 'Downloading'); // determinate ring, percent text
 *   Splash.done();                      // fade out + remove
 *   Splash.fail('No backend', () => retry());  // error state with optional Retry
 *
 * Holds nothing, owns nothing: pure presenter chrome over the presenter while objects arrive.
 */

const CSS = `
.ss-splash {
  position: fixed; inset: 0; z-index: 1000;
  display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px;
  background: var(--bg); color: var(--muted);
  font-family: var(--font-sans); font-size: 13px;
  transition: opacity .25s ease; opacity: 1;
}
.ss-splash.closing { opacity: 0; pointer-events: none; }
.ss-splash svg { width: 72px; height: 72px; }
.ss-splash circle {
  fill: none; stroke-width: 6px; transform-origin: 50% 50%;
  stroke: var(--border);
}
.ss-splash circle:last-child {
  stroke: var(--accent); transform: rotate(-90deg);
  stroke-linecap: round;
  /* determinate: dasharray driven by --ss-load-percentage (the Blazor ring, theme-var colored) */
  stroke-dasharray: calc(3.141 * 0.8 * var(--ss-load-percentage, 25%)), 500%;
  transition: stroke-dasharray .15s ease-in-out;
}
.ss-splash.indeterminate circle:last-child { animation: ss-splash-sweep 1.1s linear infinite; }
@keyframes ss-splash-sweep { to { transform: rotate(270deg); } }
.ss-splash .ss-splash-text { min-height: 1.2em; }
.ss-splash .ss-splash-pct { color: var(--fg); font-weight: 600; }
.ss-splash.failed circle:last-child { stroke: var(--error); animation: none; }
.ss-splash button {
  border: 1px solid var(--border); background: transparent; color: var(--fg);
  padding: 6px 16px; border-radius: 6px; cursor: pointer; font-size: 12px;
}
.ss-splash button:hover { border-color: var(--accent); }
`;

let el = null;

function ensure() {
  if (el) return el;
  const style = document.createElement('style');
  style.textContent = CSS;
  document.head.appendChild(style);
  el = document.createElement('div');
  el.className = 'ss-splash indeterminate';
  el.innerHTML =
    '<svg><circle r="40%" cx="50%" cy="50%"/><circle r="40%" cx="50%" cy="50%"/></svg>' +
    '<div class="ss-splash-pct"></div><div class="ss-splash-text"></div>';
  document.body.appendChild(el);
  return el;
}

export const Splash = {
  show(text) {
    const s = ensure();
    s.classList.remove('closing', 'failed');
    s.classList.add('indeterminate');
    s.querySelector('.ss-splash-text').textContent = text || 'Loading…';
    s.querySelector('.ss-splash-pct').textContent = '';
    const btn = s.querySelector('button'); if (btn) btn.remove();
  },
  progress(pct, text) {
    const s = ensure();
    s.classList.remove('closing', 'failed', 'indeterminate');
    s.style.setProperty('--ss-load-percentage', Math.max(0, Math.min(100, pct)) + '%');
    s.querySelector('.ss-splash-pct').textContent = Math.round(pct) + '%';
    if (text != null) s.querySelector('.ss-splash-text').textContent = text;
  },
  done() {
    if (!el) return;
    el.classList.add('closing');
    setTimeout(() => { el?.remove(); el = null; }, 300);
  },
  fail(text, retry) {
    const s = ensure();
    s.classList.remove('indeterminate', 'closing');
    s.classList.add('failed');
    s.querySelector('.ss-splash-pct').textContent = '';
    s.querySelector('.ss-splash-text').textContent = text || 'Something went wrong.';
    if (retry && !s.querySelector('button')) {
      const b = document.createElement('button');
      b.textContent = 'Retry';
      b.onclick = () => { Splash.show(); retry(); };
      s.appendChild(b);
    }
  },
};
