using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

namespace Subsystem;

// ObpHost — the in-memory Object-Presenter host (SHELL-PLAN step 5). The shell's presenters
// (.obp — see SHELL-PLAN: an Object Presenter binds to and projects a named kernel object) and
// their support files are COMPILED into the assembly as EmbeddedResource with an explicit
// LogicalName per file (the manifest name IS the virtual path — never reconstructed from dotted
// resource names), and served from RAM. No loose shell files in the unzipped APK.
//
// This is the ONE resolver for the shell/* virtual tree (mirrors Registry.js contentUrl: physical
// layout confined to a single place). Resolution ladder, additive and surge-grounded:
//   1. embedded resource (the compiled shell — lazy-loaded, cached, served from RAM)
//   2. .html <-> .obp extension alias (so pre-rename URLs and post-rename files always meet)
//   3. AndroidAsset fallback (the zoo, anything deliberately left loose)
public static class ObpHost
{
    private static readonly object _initLock = new();
    private static Dictionary<string, string>? _index;            // virtual path -> manifest resource name
    private static readonly ConcurrentDictionary<string, byte[]> _cache = new(StringComparer.OrdinalIgnoreCase);

    private static Dictionary<string, string> Index()
    {
        if (_index != null) return _index;
        lock (_initLock)
        {
            if (_index != null) return _index;
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                var asm = typeof(ObpHost).Assembly;
                foreach (var name in asm.GetManifestResourceNames())
                {
                    // LogicalName carries the real relative path; only the OS path separator needs
                    // normalizing (an exact transform — not the dotted-name reconstruction the plan bans).
                    var virtualPath = name.Replace('\\', '/');
                    if (virtualPath.StartsWith("shell/", StringComparison.OrdinalIgnoreCase))
                        map[virtualPath] = name;
                }
                Dg.Log("obp", $"embedded presenter index: {map.Count} files");
            }
            catch (Exception ex) { Dg.Log("obp", "index failed: " + ex.Message); }
            _index = map;
            return map;
        }
    }

    private static string? AliasOf(string path)
    {
        if (path.EndsWith(".html", StringComparison.OrdinalIgnoreCase)) return path[..^5] + ".obp";
        if (path.EndsWith(".obp", StringComparison.OrdinalIgnoreCase))  return path[..^4] + ".html";
        return null;
    }

    // Embedded-only probe (no asset fallback) — bytes from RAM, lazily hydrated and cached.
    public static bool TryGetEmbedded(string virtualPath, out byte[] bytes)
    {
        bytes = Array.Empty<byte>();
        var index = Index();
        var key = virtualPath.Replace('\\', '/');
        if (!index.ContainsKey(key))
        {
            var alias = AliasOf(key);
            if (alias == null || !index.ContainsKey(alias)) return false;
            key = alias;
        }
        if (_cache.TryGetValue(key, out var cached)) { bytes = cached; return true; }
        try
        {
            using var s = typeof(ObpHost).Assembly.GetManifestResourceStream(index[key]);
            if (s == null) return false;
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            bytes = _cache.GetOrAdd(key, ms.ToArray());
            return true;
        }
        catch (Exception ex) { Dg.Log("obp", $"read {key} failed: {ex.Message}"); return false; }
    }

    // The one open: embedded -> extension alias -> AndroidAsset. Callers stop touching AssetManager
    // for the shell tree directly.
    public static Stream? OpenRead(string virtualPath)
    {
        if (TryGetEmbedded(virtualPath, out var bytes)) return new MemoryStream(bytes, writable: false);
        try
        {
            var assets = Android.App.Application.Context.Assets;
            if (assets != null)
            {
                try { return assets.Open(virtualPath); }
                catch
                {
                    var alias = AliasOf(virtualPath);
                    if (alias != null) { try { return assets.Open(alias); } catch { } }
                }
            }
        }
        catch (Exception ex) { Dg.Log("obp", $"asset open {virtualPath} failed: {ex.Message}"); }
        return null;
    }

    public static string? ReadAllText(string virtualPath)
    {
        using var s = OpenRead(virtualPath);
        if (s == null) return null;
        using var r = new StreamReader(s);
        return r.ReadToEnd();
    }

    // Enumerate embedded virtual paths under a prefix (the Registrar's seed catalog). Falls back to
    // the asset dir listing when nothing is embedded there.
    public static string[] Enumerate(string prefix)
    {
        var p = prefix.Replace('\\', '/').TrimEnd('/') + "/";
        var hits = Index().Keys.Where(k => k.StartsWith(p, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (hits.Length > 0) return hits;
        try
        {
            var assets = Android.App.Application.Context.Assets;
            var names = assets?.List(p.TrimEnd('/')) ?? Array.Empty<string>();
            return names.Select(n => p + n).ToArray();
        }
        catch { return Array.Empty<string>(); }
    }
}
