using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Data.Sqlite;

namespace Subsystem.Cm;

// One ticket — an Incident (defect) or Change (enhancement/RFC) row, named after BMC Remedy ITSM's record
// types (we borrow Remedy's vocabulary for recognizability, never where it spites NT). Stored DENSE in the
// registry's durable plane: kind/category/status are integer codes dictionary-encoded against the closed
// vocabularies below, timestamps are unix-epoch seconds, and related files ride a single 0x1f-joined column
// (the unit-separator Cm uses for DependsOn) — no nested JSON at rest. The flat JSON shape is a PROJECTION
// rendered on read; the EOS log (the append-only end-of-session history) loads alongside.
public sealed class TicketRecord
{
    public long          Id           { get; set; }
    public string        Kind         { get; set; } = "";   // Incident | Change
    public string        Category     { get; set; } = "";
    public string        Summary      { get; set; } = "";
    public string[]      RelatedFiles { get; set; } = Array.Empty<string>();
    public int           Severity     { get; set; }
    public string        Status       { get; set; } = "";   // Open | Closed
    public long          Created      { get; set; }         // unix epoch seconds
    public long          Closed       { get; set; }         // 0 == still open
    public string        Disposition  { get; set; } = "";   // how it was closed — required to close (the terminal disposition)
    public EosLogEntry[] EosLog       { get; set; } = Array.Empty<EosLogEntry>();   // append-only end-of-session history
}

// One EOS-log entry — an append-only End-Of-Session record: what a session did to this ticket and the
// disposition it left. The durable shift-note that makes the raw chat disposable; named for the mechanism (a
// log of end-of-session reports), not metaphor. Stored DENSE in a sibling table (noted unix-epoch); entries
// are WRITTEN, never edited or deleted.
public sealed class EosLogEntry
{
    public long   Ticket      { get; set; }
    public long   Noted       { get; set; }   // unix epoch seconds
    public string Disposition { get; set; } = "";   // how the session left it
    public string Body        { get; set; } = "";   // the end-of-session report
}

// The ticket hive — the durable ticket plane, a projection of the ONE registry (Cm's subsystem-registry.db),
// NOT a second store ("Hive" is Cm-canonical for a durable plane; the tickets ARE one). Two-state call-center
// lifecycle: a ticket is OPENED (Create) and CLOSED with a mandatory DISPOSITION (how it was handled — fixed /
// won't-fix / duplicate / by-design / …), and accrues an append-only EOS log between. Synchronous by Cm's law.
// Verbs are the approved NT vocabulary (Create/Query/Write/Close); the cmdlets are thin host bindings.
public static class TicketHive
{
    // Closed vocabularies, dictionary-encoded: the stored integer IS the index. Append only, never reorder
    // (a reorder rewrites the meaning of every stored row). Expression-bodied so there is no static state.
    private static string[] Kinds      => new[] { "Incident", "Change" };   // BMC Remedy ITSM record types: Incident = defect, Change = enhancement/RFC
    private static string[] Statuses   => new[] { "Open", "Closed" };
    private static string[] Categories => new[] { "Vom", "Cm", "Dg", "Pp", "Rb", "Rs", "Pwsh", "Device", "gate", "build", "shell", "agent" };

    private static readonly char Sep = (char)0x1f;   // unit-separator: joins RelatedFiles (mirrors Cm.DependsOn)

    private static SqliteConnection Open()
    {
        var c = new SqliteConnection($"Data Source={Cm.DbPath}");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText =
            "CREATE TABLE IF NOT EXISTS Tickets(" +
            " id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER, category INTEGER, summary TEXT," +
            " related_files TEXT, severity INTEGER, status INTEGER, created INTEGER, closed INTEGER," +
            " disposition TEXT);" +
            // The EOS log — append-only end-of-session entries, one row each, ticket -> Tickets.id.
            "CREATE TABLE IF NOT EXISTS EosLog(" +
            " id INTEGER PRIMARY KEY AUTOINCREMENT, ticket INTEGER, noted INTEGER, disposition TEXT, body TEXT);";
        cmd.ExecuteNonQuery();
        return c;
    }

