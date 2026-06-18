using System;
using System.Management.Automation;
using System.Text;
using System.Threading;
using Subsystem.Device;

namespace Subsystem.Pwsh.Cmdlets;

// The Rd browse driver, surfaced to the runspace (and so to PSRP and the agent tool loop). Invoke-WebDrive
// runs a '|'-separated intent sequence on the agent-owned WebView and returns the HUD; Get-WebHud reads the
// current situation report; Stop-WebDrive tears the surface down. The on-device port of agent-webview2's
// --drive, driven the same way from either head.
[Cmdlet(VerbsLifecycle.Invoke, "WebDrive")]
public sealed class InvokeWebDriveCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Script { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            var hud = WebDrive.Open().ApplyAsync(Script).GetAwaiter().GetResult();
            Emit(hud);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "InvokeWebDriveFailed", ErrorCategory.InvalidOperation, Script));
        }
    }
}

[Cmdlet(VerbsCommon.Get, "WebHud")]
public sealed class GetWebHudCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try
        {
            var hud = WebDrive.Open().ReadHudAsync("current").GetAwaiter().GetResult();
            Emit(hud);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "GetWebHudFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}

[Cmdlet(VerbsLifecycle.Stop, "WebDrive")]
public sealed class StopWebDriveCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try
        {
            WebDrive.Open().Close();
            Emit("closed");
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "StopWebDriveFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}

// Invoke-WebAgent — the on-device model drives the WebView to complete an OBJECTIVE over several turns,
// one intent per turn (the agent-webview2 --agent loop, native). The model runs on a FORKED side-
// conversation (shared engine, ephemeral KV) so its driving turns never pollute the resident Broker's
// conversation; the surface's own navigation history supplies the visited-page dedup instead of an
// ever-growing prompt. Operator-cancelable: Ctrl-C (or a stopped PSRP call) cancels the in-flight turn.
[Cmdlet(VerbsLifecycle.Invoke, "WebAgent")]
public sealed class InvokeWebAgentCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Objective { get; set; } = string.Empty;

    [Parameter] public int MaxHops { get; set; } = 6;

    private CancellationTokenSource? _cts;

    protected override void ProcessRecord()
    {
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        try
        {
            var ctx = Subsystem.MainActivity.Instance ?? Android.App.Application.Context;
            var broker = Subsystem.Rb.GetAsync(ctx, null, ct).GetAwaiter().GetResult();
            var sideOpt = broker.OpenSideConversation(ResolveWebAgentPrompt(), null);
            if (sideOpt == null)
            {
                // Degrade visibly (the error stream does not cross /clixml) — never vanish.
                var degraded = new PSObject();
                degraded.Properties.Add(new PSNoteProperty("Objective", Objective));
                degraded.Properties.Add(new PSNoteProperty("Hops", 0));
                degraded.Properties.Add(new PSNoteProperty("Answer", ""));
                degraded.Properties.Add(new PSNoteProperty("Trail", ""));
                degraded.Properties.Add(new PSNoteProperty("Error", "no forked side-conversation from the active runtime (see Dg engine log: SIDE-CONV …)"));
                Emit(degraded);
                return;
            }
            using var side = sideOpt;
            var surface = WebDrive.Open();

            var trail = new StringBuilder();
            string answer = "";
            string hud = surface.ReadHudAsync("start").GetAwaiter().GetResult();
            int hops = 0;

            for (int hop = 1; hop <= MaxHops; hop++)
            {
                ct.ThrowIfCancellationRequested();
                hops = hop;
                var visited = surface.QueryHistory();
                string seen = visited.Length == 0 ? "" : "\n[ALREADY VISITED]\n- " + string.Join("\n- ", visited);
                string user = "OBJECTIVE: " + Objective + seen + "\n\n" + hud + "\n\nYour single next intent:";

                string reply = ReadReplyAsync(side, user, ct).GetAwaiter().GetResult();
                string intent = ParseIntent(reply);
                trail.Append("\n===== HOP ").Append(hop).Append(" =====\n[MODEL] ").Append(reply.Trim())
                     .Append("\n[INTENT] ").Append(intent).Append('\n');

                if (string.IsNullOrWhiteSpace(intent) || intent.Equals("DONE", StringComparison.OrdinalIgnoreCase))
                    break;
                if (intent.StartsWith("respond", StringComparison.OrdinalIgnoreCase))
                {
                    answer = intent.Length > 7 ? intent.Substring(7).Trim().Trim('"') : "";
                    break;
                }
                hud = surface.ApplyAsync(intent, ct).GetAwaiter().GetResult();
            }

            var obj = new PSObject();
            obj.Properties.Add(new PSNoteProperty("Objective", Objective));
            obj.Properties.Add(new PSNoteProperty("Hops", hops));
            obj.Properties.Add(new PSNoteProperty("Answer", answer));
            obj.Properties.Add(new PSNoteProperty("Trail", trail.ToString()));
            Emit(obj);
        }
        catch (OperationCanceledException)
        {
            WriteWarning("Invoke-WebAgent canceled by operator.");
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "InvokeWebAgentFailed", ErrorCategory.InvalidOperation, Objective));
        }
        finally { _cts?.Dispose(); _cts = null; }
    }

    protected override void StopProcessing() => _cts?.Cancel();

    // Drain a side-conversation turn to its visible answer text (the thinking channel is already split out
    // by the runtime). Only Token deltas are collected — the intent is parsed from the answer.
    private static async System.Threading.Tasks.Task<string> ReadReplyAsync(
        Subsystem.RuntimeBroker.SideConversation side, string prompt, CancellationToken ct)
    {
        var sb = new StringBuilder();
        await foreach (var d in side.StreamTurnAsync(prompt, ct))
            if (d.Kind == Subsystem.RuntimeBroker.AgentDeltaKind.Token && !string.IsNullOrEmpty(d.Text)) sb.Append(d.Text);
        return sb.ToString();
    }

    // The web-agent system prompt is a Cm CONTRACT (\Capability\Prompt\webagent, seeded from prompts.json),
    // resolved live — never a C# literal (SS020). Absent -> empty (the engine default).
    private static string ResolveWebAgentPrompt()
    {
        try
        {
            var rec = Subsystem.Cm.Cm.Get("\\Capability\\Prompt\\webagent");
            if (rec?.ManifestJson == null) return "";
            using var doc = System.Text.Json.JsonDocument.Parse(rec.ManifestJson);
            return doc.RootElement.TryGetProperty("systemInstruction", out var v) ? (v.GetString() ?? "") : "";
        }
        catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); return ""; }
    }

    // Pull the single next intent out of the model's reply (tolerant of a chatty model). The runtime
    // already strips the Gemma thinking channel; a stray <think> block is removed defensively.
    private static string ParseIntent(string reply)
    {
        if (string.IsNullOrEmpty(reply)) return "";
        var t = System.Text.RegularExpressions.Regex.Replace(reply, "(?s)<think>.*?</think>", "");
        var m = System.Text.RegularExpressions.Regex.Match(t,
            "(?im)(/goto\\s+\\S+|/type\\s+\\d+\\s+\"[^\"]*\"|/click\\s+\\d+|/back|/respond\\s+.+|\\bDONE\\b)");
        if (!m.Success) return "";
        var v = m.Value.Trim();
        if (v.Equals("DONE", StringComparison.OrdinalIgnoreCase)) return "DONE";
        return v.StartsWith("/") ? v.Substring(1).Trim() : v;
    }
}
