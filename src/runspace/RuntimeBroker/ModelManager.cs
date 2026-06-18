using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Android.Content;

namespace Subsystem;

// The model's generation contract (the generation_config.json analog), projected from the model record's
// `sampler` object — never a C# literal (SS020/no-hardcoded). Absent => the engine's own default sampling.
// Type maps to LiteRtLmSamplerType (unspecified|topK|topP|greedy) at the runtime seam.
public sealed record SamplerSpec(string Type, int TopK, float TopP, float Temperature, int Seed);

// One on-device model, projected from its \Capability\Model\<id> registry record. The record is the
// truth (REGISTRY-SPEC: no C# copy of durable definitions); this is the typed view the loader and
// the /models surface consume.
public sealed record ModelSpec(
    string Id,            // stable key — the registry leaf name
    string FileName,      // file under files/models/
    string Url,           // HF resolve URL (anonymous, ungated); "" for a sideloaded/discovered file
    long   MinBytes,      // completeness guard — a partial download is smaller than this
    string DisplayName,   // user-facing name
    string Role,          // user-facing one-liner
    string ApproxSize,    // user-facing size string ("2.6 GB")
    bool   HeavyForLowRam = false, // true => warn on <~10 GB devices (e.g. E4B on an 8 GB S23)
    string Format = "litertlm",    // runtime family — litertlm today; other formats become new scopes
    bool   Discovered = false,     // true => registered by the disk-discovery pass, not a seed
    bool   Degraded = false,       // §5: faulted at bring-up; excluded from resolution until cleared
    string DegradedDetail = "",    // opaque fault detail recorded at demotion
    SamplerSpec? Sampler = null)   // the model's sampling contract (null => engine default)
{
    public bool Downloadable => !string.IsNullOrEmpty(Url);
}

// The model catalog — a PROJECTION of \Capability\Model\* (Cm), never a parallel list.
//
//   • Known models are seeded by the Registrar (with url/minBytes so the download knowledge lives
//     in the registry).
//   • Sideloaded files are DISCOVERED: every files/models/*.litertlm with no record gets one
//     registered (discovery = registration; the registry stays the one truth, the UI just projects).
//   • The ACTIVE model is the enabled Model record (single-active invariant — Select enables one
//     and disables the rest). Rb resolves the active spec at engine load.
//
// Files live in PRIVATE app storage under files/models/ (no permission, app_data_file SELinux
// context). Download/resume/progress is the original loop, parameterized per-spec.
public static class ModelCatalog
{
    public const string RegistryPrefix = "\\Capability\\Model\\";
    private const string DefaultId = "e2b";

    // ---- registry projection ----

    // Every model record that names a file, as typed specs. Runs the discovery pass first so a
    // freshly sideloaded file is already registered by the time the caller enumerates.
    public static IReadOnlyList<ModelSpec> All(Context context)
    {
        DiscoverSideloaded(context);
        var specs = new List<ModelSpec>();
        foreach (var rec in Subsystem.Cm.Cm.List())
        {
            if (rec.Type != "Model" || string.IsNullOrEmpty(rec.ManifestJson)) continue;
            var spec = FromManifest(rec.ManifestJson!);
            if (spec != null) specs.Add(spec);
        }
        return specs;
    }

    public static ModelSpec? GetById(Context context, string id) =>
        All(context).FirstOrDefault(m => string.Equals(m.Id, id, StringComparison.OrdinalIgnoreCase));

    // The active model: the enabled, non-degraded record whose file is present, else the default,
    // else the first present unit. Degraded units (§5) are excluded from every pick until cleared.
    public static ModelSpec Active(Context context)
    {
        var all = All(context);
        var enabledIds = Subsystem.Cm.Cm.List()
            .Where(r => r.Type == "Model" && r.Enabled)
            .Select(r => r.Path.Substring(r.Path.LastIndexOf('\\') + 1))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        return all.FirstOrDefault(m => !m.Degraded && enabledIds.Contains(m.Id) && IsPresent(context, m))
            ?? all.FirstOrDefault(m => !m.Degraded && string.Equals(m.Id, DefaultId, StringComparison.OrdinalIgnoreCase))
            ?? all.FirstOrDefault(m => !m.Degraded && IsPresent(context, m))
            ?? throw new InvalidOperationException("No serviceable model records in the registry (\\Capability\\Model\\*).");
    }

