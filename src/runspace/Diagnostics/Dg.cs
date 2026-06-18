using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using Android.Content;

namespace Subsystem;

// Dg — Diagnostics (NT-shaped; replaces the old /sdcard 'Dom' text-appender). The system's one logging
// sink: leveled, structured records held in a bounded in-memory ring AND appended to an app-PRIVATE file
// (FilesDir/log/, no /sdcard, no storage permission), with size rotation. Crash capture folds in as Fatal.
// Records are objects, queryable via Snapshot()/Recent() — the /diag + Get-Diagnostics presenters render
// them. One sink, many writers: a subsystem that hits trouble writes Dg.Warn/Dg.Error here instead of
// swallowing the error.
public enum DgLevel { Trace, Debug, Info, Warn, Error, Fatal }

public readonly record struct DgRecord(DateTime Time, DgLevel Level, string Source, string Message);

public static class Dg
{
    private const int  RingCapacity = 500;        // recent records kept in memory for /diag
    private const long MaxFileBytes = 1_000_000;  // rotate events.log past ~1 MB

    private static readonly object _gate = new();
    private static readonly Queue<DgRecord> _ring = new(RingCapacity + 1);
    private static readonly DateTime _start = DateTime.Now;
    private static Context? _ctx;
    private static string? _dir;

    public static void Initialize(Context ctx)
    {
        _ctx = ctx;
        try
        {
            _dir = Path.Combine(ctx.FilesDir!.AbsolutePath, "log");
            Directory.CreateDirectory(_dir);
        }
        catch (Exception ex) { Android.Util.Log.Warn("Subsystem.Dg", $"log dir init failed: {ex.Message}"); }

        // Managed unhandled exceptions.
        AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            RecordCrash(e.ExceptionObject as Exception, "AppDomain");
        // Android/Java-side unhandled (the FATAL EXCEPTIONs). We record but DON'T mark handled —
        // let it crash normally; we just captured the artifact first.
        Android.Runtime.AndroidEnvironment.UnhandledExceptionRaiser += (s, e) =>
            RecordCrash(e.Exception, "AndroidEnvironment");

        Write(DgLevel.Info, "boot", $"Subsystem started (v{AppVersion()})");
    }

    // Back-compat entry point (the old Dom.Log) — an Info record. Prefer the leveled methods below.
    public static void Log(string source, string message)   => Write(DgLevel.Info,  source, message);

    public static void Trace(string source, string message) => Write(DgLevel.Trace, source, message);
    public static void Debug(string source, string message) => Write(DgLevel.Debug, source, message);
    public static void Info (string source, string message) => Write(DgLevel.Info,  source, message);
    public static void Warn (string source, string message) => Write(DgLevel.Warn,  source, message);
    public static void Error(string source, string message) => Write(DgLevel.Error, source, message);

    // The empty-catch cure (SS007): a degraded path reports WHAT failed, with level.
    public static void Warn (string source, Exception ex)   => Write(DgLevel.Warn,  source, Describe(ex));
    public static void Error(string source, Exception ex)   => Write(DgLevel.Error, source, Describe(ex));

    private static string Describe(Exception ex) => $"{ex.GetType().Name}: {ex.Message}";

    public static void Write(DgLevel level, string source, string message)
    {
        var rec = new DgRecord(DateTime.Now, level, source, message);
        lock (_gate)
        {
            _ring.Enqueue(rec);
            while (_ring.Count > RingCapacity) _ring.Dequeue();
            Append(rec);
        }
    }

    // Caller holds _gate.
    private static void Append(DgRecord r)
    {
        if (_dir == null) return;
        try
        {
            var path = Path.Combine(_dir, "events.log");
            var fi = new FileInfo(path);
            if (fi.Exists && fi.Length > MaxFileBytes)
                File.Move(path, Path.Combine(_dir, "events.1.log"), overwrite: true);
            File.AppendAllText(path, $"{r.Time:yyyy-MM-dd HH:mm:ss} [{r.Level}] [{r.Source}] {r.Message}\n");
        }
        catch (Exception ex) { Android.Util.Log.Warn("Subsystem.Dg", $"event append failed: {ex.Message}"); }
    }

