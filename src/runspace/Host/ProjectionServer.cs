using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using Android.App;
using System.Linq;

namespace Subsystem;

public class ProjectionServer
{
    private HttpListener? _listener;
    private readonly MainActivity _mainActivity;
    private readonly ConcurrentDictionary<WebSocket, ClientState> _clients = new();

    private sealed class ClientState
    {
        public WebSocket Ws = null!;
        public Channel<(long TabId, byte[] Data)> Channel = null!;
        public CancellationTokenSource Cts = null!;
    }

    public ProjectionServer(MainActivity mainActivity)
    {
        _mainActivity = mainActivity;
    }

    // The one true loopback endpoint — clients resolve here instead of re-hardcoding host:port. This is
    // bootstrap infrastructure (the host binds before Cm is ready), so it lives HERE, not in a Cm record; Se +
    // BindGuard keep it loopback-only. Composed from IPAddress.Loopback + Port so the address and port are
    // defined in ONE place (Port) and no endpoint literal is baked into source.
    public const int    Port         = 8080;   // main UI/API/LLM backend
    public const int    ScreenPort   = 8081;   // isolated screen-mirror stream (heavy frames off the UI port)
    public static readonly string LoopbackBase = $"http://{IPAddress.Loopback}:{Port}/";

    // Per-boot loopback capability token. Loopback is NOT private on Android — any app with INTERNET can
    // reach 127.0.0.1:<Port>, and the command surfaces (/api/exec, /clixml, /psrp, the input WebSockets)
    // execute commands. They now require possession of this token: the in-process WebView fetches it via
    // AndroidBridge.getCap() (it never crosses the wire); dev tooling reads it from the private-dir .cap
    // file (own-uid / adb only). An unknown app can neither read nor guess it. Possession, not identity —
    // the Se gate finally applied to the local surface (Cm enable-gates are NOT enough: loopback ≠ private).
    public static readonly string CapToken = Guid.NewGuid().ToString("N");

    // The command surfaces consult this. Token rides an X-Subsystem-Cap header (HTTP) or a ?cap= query
    // (WebSocket — browser JS cannot set WS headers). Read-only GETs (static shell, /apps, /themes) stay
    // open; only the command/execution routes are gated — RCE is the door being locked.
    private static bool Authorized(HttpListenerContext ctx)
    {
        var tok = ctx.Request.Headers["X-Subsystem-Cap"];
        if (string.IsNullOrEmpty(tok)) tok = ctx.Request.QueryString["cap"];
        return !string.IsNullOrEmpty(tok) && string.Equals(tok, CapToken, StringComparison.Ordinal);
    }

    // Refuse an unauthorized command request and RECORD it (degrade + report — never an empty catch).
    // json=true returns the renderer-friendly envelope (the /api/exec data-lane rule); else a bare 401 close.
    private static void CloseUnauthorized(HttpListenerContext ctx, bool json)
    {
        try
        {
            if (json)
            {
                ctx.Response.ContentType = "application/json";
                var b = Encoding.UTF8.GetBytes("{\"error\":\"unauthorized\"}");
                ctx.Response.OutputStream.Write(b, 0, b.Length);
            }
            else ctx.Response.StatusCode = 401;
            ctx.Response.Close();
        }
        catch (Exception ex) { Subsystem.Dg.Log("http", "unauthorized-close: " + ex.Message); }
    }

    private int _screenPort = ScreenPort;

    // port      = main UI/API/LLM backend
    // screenPort = isolated screen-mirroring stream (heavy binary frames kept off the UI port)
    public void Start(int port = Port, int screenPort = ScreenPort)
    {
        _screenPort = screenPort;
        try {
            _listener = new HttpListener();
            Firewall.Attach(_mainActivity);   // Layer 2 zone firewall gets the Android context (ConnectivityManager)
            // Drop the per-boot capability token where only trusted callers can read it: the app's PRIVATE
            // dir (own-uid only; a dev build's `adb run-as` can read it for the dev tooling). Never networked.
            try {
                var capPath = System.IO.Path.Combine(_mainActivity.FilesDir!.AbsolutePath, ".cap");
                System.IO.File.WriteAllText(capPath, CapToken);
            } catch (Exception ex) { Android.Util.Log.Error("Subsystem", "cap file write failed: " + ex.Message); }
            // LOOPBACK ONLY — never 0.0.0.0 / all-interfaces. The control plane (/terminal shell, /api
            // exec, /screen capture+tap, RDP) must NOT be reachable from the network. The on-device
            // WebView + adb-forward use loopback; remote is a DELIBERATE, Se-gated, tunneled (Tailscale/
            // SPAKE2) opt-in — never raw `*` (Se charter #1).
            // Every prefix passes the BindGuard: loopback is always allowed; a non-loopback bind is REFUSED
            // unless HTTPS + an auth gate is present. No auth gate exists yet -> only loopback can ever bind.
            AddPrefixGuarded(_listener, $"http://127.0.0.1:{port}/",        authGateReady: false);
            AddPrefixGuarded(_listener, $"http://localhost:{port}/",        authGateReady: false);
            AddPrefixGuarded(_listener, $"http://127.0.0.1:{screenPort}/",  authGateReady: false);
            AddPrefixGuarded(_listener, $"http://localhost:{screenPort}/",  authGateReady: false);
            _listener.Start();
            // Seed the registry from the APK assets so /apps + /shell-layout resolve from Cm, not the
            // filesystem (REGISTRY-SPEC §1). Idempotent + reconciling; guarded so it never blocks the server.
            Task.Run(() => Registrar.SeedFromAssets(_mainActivity.Assets));
            Task.Run(ListenLoop);
        } catch (Exception ex) {
            Android.Util.Log.Error("Subsystem", "ProjectionServer Error: " + ex.ToString());
        }
    }

