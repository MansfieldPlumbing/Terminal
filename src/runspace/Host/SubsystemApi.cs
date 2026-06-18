using System;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Net.WebSockets;
using System.Management.Automation;

namespace Subsystem;

public static class SubsystemApi
{
    private static System.Management.Automation.Runspaces.RunspacePool? _apiPool;
    private static Subsystem.RuntimeBroker.Broker? _assistant;

    // The single home for the adb client-key path (Personal/adbkey.bin). The connect path treats
    // "key on disk" as the paired signal (see SubsystemService), so IsAdbPaired reads the same truth
    // instead of a hardcoded stub.
    public static string AdbKeyPath =>
        System.IO.Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Personal), "adbkey.bin");

    public static bool IsAdbPaired() => System.IO.File.Exists(AdbKeyPath);

    public static async Task<string> PairAdbLoopback(int port, string code)
    {
        try
        {
            string keyPath = AdbKeyPath;
            using var rsa = System.Security.Cryptography.RSA.Create(2048);
            
            if (System.IO.File.Exists(keyPath))
            {
                rsa.ImportRSAPrivateKey(System.IO.File.ReadAllBytes(keyPath), out _);
            }
            else
            {
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(keyPath)!);
                System.IO.File.WriteAllBytes(keyPath, rsa.ExportRSAPrivateKey());
            }

            using var client = new AdbPairingClient("127.0.0.1", port, code, rsa);
            
            bool success = await client.PairAsync();
            if (success)
            {
                return "Success";
            }
            else
            {
                return "Failed";
            }
        }
        catch (Exception ex)
        {
            return $"Exception: {ex.Message}";
        }
    }

    public static void Initialize(System.Management.Automation.Runspaces.InitialSessionState iss, System.Management.Automation.Host.PSHost host)
    {
        if (_apiPool != null) return;
        _apiPool = System.Management.Automation.Runspaces.RunspaceFactory.CreateRunspacePool(1, 5, iss, host);
        _apiPool.ThreadOptions = System.Management.Automation.Runspaces.PSThreadOptions.UseNewThread;
        _apiPool.Open();
    }
    public static async Task ProcessApiWebSocket(WebSocket ws, CancellationToken token)
    {
        var buffer = new byte[8192];
        while (ws.State == WebSocketState.Open && !token.IsCancellationRequested)
        {
            var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token);
            if (result.MessageType == WebSocketMessageType.Close) break;

            string input = Encoding.UTF8.GetString(buffer, 0, result.Count).Trim();
            if (string.IsNullOrEmpty(input)) continue;

            string jsonResponse = await ExecuteCommandAsJson(input);
            
            var seg = new ArraySegment<byte>(Encoding.UTF8.GetBytes(jsonResponse));
            await ws.SendAsync(seg, WebSocketMessageType.Text, true, token);
        }
    }

    // Serializes a typed frame to the socket. This is the single point where everything the
    // chat UI / CLI sees is emitted — the canonical "what gets sent to the webview".
    private static async Task SendFrame(WebSocket ws, object frame, CancellationToken token)
    {
        if (ws.State != WebSocketState.Open) return;
        var bytes = Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(frame));
        try { await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, token); } catch { }
    }

    // Parse the `offer_choices` tool result (a JSON string array) into chip strings. Resilient to a
    // single bare string or malformed output — a bad offer must never break the turn.
    private static string[] ParseChoices(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) return Array.Empty<string>();
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Array)
                return doc.RootElement.EnumerateArray()
                    .Select(e => e.ValueKind == System.Text.Json.JsonValueKind.String ? e.GetString() : e.ToString())
                    .Where(s => !string.IsNullOrWhiteSpace(s)).Take(5).ToArray();
            if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.String)
                return new[] { doc.RootElement.GetString() };
        }
        catch { }
        return new[] { json.Trim() };
    }

    // /agent protocol (typed JSON text frames, one object per frame):
    //   Server → client:
    //     { type:"status", state, pct?, text }   model download/init lifecycle
    //     { type:"meta",   model, backend }       sent once the model is ready
    //     { type:"token",  text }                 a streamed chunk of the answer (append)
    //     { type:"done" }                         turn finished
    //     { type:"benchmark", ... }               result of a profile request
    //     { type:"suggestions", items, replace }  Action Surface chips she offers (offer_choices verb)
    //     { type:"error",  text }
    //   Client → server (JSON, or bare text = a chat message for back-compat):
    //     { type:"chat",    text }
    //     { type:"profile", prompt? }             run one turn + return benchmark counters
    public static async Task ProcessLlmWebSocket(Android.Content.Context context, WebSocket ws, CancellationToken token)
    {
        Subsystem.RuntimeBroker.Broker assistant;
        try {
            Func<string, Task> report = async (txt) => {
                var m = System.Text.RegularExpressions.Regex.Match(txt, @"(\d+)%");
                await SendFrame(ws, new { type = "status", state = "loading", pct = m.Success ? int.Parse(m.Groups[1].Value) : (int?)null, text = txt.Trim() }, token);
            };
            assistant = await Rb.GetAsync(context, report, token);
            await SendFrame(ws, new { type = "meta", model = ModelCatalog.Active(context).DisplayName, backend = assistant.BackendName }, token);
            await SendFrame(ws, new { type = "status", state = "ready", text = "Ready." }, token);
        } catch (Subsystem.RuntimeBroker.RbFaultException fx) {
            // §3.1: the typed fault crosses to the client as structured fields; text is display-only.
            await SendFrame(ws, new { type = "error", @class = fx.Fault.Class.ToString(),
                unitId = fx.Fault.UnitId, backend = fx.Fault.Backend, text = fx.Fault.NativeDetail }, token);
            return;
        } catch (Exception ex) {
            await SendFrame(ws, new { type = "error", text = $"Failed to initialize AI: {ex.Message}" }, token);
            return;
        }

        // The chat being persisted on this connection (a Cm \Agent\Session\* object). Created lazily on the
        // first chat turn; the UI can switch/new/load/delete via session commands below.
        string sessionId = "";

        var buffer = new byte[16384];
        using var frame = new System.IO.MemoryStream();
        while (ws.State == WebSocketState.Open && !token.IsCancellationRequested)
        {
            // Accumulate every fragment of one WS message before parsing — a voice frame carries
            // hundreds of KB of base64 audio across many 16KB reads, so a single ReceiveAsync would
            // truncate it (the cause of an invalid-base64 / clipped-prompt class of bugs).
            frame.SetLength(0);
            WebSocketReceiveResult result;
            bool closed = false;
            do
            {
                try { result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token); }
                catch { closed = true; break; }
                if (result.MessageType == WebSocketMessageType.Close) { closed = true; break; }
                frame.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);
            if (closed) break;

            string raw = Encoding.UTF8.GetString(frame.GetBuffer(), 0, (int)frame.Length).Trim();
            if (string.IsNullOrEmpty(raw)) continue;

            // Accept either a JSON command frame or bare text (treated as a chat message). A chat
            // frame may carry `audio` (base64) for MULTIMODAL speech-in — Gemma 4 is text·image·
            // audio·video, and the engine takes the audio as a side channel alongside the prompt.
            string action = "chat", text = raw, id = "", title = "";
            byte[]? audioBytes = null;
            if (raw.StartsWith("{"))
            {
                try
                {
                    using var doc = System.Text.Json.JsonDocument.Parse(raw);
                    if (doc.RootElement.TryGetProperty("type", out var t)) action = t.GetString() ?? "chat";
                    if (doc.RootElement.TryGetProperty("text", out var x)) text = x.GetString() ?? "";
                    else if (doc.RootElement.TryGetProperty("prompt", out var p)) text = p.GetString() ?? "";
                    if (doc.RootElement.TryGetProperty("id", out var iv)) id = iv.GetString() ?? "";
                    if (doc.RootElement.TryGetProperty("title", out var tv)) title = tv.GetString() ?? "";
                    if (doc.RootElement.TryGetProperty("audio", out var au) && au.ValueKind == System.Text.Json.JsonValueKind.String)
                    {
                        try { audioBytes = Convert.FromBase64String(au.GetString() ?? ""); }
                        catch (Exception ex) { Subsystem.Dg.Warn("agent", ex); }
                    }
                }
                catch { /* not JSON after all — treat as text */ }
            }

            try
            {
                // --- Saved-chat commands (Cm \Agent\Session\*) ---
                if (action == "sessions") { await SendFrame(ws, new { type = "sessions", items = Subsystem.RuntimeBroker.AgentSessionTable.ListSummaries() }, token); continue; }
                if (action == "new")      { sessionId = Subsystem.RuntimeBroker.AgentSessionTable.Create(title); await SendFrame(ws, new { type = "session", id = sessionId }, token); continue; }
                if (action == "load")     { sessionId = id; await SendFrame(ws, new { type = "transcript", id, json = Subsystem.RuntimeBroker.AgentSessionTable.LoadJson(id) }, token); continue; }
                if (action == "delete")   { Subsystem.RuntimeBroker.AgentSessionTable.Delete(id); if (sessionId == id) sessionId = ""; await SendFrame(ws, new { type = "sessions", items = Subsystem.RuntimeBroker.AgentSessionTable.ListSummaries() }, token); continue; }
                if (action == "rename")   { Subsystem.RuntimeBroker.AgentSessionTable.Rename(id, title); await SendFrame(ws, new { type = "sessions", items = Subsystem.RuntimeBroker.AgentSessionTable.ListSummaries() }, token); continue; }

                if (action == "profile")
                {
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    int chars = 0;
                    var probe = string.IsNullOrWhiteSpace(text) ? "Say hello in one short sentence." : text;
                    await foreach (var chunk in assistant.SendMessageStreamAsync(probe, ct: token)) chars += chunk.Length;
                    sw.Stop();
                    var b = assistant.GetBenchmark();
                    await SendFrame(ws, new {
                        type = "benchmark",
                        model = ModelCatalog.Active(context).DisplayName,
                        backend = assistant.BackendName,
                        wallMs = sw.ElapsedMilliseconds,
                        chars,
                        initSeconds = b?.InitSeconds,
                        timeToFirstTokenSeconds = b?.TimeToFirstTokenSeconds,
                        prefillTokens = b?.PrefillTokens,
                        prefillTokensPerSecond = b?.PrefillTokensPerSecond,
                        decodeTokens = b?.DecodeTokens,
                        decodeTokensPerSecond = b?.DecodeTokensPerSecond,
                    }, token);
                    continue;
                }

                // Persist the user turn into the active saved chat (create one lazily on first message so
                // every conversation is durable in Cm without the user asking). Announce the session id once.
                if (string.IsNullOrEmpty(sessionId)) { sessionId = Subsystem.RuntimeBroker.AgentSessionTable.Create(); await SendFrame(ws, new { type = "session", id = sessionId }, token); }
                Subsystem.RuntimeBroker.AgentSessionTable.AppendTurn(sessionId,
                    "user", audioBytes != null && text.Length == 0 ? "🎤 (voice message)" : text);
                var answerBuf = new StringBuilder();

                // Announce the THINKING state the instant the turn starts — prefill / cold-load can run
                // many seconds before the first token. The renderer shows her thinking indicator until the
                // first token (or thought) arrives (backend owns the state; the renderer only presents it).
                await SendFrame(ws, new { type = "status", state = "thinking" }, token);

                // Pin the HUD sitrep to the head of the turn (AGENT-SPEC §2/§3): fresh device vitals
                // re-projected by the harness every loop. The transcript above persisted the RAW user
                // text — the HUD is projection, never transcript truth.
                var turnText = Subsystem.RuntimeBroker.Hud.Wrap(
                    text, ModelCatalog.Active(context).DisplayName, assistant.BackendName);

                // Stream the structured turn: visible tokens, the thinking channel, and native tool
                // call/result activity (the engine runs tools itself — AgentTools.cs). One frame per delta.
                await foreach (var d in assistant.SendTurnAsync(turnText, audioBytes, ct: token))
                {
                    if (ws.State != WebSocketState.Open) break;
                    switch (d.Kind)
                    {
                        case Subsystem.RuntimeBroker.AgentDeltaKind.Token:
                            answerBuf.Append(d.Text);
                            await SendFrame(ws, new { type = "token", text = d.Text }, token); break;
                        case Subsystem.RuntimeBroker.AgentDeltaKind.Think:
                            await SendFrame(ws, new { type = "think", text = d.Text }, token); break;
                        case Subsystem.RuntimeBroker.AgentDeltaKind.ToolCall:
                            await SendFrame(ws, new { type = "tool", name = d.Name, args = d.Text }, token); break;
                        case Subsystem.RuntimeBroker.AgentDeltaKind.ToolResult:
                            // The `offer_choices` verb is presentation, not a data tool: route its result
                            // to the Action Surface as a `suggestions` frame rather than a tool card.
                            if (d.Name == "offer_choices")
                                await SendFrame(ws, new { type = "suggestions", items = ParseChoices(d.Text), replace = true }, token);
                            else
                                await SendFrame(ws, new { type = "tool_result", name = d.Name, result = d.Text }, token);
                            break;
                        case Subsystem.RuntimeBroker.AgentDeltaKind.Error:
                            await SendFrame(ws, d.Fault is { } f
                                ? new { type = "error", @class = (string?)f.Class.ToString(), unitId = (string?)f.UnitId, backend = (string?)f.Backend, text = d.Text }
                                : new { type = "error", @class = (string?)null, unitId = (string?)null, backend = (string?)null, text = d.Text }, token);
                            break;
                    }
                }
                // Close the turn with the native tok/s counters so the UI can show throughput.
                var bench = assistant.GetBenchmark();
                await SendFrame(ws, new {
                    type = "done",
                    backend = assistant.BackendName,
                    decodeTokens = bench?.DecodeTokens,
                    decodeTokensPerSecond = bench?.DecodeTokensPerSecond,
                    prefillTokensPerSecond = bench?.PrefillTokensPerSecond,
                    timeToFirstTokenSeconds = bench?.TimeToFirstTokenSeconds,
                }, token);

                // Persist her answer (append-only transcript in Cm).
                if (answerBuf.Length > 0) Subsystem.RuntimeBroker.AgentSessionTable.AppendTurn(sessionId, "assistant", answerBuf.ToString());
            }
            catch (Exception ex)
            {
                await SendFrame(ws, new { type = "error", text = ex.Message }, token);
            }
        }
    }

    // Once-per-runspace, runtime-time assembly registration. The API pool is built during app boot
    // (OnCreate), before some cmdlets' Android-binding dependencies are ready, so those types fail
    // ISS-time validation and silently drop — the bug where Broker's run_powershell couldn't see
    // Send-Morse et al. Import-Module -Assembly runs AFTER boot, when every [Cmdlet] type loads
    // cleanly (proven), and is the same mechanism the PSRP bootstrap uses. The $global guard makes it
    // a no-op after the first command in each pooled runspace.
    private const string EnsureSubsystemModule =
        "if (-not $global:__ssMod) { Import-Module -Assembly ([Subsystem.MainActivity].Assembly) -ErrorAction SilentlyContinue; $global:__ssMod = $true }\n";

    public static async Task<string> ExecuteCommandAsJson(string command)
    {
        return await Task.Run(async () =>
        {
            try
            {
                if (_apiPool == null) return "{\"error\": \"API RunspacePool not initialized\"}";

                using var ps = PowerShell.Create();
                ps.RunspacePool = _apiPool;
                ps.AddScript(EnsureSubsystemModule + $"{command} | ConvertTo-Json -Depth 3 -Compress");

                Android.Util.Log.Info("SubsystemApi", $"Executing: {command}");
                var results = await ps.InvokeAsync().ConfigureAwait(false);
                Android.Util.Log.Info("SubsystemApi", $"Finished Executing: {command}, Results: {results.Count}");

                if (ps.HadErrors) 
                {
                    var errors = new System.Collections.Generic.List<string>();
                    foreach (var err in ps.Streams.Error) errors.Add(err.ToString());
                    return $"{{\"error\": \"{string.Join("; ", errors).Replace("\"", "\\\"")}\"}}";
                }

                if (results.Count == 0) return "{}";
                if (results.Count == 1) return results[0]?.ToString() ?? "null";

                var sb = new StringBuilder("[");
                for (int i = 0; i < results.Count; i++) {
                    sb.Append(results[i]?.ToString() ?? "null");
                    if (i < results.Count - 1) sb.Append(",");
                }
                sb.Append("]");
                return sb.ToString();
            }
            catch (Exception ex)
            {
                return $"{{\"error\": \"{ex.Message.Replace("\"", "\\\"")}\"}}";
            }
        });
    }

    // PSRP-flavored object remoting: run the command raw and serialize the result objects
    // (and any error records) as CLIXML — full type + stream fidelity, deserializes back into
    // live PSObjects in any PowerShell client. This is the payload for the TLS conhost channel
    // and an object-fidelity mode for the projection /api.
    public static async Task<string> ExecuteCommandAsClixml(string command, int depth = 4)
    {
        return await Task.Run(async () =>
        {
            try
            {
                if (_apiPool == null)
                    return PSSerializer.Serialize("Error: API RunspacePool not initialized");

                using var ps = PowerShell.Create();
                ps.RunspacePool = _apiPool;
                ps.AddScript(EnsureSubsystemModule + command); // raw — no ConvertTo-Json; objects stay objects

                var results = await ps.InvokeAsync().ConfigureAwait(false);

                if (ps.HadErrors)
                {
                    var errs = new System.Collections.Generic.List<object>();
                    foreach (var e in ps.Streams.Error) errs.Add(e);
                    return PSSerializer.Serialize(errs.ToArray(), depth);
                }

                var objs = new System.Collections.Generic.List<object>();
                foreach (var r in results) objs.Add(r);
                return PSSerializer.Serialize(objs.ToArray(), depth);
            }
            catch (Exception ex)
            {
                return PSSerializer.Serialize(ex);
            }
        });
    }
}
