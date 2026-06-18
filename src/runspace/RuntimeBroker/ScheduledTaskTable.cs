using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Subsystem.Cm;

namespace Subsystem.RuntimeBroker
{
    // The durable scheduled-task plane — the temporal agent's spine: inference that fires OUTSIDE the chat
    // window, on a clock. Registry-faithful (one namespace, no second store): a task is a Cm capability at
    // `\Agent\Task\<id>`, Type="ScheduledTask"; its ManifestJson IS the spec + status. The durable SQLite
    // plane under Cm gives persistence and rehydrate-on-boot, so a scheduled task survives a process restart.
    //
    // TWO MODES: `owner` = a task the owner scheduled; `agent` = a task the agent scheduled for itself. Both
    // are possession-gated (default-deny): an agent-mode unattended run requires the owner-granted handle
    // named in Gate (e.g. `\Capability\Inference\Unattended`). This table is the RECORD only — it stores the
    // spec, answers "what is due", and advances recurrence. The ticker (the clock) fires due tasks and the
    // consent gate checks Gate possession at fire time; neither lives here (mount doctrine, not a god object).
    public static class ScheduledTaskTable
    {
        private const string Prefix = "\\Agent\\Task\\";

        public sealed class ScheduledTask
        {
            [JsonPropertyName("id")]         public string Id         { get; set; } = "";
            [JsonPropertyName("title")]      public string Title      { get; set; } = "Task";
            [JsonPropertyName("prompt")]     public string Prompt     { get; set; } = "";       // what the agent inferences on when it fires
            [JsonPropertyName("mode")]       public string Mode       { get; set; } = "owner";  // owner | agent — who scheduled it
            [JsonPropertyName("gate")]       public string Gate       { get; set; } = "";       // capability path whose possession authorizes the run
            [JsonPropertyName("sessionId")]  public string SessionId  { get; set; } = "";       // optional \Agent\Session the result threads into
            [JsonPropertyName("recurrence")] public string Recurrence { get; set; } = "";       // "" = one-shot; "every:<seconds>" = fixed interval
            [JsonPropertyName("nextRun")]    public string NextRun    { get; set; } = "";       // ISO-o UTC of the next fire
            [JsonPropertyName("status")]     public string Status     { get; set; } = "pending";// pending | running | done | failed | cancelled
            [JsonPropertyName("created")]    public string Created    { get; set; } = "";
            [JsonPropertyName("updated")]    public string Updated    { get; set; } = "";
            [JsonPropertyName("lastRun")]    public string LastRun    { get; set; } = "";
            [JsonPropertyName("lastResult")] public string LastResult { get; set; } = "";
        }

        private static readonly JsonSerializerOptions Opt = new() { DefaultIgnoreCondition = JsonIgnoreCondition.Never };

        // Create (schedule) a task. firstRunUtc is its first fire; recurrence "" = one-shot, "every:<seconds>"
        // repeats at a fixed cadence after each run. mode is "owner" or "agent"; gate is the capability path
        // whose possession authorizes the (unattended) run. Returns the task id.
        public static string Create(string title, string prompt, DateTime firstRunUtc,
            string mode = "owner", string gate = "", string recurrence = "", string sessionId = "")
        {
            var now = DateTime.UtcNow;
            var id = now.ToString("yyyyMMdd-HHmmss-fff");
            var t = new ScheduledTask
            {
                Id = id,
                Title = string.IsNullOrWhiteSpace(title) ? "Task" : title.Trim(),
                Prompt = prompt ?? "",
                Mode = mode == "agent" ? "agent" : "owner",
                Gate = gate ?? "",
                Recurrence = recurrence ?? "",
                SessionId = sessionId ?? "",
                NextRun = firstRunUtc.ToUniversalTime().ToString("o"),
                Status = "pending",
                Created = now.ToString("o"),
                Updated = now.ToString("o"),
            };
            Persist(t);
            return id;
        }

        public static ScheduledTask? Load(string id)
        {
            var rec = Cm.Cm.Get(Prefix + id);
            if (rec?.ManifestJson == null) return null;
            try { return JsonSerializer.Deserialize<ScheduledTask>(rec.ManifestJson, Opt); }
            catch (Exception ex) { Subsystem.Dg.Warn("schedule", ex); return null; }
        }