    public void Stop() {
        try {
            _listener?.Stop();
            _listener?.Close();
            _listener = null;
        } catch { }
    }

    // BindGuard — the control-plane bind invariant (Se charter #1). Loopback
    // (on-device, in-process) is always allowed. A NON-loopback interface may be bound ONLY when the channel
    // is HTTPS *and* an auth gate (2FA / SPAKE2 / Tailscale identity) is registered. Otherwise this THROWS
    // and the server refuses to start — "0.0.0.0 over plain http with no 2FA" is not a mistake you can make,
    // it cannot bind. HttpListener wildcards '+' and '*' (= all interfaces) are classified as non-loopback.
    private static void AddPrefixGuarded(HttpListener listener, string prefix, bool authGateReady)
    {
        string forParse = prefix.Replace("://+", "://0.0.0.0").Replace("://*", "://0.0.0.0");
        string host, scheme;
        try { var u = new Uri(forParse); host = u.Host; scheme = u.Scheme; }
        catch { host = "0.0.0.0"; scheme = "http"; }   // unparseable -> assume the worst (non-loopback)

        bool isLoopback = host == "localhost"
            || (System.Net.IPAddress.TryParse(host, out var ip) && System.Net.IPAddress.IsLoopback(ip));

        if (!isLoopback)
        {
            bool https = string.Equals(scheme, "https", StringComparison.OrdinalIgnoreCase);
            if (!https || !authGateReady)
                throw new InvalidOperationException(
                    "BindGuard: refusing non-loopback control-plane bind '" + prefix + "' — requires HTTPS + an " +
                    "auth gate (2FA / SPAKE2 / Tailscale identity). Loopback-only by default (Se charter #1).");
        }
        listener.Prefixes.Add(prefix);
    }