    public static void RecordCrash(Exception? ex, string source)
    {
        try
        {
            var sb = new StringBuilder();
            sb.AppendLine($"time:   {DateTime.Now:o}");
            sb.AppendLine($"source: {source}");
            sb.AppendLine($"build:  v{AppVersion()}");
            sb.AppendLine($"uptime: {(DateTime.Now - _start).TotalSeconds:F0}s");
            sb.AppendLine($"model:  ready={Rb.IsReady}");
            sb.AppendLine("--- exception ---");
            sb.AppendLine(ex?.ToString() ?? "(null)");
            if (_dir != null)
                File.WriteAllText(Path.Combine(_dir, $"crash-{DateTime.Now:yyyyMMdd-HHmmss}.txt"), sb.ToString());
            Write(DgLevel.Fatal, "crash", $"{source}: {ex?.GetType().Name}: {ex?.Message}");
        }
        catch (Exception e) { Android.Util.Log.Warn("Subsystem.Dg", $"crash record failed: {e.Message}"); }
    }

    // Succinct runtime snapshot — what /diag, Get-Diagnostics, and the Settings About presenter
    // render. THE telemetry truth: every consumer projects this; nothing bakes its own copy.
    public static string Snapshot()
    {
        var o = new Dictionary<string, object?>();
        try
        {
            o["time"]       = DateTime.Now.ToString("o");
            o["build"]      = AppVersion();
            o["uptimeSec"]  = (int)(DateTime.Now - _start).TotalSeconds;
            o["modelReady"] = Rb.IsReady;
            // Resolves through the registry's active selection — absent records (fresh install,
            // pre-seed) degrade to false rather than voiding the whole snapshot.
            if (_ctx != null) { try { o["modelPresent"] = ModelManager.IsPresent(_ctx); } catch { o["modelPresent"] = false; } }
            o["runtime"]    = RuntimeFacts();
            o["vom"] = global::Subsystem.Vom.Vom.Snapshot();
            var sessions = SessionManager.List();
            var sessInfo = new List<object>();
            foreach (var s in sessions) sessInfo.Add(new { s.Name, s.Background, s.Busy });
            o["sessions"]      = sessInfo;
            o["psrpSessions"]  = PsrpSessionFacts();
            o["recentCrashes"] = RecentFiles("crash-*.txt", 5);
            o["recentEvents"]  = Recent(15);
        }
        catch (Exception ex) { o["snapshotError"] = ex.Message; }
        return JsonSerializer.Serialize(o, new JsonSerializerOptions { WriteIndented = true });
    }

    // Live runtime/platform facts. Each value is read from the running system at call time —
    // engine versions from the loaded assemblies, device facts from android.os.Build, the model
    // from the registry's active selection, the registry count from Cm itself.
    private static object RuntimeFacts()
    {
        string Try(Func<string?> read) { try { return read() ?? "?"; } catch { return "?"; } }
        return new
        {
            powershell = Try(() => System.Management.Automation.PSVersionInfo.PSVersion?.ToString()),
            dotnet     = Try(() => System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription),
            android    = Try(() => $"{Android.OS.Build.VERSION.Release} (API {(int)Android.OS.Build.VERSION.SdkInt})"),
            device     = Try(() => $"{Android.OS.Build.Manufacturer} {Android.OS.Build.Model}"),
            ramGb      = _ctx == null ? (double?)null : Math.Round(ModelCatalog.TotalRamBytes(_ctx) / 1_000_000_000.0, 1),
            activeModel = Try(() => _ctx == null ? null : ModelCatalog.Active(_ctx).DisplayName),
            modelBackend = Try(() => Rb.BackendName),
            registryCount = Try(() => Subsystem.Cm.Cm.List().Length.ToString()),
        };
    }

    private static object PsrpSessionFacts()
    {
        var list = new List<object>();
        try
        {
            foreach (var s in Rs.List())
                list.Add(new { s.Id, Owner = s.OwnerTag, s.State, s.Busy });
        }
        catch (Exception ex) { Warn("dg", ex); }
        return list;
    }

