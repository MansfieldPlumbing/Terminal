using System;

namespace Subsystem;

// De-risk probe: does Microsoft.Data.Sqlite's native engine (e_sqlite3) actually load + round-trip
// under .NET-on-Android? If yes, it's the registry's durable plane (WAL/transactions/query). If it
// throws, the registry falls back to in-box JSON/Clixml persistence (zero native dep). Test-Sqlite.
public static class SqliteProbe
{
    public static object SmokeTest()
    {
        try
        {
            try { SQLitePCL.Batteries_V2.Init(); } catch { /* newer bundles auto-init */ }

            using var c = new Microsoft.Data.Sqlite.SqliteConnection("Data Source=:memory:");
            c.Open();
            using (var cmd = c.CreateCommand())
            {
                cmd.CommandText = "CREATE TABLE t(k TEXT, v TEXT); INSERT INTO t VALUES('hello','world');";
                cmd.ExecuteNonQuery();
            }
            using (var q = c.CreateCommand())
            {
                q.CommandText = "SELECT v FROM t WHERE k='hello'";
                var v = q.ExecuteScalar() as string;
                var ver = typeof(Microsoft.Data.Sqlite.SqliteConnection).Assembly.GetName().Version?.ToString();
                return new { ok = v == "world", roundTrip = v, sqliteVersion = ver };
            }
        }
        catch (Exception ex)
        {
            return new { ok = false, error = $"{ex.GetType().Name}: {ex.Message}" };
        }
    }
}