    // §5 — failed-unit demotion: mark the record degraded with the fault; Active() excludes it.
    // Cleared only by explicit operator action (re-selecting the unit) or a verification pass.
    public static void Demote(Context context, string id, Subsystem.RuntimeBroker.RbFault fault)
    {
        RewriteManifest(context, id, obj =>
        {
            obj["degraded"] = new System.Text.Json.Nodes.JsonObject
            {
                ["class"] = fault.Class.ToString(),
                ["detail"] = fault.NativeDetail,
                ["at"] = DateTime.UtcNow.ToString("o"),
            };
        });
        Dg.Log("engine", $"DEMOTE {id}: {fault.Class} ({fault.NativeDetail})");
    }

    public static void ClearDemotion(Context context, string id)
    {
        bool had = false;
        RewriteManifest(context, id, obj => { had = obj.Remove("degraded"); });
        if (had) Dg.Log("engine", $"DEMOTION CLEARED {id} (operator action)");
    }

    private static void RewriteManifest(Context context, string id, Action<System.Text.Json.Nodes.JsonObject> mutate)
    {
        var rec = Subsystem.Cm.Cm.Get(RegistryPrefix + id);
        if (rec?.ManifestJson == null) return;
        try
        {
            if (System.Text.Json.Nodes.JsonNode.Parse(rec.ManifestJson) is not System.Text.Json.Nodes.JsonObject obj) return;
            mutate(obj);
            Subsystem.Cm.Cm.Register(new Subsystem.Cm.CapabilityRecord
            {
                Path = rec.Path, Name = rec.Name, Type = rec.Type, Source = rec.Source,
                Owner = rec.Owner, Integrity = rec.Integrity, StartType = rec.StartType,
                Enabled = rec.Enabled, ManifestJson = obj.ToJsonString(),
            });
        }
        catch (Exception ex) { Dg.Log("engine", $"manifest rewrite failed for {id}: {ex.Message}"); }
    }

    // §6 — transactional selection: (a) commit the single-active invariant; (b) rundown the
    // incumbent; (c)+(d) bring up the successor under admission control and verify; (e) on failure
    // the unit is demoted (by Rb.GetAsync), the prior serviceable unit is restored, and the
    // failover is journaled. Views read committed state only.
    public static async System.Threading.Tasks.Task<ModelSpec> SelectAsync(
        Context context, string id, Func<string, System.Threading.Tasks.Task>? report = null,
        System.Threading.CancellationToken ct = default)
    {
        var target = GetById(context, id)
            ?? throw new ArgumentException($"No model record '{id}' under {RegistryPrefix}.");
        string priorId;
        try { priorId = Active(context).Id; } catch { priorId = ""; }

        ClearDemotion(context, target.Id);          // explicit operator action clears the mark (§5)
        CommitSingleActive(context, target.Id);     // (a)
        Rb.Reset();                                 // (b)
        try
        {
            var broker = await Rb.GetAsync(context, report, ct);   // (c)+(d)
            Dg.Log("engine", $"SELECT {target.Id} committed; serviceable on {broker.BackendName}");
            return target;
        }
        catch (Subsystem.RuntimeBroker.RbFaultException fx)
        {
            if (priorId.Length > 0 && !string.Equals(priorId, target.Id, StringComparison.OrdinalIgnoreCase))
            {
                CommitSingleActive(context, priorId);              // (e) restore
                Rb.Reset();
                Dg.Log("engine", $"FAILOVER select {target.Id} ({fx.Fault.Class}) -> restored {priorId}");
            }
            throw;
        }
    }

    private static void CommitSingleActive(Context context, string id)
    {
        foreach (var rec in Subsystem.Cm.Cm.List())
        {
            if (rec.Type != "Model") continue;
            var recId = rec.Path.Substring(rec.Path.LastIndexOf('\\') + 1);
            bool isTarget = string.Equals(recId, id, StringComparison.OrdinalIgnoreCase);
            if (rec.Enabled != isTarget) Subsystem.Cm.Cm.Set(rec.Path, enabled: isTarget, startType: null);
        }
    }

