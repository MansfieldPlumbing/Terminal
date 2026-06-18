using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Diagnostics;
using Microsoft.CodeAnalysis.Text;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SystemCatalog.json loaded through AdditionalFiles — the one seed the naming/structure rules
    /// (SS011–SS016) read. One file, two consumers (these analyzers at compile time; the Registrar
    /// projects the same file to \System\Contract at boot) — never two lists.
    ///
    /// FAIL-CLOSED: a missing or unparsable catalog is reported by SS000 as an error and every
    /// catalog-fed rule stays silent (the build screams once, loudly, instead of silently running
    /// ungated). EnforceExtendedAnalyzerRules bans file I/O here by construction — AdditionalText
    /// is the only door, which is exactly the discipline the contract wants.
    /// </summary>
    internal sealed class SystemCatalogFile
    {
        public const string FileName = "SystemCatalog.json";

        public string Root = "";
        public string RootToday = "";
        // component code -> (dependsOn set, folder prefix like "src/runspace/Vom/")
        public readonly Dictionary<string, (HashSet<string> DependsOn, string Folder)> Components =
            new Dictionary<string, (HashSet<string>, string)>(StringComparer.Ordinal);
        public readonly HashSet<string> ApprovedSuffixes = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> BannedSuffixes = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> ContextWords = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> BannedNouns = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> AlwaysFlag = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public readonly List<string> CommentPatterns = new List<string>();
        public readonly HashSet<string> PlatformNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public readonly HashSet<string> ShippedTypes = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> VerbsApproved = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> VerbsPwsh = new HashSet<string>(StringComparer.Ordinal);
        public readonly HashSet<string> VerbsTriage = new HashSet<string>(StringComparer.Ordinal);
        public readonly List<string> HostPaths = new List<string>();
        public readonly HashSet<string> SynchronousCore = new HashSet<string>(StringComparer.Ordinal);

        // Per-compilation parse cache (the catalog text object is stable across analyzer callbacks).
        private static readonly ConcurrentDictionary<SourceText, (SystemCatalogFile? Catalog, string? Error)> Cache =
            new ConcurrentDictionary<SourceText, (SystemCatalogFile?, string?)>();

        public static SystemCatalogFile? TryLoad(AnalyzerOptions options, out string? error)
        {
            AdditionalText? file = null;
            foreach (var f in options.AdditionalFiles)
                if (f.Path != null && f.Path.EndsWith(FileName, StringComparison.OrdinalIgnoreCase)) { file = f; break; }
            if (file == null) { error = FileName + " is not wired as an AdditionalFile"; return null; }

            var text = file.GetText();
            if (text == null) { error = FileName + " could not be read"; return null; }

            var cached = Cache.GetOrAdd(text, t =>
            {
                try
                {
                    var cat = Parse(t.ToString());
                    return (cat, cat == null ? "catalog parsed but required sections are missing" : null);
                }
                catch (Exception ex) { return ((SystemCatalogFile?)null, ex.Message); }
            });
            error = cached.Error;
            return cached.Catalog;
        }

        private static SystemCatalogFile? Parse(string json)
        {
            if (!(JsonMini.Parse(json) is Dictionary<string, object?> root)) return null;
            var c = new SystemCatalogFile
            {
                Root = Str(root, "root"),
                RootToday = Str(root, "rootToday"),
            };
            if (c.Root.Length == 0 || c.RootToday.Length == 0) return null;

            if (!(Get(root, "components") is Dictionary<string, object?> comps) || comps.Count == 0) return null;
            foreach (var kv in comps)
            {
                if (!(kv.Value is Dictionary<string, object?> comp)) continue;
                var deps = new HashSet<string>(Strings(Get(comp, "dependsOn")), StringComparer.Ordinal);
                c.Components[kv.Key] = (deps, Norm(Str(comp, "folder")));
            }

            if (Get(root, "types") is Dictionary<string, object?> types)
            {
                foreach (var s in Strings(Get(types, "suffixes"))) c.ApprovedSuffixes.Add(s);
                foreach (var s in Strings(Get(types, "shipped"))) c.ShippedTypes.Add(s);
            }
            if (Get(root, "banned") is Dictionary<string, object?> banned)
            {
                foreach (var s in Strings(Get(banned, "suffixes"))) c.BannedSuffixes.Add(s);
                foreach (var s in Strings(Get(banned, "contextWords"))) c.ContextWords.Add(s);
                foreach (var s in Strings(Get(banned, "nouns"))) c.BannedNouns.Add(s);
                foreach (var s in Strings(Get(banned, "alwaysFlag"))) c.AlwaysFlag.Add(s);
                foreach (var s in Strings(Get(banned, "commentPatterns"))) c.CommentPatterns.Add(s);
            }
            if (Get(root, "platformNames") is Dictionary<string, object?> plat)
            {
                foreach (var s in Strings(Get(plat, "aosp"))) c.PlatformNames.Add(s);
                foreach (var s in Strings(Get(plat, "linux"))) c.PlatformNames.Add(s);
                foreach (var s in Strings(Get(plat, "ntReserved"))) c.PlatformNames.Add(s);
            }
            if (Get(root, "verbs") is Dictionary<string, object?> verbs)
            {
                foreach (var s in Strings(Get(verbs, "approved"))) c.VerbsApproved.Add(s);
                foreach (var s in Strings(Get(verbs, "pwsh"))) c.VerbsPwsh.Add(s);
                foreach (var s in Strings(Get(verbs, "triage"))) c.VerbsTriage.Add(s);
            }
            foreach (var s in Strings(Get(root, "hostPaths"))) c.HostPaths.Add(Norm(s));
            foreach (var s in Strings(Get(root, "synchronousCore"))) c.SynchronousCore.Add(s);

            // Required sections for the rules to mean anything — fail closed if absent.
            if (c.ApprovedSuffixes.Count == 0 || c.BannedSuffixes.Count == 0 || c.VerbsApproved.Count == 0)
                return null;
            return c;
        }

        // ---- attribution: file path -> component code, "(host)", or null (unassigned core) ----

        public string? ComponentOfPath(string? path)
        {
            if (path == null) return null;
            var p = Norm(path);
            foreach (var host in HostPaths)
                if (p.IndexOf(host, StringComparison.OrdinalIgnoreCase) >= 0) return "(host)";
            foreach (var kv in Components)
                if (kv.Value.Folder.Length > 0 && p.IndexOf(kv.Value.Folder, StringComparison.OrdinalIgnoreCase) >= 0)
                    return kv.Key;
            return null;
        }

        public bool IsHostPath(string? path) => ComponentOfPath(path) == "(host)";

        // Build-output / generated trees (obj/, bin/, the AAR Java->C# bindings, *.g.cs) are FOREIGN
        // surface — not authored, not part of any component. The naming/structure rules treat them like
        // the BCL: out of scope. Roslyn's generated-code detection misses the binding files (no
        // <auto-generated> header), so path attribution is the reliable signal.
        public static bool IsGeneratedPath(string? path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            var p = Norm(path!);
            return p.IndexOf("/obj/", StringComparison.OrdinalIgnoreCase) >= 0
                || p.IndexOf("/bin/", StringComparison.OrdinalIgnoreCase) >= 0
                || p.EndsWith(".g.cs", StringComparison.OrdinalIgnoreCase)
                || p.EndsWith(".designer.cs", StringComparison.OrdinalIgnoreCase)
                || p.EndsWith(".generated.cs", StringComparison.OrdinalIgnoreCase);
        }

        private static string Norm(string s) => s.Replace('\\', '/');

        private static object? Get(Dictionary<string, object?> d, string key)
            => d.TryGetValue(key, out var v) ? v : null;

        private static string Str(Dictionary<string, object?> d, string key)
            => Get(d, key) as string ?? "";

        private static IEnumerable<string> Strings(object? v)
            => v is List<object?> list ? list.OfType<string>() : Enumerable.Empty<string>();

        /// <summary>Splits a PascalCase identifier into camel-hump tokens ("WinHeadBootV2" -> Win,Head,Boot,V2).</summary>
        public static List<string> Tokens(string name)
        {
            var tokens = new List<string>();
            int start = 0;
            for (int i = 1; i <= name.Length; i++)
            {
                if (i == name.Length ||
                    (char.IsUpper(name[i]) && (!char.IsUpper(name[i - 1]) ||
                        (i + 1 < name.Length && char.IsLower(name[i + 1])))))
                {
                    if (i > start) tokens.Add(name.Substring(start, i - start));
                    start = i;
                }
            }
            return tokens;
        }
    }

    /// <summary>
    /// Minimal recursive-descent JSON reader (objects, arrays, strings, numbers, bools, null).
    /// Exists because analyzers are netstandard2.0 sandboxes that cannot carry System.Text.Json —
    /// and the catalog must stay ONE json file (the Registrar's seed), not an analyzer-friendly twin.
    /// </summary>
    internal static class JsonMini
    {
        public static object? Parse(string s) { int i = 0; var v = Value(s, ref i); Ws(s, ref i); return i == s.Length ? v : throw Err(i); }

        private static object? Value(string s, ref int i)
        {
            Ws(s, ref i);
            if (i >= s.Length) throw Err(i);
            char ch = s[i];
            if (ch == '{') return Obj(s, ref i);
            if (ch == '[') return Arr(s, ref i);
            if (ch == '"') return Str(s, ref i);
            if (ch == 't') { Lit(s, ref i, "true"); return true; }
            if (ch == 'f') { Lit(s, ref i, "false"); return false; }
            if (ch == 'n') { Lit(s, ref i, "null"); return null; }
            return Num(s, ref i);
        }

        private static Dictionary<string, object?> Obj(string s, ref int i)
        {
            var d = new Dictionary<string, object?>(StringComparer.Ordinal);
            i++; Ws(s, ref i);
            if (s[i] == '}') { i++; return d; }
            while (true)
            {
                Ws(s, ref i);
                var key = Str(s, ref i);
                Ws(s, ref i);
                if (s[i] != ':') throw Err(i); i++;
                d[key] = Value(s, ref i);
                Ws(s, ref i);
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '}') { i++; return d; }
                throw Err(i);
            }
        }

        private static List<object?> Arr(string s, ref int i)
        {
            var list = new List<object?>();
            i++; Ws(s, ref i);
            if (s[i] == ']') { i++; return list; }
            while (true)
            {
                list.Add(Value(s, ref i));
                Ws(s, ref i);
                if (s[i] == ',') { i++; continue; }
                if (s[i] == ']') { i++; return list; }
                throw Err(i);
            }
        }

        private static string Str(string s, ref int i)
        {
            if (s[i] != '"') throw Err(i);
            var sb = new System.Text.StringBuilder();
            i++;
            while (s[i] != '"')
            {
                if (s[i] == '\\')
                {
                    i++;
                    switch (s[i])
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            sb.Append((char)Convert.ToInt32(s.Substring(i + 1, 4), 16));
                            i += 4; break;
                        default: throw Err(i);
                    }
                }
                else sb.Append(s[i]);
                i++;
            }
            i++;
            return sb.ToString();
        }

        private static double Num(string s, ref int i)
        {
            int start = i;
            while (i < s.Length && (char.IsDigit(s[i]) || s[i] == '-' || s[i] == '+' || s[i] == '.' || s[i] == 'e' || s[i] == 'E')) i++;
            return double.Parse(s.Substring(start, i - start), System.Globalization.CultureInfo.InvariantCulture);
        }

        private static void Lit(string s, ref int i, string lit)
        {
            if (i + lit.Length > s.Length || s.Substring(i, lit.Length) != lit) throw Err(i);
            i += lit.Length;
        }

        private static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }
        private static Exception Err(int i) => new FormatException("SystemCatalog.json: parse error at offset " + i);
    }

    /// <summary>
    /// SS000 — the fail-closed guard. The catalog missing or unparsable is ONE loud error; the
    /// catalog-fed rules (SS011–SS016) stay silent without it rather than running on guesses.
    /// A gate whose configuration silently fails open is a gate that is off without anyone noticing.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS000CatalogGuardAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS000";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "SystemCatalog.json unavailable",
            "The naming/structure gate is OFF: {0}. Wire src/analyzers/SystemCatalog.json as an AdditionalFile and keep it parsable",
            "Subsystem.NT", DiagnosticSeverity.Error, isEnabledByDefault: true,
            "SS011-SS016 read their closed vocabulary and component DAG from SystemCatalog.json (one seed, two consumers). Without it they cannot run; this error is the fail-closed signal.",
            customTags: WellKnownDiagnosticTags.CompilationEnd);

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationAction(ctx =>
            {
                var cat = SystemCatalogFile.TryLoad(ctx.Options, out var error);
                if (cat == null)
                    ctx.ReportDiagnostic(Diagnostic.Create(Rule, Location.None, error ?? "unknown error"));
            });
        }
    }
}
