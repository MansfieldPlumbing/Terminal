// actemplate.js — a deliberately MINIMAL Adaptive Card template expander (the ${...} data-binding
// subset our cards actually use), replacing adaptivecards-templating. The Microsoft package is 9 KB
// of glue around adaptive-expressions — a ~1 MB expression VM — for what is, in every card we mint,
// a property lookup. Surge-protector doctrine: own the 40 lines, bat the dependency to ground.
//
// Supported: ${prop}, ${a.b.c}, ${$root.x} in any string value (multiple per string); `$when` on any
// object (falsy/"false" ⇒ the element is dropped). NOT supported (left literal + console.warn once):
// functions, operators, indexers — if a template needs real AEL, that's the cue to vendor it then.

function lookup(data, path) {
  if (path.startsWith('$root.')) path = path.slice(6);
  let v = data;
  for (const part of path.split('.')) {
    if (v == null) return undefined;
    v = v[part];
  }
  return v;
}

const COMPLEX = /[^A-Za-z0-9_.$]/;   // anything beyond a dotted property path = AEL territory
let warned = false;

function expandString(s, data) {
  // A whole-string single binding returns the RAW value (numbers/booleans survive — standard
  // templating behavior, and what makes `$when: "${SomeBool}"` work).
  const whole = /^\$\{([^}]+)\}$/.exec(s);
  if (whole) {
    const expr = whole[1].trim();
    if (!COMPLEX.test(expr)) {
      const v = lookup(data, expr);
      return v === undefined || v === null ? s : v;
    }
  }
  return s.replace(/\$\{([^}]+)\}/g, (m, expr) => {
    expr = expr.trim();
    if (COMPLEX.test(expr)) {
      if (!warned) { console.warn('actemplate: unsupported expression left literal:', expr); warned = true; }
      return m;
    }
    const v = lookup(data, expr);
    return v === undefined || v === null ? m : String(v);
  });
}

function expandNode(node, data) {
  if (typeof node === 'string') return expandString(node, data);
  if (Array.isArray(node)) {
    const out = [];
    for (const item of node) {
      const e = expandNode(item, data);
      if (e !== undefined) out.push(e);
    }
    return out;
  }
  if (node && typeof node === 'object') {
    // $when — conditional presence: a falsy/"false" expansion drops the element entirely.
    if ('$when' in node) {
      const w = expandNode(node.$when, data);
      if (w === false || w === 'false' || w === undefined || w === null || w === '') return undefined;
    }
    const out = {};
    for (const [k, v] of Object.entries(node)) {
      if (k === '$when') continue;
      const e = expandNode(v, data);
      if (e !== undefined) out[k] = e;
    }
    return out;
  }
  return node;
}

// expand(template, data) → a new card payload with ${bindings} resolved against `data` ($root).
export function expand(template, data) {
  return expandNode(template, data || {});
}
