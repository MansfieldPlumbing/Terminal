/* lib/psrp.js — the PSRP session client for presenters.
 *
 * The renderer can't speak MS-PSRP itself; this talks to the /psrp seam, which brokers
 * a real remote runspace over the Subsystem.Psrp named pipe (\Capability\Remoting\Psrp; backend Rs).
 *
 * Contract (vs. lib/api.js executeCommand): commands are STRUCTURED — [{ name, parameters }] —
 * so parameters cross the seam as data; no PowerShell string interpolation, no quoting/injection
 * class. Results come back as a JSON ARRAY (the backend appends ConvertTo-Json -AsArray remotely).
 * Session state ($PWD, variables, modules) persists across invokes for the life of the session.
 *
 *   const psrp = new PsrpSession('files');
 *   const items = await psrp.invoke([
 *     { name: 'Get-ChildItem', parameters: { LiteralPath: '/sdcard', Force: true } },
 *   ]);
 *
 * Lifecycle: opens lazily on first invoke; a "no-session" refusal (idle-reaped / app restart)
 * reopens and retries once; pagehide closes via sendBeacon so the pipe frees for the next owner.
 *
 * Two lanes (the pipe serves ONE connection at a time — backend Rs):
 *   shared (default for presenters): new PsrpSession('edit', { shared: true }) — multiplexes onto the
 *     backend's one shared remote runspace. Right whenever the presenter passes absolute paths and
 *     keeps no runspace state; any number of presenters coexist. close() is a no-op (shared lane is
 *     reaped server-side, never killed by one tab).
 *   exclusive: new PsrpSession('repl') — a private runspace whose state ($PWD, variables) persists
 *     across invokes. Takes the whole pipe; opening it evicts the shared lane until it closes.
 */

async function post(path, payload) {
  const res = await fetch(path, { method: 'POST', body: JSON.stringify(payload) });
  if (!res.ok) throw new Error(`HTTP error ${res.status}`);
  return res.json();
}

export class PsrpSession {
  constructor(owner, opts = {}) {
    this.owner = owner || 'presenter';
    this.shared = !!opts.shared;
    this.id = this.shared ? 'shared' : null;
    this._opening = null;
    if (!this.shared) window.addEventListener('pagehide', () => this.close());
  }

  async open() {
    if (this.shared) return this.id;   // the backend materializes the shared lane on first invoke
    // Coalesce concurrent opens into one in-flight request.
    if (this._opening) return this._opening;
    this._opening = (async () => {
      const json = await post('/psrp/session', { owner: this.owner });
      if (json.error) throw new Error(json.error);
      this.id = json.id;
      return this.id;
    })();
    try { return await this._opening; }
    finally { this._opening = null; }
  }

  /** commands: [{ name, parameters? }] → resolves to the result array. */
  async invoke(commands, opts = {}) {
    if (!this.id) await this.open();
    let json = await post('/psrp/invoke', { session: this.id, commands, depth: opts.depth || 4 });
    if (json.code === 'no-session' && !this.shared) {
      // The broker reaped us (idle) or the backend restarted — reopen once and retry.
      this.id = null;
      await this.open();
      json = await post('/psrp/invoke', { session: this.id, commands, depth: opts.depth || 4 });
    }
    if (json.error) throw new Error(json.error);
    return json.data || [];
  }

  /** Raw script in an EXCLUSIVE session (the REPL lane — the backend refuses it for shared).
   *  Resolves to the combined output+error text. */
  async run(script) {
    if (this.shared) throw new Error('The shared lane does not run script.');
    if (!this.id) await this.open();
    let json = await post('/psrp/run', { session: this.id, script });
    if (json.code === 'no-session') {
      this.id = null;
      await this.open();
      json = await post('/psrp/run', { session: this.id, script });
    }
    if (json.error) throw new Error(json.error);
    return json.text ?? '';
  }

  close() {
    if (!this.id || this.shared) return;   // the shared lane outlives any one tab
    const body = JSON.stringify({ session: this.id });
    this.id = null;
    try {
      if (!navigator.sendBeacon('/psrp/close', body)) {
        fetch('/psrp/close', { method: 'POST', body, keepalive: true }).catch(() => {});
      }
    } catch (e) {
      try { fetch('/psrp/close', { method: 'POST', body, keepalive: true }).catch(() => {}); } catch (e2) {}
    }
  }
}