    private async Task ListenLoop()
    {
        if (_listener == null) return;

        while (true)
        {
            try {
                var context = await _listener.GetContextAsync();
                // Layer 2 — the zone firewall. Even if a non-loopback interface were somehow bound, a connection
                // whose zone has no allow rule is dropped HERE (default-deny; loopback/USB always pass).
                if (!Firewall.Allow(context.Request.RemoteEndPoint, context.Request.LocalEndPoint))
                {
                    try { context.Response.StatusCode = 403; context.Response.Close(); } catch { }
                    continue;
                }
                var req = context.Request;
                if (req.IsWebSocketRequest) {
                    if (!Authorized(context)) { CloseUnauthorized(context, json: false); continue; }
                    if (req.Url!.Port == _screenPort)
                    {
                        // Anything arriving on the dedicated screen port is the mirror stream.
                        _ = ProcessScreenWebSocket(context);
                    }
                    else if (req.Url.AbsolutePath == "/terminal")
                    {
                        _ = ProcessWebSocket(context);
                    }
                    else if (req.Url.AbsolutePath == "/api")
                    {
                        _ = Task.Run(async () => {
                            try {
                                var wsContext = await context.AcceptWebSocketAsync(null);
                                await SubsystemApi.ProcessApiWebSocket(wsContext.WebSocket, CancellationToken.None);
                            } catch {}
                        });
                    }
                    else if (req.Url.AbsolutePath == "/agent" || req.Url.AbsolutePath == "/llm")
                    {
                        _ = Task.Run(async () => {
                            try {
                                var wsContext = await context.AcceptWebSocketAsync(null);
                                await SubsystemApi.ProcessLlmWebSocket(_mainActivity, wsContext.WebSocket, CancellationToken.None);
                            } catch {}
                        });
                    }
                    else if (req.Url.AbsolutePath == "/models")
                    {
                        _ = Task.Run(async () => {
                            try {
                                var wsContext = await context.AcceptWebSocketAsync(null);
                                await ModelsApi.ProcessModelsWebSocket(_mainActivity, wsContext.WebSocket, CancellationToken.None);
                            } catch {}
                        });
                    }
                    else if (req.Url.AbsolutePath == "/screen")
                    {
                        _ = ProcessScreenWebSocket(context);
                    }
                    else
                    {
                        _ = ProcessWebSocket(context);
                    }
                }
                else if (context.Request.Url.AbsolutePath == "/api/exec" && context.Request.HttpMethod == "POST")
                {
                    _ = ProcessApiExec(context);
                }
                else if (context.Request.Url.AbsolutePath == "/clixml" && context.Request.HttpMethod == "POST")
                {
                    _ = ProcessApiClixml(context);
                }
                else if (context.Request.Url.AbsolutePath == "/psrp/session" && context.Request.HttpMethod == "POST")
                {
                    _ = ProcessPsrp(context, PsrpRoute.Session);
                }
                else if (context.Request.Url.AbsolutePath == "/psrp/invoke" && context.Request.HttpMethod == "POST")
                {
                    _ = ProcessPsrp(context, PsrpRoute.Invoke);
                }
                else if (context.Request.Url.AbsolutePath == "/psrp/close" && context.Request.HttpMethod == "POST")
                {
                    _ = ProcessPsrp(context, PsrpRoute.Close);
                }
                else if (context.Request.Url.AbsolutePath == "/psrp/run" && context.Request.HttpMethod == "POST")
                {
                    _ = ProcessPsrp(context, PsrpRoute.Run);
                }
                else if (context.Request.Url!.AbsolutePath == "/apps")
                {
                    _ = Task.Run(() => ServeAppsJson(context));
                }
                else if (context.Request.Url!.AbsolutePath == "/shell-layout")
                {
                    _ = Task.Run(() => ServeShellLayout(context));
                }
                else if (context.Request.Url!.AbsolutePath == "/verbs")
                {
                    _ = Task.Run(() => ServeVerbs(context));
                }
                else if (context.Request.Url!.AbsolutePath == "/themes")
                {
                    _ = Task.Run(() => ServeThemes(context));
                }
                else if (context.Request.Url!.AbsolutePath.StartsWith("/api/config/"))
                {
                    _ = Task.Run(() => ServeConfig(context));
                }
                else if (context.Request.Url!.AbsolutePath == "/cards")
                {
                    _ = Task.Run(() => ServeCards(context));
                }
                else if (context.Request.Url!.AbsolutePath == "/cli")
                {
                    // The phone hands out its own PowerShell control module.
                    _ = Task.Run(() => {
                        try {
                            var res = context.Response;
                            res.ContentType = "text/plain; charset=utf-8";
                            res.Headers["Content-Disposition"] = "inline; filename=Subsystem.psm1";
                            using var s = ObpHost.OpenRead("shell/cli/Subsystem.psm1")
                                ?? throw new System.IO.FileNotFoundException("Subsystem.psm1");
                            s.CopyTo(res.OutputStream);
                            res.OutputStream.Close();
                        } catch { try { var b = System.Text.Encoding.UTF8.GetBytes("# Subsystem CLI module unavailable\n"); context.Response.OutputStream.Write(b, 0, b.Length); } catch { } try { context.Response.Close(); } catch { } }
                    });
                }
                else if (context.Request.Url!.AbsolutePath.StartsWith("/vom/"))
                {
                    // The loopback face of the CoreCLR→WebView byte lane: /vom/<handle> resolves the
                    // SAME named Float32 region as the vom:// scheme (VomInterop — one truth, two
                    // schemes). fetch()-friendly where the custom scheme is not. Authority is the
                    // handle name (possession); empty region → empty 200, never a 404.
                    _ = Task.Run(() => {
                        try {
                            var res = context.Response;
                            res.ContentType = "application/octet-stream";
                            var name = context.Request.Url!.AbsolutePath.Substring("/vom/".Length);
                            // The system-state region refreshes ON READ (staleness-throttled in Dg) —
                            // live state is PULLED as a texture; no ambient publisher thread exists.
                            if (string.Equals(name, Subsystem.Dg.StateTextureName, StringComparison.OrdinalIgnoreCase))
                                Subsystem.Dg.RefreshStateTexture();
                            var bytes = VomInterop.GetTextureBytes(name);
                            res.OutputStream.Write(bytes, 0, bytes.Length);
                        } catch (Exception ex) { Subsystem.Dg.Log("http", "/vom error: " + ex.Message); }
                        finally { try { context.Response.Close(); } catch { } }
                    });
                }
                else if (context.Request.Url!.AbsolutePath == "/diag")
                {
                    _ = Task.Run(() => {
                        try {
                            var res = context.Response;
                            res.ContentType = "application/json";
                            var bytes = System.Text.Encoding.UTF8.GetBytes(Subsystem.Dg.Snapshot());
                            res.OutputStream.Write(bytes, 0, bytes.Length);
                            res.OutputStream.Close();
                        } catch { }
                    });
                }
                else
                    _ = Task.Run(() => ServeStaticFile(context));
            } catch { }
        }
    }

