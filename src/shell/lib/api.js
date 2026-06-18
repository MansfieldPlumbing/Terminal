/* lib/api.js — the unified API helper for WS client and cmdlet execution.
 *
 * Implements a single reusable WebSocketClient class featuring auto-reconnection
 * with backoff, and an executeCommand function to call C# backend seams.
 */

export class WebSocketClient {
  constructor(urlPath, options = {}) {
    this.urlPath = urlPath;
    this.onOpen = options.onOpen || (() => {});
    this.onMessage = options.onMessage || (() => {});
    this.onClose = options.onClose || (() => {});
    this.onReconnecting = options.onReconnecting || (() => {});
    
    this.ws = null;
    this.reconnectDelay = options.reconnectDelay || 2000;
    this.maxReconnectDelay = options.maxReconnectDelay || 10000;
    this.currentDelay = this.reconnectDelay;
    this.shouldReconnect = true;
  }

  connect() {
    if (!this.shouldReconnect) return;
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const host = location.hostname || '127.0.0.1';
    const port = location.port || (location.protocol === 'https:' ? '443' : '8080');
    const url = `${protocol}//${host}:${port}${this.urlPath}?cap=${encodeURIComponent(capToken())}`;

    try {
      this.ws = new WebSocket(url);
    } catch (e) {
      this.handleClose();
      return;
    }

    this.ws.onopen = () => {
      this.currentDelay = this.reconnectDelay; // reset backoff
      this.onOpen();
    };

    this.ws.onmessage = (e) => {
      this.onMessage(e.data);
    };

    this.ws.onclose = () => {
      this.handleClose();
    };

    this.ws.onerror = () => {
      // close will follow
    };
  }

  handleClose() {
    this.onClose();
    if (this.shouldReconnect) {
      this.onReconnecting();
      setTimeout(() => {
        this.connect();
        // exponential backoff
        this.currentDelay = Math.min(this.currentDelay * 1.5, this.maxReconnectDelay);
      }, this.currentDelay);
    }
  }

  send(data) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const msg = typeof data === 'string' ? data : JSON.stringify(data);
      this.ws.send(msg);
      return true;
    }
    return false;
  }

  close() {
    this.shouldReconnect = false;
    if (this.ws) {
      this.ws.close();
    }
  }
}

// The loopback capability token — locks /api/exec + the command WebSockets against other apps on the
// device. Provided IN-PROCESS by the WebView host (AndroidBridge.getCap() on Android; window.__ssCap on
// the Windows head). Never on the wire, so a foreign app can't read it; random per boot, so it can't guess.
export function capToken() {
  try { if (window.AndroidBridge && window.AndroidBridge.getCap) return window.AndroidBridge.getCap() || ""; } catch (_) {}
  return (window.__ssCap || "");
}

export async function executeCommand(command) {
  const res = await fetch("/api/exec", {
    method: "POST",
    headers: { "X-Subsystem-Cap": capToken() },
    body: command,
  });
  if (!res.ok) throw new Error(`HTTP error ${res.status}`);
  const json = await res.json();
  if (json && json.error) throw new Error(json.error);
  return json;
}