    // ---- discovery: files/models/*.litertlm with no record become discovered records ----

    // The format scope. Other runtime families (gguf, onnx, …) get their own extension entry and
    // Format value when a runtime for them exists — discovery is data-driven, not special-cased.
    private static readonly IReadOnlyDictionary<string, string> FormatByExtension =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { [".litertlm"] = "litertlm" };

    private static void DiscoverSideloaded(Context context)
    {
        try
        {
            var knownFiles = Subsystem.Cm.Cm.List()
                .Where(r => r.Type == "Model" && !string.IsNullOrEmpty(r.ManifestJson))
                .Select(r => FromManifest(r.ManifestJson!)?.FileName)
                .Where(f => f != null)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            foreach (var path in Directory.EnumerateFiles(ModelsDir(context)))
            {
                var ext = Path.GetExtension(path);
                if (!FormatByExtension.TryGetValue(ext, out var format)) continue;
                var fileName = Path.GetFileName(path);
                if (knownFiles.Contains(fileName)) continue;

                var id = SanitizeId(Path.GetFileNameWithoutExtension(fileName));
                Subsystem.Cm.Cm.Register(new Subsystem.Cm.CapabilityRecord
                {
                    Path = RegistryPrefix + id,
                    Name = Path.GetFileNameWithoutExtension(fileName),
                    Type = "Model",
                    Source = "discovered:files/models/" + fileName,
                    Owner = "\\Agent",
                    Integrity = "User",
                    StartType = "manual",
                    Enabled = false,
                    ManifestJson = JsonSerializer.Serialize(new
                    {
                        version = 1,
                        id,
                        kind = "model",
                        format,
                        file = fileName,
                        displayName = Path.GetFileNameWithoutExtension(fileName),
                        role = "sideloaded",
                        approxSize = $"{new FileInfo(path).Length / 1_000_000_000.0:0.0} GB",
                        minBytes = new FileInfo(path).Length,   // exact: the file is already complete
                        discovered = true,
                    }),
                });
                Dg.Log("model", $"DISCOVERED {fileName} -> {RegistryPrefix}{id}");
            }
        }
        catch (Exception ex) { Dg.Log("model", "discovery failed: " + ex.Message); }
    }