    private async Task ProcessWebSocket(HttpListenerContext context)
    {
        WebSocket? ws = null;
        ClientState? state = null;
        try {
            var wsContext = await context.AcceptWebSocketAsync(null);
            ws = wsContext.WebSocket;

            var channel = Channel.CreateBounded<(long, byte[])>(new BoundedChannelOptions(512) {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = false,
            });
            state = new ClientState {
                Ws = ws,
                Channel = channel,
                Cts = new CancellationTokenSource(),
            };
            _clients[ws] = state;
            _ = Task.Run(() => SendPump(state));

            var buffer = new byte[8192];
            while (ws.State == WebSocketState.Open)
            {
                var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Close) break;

                var msg = Encoding.UTF8.GetString(buffer, 0, result.Count);
                _mainActivity.RouteInputEvent(msg);
            }
        }
        catch { }
        finally {
            if (ws != null && state != null) {
                _clients.TryRemove(ws, out _);
                state.Channel.Writer.TryComplete();
                state.Cts.Cancel();
                try { await Task.Delay(50); } catch { }
                try { ws.Dispose(); } catch { }
                state.Cts.Dispose();
            }
        }
    }

    private async Task ProcessApiExec(HttpListenerContext context)
    {
        var req = context.Request;
        var res = context.Response;
        res.ContentType = "application/json";
        
        if (!Authorized(context)) { CloseUnauthorized(context, json: true); return; }

        try {
            string command;
            using (var reader = new StreamReader(req.InputStream, req.ContentEncoding)) {
                command = await reader.ReadToEndAsync();
            }
            if (string.IsNullOrWhiteSpace(command)) {
                command = "{}";
            }
            
            string jsonResponse = await SubsystemApi.ExecuteCommandAsJson(command);
            var bytes = Encoding.UTF8.GetBytes(jsonResponse);
            await res.OutputStream.WriteAsync(bytes, 0, bytes.Length);
        }
        catch (Exception ex) {
            // NEVER 404/500 (project rule): hand back a graceful error object (200) so the renderer shows
            // a card, not an HTTP error page. The fumble is recorded, not surfaced.
            Subsystem.Dg.Log("http", $"/api/exec error: {ex.Message}");
            var bytes = Encoding.UTF8.GetBytes($"{{\"error\": \"{ex.Message.Replace("\"", "\\\"")}\"}}");
            try { await res.OutputStream.WriteAsync(bytes, 0, bytes.Length); } catch { }
        }
        finally {
            res.Close();
        }
    }

    // Object-fidelity sibling of /api/exec (hydrate, don't replace): run the POSTed command raw and
    // return CLIXML (PSSerializer) instead of flattened JSON. A PowerShell client deserializes the
    // body with [PSSerializer]::Deserialize back into live PSObjects — full type + stream fidelity.
    // This is the PSRP-flavored object-remoting payload; the transport is the same loopback host
    // (BindGuard keeps it loopback-only; reach it via `adb forward tcp:8080`).
    private async Task ProcessApiClixml(HttpListenerContext context)
    {
        var req = context.Request;
        var res = context.Response;
        res.ContentType = "application/xml; charset=utf-8";

        if (!Authorized(context)) { CloseUnauthorized(context, json: false); return; }

        try {
            // Authority is possession: the surface is reachable iff the \Capability\Remoting\Clixml mount is
            // enabled. The capability record is the one truth (not this route) — disable it in Cm and the
            // endpoint goes dark. Hand back the refusal AS CLIXML so the client deserializes a real object.
            var cap = Subsystem.Cm.Cm.Get("\\Capability\\Remoting\\Clixml");
            if (cap == null || !cap.Enabled) {
                var denied = System.Management.Automation.PSSerializer.Serialize(
                    "Object remoting is not granted (\\Capability\\Remoting\\Clixml is disabled).");
                var db = Encoding.UTF8.GetBytes(denied);
                await res.OutputStream.WriteAsync(db, 0, db.Length);
                return;
            }

            string command;
            using (var reader = new StreamReader(req.InputStream, req.ContentEncoding)) {
                command = await reader.ReadToEndAsync();
            }
            if (string.IsNullOrWhiteSpace(command)) command = "$null";

            string xml = await SubsystemApi.ExecuteCommandAsClixml(command);
            var bytes = Encoding.UTF8.GetBytes(xml);
            await res.OutputStream.WriteAsync(bytes, 0, bytes.Length);
        }
        catch (Exception ex) {
            // NEVER 404/500 (project rule): hand back the exception AS CLIXML (200) so the client
            // deserializes a real error object, not an HTTP error page. The fumble is recorded.
            Subsystem.Dg.Log("http", $"/clixml error: {ex.Message}");
            try {
                var bytes = Encoding.UTF8.GetBytes(System.Management.Automation.PSSerializer.Serialize(ex));
                await res.OutputStream.WriteAsync(bytes, 0, bytes.Length);
            } catch { }
        }
        finally {
            res.Close();
        }
    }

    private enum PsrpRoute { Session, Invoke, Close, Run }

    // The /psrp seam — the loopback HTTP face of Rs (the PSRP subsystem). The WebView can't speak
    // MS-PSRP itself (it has no MS-PSRP stack); these routes broker its session against the real PSRP
    // endpoint on the Subsystem.Psrp named pipe. Gated on \Capability\Remoting\Psrp exactly like
    // /clixml: the Cm record is the one truth — disable it and the surface goes dark. Commands are
    // STRUCTURED ({name, parameters}) so parameters cross as data, never spliced script text.
    private async Task ProcessPsrp(HttpListenerContext context, PsrpRoute route)
    {
        var res = context.Response;
        res.ContentType = "application/json";
        if (!Authorized(context)) { CloseUnauthorized(context, json: false); return; }
        try
        {
            if (!Rs.Granted())
            {
                await WriteJson(res, JsonError("not-granted",
                    $"PowerShell remoting is not granted ({Rs.CapabilityPath} is disabled)."));
                return;
            }

            string body;
            using (var reader = new StreamReader(context.Request.InputStream, context.Request.ContentEncoding))
                body = await reader.ReadToEndAsync();
            using var doc = System.Text.Json.JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
            var root = doc.RootElement;
            string Str(string k, string fallback = "") =>
                root.TryGetProperty(k, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String
                    ? (v.GetString() ?? fallback) : fallback;

            string payload;
            switch (route)
            {
                case PsrpRoute.Session:
                {
                    var s = await Task.Run(() => Rs.Open(Str("owner", "presenter")));
                    payload = System.Text.Json.JsonSerializer.Serialize(
                        new { id = s.Id, owner = s.OwnerTag, pipe = Rs.PipeName });
                    break;
                }
                case PsrpRoute.Invoke:
                {
                    int depth = root.TryGetProperty("depth", out var d)
                        && d.ValueKind == System.Text.Json.JsonValueKind.Number ? d.GetInt32() : 4;
                    if (!root.TryGetProperty("commands", out var commands))
                        throw new RsException("bad-request", "Body must carry a 'commands' array.");
                    var json = await Task.Run(() => Rs.Invoke(Str("session"), commands, depth));
                    payload = "{\"data\":" + json + "}";
                    break;
                }
                case PsrpRoute.Run:
                {
                    // The REPL face: raw script in an EXCLUSIVE session (Rs enforces the lane rule),
                    // combined output+error text back — terminal semantics, not object envelopes.
                    var text = await Task.Run(() => Rs.InvokeScript(Str("session"), Str("script")));
                    payload = System.Text.Json.JsonSerializer.Serialize(new { text });
                    break;
                }
                default:
                {
                    bool closed = Rs.Close(Str("session"));
                    payload = System.Text.Json.JsonSerializer.Serialize(new { closed });
                    break;
                }
            }
            await WriteJson(res, payload);
        }
        catch (RsException rex)
        {
            // Typed refusal (busy / no-session / command-error / …) — a graceful 200 envelope; the
            // client reads `code` (e.g. "no-session" → reopen + retry). Recorded, not surfaced as HTTP.
            Subsystem.Dg.Log("http", $"/psrp {route} refused: {rex.Code}");
            try { await WriteJson(res, JsonError(rex.Code, rex.Message)); } catch { }
        }
        catch (Exception ex)
        {
            // NEVER 404/500 (project rule): hand back a graceful error object; the fumble is recorded.
            Subsystem.Dg.Log("http", $"/psrp {route} error: {ex.Message}");
            try { await WriteJson(res, JsonError("error", ex.Message)); } catch { }
        }
        finally
        {
            res.Close();
        }
    }

    private static string JsonError(string code, string message) =>
        System.Text.Json.JsonSerializer.Serialize(new { error = message, code });

    private static async Task WriteJson(HttpListenerResponse res, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        await res.OutputStream.WriteAsync(bytes, 0, bytes.Length);
    }

    // Drains the per-client send channel, coalescing consecutive same-tab payloads
    // into a single WebSocket frame. Wire format: "{tabId}:{concatenated bytes}".
    // The JS handler only parses the first ':' for tabId — coalescing must preserve
    // that contract by NOT re-prefixing appended items.
    private async Task SendPump(ClientState state)
    {
        var ws = state.Ws;
        var reader = state.Channel.Reader;
        var token = state.Cts.Token;
        var buf = new MemoryStream(4096);
        (long TabId, byte[] Data)? carried = null;

        try {
            while (!token.IsCancellationRequested)
            {
                (long TabId, byte[] Data) first;
                if (carried.HasValue) {
                    first = carried.Value;
                    carried = null;
                } else {
                    bool more;
                    try { more = await reader.WaitToReadAsync(token).ConfigureAwait(false); }
                    catch { break; }
                    if (!more) break;
                    if (!reader.TryRead(out first)) continue;
                }

                if (ws.State != WebSocketState.Open) break;

                buf.SetLength(0);
                var prefix = Encoding.UTF8.GetBytes($"{first.TabId}:");
                buf.Write(prefix, 0, prefix.Length);
                buf.Write(first.Data, 0, first.Data.Length);

                long currentTab = first.TabId;
                while (reader.TryRead(out var next))
                {
                    if (next.TabId != currentTab) { carried = next; break; }
                    buf.Write(next.Data, 0, next.Data.Length);
                    if (buf.Length > 32 * 1024) break;
                }

                try {
                    var seg = new ArraySegment<byte>(buf.GetBuffer(), 0, (int)buf.Length);
                    await ws.SendAsync(seg, WebSocketMessageType.Text, true, token).ConfigureAwait(false);
                } catch { break; }
            }
        } catch { }
    }

    public void Broadcast(long tabId, byte[] rawAnsiBytes)
    {
        if (_clients.IsEmpty) return;
        foreach (var kv in _clients)
        {
            kv.Value.Channel.Writer.TryWrite((tabId, rawAnsiBytes));
        }
    }

    private readonly ConcurrentDictionary<WebSocket, bool> _screenClients = new();

    private int _isSendingScreen = 0;

    public void BroadcastRdpFrame(byte[] jpegBytes) {
        if (_screenClients.IsEmpty) return;
        if (System.Threading.Interlocked.CompareExchange(ref _isSendingScreen, 1, 0) != 0) return; // Drop frame if busy
        
        Task.Run(async () => {
            try {
                var seg = new ArraySegment<byte>(jpegBytes);
                foreach (var ws in _screenClients.Keys) {
                    if (ws.State == System.Net.WebSockets.WebSocketState.Open) {
                        try { await ws.SendAsync(seg, System.Net.WebSockets.WebSocketMessageType.Binary, true, CancellationToken.None).ConfigureAwait(false); } catch { }
                    }
                }
            } finally {
                System.Threading.Interlocked.Exchange(ref _isSendingScreen, 0);
            }
        });
    }

    private async Task ProcessScreenWebSocket(HttpListenerContext context) {
        WebSocket? ws = null;
        try {
            var wsContext = await context.AcceptWebSocketAsync(null);
            ws = wsContext.WebSocket;
            _screenClients[ws] = true;

            var buffer = new byte[8192];
            while (ws.State == WebSocketState.Open) {
                var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Close) break;

                var msg = Encoding.UTF8.GetString(buffer, 0, result.Count);
                if (msg.Contains("tap")) {
                    try {
                        var doc = System.Text.Json.JsonDocument.Parse(msg);
                        var x = doc.RootElement.GetProperty("x").GetSingle();
                        var y = doc.RootElement.GetProperty("y").GetSingle();
                        TerminalAccessibilityService.Instance?.DispatchTap(x, y);
                    } catch { }
                }
            }
        }
        catch { }
        finally {
            if (ws != null) {
                _screenClients.TryRemove(ws, out _);
                try { ws.Dispose(); } catch { }
            }
        }
    }

    // /apps is now a Cm QUERY, not a filesystem scan (REGISTRY-SPEC §1). The Registrar seeded the
    // presenter/system surfaces as capabilities; here we project the granted Presenter/System records to
    // the launcher summary the Shell expects: [{id,group,name,file,icon,firstClass}]. The registry is the
    // source of truth; the filesystem only seeded it.
    private void ServeAppsJson(HttpListenerContext context)
    {
        var res = context.Response;
        res.ContentType = "application/json";
        try {
            var groupOrder = new System.Collections.Generic.List<string> { "core", "tools", "games", "system" };
            int Rank(string g) { var i = groupOrder.IndexOf(g); return i == -1 ? int.MaxValue : i; }

            var rows = new System.Collections.Generic.List<(string id, string group, string name, string file, string icon, bool firstClass, string role)>();
            foreach (var rec in Subsystem.Cm.Cm.List()) {
                if (rec.Type != "Presenter" && rec.Type != "System") continue;
                if (string.IsNullOrEmpty(rec.ManifestJson)) continue;
                try {
                    using var doc = System.Text.Json.JsonDocument.Parse(rec.ManifestJson);
                    var m = doc.RootElement;
                    string Get(string k) => m.TryGetProperty(k, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? (v.GetString() ?? "") : "";
                    bool firstClass = m.TryGetProperty("firstClass", out var fc) && fc.ValueKind == System.Text.Json.JsonValueKind.True;
                    var id = Get("id");
                    if (id.Length == 0) continue;
                    // role rides through (e.g. "desktop" — the Shell's resting layer): launchers
                    // filter on it client-side; the projection stays ONE truth for all consumers.
                    rows.Add((id, Get("group"), Get("name"), Get("file"), Get("icon"), firstClass, Get("role")));
                } catch { }
            }

            var apps = rows
                .OrderBy(r => Rank(r.group)).ThenBy(r => r.name, StringComparer.OrdinalIgnoreCase)
                .Select(r => (object)new { id = r.id, group = r.group, name = r.name, file = r.file, icon = r.icon, firstClass = r.firstClass, role = r.role })
                .ToList();

            var json = System.Text.Json.JsonSerializer.Serialize(apps);
            var bytes = Encoding.UTF8.GetBytes(json);
            res.OutputStream.Write(bytes, 0, bytes.Length);
        } catch {
            // NEVER 500 (project rule): degrade to an empty manifest so the launcher just shows nothing.
            Subsystem.Dg.Log("http", "/apps build failed → empty manifest");
            try { var b = Encoding.UTF8.GetBytes("[]"); res.OutputStream.Write(b, 0, b.Length); } catch { }
        } finally {
            res.Close();
        }
    }

    // /shell-layout is a Cm QUERY: the chrome objects the Shell mounts (\Shell\Layout\*), ordered. The
    // ShellObject manifests are served through verbatim — the Shell parses them (one JSON, many consumers).
    private void ServeShellLayout(HttpListenerContext context)
    {
        var res = context.Response;
        res.ContentType = "application/json";
        try {
            var rows = new System.Collections.Generic.List<(int order, string json)>();
            foreach (var rec in Subsystem.Cm.Cm.List()) {
                if (rec.Type != "ShellObject" || string.IsNullOrEmpty(rec.ManifestJson)) continue;
                int order = 0;
                try {
                    using var doc = System.Text.Json.JsonDocument.Parse(rec.ManifestJson);
                    if (doc.RootElement.TryGetProperty("order", out var ov) && ov.ValueKind == System.Text.Json.JsonValueKind.Number) order = ov.GetInt32();
                } catch { }
                rows.Add((order, rec.ManifestJson!));
            }
            var json = "[" + string.Join(",", rows.OrderBy(r => r.order).Select(r => r.json)) + "]";
            var bytes = Encoding.UTF8.GetBytes(json);
            res.OutputStream.Write(bytes, 0, bytes.Length);
        } catch {
            Subsystem.Dg.Log("http", "/shell-layout build failed → empty layout");
            try { var b = Encoding.UTF8.GetBytes("[]"); res.OutputStream.Write(b, 0, b.Length); } catch { }
        } finally {
            res.Close();
        }
    }

    // /verbs is a Cm QUERY: the shell verbs (\Shell\Verb\<scope>\<verb>) the Menu renders. Projects each
    // Verb record to [{path,scope,menu,label,icon,command}]. `scope` comes from the path (the HKCR\<type>
    // analog), `menu` from the manifest's values.menu. REGISTRY-SPEC §6.
    private void ServeVerbs(HttpListenerContext context)
    {
        var res = context.Response;
        res.ContentType = "application/json";
        try {
            var rows = new System.Collections.Generic.List<object>();
            foreach (var rec in Subsystem.Cm.Cm.List()) {
                if (rec.Type != "Verb" || string.IsNullOrEmpty(rec.ManifestJson)) continue;
                var parts = rec.Path.Trim('\\').Split('\\');
                string scope = parts.Length >= 3 ? parts[2] : "*";
                try {
                    using var doc = System.Text.Json.JsonDocument.Parse(rec.ManifestJson);
                    var m = doc.RootElement;
                    string Get(string k) => m.TryGetProperty(k, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? (v.GetString() ?? "") : "";
                    string menu = "file";
                    if (m.TryGetProperty("values", out var vals) && vals.ValueKind == System.Text.Json.JsonValueKind.Object
                        && vals.TryGetProperty("menu", out var mv) && mv.ValueKind == System.Text.Json.JsonValueKind.String)
                        menu = mv.GetString() ?? "file";
                    rows.Add(new { path = rec.Path, scope, menu, label = Get("label"), icon = Get("icon"), command = Get("command") });
                } catch { }
            }
            var json = System.Text.Json.JsonSerializer.Serialize(rows);
            var bytes = Encoding.UTF8.GetBytes(json);
            res.OutputStream.Write(bytes, 0, bytes.Length);
        } catch {
            Subsystem.Dg.Log("http", "/verbs build failed → empty");
            try { var b = Encoding.UTF8.GetBytes("[]"); res.OutputStream.Write(b, 0, b.Length); } catch { }
        } finally {
            res.Close();
        }
    }

    // /themes is a Cm QUERY: theme objects (\Capability\Theme\*). Each manifest is the var bundle (with id).
    // The registry is the source of truth; themes.js reads this. (REGISTRY-SPEC §4; mirrors ServeShellLayout.)
    private void ServeThemes(HttpListenerContext context)
    {
        var res = context.Response;
        res.ContentType = "application/json";
        try {
            var rows = new System.Collections.Generic.List<string>();
            foreach (var rec in Subsystem.Cm.Cm.List()) {
                if (rec.Type != "Theme" || string.IsNullOrEmpty(rec.ManifestJson)) continue;
                rows.Add(rec.ManifestJson!);
            }
            var json = "[" + string.Join(",", rows) + "]";
            var bytes = Encoding.UTF8.GetBytes(json);
            res.OutputStream.Write(bytes, 0, bytes.Length);
        } catch {
            Subsystem.Dg.Log("http", "/themes build failed → empty");
            try { var b = Encoding.UTF8.GetBytes("[]"); res.OutputStream.Write(b, 0, b.Length); } catch { }
        } finally {
            res.Close();
        }
    }

    // (/wallpapers retired 2026-06-11 with the in-app live wallpaper: the Shader catalog
    // (\Capability\Shader\*) is consumed natively by the Wp engine via ObpHost, and the pickers
    // query it through /api/exec (Get-SystemWallpaper) — no HTTP projection needed.)

    // /cards is a Cm QUERY: card objects (\Capability\Card\*, REGISTRY-SPEC §3 kind:"card") — the
    // Surface renders these as live widgets; the agent mints new ones at runtime (Register-Capability).
    // A record whose manifest fails to parse is SKIPPED (a malformed LLM-authored card must never
    // break the projection — render-time guards are the next line of defense). Mirrors ServeThemes.
    private void ServeCards(HttpListenerContext context)
    {
        var res = context.Response;
        res.ContentType = "application/json";
        try {
            var rows = new System.Collections.Generic.List<string>();
            foreach (var rec in Subsystem.Cm.Cm.List()) {
                if (rec.Type != "Card" || !rec.Enabled || string.IsNullOrEmpty(rec.ManifestJson)) continue;
                try { using var probe = System.Text.Json.JsonDocument.Parse(rec.ManifestJson); }
                catch { Subsystem.Dg.Log("http", "/cards: skipping malformed manifest at " + rec.Path); continue; }
                rows.Add(rec.ManifestJson!);
            }
            var json = "[" + string.Join(",", rows) + "]";
            var bytes = Encoding.UTF8.GetBytes(json);
            res.OutputStream.Write(bytes, 0, bytes.Length);
        } catch {
            Subsystem.Dg.Log("http", "/cards build failed → empty");
            try { var b = Encoding.UTF8.GetBytes("[]"); res.OutputStream.Write(b, 0, b.Length); } catch { }
        } finally {
            res.Close();
        }
    }

    // /api/config/{key} — the UI's durable state lane (lib/store.js): GET reads, POST upserts. Truth
    // is a Cm record at \Config\{key} (Type="Config", ManifestJson = the value verbatim) — the UI
    // holds nothing; localStorage is its offline cache. GET of a MISSING key is a deliberate 404
    // (the one commented exception to never-404): store.js keys off r.ok to fall back to its cache —
    // a 200 with empty/HTML body is what used to poison it.
    private void ServeConfig(HttpListenerContext context)
    {
        var req = context.Request;
        var res = context.Response;
        try
        {
            var key = (req.Url?.AbsolutePath ?? "").Substring("/api/config/".Length);
            if (!System.Text.RegularExpressions.Regex.IsMatch(key, @"^[A-Za-z0-9._-]{1,64}$"))
            {
                res.ContentType = "application/json";
                var bad = Encoding.UTF8.GetBytes("{\"error\":\"bad config key\"}");
                res.OutputStream.Write(bad, 0, bad.Length);
                return;
            }
            var path = "\\Shell\\Config\\" + key;   // shell/UI state lives under the Shell subtree (SS004)

            if (req.HttpMethod == "POST")
            {
                string body;
                using (var rd = new System.IO.StreamReader(req.InputStream, req.ContentEncoding ?? Encoding.UTF8))
                    body = rd.ReadToEnd();
                if (body.Length > 256 * 1024)
                {
                    res.ContentType = "application/json";
                    var big = Encoding.UTF8.GetBytes("{\"error\":\"config value too large\"}");
                    res.OutputStream.Write(big, 0, big.Length);
                    return;
                }
                Subsystem.Cm.Cm.Register(new Subsystem.Cm.CapabilityRecord
                {
                    Path = path, Name = key, Type = "Config",
                    ManifestJson = body, Owner = "\\Shell", Integrity = "User",
                    StartType = "manual", Enabled = true,
                });
                res.ContentType = "application/json";
                var ok = Encoding.UTF8.GetBytes("{\"ok\":true}");
                res.OutputStream.Write(ok, 0, ok.Length);
                return;
            }

            var rec = Subsystem.Cm.Cm.Get(path);
            if (rec == null || rec.ManifestJson == null)
            {
                res.StatusCode = 404;                       // deliberate — see header comment
                return;
            }
            res.ContentType = "text/plain; charset=utf-8";  // value verbatim — exact round-trip
            var bytes = Encoding.UTF8.GetBytes(rec.ManifestJson);
            res.OutputStream.Write(bytes, 0, bytes.Length);
        }
        catch (Exception ex)
        {
            Subsystem.Dg.Log("http", "/api/config error: " + ex.Message);
            try { res.ContentType = "application/json"; var b = Encoding.UTF8.GetBytes("{\"error\":\"config failed\"}"); res.OutputStream.Write(b, 0, b.Length); } catch { }
        }
        finally { res.Close(); }
    }

    private static string MimeFor(string path)
    {
        if (path.EndsWith(".obp"))   return "text/html";            // Object Presenter — html-shaped content
        if (path.EndsWith(".html"))  return "text/html";
        if (path.EndsWith(".js"))    return "application/javascript";
        if (path.EndsWith(".css"))   return "text/css";
        if (path.EndsWith(".json"))  return "application/json";
        if (path.EndsWith(".svg"))   return "image/svg+xml";
        if (path.EndsWith(".png"))   return "image/png";
        if (path.EndsWith(".ico"))   return "image/x-icon";
        if (path.EndsWith(".woff2")) return "font/woff2";
        if (path.EndsWith(".ttf"))   return "font/ttf";
        if (path.EndsWith(".frag") || path.EndsWith(".wgsl")) return "text/plain";   // shader sources
        return "application/octet-stream";
    }

    // THE FRONT DOOR (REGISTRY-SPEC §9): a whole shell is a presenter mount, and WHICH presenter
    // answers "/" is the \Shell\FrontDoor record's `file` value — swap it (Register-Capability) and
    // the app becomes a different UI on the next shell load. Same namespace, different door:
    // desktop, kiosk, cylon, GERTY — all data. Degrades to shell.obp if the record is absent/bad.
    private static string FrontDoorFile()
    {
        try
        {
            var rec = Subsystem.Cm.Cm.Get("\\Shell\\FrontDoor");
            if (rec is { Enabled: true, ManifestJson: not null })
            {
                using var doc = System.Text.Json.JsonDocument.Parse(rec.ManifestJson);
                if (doc.RootElement.TryGetProperty("file", out var f)
                    && f.ValueKind == System.Text.Json.JsonValueKind.String)
                {
                    var v = (f.GetString() ?? "").TrimStart('/');
                    if (v.Length > 0) return v;
                }
            }
        }
        catch (Exception ex) { Subsystem.Dg.Log("http", "front-door resolve failed: " + ex.Message); }
        return "shell.obp";
    }

    // The shell is served from RAM (ObpHost: compiled EmbeddedResource, .html<->.obp alias, asset
    // fallback for anything deliberately loose). ProjectionServer never touches physical layout itself.
    private void ServeStaticFile(HttpListenerContext context)
    {
        var req = context.Request;
        var res = context.Response;
        var path = req.Url?.AbsolutePath ?? "/";

        // API routes NEVER fall through to the SPA shell. Before this guard, an unmatched
        // GET /api/config/<key> was answered with shell.obp HTML + 200 — and store.js, seeing r.ok,
        // CACHED THE HTML into localStorage, poisoning the key (the Surface layout flakiness).
        // An unknown /api/* is a typed error envelope, still 200 (the no-404 rule for data lanes).
        if (path.StartsWith("/api/"))
        {
            try
            {
                res.ContentType = "application/json";
                var err = Encoding.UTF8.GetBytes("{\"error\":\"no such api: " + path.Replace("\"", "'") + "\"}");
                res.OutputStream.Write(err, 0, err.Length);
            }
            catch { }
            finally { res.Close(); }
            return;
        }

        if (path == "/") path = "/" + FrontDoorFile();   // which presenter answers the door is a Cm VALUE

        try
        {
            using var stream = ObpHost.OpenRead("shell" + path)
                ?? throw new System.IO.FileNotFoundException(path);
            res.ContentType = MimeFor(path);
            stream.CopyTo(res.OutputStream);
        }
        catch
        {
            // NEVER 404 (project rule): a page request falls back to the shell (SPA-style) so any unknown
            // path lands somewhere real; a missing sub-resource returns an empty 200, not a 404. Logged.
            Subsystem.Dg.Log("http", $"static miss: {path}");
            try
            {
                var leaf = path.Substring(path.LastIndexOf('/') + 1);
                bool isPage = path.EndsWith(".html") || path.EndsWith(".obp") || !leaf.Contains('.');
                using var shell = isPage ? ObpHost.OpenRead("shell/shell.obp") : null;
                if (shell != null)
                {
                    res.ContentType = "text/html";
                    shell.CopyTo(res.OutputStream);
                }
                else
                {
                    res.ContentType = "application/octet-stream";   // empty 200, never a 404
                }
            }
            catch
            {
                res.ContentType = "text/html";
                var html = Encoding.UTF8.GetBytes("<!doctype html><meta charset=utf-8><body style='background:#000'></body>");
                try { res.OutputStream.Write(html, 0, html.Length); } catch { }
            }
        }
        finally
        {
            res.Close();
        }
    }
}
