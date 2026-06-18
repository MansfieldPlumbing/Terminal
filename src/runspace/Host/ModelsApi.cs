using System;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Net.WebSockets;
using Android.Content;

namespace Subsystem;

// WebSocket backend for the Settings "Models" section. Typed JSON text frames (one object per
// frame) — the same shape the chat thinking-block stream will use, so this is the rehearsal.
//
//   Server → client:
//     { "type":"manifest",  "models":[ { id, name, role, size, present, downloading, warn, … } ] }
//     { "type":"progress",  "id":"e2b", "text":"Downloading… 42%", "pct":42 }
//     { "type":"done",      "id":"e2b" }           (followed by a fresh manifest)
//     { "type":"cancelled", "id":"e2b" }           (deliberate stop, .part retained for resume; followed by a fresh manifest)
//     { "type":"error",     "id":"e2b", "text":"…" }
//   Client → server:
//     { "action":"list" }
//     { "action":"download", "id":"e4b" }
//     { "action":"cancel",   "id":"e4b" }
//     { "action":"select",   "id":"e4b" }
//     { "action":"delete",   "id":"e4b" }
public static class ModelsApi
{
    public static async Task ProcessModelsWebSocket(Context context, WebSocket ws, CancellationToken token)
    {
        await SendManifest(context, ws, token);

        var buffer = new byte[8192];
        while (ws.State == WebSocketState.Open && !token.IsCancellationRequested)
        {
            WebSocketReceiveResult result;
            try { result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token); }
            catch { break; }
            if (result.MessageType == WebSocketMessageType.Close) break;

            var input = Encoding.UTF8.GetString(buffer, 0, result.Count).Trim();
            if (string.IsNullOrEmpty(input)) continue;

            string action, id;
            try
            {
                using var doc = JsonDocument.Parse(input);
                action = doc.RootElement.TryGetProperty("action", out var a) ? (a.GetString() ?? "") : "";
                id = doc.RootElement.TryGetProperty("id", out var i) ? (i.GetString() ?? "") : "";
            }
            catch { continue; }

            switch (action)
            {
                case "list":
                    await SendManifest(context, ws, token);
                    break;

                case "delete":
                {
                    var spec = ModelCatalog.GetById(context, id);
                    if (spec != null) ModelCatalog.Delete(context, spec);
                    await SendManifest(context, ws, token);
                    break;
                }

                case "select":
                {
                    // §6 transactional selection: commit, rundown, bring-up under admission, verify.
                    // The manifest sent afterward reflects COMMITTED state only — on failover the
                    // checkmark shows the restored prior unit, and the error frame carries the
                    // typed fault (§3.1) for the failed target.
                    Func<string, Task> selReport = async (txt) =>
                        await Send(ws, new { type = "progress", id, text = txt.Trim(), pct = (int?)null }, token);
                    try { await ModelCatalog.SelectAsync(context, id, selReport, token); }
                    catch (Subsystem.RuntimeBroker.RbFaultException fx)
                    {
                        await Send(ws, new { type = "error", id, @class = fx.Fault.Class.ToString(),
                            backend = fx.Fault.Backend, text = fx.Fault.NativeDetail }, token);
                    }
                    catch (Exception ex) { await SendError(ws, id, ex.Message, token); }
                    await SendManifest(context, ws, token);
                    break;
                }

                case "download":
                {
                    var spec = ModelCatalog.GetById(context, id);
                    if (spec == null) { await SendError(ws, id, "Unknown model.", token); break; }
                    if (ModelCatalog.IsDownloading(spec.Id)) { await SendManifest(context, ws, token); break; }
                    // Detached ON PURPOSE: the receive loop must stay free so a later {action:'cancel'}
                    // frame on this same socket can reach ModelCatalog.Cancel while the download runs.
                    // Concurrent sends interleave safely via the per-socket gate in Send().
                    _ = DownloadAsync(context, ws, spec, token);
                    break;
                }

                case "cancel":
                {
                    // Cooperative stop; the .part stays on disk for resume. The detached download task
                    // emits the 'cancelled' frame as it unwinds; this manifest reflects the cancelled
                    // state (downloading=false) — immediately so when nothing was in flight.
                    ModelCatalog.Cancel(id);
                    await SendManifest(context, ws, token);
                    break;
                }
            }
        }
    }

    // One in-flight download for one socket: progress frames, then done|cancelled|error, then a
    // fresh manifest. Runs detached from the receive loop (see the 'download' case for why).
    private static async Task DownloadAsync(Context context, WebSocket ws, ModelSpec spec, CancellationToken token)
    {
        Func<string, Task> report = async (txt) =>
        {
            var m = System.Text.RegularExpressions.Regex.Match(txt, @"(\d+)%");
            await Send(ws, new { type = "progress", id = spec.Id, text = txt.Trim(), pct = m.Success ? int.Parse(m.Groups[1].Value) : (int?)null }, token);
        };
        try
        {
            await ModelCatalog.EnsureAsync(context, spec, report, token);
            await Send(ws, new { type = "done", id = spec.Id }, token);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            // Cancel(id) fired — a deliberate stop, not a fault; the .part is retained for resume.
            await Send(ws, new { type = "cancelled", id = spec.Id }, token);
        }
        catch (Exception ex) { await SendError(ws, spec.Id, ex.Message, token); }
        await SendManifest(context, ws, token);
    }

    private static async Task SendManifest(Context context, WebSocket ws, CancellationToken token)
    {
        // The registry projection: All() runs the sideload-discovery pass, so a model file dropped
        // into files/models/ appears here without a recompile. `active` marks the loader's selection;
        // an unseeded registry (fresh install, pre-Registrar) just means nothing is marked yet.
        string activeId;
        try { activeId = ModelCatalog.Active(context).Id; } catch { activeId = ""; }
        var models = new System.Collections.Generic.List<object>();
        foreach (var spec in ModelCatalog.All(context))
        {
            models.Add(new
            {
                id = spec.Id,
                name = spec.DisplayName,
                role = spec.Role,
                size = spec.ApproxSize,
                format = spec.Format,
                present = ModelCatalog.IsPresent(context, spec),
                downloading = ModelCatalog.IsDownloading(spec.Id),
                warn = ModelCatalog.ShouldWarn(context, spec),
                active = string.Equals(spec.Id, activeId, StringComparison.OrdinalIgnoreCase),
                discovered = spec.Discovered,
                downloadable = spec.Downloadable,
                degraded = spec.Degraded,
                degradedDetail = spec.DegradedDetail,
            });
        }
        await Send(ws, new { type = "manifest", models }, token);
    }

    private static Task SendError(WebSocket ws, string id, string text, CancellationToken token)
        => Send(ws, new { type = "error", id, text }, token);

    // Per-socket send gate: the receive loop and a detached download task both send frames, and
    // WebSocket.SendAsync forbids concurrent sends. Keyed weakly so a closed socket's gate is GC'd.
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<WebSocket, SemaphoreSlim> _sendGates = new();

    private static async Task Send(WebSocket ws, object frame, CancellationToken token)
    {
        if (ws.State != WebSocketState.Open) return;
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame));
        var gate = _sendGates.GetValue(ws, _ => new SemaphoreSlim(1, 1));
        try
        {
            await gate.WaitAsync(token);
            try { await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, token); }
            finally { gate.Release(); }
        }
        catch (Exception ex) { Dg.Log("models", "ws send dropped: " + ex.Message); }
    }
}
