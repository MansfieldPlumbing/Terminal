using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Subsystem.Cm;

namespace Subsystem.RuntimeBroker
{
    // Saved agent chats — registry-faithful (doctrine: everything is an object in ONE namespace; no second
    // store). A conversation is a Cm capability at `\Agent\Session\<id>`, Type="Session"; its ManifestJson IS
    // the transcript. Append-only turns. No sibling DB, no files
    // — the durable SQLite plane under Cm already gives us persistence + rehydrate-on-boot for free.
    public static class AgentSessionTable
    {
        private const string Prefix = "\\Agent\\Session\\";
        private const int MaxTurns = 400;   // bound the manifest; a phone chat doesn't need infinite scrollback

        public sealed class Turn
        {
            [JsonPropertyName("role")] public string Role { get; set; } = "user";   // user | assistant
            [JsonPropertyName("text")] public string Text { get; set; } = "";
            [JsonPropertyName("ts")]   public string Ts   { get; set; } = "";
        }

        public sealed class Session
        {
            [JsonPropertyName("id")]      public string Id      { get; set; } = "";
            [JsonPropertyName("title")]   public string Title   { get; set; } = "New chat";
            [JsonPropertyName("created")] public string Created { get; set; } = "";
            [JsonPropertyName("updated")] public string Updated { get; set; } = "";
            [JsonPropertyName("turns")]   public List<Turn> Turns { get; set; } = new();
        }

        private static readonly JsonSerializerOptions Opt = new() { DefaultIgnoreCondition = JsonIgnoreCondition.Never };

        // Create a new empty session; returns its id. Title defaults; first user turn can rename it.
        public static string Create(string? title = null)
        {
            var now = DateTime.UtcNow;
            var id = now.ToString("yyyyMMdd-HHmmss-fff");
            var s = new Session { Id = id, Title = string.IsNullOrWhiteSpace(title) ? "New chat" : title!.Trim(), Created = now.ToString("o"), Updated = now.ToString("o") };
            Persist(s);
            return id;
        }

        // Append one turn. If the session doesn't exist yet it's created. The first user turn auto-titles the
        // chat from its text ("name the thread by its first ask").
        public static void AppendTurn(string id, string role, string text)
        {
            var s = Load(id) ?? new Session { Id = id, Created = DateTime.UtcNow.ToString("o") };
            if (s.Title is "New chat" or "" && role == "user" && !string.IsNullOrWhiteSpace(text))
                s.Title = text.Trim().Length <= 48 ? text.Trim() : text.Trim().Substring(0, 48) + "…";
            s.Turns.Add(new Turn { Role = role, Text = text ?? "", Ts = DateTime.UtcNow.ToString("o") });
            if (s.Turns.Count > MaxTurns) s.Turns.RemoveRange(0, s.Turns.Count - MaxTurns);
            s.Updated = DateTime.UtcNow.ToString("o");
            Persist(s);
        }

        public static Session? Load(string id)
        {
            var rec = Cm.Cm.Get(Prefix + id);
            if (rec?.ManifestJson == null) return null;
            try { return JsonSerializer.Deserialize<Session>(rec.ManifestJson, Opt); } catch { return null; }
        }

        // The session as its raw manifest JSON (what the UI loads to replay a transcript).
        public static string? LoadJson(string id) => Cm.Cm.Get(Prefix + id)?.ManifestJson;

        public static bool Delete(string id) => Cm.Cm.Unregister(Prefix + id);

        public static bool Rename(string id, string title)
        {
            var s = Load(id); if (s == null) return false;
            s.Title = string.IsNullOrWhiteSpace(title) ? s.Title : title.Trim();
            s.Updated = DateTime.UtcNow.ToString("o"); Persist(s); return true;
        }

        // Lightweight list for the chat drawer: newest first, no transcript bodies.
        public static object[] ListSummaries()
        {
            var list = new List<(string updated, object row)>();
            foreach (var rec in Cm.Cm.List())
            {
                if (rec.Type != "Session" || !rec.Path.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase) || rec.ManifestJson == null) continue;
                try
                {
                    var s = JsonSerializer.Deserialize<Session>(rec.ManifestJson, Opt);
                    if (s == null) continue;
                    list.Add((s.Updated, new { id = s.Id, title = s.Title, updated = s.Updated, turns = s.Turns.Count }));
                }
                catch { }
            }
            return list.OrderByDescending(x => x.updated, StringComparer.Ordinal).Select(x => x.row).ToArray();
        }

        private static void Persist(Session s)
        {
            Cm.Cm.Register(new CapabilityRecord
            {
                Path = Prefix + s.Id,
                Name = s.Title,
                Type = "Session",
                Owner = "\\Agent",
                Integrity = "User",
                StartType = "manual",
                Enabled = true,
                ManifestJson = JsonSerializer.Serialize(s, Opt),
            });
        }
    }
}
