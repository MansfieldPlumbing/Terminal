/* lib/download.js — file download for presenters (the Blazor pattern, vanilla).
 *
 * Mirrors blazor-samples' downloadFileFromStream / triggerFileDownload helpers: materialize the
 * bytes client-side, hand them to an <a download> with an object URL, click, revoke. Works in any
 * desktop browser projecting the shell over the adb forward; on-device the bytes are already on
 * the phone, so presenters mostly offer this for the projection case.
 *
 *   import { downloadText, downloadBase64 } from '/lib/download.js';
 *   downloadText('notes.txt', editor.getValue());
 *   downloadBase64('photo.jpg', b64FromBackend, 'image/jpeg');
 */

export function downloadBlob(fileName, blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName || 'download';
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export function downloadText(fileName, text, mime = 'text/plain;charset=utf-8') {
  downloadBlob(fileName, new Blob([text], { type: mime }));
}

export function downloadBase64(fileName, base64, mime = 'application/octet-stream') {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  downloadBlob(fileName, new Blob([bytes], { type: mime }));
}

/* THE BYTE LANE — fetch a staged Float32 VOM region (the CoreCLR→WebView interop) and save it.
 * `handle` comes from the backend's Publish-SsFileLane verb; `size` is the true byte length (the
 * region pads to the Float32 layout — slice the padding off). Tries the native vom:// scheme first
 * (intercepted by the WebView client), then the loopback alias /vom/<handle> — one named handle,
 * two schemes, no JSON envelope either way. */
export async function fetchVomLane(handle, size) {
  let buf = null;
  for (const url of [`vom://${handle}`, `/vom/${encodeURIComponent(handle)}`]) {
    try {
      const res = await fetch(url);
      if (res.ok) { buf = await res.arrayBuffer(); if (buf.byteLength > 0) break; }
    } catch (e) { /* scheme not fetchable here — try the next face */ }
  }
  if (!buf || buf.byteLength === 0) throw new Error('VOM lane returned no bytes');
  return (typeof size === 'number' && size >= 0 && size <= buf.byteLength) ? buf.slice(0, size) : buf;
}

export async function downloadVomLane(fileName, handle, size, mime = 'application/octet-stream') {
  const buf = await fetchVomLane(handle, size);
  downloadBlob(fileName, new Blob([buf], { type: mime }));
}

/* Last rung of the degradation ladder: hand the bytes to the Android system chooser (ACTION_SEND)
 * instead of a browser download — "android message or base64 rn" (the user's graceful-degrade
 * directive). Text/JSON shares as text; anything else we don't force. The host owns the share;
 * the renderer just asks. Returns true if the bridge took it. */
export function shareTextOut(title, text, mime = 'text/plain') {
  try {
    if (window.AndroidBridge && window.AndroidBridge.shareText) {
      window.AndroidBridge.shareText(title || '', text, mime);
      return true;
    }
  } catch (e) { /* bridge absent (projection/browser) — caller falls back */ }
  return false;
}
