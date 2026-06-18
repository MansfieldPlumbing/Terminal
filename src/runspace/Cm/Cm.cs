using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using Microsoft.Data.Sqlite;

namespace Subsystem.Cm;

// Cm — the Configuration Manager (NT's registry subsystem; the COM/CLSID analog). Two planes
// (VOM-SPEC §6/§7): an in-memory VOLATILE namespace (the live, resolvable records — the fast read path)
// + a durable SQLITE plane (WAL, atomic upsert) that rehydrates on boot. This is what makes real-time
// cmdlets persist (lock-in/promotion, the north-star loop) and is the SCM database for the Sc services
// layer + the rocker-toggle settings. Lazy-inits on first use; db lives in the app's private files dir.
public static class Cm
{
    private static readonly ConcurrentDictionary<string, CapabilityRecord> _records =
        new(StringComparer.OrdinalIgnoreCase);
    private static readonly object _initLock = new();
    private static bool _initialized;
    private static string _dbPath = "";
    private static readonly char Sep = (char)0x1f;   // unit-separator: joins DependsOn (illegal in paths)

    public static string DbPath { get { Ensure(); return _dbPath; } }

    private static void Ensure()
    {
        if (_initialized) return;
        lock (_initLock)
        {
            if (_initialized) return;
            try { SQLitePCL.Batteries_V2.Init(); } catch { /* newer bundles auto-init */ }
            // Resolve a GUARANTEED-writable dir. SpecialFolder.Personal can resolve empty / non-writable
            // on .NET-Android at this early point (the Registrar inits Cm before HOME is set) → the DB opens
            // at "/" and throws SQLite error 14 CANTOPEN, preventing registry initialization (no /apps, no menu).
            // The app's private FilesDir is the same dir the models live in; always exists, always ours.
            string dir = null;
            try { dir = Subsystem.MainActivity.Instance?.FilesDir?.AbsolutePath; } catch { }
            if (string.IsNullOrEmpty(dir)) { try { dir = Environment.GetFolderPath(Environment.SpecialFolder.Personal); } catch { } }
            if (string.IsNullOrEmpty(dir)) dir = Path.GetTempPath();   // last-ditch: the platform temp (app cache on Android) — always writable and ours, never a hardcoded device path
            try { Directory.CreateDirectory(dir); } catch { }
            _dbPath = Path.Combine(dir, "subsystem-registry.db");
            using (var c = Open())
            {
                Exec(c,
                    "PRAGMA journal_mode=WAL;" +
                    "CREATE TABLE IF NOT EXISTS Capabilities(" +
                    " path TEXT PRIMARY KEY, name TEXT, type TEXT, source TEXT, manifest_json TEXT," +
                    " owner TEXT, integrity TEXT, start_type TEXT, enabled INTEGER, depends_on TEXT," +
                    " created TEXT, modified TEXT, hash TEXT);" +
                    "CREATE TABLE IF NOT EXISTS CapabilityRefs(" +
                    " from_path TEXT, to_path TEXT, PRIMARY KEY(from_path,to_path));");
                Rehydrate(c);
            }
            _initialized = true;
            Dg.Log("cm", $"registry init: {_records.Count} capabilities rehydrated from {_dbPath}");
        }
    }

    private static SqliteConnection Open()
    {
        var c = new SqliteConnection($"Data Source={_dbPath}");
        c.Open();
        return c;
    }

