/* lib/store.js — configuration store client for the Subsystem UI.
 *
 * Interacts with the backend /api/config/<key> endpoints and uses localStorage
 * solely as an offline cache and optimistic fallback.
 */

export async function getConfig(key) {
  try {
    const r = await fetch(`/api/config/${key}`, { cache: 'no-store' });
    if (r.ok) {
      const val = await r.text();
      localStorage.setItem(key, val);
      return val;
    }
  } catch (e) {
    console.warn(`Failed to fetch config for ${key} from backend:`, e);
  }
  // TODO(backend): /api/config/<key>
  return localStorage.getItem(key);
}

export async function setConfig(key, value) {
  const strVal = typeof value === 'string' ? value : JSON.stringify(value);
  localStorage.setItem(key, strVal);

  try {
    const r = await fetch(`/api/config/${key}`, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: strVal
    });
    if (!r.ok) {
      console.warn(`Failed to save config for ${key} to backend: HTTP ${r.status}`);
    }
  } catch (e) {
    console.warn(`Failed to save config for ${key} to backend:`, e);
  }
  // TODO(backend): /api/config/<key>
}

export function getConfigSync(key) {
  return localStorage.getItem(key);
}