    private static int Code(string[] dict, string value, string field)
    {
        int i = Array.FindIndex(dict, d => d.Equals(value, StringComparison.OrdinalIgnoreCase));
        if (i < 0) throw new ArgumentException($"{field} '{value}' is not in the closed set: {string.Join(", ", dict)}");
        return i;
    }

    private static string Label(string[] dict, long code) => code >= 0 && code < dict.Length ? dict[code] : "?";

    // Create (Open) a ticket. Returns the stored row, projected with labels.
    public static TicketRecord Create(string kind, string category, string summary, string[]? relatedFiles, int severity)
    {
        int kindCode = Code(Kinds, kind, "Type");
        int catCode  = Code(Categories, category, "Category");
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var files = relatedFiles ?? Array.Empty<string>();

        using var c = Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText =
            "INSERT INTO Tickets(kind,category,summary,related_files,severity,status,created,closed,disposition)" +
            " VALUES($k,$c,$s,$f,$sev,0,$cr,0,''); SELECT last_insert_rowid();";
        cmd.Parameters.AddWithValue("$k", kindCode);
        cmd.Parameters.AddWithValue("$c", catCode);
        cmd.Parameters.AddWithValue("$s", summary ?? "");
        cmd.Parameters.AddWithValue("$f", string.Join(Sep, files));
        cmd.Parameters.AddWithValue("$sev", severity);
        cmd.Parameters.AddWithValue("$cr", now);
        long id = Convert.ToInt64(cmd.ExecuteScalar());
        Dg.Log("ticket", $"OPEN #{id} {kind}/{category} sev{severity}: {summary}");
        return new TicketRecord
        {
            Id = id, Kind = Kinds[kindCode], Category = Categories[catCode], Summary = summary ?? "",
            RelatedFiles = files, Severity = severity, Status = Statuses[0], Created = now,
        };
    }

    // Query (Enumerate) tickets, newest first. null/empty filters = any. search = case-insensitive substring
    // over summary + disposition. since/before bound the created date (unix epoch; 0 = unbounded). Each row's
    // EOS log loads alongside (oldest-first).
    public static List<TicketRecord> Query(string? kind, string? category, string? status, long? id,
                                           string? search, long since, long before)
    {
        using var c = Open();
        var list = new List<TicketRecord>();

        using (var cmd = c.CreateCommand())
        {
            var where = new List<string>();
            if (id.HasValue)                     { where.Add("id=$id");          cmd.Parameters.AddWithValue("$id", id.Value); }
            if (!string.IsNullOrEmpty(kind))     { where.Add("kind=$k");         cmd.Parameters.AddWithValue("$k", Code(Kinds, kind!, "Type")); }
            if (!string.IsNullOrEmpty(category)) { where.Add("category=$c");     cmd.Parameters.AddWithValue("$c", Code(Categories, category!, "Category")); }
            if (!string.IsNullOrEmpty(status))   { where.Add("status=$st");      cmd.Parameters.AddWithValue("$st", Code(Statuses, status!, "Status")); }
            if (!string.IsNullOrEmpty(search))   { where.Add("(summary LIKE $q OR disposition LIKE $q)"); cmd.Parameters.AddWithValue("$q", "%" + search + "%"); }
            if (since  > 0)                      { where.Add("created>=$since"); cmd.Parameters.AddWithValue("$since", since); }
            if (before > 0)                      { where.Add("created<$before"); cmd.Parameters.AddWithValue("$before", before); }
            cmd.CommandText =
                "SELECT id,kind,category,summary,related_files,severity,status,created,closed,disposition FROM Tickets"
                + (where.Count > 0 ? " WHERE " + string.Join(" AND ", where) : "") + " ORDER BY id DESC";

            using var r = cmd.ExecuteReader();
            while (r.Read())
                list.Add(new TicketRecord
                {
                    Id           = r.GetInt64(0),
                    Kind         = Label(Kinds, r.GetInt64(1)),
                    Category     = Label(Categories, r.GetInt64(2)),
                    Summary      = r.IsDBNull(3) ? "" : r.GetString(3),
                    RelatedFiles = r.IsDBNull(4) || r.GetString(4).Length == 0
                                     ? Array.Empty<string>()
                                     : r.GetString(4).Split(Sep, StringSplitOptions.RemoveEmptyEntries),
                    Severity     = r.IsDBNull(5) ? 0 : r.GetInt32(5),
                    Status       = Label(Statuses, r.GetInt64(6)),
                    Created      = r.IsDBNull(7) ? 0 : r.GetInt64(7),
                    Closed       = r.IsDBNull(8) ? 0 : r.GetInt64(8),
                    Disposition  = r.IsDBNull(9) ? "" : r.GetString(9),
                });
        }

        // Load each row's EOS log — oldest-first (append order). Same connection, after the ticket reader has
        // closed (Sqlite has no MARS).
        foreach (var t in list)
            t.EosLog = ReadEosLog(c, t.Id);

        return list;
    }