    // Registry leaf names are path segments: keep them lowercase and path/JSON-safe.
    private static string SanitizeId(string stem)
    {
        var chars = stem.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) || c == '-' || c == '_' ? c : '-');
        return new string(chars.ToArray()).Trim('-');
    }

    private static ModelSpec? FromManifest(string manifestJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(manifestJson);
            var m = doc.RootElement;
            string Str(string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";
            bool Flag(string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
            long Num(string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : 0;

            var id = Str("id");
            var file = Str("file");
            if (id.Length == 0 || file.Length == 0) return null;   // a parked note (no file) is not a loadable model

            bool degraded = false; string degradedDetail = "";
            if (m.TryGetProperty("degraded", out var dg) && dg.ValueKind == JsonValueKind.Object)
            {
                degraded = true;
                if (dg.TryGetProperty("detail", out var dd) && dd.ValueKind == JsonValueKind.String)
                    degradedDetail = dd.GetString() ?? "";
            }

            SamplerSpec? sampler = null;
            if (m.TryGetProperty("sampler", out var sj) && sj.ValueKind == JsonValueKind.Object)
            {
                int SInt(string k) => sj.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
                float SFloat(string k) => sj.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? (float)v.GetDouble() : 0f;
                string sType = sj.TryGetProperty("type", out var stv) && stv.ValueKind == JsonValueKind.String ? (stv.GetString() ?? "") : "";
                sampler = new SamplerSpec(sType, SInt("topK"), SFloat("topP"), SFloat("temperature"), SInt("seed"));
            }

            return new ModelSpec(
                Id: id,
                FileName: file,
                Url: Str("url"),
                MinBytes: Num("minBytes"),
                DisplayName: Str("displayName").Length > 0 ? Str("displayName") : id,
                Role: Str("role"),
                ApproxSize: Str("approxSize"),
                HeavyForLowRam: Flag("heavyForLowRam"),
                Format: Str("format").Length > 0 ? Str("format") : "litertlm",
                Discovered: Flag("discovered"),
                Degraded: degraded,
                DegradedDetail: degradedDetail,
                Sampler: sampler);
        }
        catch { return null; }
    }

    // ---- file mechanics (unchanged semantics) ----

    // files/models/ — created on demand.
    private static string ModelsDir(Context context)
    {
        var dir = Path.Combine(context.FilesDir!.AbsolutePath, "models");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static string LocalPath(Context context, ModelSpec spec)
        => Path.Combine(ModelsDir(context), spec.FileName);

    public static bool IsPresent(Context context, ModelSpec spec)
    {
        var p = LocalPath(context, spec);
        return File.Exists(p) && new FileInfo(p).Length >= spec.MinBytes;
    }

    // Total physical RAM in bytes (ActivityManager.MemoryInfo.TotalMem).
    public static long TotalRamBytes(Context context)
    {
        try
        {
            var am = (Android.App.ActivityManager?)context.GetSystemService(Context.ActivityService);
            if (am == null) return 0;
            var mi = new Android.App.ActivityManager.MemoryInfo();
            am.GetMemoryInfo(mi);
            return mi.TotalMem;
        }
        catch { return 0; }
    }

    // E4B-class models want headroom; flag devices under ~10 GB (covers the 8 GB S23).
    private const long LowRamThreshold = 10_000_000_000L;
    public static bool IsLowRamDevice(Context context) => TotalRamBytes(context) < LowRamThreshold;

    // Should the UI show a stability warning before downloading this model on THIS device?
    public static bool ShouldWarn(Context context, ModelSpec spec) => spec.HeavyForLowRam && IsLowRamDevice(context);

    // One-time move of any pre-models/ flat files (files/<name>) into files/models/ so a completed
    // download isn't repeated after the layout refactor.
    public static void MigrateLegacyLayout(Context context)
    {
        foreach (var spec in All(context))
        {
            try
            {
                var legacy = Path.Combine(context.FilesDir!.AbsolutePath, spec.FileName);
                var dest = LocalPath(context, spec);
                if (File.Exists(legacy) && !File.Exists(dest)) File.Move(legacy, dest);
            }
            catch { /* best-effort */ }
        }
    }

    // Ensures the model is present; returns its path. Streams human-readable progress (throttled).
    // Resumes a partial download (HTTP Range against the .part file; a server that ignores Range
    // restarts clean). Cancel(id) stops an in-flight download cooperatively: the .part stays on disk
    // and the next EnsureAsync resumes from its length. A discovered model has no URL — absent means
    // "re-sideload it", never a silent download attempt against an empty endpoint.
    public static async Task<string> EnsureAsync(Context context, ModelSpec spec, Func<string, Task> onProgress, CancellationToken ct = default)
    {
        MigrateLegacyLayout(context);

        var path = LocalPath(context, spec);
        if (IsPresent(context, spec)) return path;

        if (!spec.Downloadable)
            throw new FileNotFoundException(
                $"{spec.DisplayName} is a sideloaded model with no download source; restore it to files/models/{spec.FileName}.");

        var gate = GateFor(spec);
        await gate.WaitAsync(ct);
        CancellationTokenSource? cts = null;
        try
        {
            if (IsPresent(context, spec)) return path;

            // The cancel lever for THIS download — linked so the caller's token still cancels too.
            cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            lock (_gatesLock) { _active[spec.Id] = cts; }
            var dl = cts.Token;

            var tmp = path + ".part";
            long resumeFrom = 0;
            try { if (File.Exists(tmp)) resumeFrom = new FileInfo(tmp).Length; }
            catch (Exception ex) { Dg.Log("model", $"{spec.Id} .part probe failed: {ex.Message}"); }

            await onProgress(resumeFrom > 0
                ? $"Resuming {spec.DisplayName} at {resumeFrom / 1_000_000} MB…"
                : $"Downloading {spec.DisplayName} (~{spec.ApproxSize}, first run only)…");

            using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            using var req = new HttpRequestMessage(HttpMethod.Get, spec.Url);
            if (resumeFrom > 0) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(resumeFrom, null);
            using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, dl);
            if (resumeFrom > 0 && resp.StatusCode != System.Net.HttpStatusCode.PartialContent)
            {
                resumeFrom = 0;   // server ignored the Range — restart clean
                try { File.Delete(tmp); }
                catch (Exception ex) { Dg.Log("model", $"{spec.Id} stale .part delete failed: {ex.Message}"); }
            }
            resp.EnsureSuccessStatusCode();
            long? total = resp.Content.Headers.ContentLength is long remaining ? remaining + resumeFrom : null;

            await using (var src = await resp.Content.ReadAsStreamAsync(dl))
            await using (var dst = new FileStream(tmp, resumeFrom > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
            {
                var buf = new byte[1 << 20];
                long read = resumeFrom; int n; int lastPct = -1;
                var sw = System.Diagnostics.Stopwatch.StartNew();
                while ((n = await src.ReadAsync(buf, 0, buf.Length, dl)) > 0)
                {
                    await dst.WriteAsync(buf, 0, n, dl);
                    read += n;
                    if (sw.ElapsedMilliseconds >= 2000)
                    {
                        if (total.HasValue)
                        {
                            int pct = (int)(read * 100 / total.Value);
                            if (pct != lastPct) { lastPct = pct; await onProgress($"Downloading {spec.DisplayName}… {pct}%  ({read / 1_000_000} / {total.Value / 1_000_000} MB)"); }
                        }
                        else await onProgress($"Downloading {spec.DisplayName}… {read / 1_000_000} MB");
                        sw.Restart();
                    }
                }
            }

            File.Move(tmp, path, true);
            await onProgress($"{spec.DisplayName} downloaded. Initializing engine (~10s)…");
            return path;
        }
        finally
        {
            if (cts != null)
            {
                lock (_gatesLock) { _active.Remove(spec.Id); }
                cts.Dispose();
            }
            gate.Release();
        }
    }

    // Deletes a model from disk (settings "Delete" action). The registry record stays — a known
    // model remains downloadable; a discovered record whose file is gone disappears from the
    // loadable set on the next projection (no file, no spec).
    public static bool Delete(Context context, ModelSpec spec)
    {
        try
        {
            var p = LocalPath(context, spec);
            if (File.Exists(p)) { File.Delete(p); return true; }
        }
        catch { }
        return false;
    }

    // Per-model download lock so two requests for the same model don't race; different models
    // may download concurrently. _active holds the cancel lever for each in-flight download —
    // transient process sync mechanics like the gates, never a truth store (model STATE stays in
    // the registry; presence stays on disk).
    private static readonly Dictionary<string, SemaphoreSlim> _gates = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, CancellationTokenSource> _active = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object _gatesLock = new();
    private static SemaphoreSlim GateFor(ModelSpec spec)
    {
        lock (_gatesLock)
        {
            if (!_gates.TryGetValue(spec.Id, out var g)) { g = new SemaphoreSlim(1, 1); _gates[spec.Id] = g; }
            return g;
        }
    }

    // True while a download for the id is in flight (drives the manifest's `downloading` flag).
    public static bool IsDownloading(string modelId)
    {
        lock (_gatesLock) return _active.ContainsKey(modelId);
    }

    // Cooperative cancel of an in-flight download. The .part file stays on disk — EnsureAsync resumes
    // from its length on the next attempt. Returns false when nothing is downloading under that id.
    // (Removal + dispose of the lever happen in EnsureAsync's finally, under the same lock.)
    public static bool Cancel(string modelId)
    {
        lock (_gatesLock)
        {
            if (!_active.TryGetValue(modelId, out var cts)) return false;
            cts.Cancel();
            Dg.Log("model", $"CANCEL {modelId} requested (.part retained for resume)");
            return true;
        }
    }
}

// Active-model facade: callers that don't care WHICH model (Hb, Dg) operate on the registry's
// active selection — never a hardcoded default.
public static class ModelManager
{
    public static string LocalPath(Context context) => ModelCatalog.LocalPath(context, ModelCatalog.Active(context));
    public static bool IsPresent(Context context) => ModelCatalog.IsPresent(context, ModelCatalog.Active(context));
    public static Task<string> EnsureAsync(Context context, Func<string, Task> onProgress, CancellationToken ct = default)
        => ModelCatalog.EnsureAsync(context, ModelCatalog.Active(context), onProgress, ct);
}