    private static void Exec(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static void Bind(SqliteCommand cmd, string name, object? val)
        => cmd.Parameters.AddWithValue(name, val ?? DBNull.Value);

    private static void Rehydrate(SqliteConnection c)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText =
            "SELECT path,name,type,source,manifest_json,owner,integrity,start_type,enabled,depends_on,created,modified,hash FROM Capabilities";
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var rec = new CapabilityRecord
            {
                Path        = r.GetString(0),
                Name        = r.IsDBNull(1) ? "" : r.GetString(1),
                Type        = r.IsDBNull(2) ? "Capability" : r.GetString(2),
                Source      = r.IsDBNull(3) ? null : r.GetString(3),
                ManifestJson= r.IsDBNull(4) ? null : r.GetString(4),
                Owner       = r.IsDBNull(5) ? "\\System" : r.GetString(5),
                Integrity   = r.IsDBNull(6) ? "User" : r.GetString(6),
                StartType   = r.IsDBNull(7) ? "manual" : r.GetString(7),
                Enabled     = !r.IsDBNull(8) && r.GetInt32(8) != 0,
                DependsOn   = r.IsDBNull(9) || r.GetString(9).Length == 0
                                ? Array.Empty<string>()
                                : r.GetString(9).Split(Sep, StringSplitOptions.RemoveEmptyEntries),
                Created     = r.IsDBNull(10) ? "" : r.GetString(10),
                Modified    = r.IsDBNull(11) ? "" : r.GetString(11),
                Hash        = r.IsDBNull(12) ? "" : r.GetString(12),
            };
            _records[rec.Path] = rec;
        }
    }

    // Register (upsert) a capability into both planes. Atomic on the durable side via ON CONFLICT.
    public static CapabilityRecord Register(CapabilityRecord rec)
    {
        Ensure();
        var now = DateTime.UtcNow.ToString("o");
        rec.Created  = string.IsNullOrEmpty(rec.Created)
            ? (_records.TryGetValue(rec.Path, out var ex) ? ex.Created : now)
            : rec.Created;
        rec.Modified = now;
        _records[rec.Path] = rec;

        using var c = Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText =
            "INSERT INTO Capabilities(path,name,type,source,manifest_json,owner,integrity,start_type,enabled,depends_on,created,modified,hash)" +
            " VALUES($p,$n,$t,$s,$m,$o,$i,$st,$e,$d,$cr,$mo,$h)" +
            " ON CONFLICT(path) DO UPDATE SET name=$n,type=$t,source=$s,manifest_json=$m,owner=$o,integrity=$i," +
            " start_type=$st,enabled=$e,depends_on=$d,modified=$mo,hash=$h;";
        Bind(cmd, "$p", rec.Path);  Bind(cmd, "$n", rec.Name);  Bind(cmd, "$t", rec.Type);
        Bind(cmd, "$s", rec.Source); Bind(cmd, "$m", rec.ManifestJson); Bind(cmd, "$o", rec.Owner);
        Bind(cmd, "$i", rec.Integrity); Bind(cmd, "$st", rec.StartType); Bind(cmd, "$e", rec.Enabled ? 1 : 0);
        Bind(cmd, "$d", string.Join(Sep, rec.DependsOn)); Bind(cmd, "$cr", rec.Created);
        Bind(cmd, "$mo", rec.Modified); Bind(cmd, "$h", rec.Hash);
        cmd.ExecuteNonQuery();
        Dg.Log("cm", $"REGISTER {rec.Path} ({rec.Type}/{rec.Integrity}, start={rec.StartType}, enabled={rec.Enabled})");
        return rec;
    }

    public static CapabilityRecord? Get(string path)  { Ensure(); return _records.TryGetValue(path, out var r) ? r : null; }
    public static CapabilityRecord[] List()           { Ensure(); return _records.Values.OrderBy(r => r.Path, StringComparer.OrdinalIgnoreCase).ToArray(); }

    public static bool Unregister(string path)
    {
        Ensure();
        bool had = _records.TryRemove(path, out _);
        using var c = Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "DELETE FROM Capabilities WHERE path=$p; DELETE FROM CapabilityRefs WHERE from_path=$p OR to_path=$p;";
        Bind(cmd, "$p", path);
        cmd.ExecuteNonQuery();
        Dg.Log("cm", $"UNREGISTER {path} (existed={had})");
        return had;
    }

    public static CapabilityRecord? Set(string path, bool? enabled, string? startType)
    {
        Ensure();
        if (!_records.TryGetValue(path, out var r)) return null;
        if (enabled.HasValue) r.Enabled = enabled.Value;
        if (!string.IsNullOrEmpty(startType)) r.StartType = startType!;
        return Register(r);   // re-persist
    }

    // Self-test (like Test-Vom): register a probe capability, read it back from BOTH planes, then clean up.
    // The full rehydrate-on-boot proof is: register a capability -> relaunch the app -> Get-Capability.
    public static object SelfTest()
    {
        Ensure();
        string p = $"\\Capability\\__cmtest_{DateTime.Now:HHmmss}";
        Register(new CapabilityRecord
        {
            Path = p, Name = "CmTest", Type = "Probe", Integrity = "System",
            StartType = "manual", Enabled = true, DependsOn = new[] { "\\Capability\\Projection" }
        });
        var back = Get(p);

        int durable;
        using (var c = Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM Capabilities WHERE path=$p";
            Bind(cmd, "$p", p);
            durable = Convert.ToInt32(cmd.ExecuteScalar());
        }
        Unregister(p);

        return new
        {
            ok        = back != null && durable == 1 && Get(p) == null,
            dbPath    = _dbPath,
            inMemory  = back != null,
            inDurable = durable == 1,
            total     = _records.Count,
            note      = "registered a probe capability, confirmed in-memory + SQLite (WAL), then unregistered",
        };
    }
}