    // ---- THE STATE TEXTURE — live system state as a Float32 VOM region, not a serialized envelope.
    // Identity (names, paths) is the registry's; the LIVE NUMERIC state rides the data plane: a
    // versioned float vector in \Capability\IPC\TextureBridge\system-state, pulled by renderers over
    // the vom:// / /vom lane (taskmgr gauges, About). Refreshed ON READ with a staleness window —
    // state is pulled, never pushed by an ambient thread (SS009). Layout v1 (16-slot header):
    //   [0] layout version   [1] unix time (s)     [2] uptime (s)        [3] model ready (0/1)
    //   [4] VOM owner count  [5] VOM handle total  [6] VOM bytes (MB)    [7] local sessions
    //   [8] PSRP sessions    [9] RAM total (GB)    [10] RAM avail (GB)   [11] registry objects
    //   [12..15] reserved. Grow by APPENDING and bumping [0] — never reorder a shipped slot. ----
    public const string StateTextureName = "system-state";
    private const int StateLayoutVersion = 1;
    private const int StateStalenessMs = 500;
    private static long _stateRefreshedAt;   // Environment.TickCount64 of the last publish

    public static void RefreshStateTexture()
    {
        var now = Environment.TickCount64;
        if (now - Interlocked.Read(ref _stateRefreshedAt) < StateStalenessMs) return;
        Interlocked.Exchange(ref _stateRefreshedAt, now);
        try
        {
            var state = new float[16];
            state[0] = StateLayoutVersion;
            state[1] = (float)DateTimeOffset.Now.ToUnixTimeSeconds();
            state[2] = (float)(DateTime.Now - _start).TotalSeconds;
            state[3] = Rb.IsReady ? 1f : 0f;

            var (owners, handles, bytes) = global::Subsystem.Vom.Vom.Totals();
            state[4] = owners;
            state[5] = handles;
            state[6] = bytes / 1_000_000f;

            state[7] = SessionManager.List().Length;
            state[8] = Rs.List().Length;
            if (_ctx != null)
            {
                state[9] = (float)(ModelCatalog.TotalRamBytes(_ctx) / 1_000_000_000.0);
                state[10] = (float)(AvailRamBytes(_ctx) / 1_000_000_000.0);
            }
            state[11] = Subsystem.Cm.Cm.List().Length;

            VomInterop.SetTexture(StateTextureName, state);
        }
        catch (Exception ex) { Warn("dg", ex); }
    }

    private static long AvailRamBytes(Context ctx)
    {
        try
        {
            var am = (Android.App.ActivityManager?)ctx.GetSystemService(Context.ActivityService);
            if (am == null) return 0;
            var mi = new Android.App.ActivityManager.MemoryInfo();
            am.GetMemoryInfo(mi);
            return mi.AvailMem;
        }
        catch { return 0; }
    }

    // The most-recent records, newest last — straight from the in-memory ring (no file read).
    public static string[] Recent(int n)
    {
        lock (_gate)
        {
            var all = _ring.ToArray();
            int take = Math.Min(n, all.Length);
            var res = new string[take];
            for (int i = 0; i < take; i++)
            {
                var r = all[all.Length - take + i];
                res[i] = $"{r.Time:HH:mm:ss} [{r.Level}] [{r.Source}] {r.Message}";
            }
            return res;
        }
    }

    private static string AppVersion()
    {
        try { return _ctx?.PackageManager?.GetPackageInfo(_ctx.PackageName!, 0)?.VersionName ?? "?"; }
        catch (Exception ex) { Android.Util.Log.Warn("Subsystem.Dg", $"version read failed: {ex.Message}"); return "?"; }
    }

    private static string[] RecentFiles(string pattern, int n)
    {
        if (_dir == null) return Array.Empty<string>();
        try
        {
            var files = Directory.GetFiles(_dir, pattern);
            Array.Sort(files);
            int take = Math.Min(n, files.Length);
            var res = new string[take];
            for (int i = 0; i < take; i++) res[i] = Path.GetFileName(files[files.Length - take + i]);
            return res;
        }
        catch (Exception ex) { Android.Util.Log.Warn("Subsystem.Dg", $"recent files failed: {ex.Message}"); return Array.Empty<string>(); }
    }
}