        // The tasks whose next fire has arrived (NextRun <= now) and are still pending — the set the
        // ticker drains each time it wakes.
        public static ScheduledTask[] Query()
        {
            var now = DateTime.UtcNow;
            var due = new List<ScheduledTask>();
            foreach (var rec in Cm.Cm.List())
            {
                if (rec.Type != "ScheduledTask" || !rec.Path.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) || rec.ManifestJson == null) continue;
                ScheduledTask? t;
                try { t = JsonSerializer.Deserialize<ScheduledTask>(rec.ManifestJson, Opt); }
                catch (Exception ex) { Subsystem.Dg.Warn("schedule", ex); continue; }
                if (t == null || t.Status != "pending" || string.IsNullOrEmpty(t.NextRun)) continue;
                if (DateTime.TryParse(t.NextRun, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var nr) && nr.ToUniversalTime() <= now)
                    due.Add(t);
            }
            return due.OrderBy(x => x.NextRun, StringComparer.Ordinal).ToArray();
        }

        // Open the run: claim the task and mark it running (visible while it inferences).
        public static void Open(string id)
        {
            var t = Load(id); if (t == null) return;
            t.Status = "running"; t.LastRun = DateTime.UtcNow.ToString("o"); t.Updated = t.LastRun; Persist(t);
        }

        // Record the outcome and advance: a recurring task re-arms its NextRun and returns to pending; a
        // one-shot finishes (done | failed). The trail/result is the agent's claim, persisted for audit.
        public static void Close(string id, bool ok, string result)
        {
            var t = Load(id); if (t == null) return;
            t.LastResult = result ?? "";
            t.Updated = DateTime.UtcNow.ToString("o");
            var next = NextFire(t);
            if (next.HasValue) { t.NextRun = next.Value.ToString("o"); t.Status = "pending"; }
            else { t.Status = ok ? "done" : "failed"; }
            Persist(t);
        }

        public static bool Cancel(string id)
        {
            var t = Load(id); if (t == null) return false;
            t.Status = "cancelled"; t.Updated = DateTime.UtcNow.ToString("o"); Persist(t); return true;
        }

        public static bool Delete(string id) => Cm.Cm.Unregister(Prefix + id);

        // Newest-scheduled first; spec fields only (a task is small, no bodies to trim).
        public static object[] List()
        {
            var rows = new List<(string created, object row)>();
            foreach (var rec in Cm.Cm.List())
            {
                if (rec.Type != "ScheduledTask" || !rec.Path.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) || rec.ManifestJson == null) continue;
                try
                {
                    var t = JsonSerializer.Deserialize<ScheduledTask>(rec.ManifestJson, Opt);
                    if (t == null) continue;
                    rows.Add((t.Created, new { id = t.Id, title = t.Title, mode = t.Mode, status = t.Status, nextRun = t.NextRun, recurrence = t.Recurrence }));
                }
                catch (Exception ex) { Subsystem.Dg.Warn("schedule", ex); }
            }
            return rows.OrderByDescending(x => x.created, StringComparer.Ordinal).Select(x => x.row).ToArray();
        }

        // The next fire time for a recurring task after a run, or null for a one-shot. Recurrence grammar:
        // "every:<seconds>" repeats at a fixed cadence; "" (or anything unrecognized) is one-shot. Calendar
        // recurrences (time-of-day, day-of-week) extend this switch without restructuring the table.
        private static DateTime? NextFire(ScheduledTask t)
        {
            if (string.IsNullOrWhiteSpace(t.Recurrence)) return null;
            const string everyPrefix = "every:";
            if (t.Recurrence.StartsWith(everyPrefix, StringComparison.OrdinalIgnoreCase)
                && int.TryParse(t.Recurrence.Substring(everyPrefix.Length), NumberStyles.Integer, CultureInfo.InvariantCulture, out var secs)
                && secs > 0)
            {
                return DateTime.UtcNow.AddSeconds(secs);
            }
            return null;
        }

        private static void Persist(ScheduledTask t)
        {
            Cm.Cm.Register(new CapabilityRecord
            {
                Path = Prefix + t.Id,
                Name = t.Title,
                Type = "ScheduledTask",
                Owner = "\\Agent",
                Integrity = "User",
                StartType = "manual",
                Enabled = t.Status == "pending",
                ManifestJson = JsonSerializer.Serialize(t, Opt),
            });
        }
    }
}