    // Read a ticket's EOS-log entries, oldest-first (append order).
    private static EosLogEntry[] ReadEosLog(SqliteConnection c, long ticketId)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT noted,disposition,body FROM EosLog WHERE ticket=$id ORDER BY id ASC";
        cmd.Parameters.AddWithValue("$id", ticketId);
        var entries = new List<EosLogEntry>();
        using var r = cmd.ExecuteReader();
        while (r.Read())
            entries.Add(new EosLogEntry
            {
                Ticket      = ticketId,
                Noted       = r.IsDBNull(0) ? 0 : r.GetInt64(0),
                Disposition = r.IsDBNull(1) ? "" : r.GetString(1),
                Body        = r.IsDBNull(2) ? "" : r.GetString(2),
            });
        return entries.ToArray();
    }

    // Write (append) an EOS-log entry — the end-of-session record. Append-only: no edit, no delete. A
    // disposition and a body are both required (an empty end-of-session note is noise). Returns the projected
    // entry, or null when no such ticket exists.
    public static EosLogEntry? WriteEosLog(long ticketId, string disposition, string body)
    {
        if (string.IsNullOrWhiteSpace(disposition)) throw new ArgumentException("an EOS-log disposition is required.");
        if (string.IsNullOrWhiteSpace(body))        throw new ArgumentException("an EOS-log body is required.");
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        using var c = Open();
        using (var chk = c.CreateCommand())
        {
            chk.CommandText = "SELECT 1 FROM Tickets WHERE id=$id";
            chk.Parameters.AddWithValue("$id", ticketId);
            if (chk.ExecuteScalar() == null) return null;
        }
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "INSERT INTO EosLog(ticket,noted,disposition,body) VALUES($t,$n,$d,$b)";
            cmd.Parameters.AddWithValue("$t", ticketId);
            cmd.Parameters.AddWithValue("$n", now);
            cmd.Parameters.AddWithValue("$d", disposition);
            cmd.Parameters.AddWithValue("$b", body);
            cmd.ExecuteNonQuery();
        }
        Dg.Log("ticket", $"EOSLOG #{ticketId} [{disposition}]: {body}");
        return new EosLogEntry { Ticket = ticketId, Noted = now, Disposition = disposition, Body = body };
    }

    // Close a ticket with a MANDATORY disposition — a ticket cannot be closed without saying how it was
    // handled. Returns the updated row, or null when no such id exists.
    public static TicketRecord? Close(long id, string disposition)
    {
        if (string.IsNullOrWhiteSpace(disposition))
            throw new ArgumentException("a disposition is required to close a ticket.");
        using (var c = Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "UPDATE Tickets SET status=1,closed=$cl,disposition=$d WHERE id=$id";
            cmd.Parameters.AddWithValue("$cl", DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            cmd.Parameters.AddWithValue("$d", disposition);
            cmd.Parameters.AddWithValue("$id", id);
            if (cmd.ExecuteNonQuery() == 0) return null;
        }
        Dg.Log("ticket", $"CLOSE #{id}: {disposition}");
        return Query(null, null, null, id, null, 0, 0).FirstOrDefault();
    }
}
