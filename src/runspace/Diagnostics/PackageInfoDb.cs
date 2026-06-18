using System;
using System.Collections.Generic;
using System.Data.Common;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Subsystem;

// One package-metadata record in the UAD/Canta shape. dependencies/neededBy = the package dependency
// graph ("what breaks if I disable this"), mirroring Cm's DependsOn.
public sealed class PackageInfo
{
    public string   Package      { get; set; } = "";
    public string   List         { get; set; } = "";   // source list (Oem/Aosp/Google/Carrier/Misc)
    public string   Description  { get; set; } = "";
    public string   Removal      { get; set; } = "";   // Recommended | Advanced | Expert | Unsafe
    public string[] Dependencies { get; set; } = Array.Empty<string>();
    public string[] NeededBy     { get; set; } = Array.Empty<string>();
}

// The package-metadata DB (UAD/Canta shape). Durable SQLite (subsystem-pkginfo.db), populated at RUNTIME
// — NOT bundled — to keep the repo license-clean (UAD data is GPL-3.0): fetch it once with
// `Update-PackageInfoDb -Url <uad-json-url>` and it materializes into SQLite (the OOBE pattern, network
// edition); thereafter it's local, queryable, and refreshable. Offline / un-fetched => empty DB and
// Add-PackageInfo degrades to Removal='Unknown'. Backend-owned; the renderer never holds it.
public static class PackageInfoDb
{
    private static Dictionary<string, PackageInfo>? _cache;
    private static readonly object _lock = new();
    private static string _dbPath = "";
    private static readonly char Sep = (char)0x1f;

    public static int Count    { get { Ensure(); return _cache!.Count; } }
    public static string DbPath{ get { Ensure(); return _dbPath; } }

    public static PackageInfo? Lookup(string package)
    {
        Ensure();
        return _cache!.TryGetValue(package, out var p) ? p : null;
    }

    // Fetch the UAD/Canta JSON from a URL and materialize it into the durable table. Returns a status.
    public static object UpdateFromUrl(string url)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            using var stream = http.GetStreamAsync(url).GetAwaiter().GetResult();
            using var doc = JsonDocument.Parse(stream);
            lock (_lock)
            {
                using var c = OpenAndEnsureSchema();
                int n = SeedFromDoc(c, doc);
                _cache = LoadAll(c);
                Dg.Log("pkg", $"package-info DB refreshed from {url}: {n} rows");
                return new { ok = true, rows = n, source = url, dbPath = _dbPath };
            }
        }
        catch (Exception ex)
        {
            return new { ok = false, error = $"{ex.GetType().Name}: {ex.Message}", source = url };
        }
    }

    private static void Ensure()
    {
        if (_cache != null) return;
        lock (_lock)
        {
            if (_cache != null) return;
            using var c = OpenAndEnsureSchema();
            _cache = LoadAll(c);
            Dg.Log("pkg", $"package-info DB: {_cache.Count} rows ({_dbPath}) — run Update-PackageInfoDb -Url to populate");
        }
    }

    private static SqliteConnection OpenAndEnsureSchema()
    {
        try { SQLitePCL.Batteries_V2.Init(); } catch { }
        _dbPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Personal), "subsystem-pkginfo.db");
        var c = new SqliteConnection($"Data Source={_dbPath}");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText =
            "PRAGMA journal_mode=WAL;" +
            "CREATE TABLE IF NOT EXISTS PackageInfo(package TEXT PRIMARY KEY, list TEXT, description TEXT," +
            " removal TEXT, dependencies TEXT, needed_by TEXT);";
        cmd.ExecuteNonQuery();
        return c;
    }

    private static int SeedFromDoc(SqliteConnection c, JsonDocument doc)
    {
        using var tx = c.BeginTransaction();
        using var cmd = c.CreateCommand();
        cmd.CommandText =
            "INSERT OR REPLACE INTO PackageInfo(package,list,description,removal,dependencies,needed_by)" +
            " VALUES($p,$l,$d,$r,$dep,$nb)";
        DbParameter P(string nm) { var p = cmd.CreateParameter(); p.ParameterName = nm; cmd.Parameters.Add(p); return p; }
        var pp = P("$p"); var pl = P("$l"); var pd = P("$d"); var pr = P("$r"); var pdep = P("$dep"); var pnb = P("$nb");

        int n = 0;
        foreach (var prop in doc.RootElement.EnumerateObject())
        {
            var v = prop.Value;
            pp.Value   = prop.Name;
            pl.Value   = Str(v, "list");
            pd.Value   = Str(v, "description");
            pr.Value   = Str(v, "removal");
            pdep.Value = Arr(v, "dependencies");
            pnb.Value  = Arr(v, "neededBy");
            cmd.ExecuteNonQuery();
            n++;
        }
        tx.Commit();
        return n;
    }

    private static string Str(JsonElement v, string name)
        => v.TryGetProperty(name, out var e) && e.ValueKind == JsonValueKind.String ? (e.GetString() ?? "") : "";

    private static string Arr(JsonElement v, string name)
    {
        if (!v.TryGetProperty(name, out var e) || e.ValueKind != JsonValueKind.Array) return "";
        var items = new List<string>();
        foreach (var it in e.EnumerateArray()) if (it.ValueKind == JsonValueKind.String) items.Add(it.GetString()!);
        return string.Join(Sep, items);
    }

    private static Dictionary<string, PackageInfo> LoadAll(SqliteConnection c)
    {
        var db = new Dictionary<string, PackageInfo>(StringComparer.Ordinal);
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT package,list,description,removal,dependencies,needed_by FROM PackageInfo";
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var pkg = r.GetString(0);
            db[pkg] = new PackageInfo
            {
                Package      = pkg,
                List         = r.IsDBNull(1) ? "" : r.GetString(1),
                Description  = r.IsDBNull(2) ? "" : r.GetString(2),
                Removal      = r.IsDBNull(3) ? "" : r.GetString(3),
                Dependencies = SplitCol(r, 4),
                NeededBy     = SplitCol(r, 5),
            };
        }
        return db;
    }

    private static string[] SplitCol(SqliteDataReader r, int i)
        => r.IsDBNull(i) || r.GetString(i).Length == 0
            ? Array.Empty<string>()
            : r.GetString(i).Split(Sep, StringSplitOptions.RemoveEmptyEntries);
}
