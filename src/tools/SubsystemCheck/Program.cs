using System.Collections.Immutable;
using System.Reflection;
using Microsoft.Build.Locator;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.Diagnostics;
using Subsystem.Analyzers;

// MSBuild must be located BEFORE any Microsoft.CodeAnalysis.MSBuild type loads, so the real work lives
// in Runner (a separate type) invoked only after RegisterDefaults.
if (!MSBuildLocator.IsRegistered)
    MSBuildLocator.RegisterDefaults();

return await Runner.Run(args);

static class Runner
{
    // Located after MSBuild registration so the workspace assembly binds to the SDK's MSBuild.
    public static async Task<int> Run(string[] args)
    {
        var repoRoot = FindRepoRoot();
        var projectPath = Path.Combine(repoRoot, "src", "runspace", "Subsystem.csproj");

        string? refsSymbol = null;
        bool gate = false, writeBaseline = false, list = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] is "--refs" or "-r") { refsSymbol = i + 1 < args.Length ? args[i + 1] : null; }
            if (args[i] is "--gate") gate = true;
            if (args[i] is "--write-baseline") writeBaseline = true;
            if (args[i] is "--list" or "-l") list = true;
        }

        // --list: the analyzer roster (id + what it enforces) — no project load, so it is instant. The
        // count is exactly the suite the gate runs, so "how many / what" is answered by the binary itself.
        if (list) return ListMode();

        Console.Error.WriteLine($"check: loading {Path.GetFileName(projectPath)} (semantic load — first run is slow)…");
        using var ws = Microsoft.CodeAnalysis.MSBuild.MSBuildWorkspace.Create();
        ws.WorkspaceFailed += (_, e) =>
        {
            // Diagnostics from the design-time load (missing targets etc.) — show only failures.
            if (e.Diagnostic.Kind == Microsoft.CodeAnalysis.WorkspaceDiagnosticKind.Failure)
                Console.Error.WriteLine("  load: " + e.Diagnostic.Message);
        };

        var project = await ws.OpenProjectAsync(projectPath);

        // MSBuildWorkspace attaches analyzer references (ours + the android workload's) that don't resolve
        // as analyzer assemblies in THIS process — they become UnresolvedAnalyzerReference and crash the
        // solution serialization SymbolFinder relies on. We run analyzers ourselves, so strip them.
        var sol = project.Solution;
        foreach (var pid in sol.ProjectIds)
            sol = sol.WithProjectAnalyzerReferences(pid, Array.Empty<AnalyzerReference>());
        project = sol.GetProject(project.Id)!;

        var compilation = await project.GetCompilationAsync();
        if (compilation is null) { Console.Error.WriteLine("check: no compilation."); return 2; }

        if (refsSymbol is not null)
            return await RefsMode(project, compilation, refsSymbol);

        // The gate/check diagnostics: the FULL suite over the runspace project, PLUS the contract-hardcode
        // guard (SS020) over the host-windows tree. The heads are not in the gated runspace project, so
        // without this second pass a hardcoded model/prompt in a head (the chat.cs gap) escapes the gate.
        var analyzers = LoadSubsystemAnalyzers();
        var ss = new List<Diagnostic>(
            (await compilation.WithAnalyzers(analyzers, project.AnalyzerOptions).GetAnalyzerDiagnosticsAsync())
                .Where(d => d.Id.StartsWith("SS")));
        ss.AddRange(await HostScan(repoRoot));

        if (gate || writeBaseline)
            return GateMode(ss, Path.Combine(repoRoot, "src", "analyzers", "SS-BASELINE.txt"), writeBaseline);
        return CheckMode(ss);
    }

    // Run the syntax-only host-windows guards over the head's source tree: SS020 (hardcoded model/prompt)
    // and SS021 (Streisand comments). The heads are NOT part of the gated runspace project, so without this
    // both classes escape the gate (the gap that let chat.cs bake in a model path, and let "the renamed X"
    // comments accumulate). Syntax-only: a bare compilation (mscorlib only) is enough — no MSBuild load,
    // and CS errors from missing refs don't matter.
    static async Task<List<Diagnostic>> HostScan(string repoRoot)
    {
        var hostDir = Path.Combine(repoRoot, "src", "host-windows");
        if (!Directory.Exists(hostDir)) return new List<Diagnostic>();
        var trees = new List<SyntaxTree>();
        foreach (var f in Directory.EnumerateFiles(hostDir, "*.cs", SearchOption.AllDirectories))
        {
            var sep = Path.DirectorySeparatorChar;
            if (f.Contains($"{sep}obj{sep}") || f.Contains($"{sep}bin{sep}")) continue;
            try { trees.Add(CSharpSyntaxTree.ParseText(File.ReadAllText(f), path: f)); } catch { }
        }
        if (trees.Count == 0) return new List<Diagnostic>();
        var comp = CSharpCompilation.Create("hostwin-scan", trees,
            new[] { MetadataReference.CreateFromFile(typeof(object).Assembly.Location) },
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));
        var analyzers = ImmutableArray.Create<DiagnosticAnalyzer>(
            new SS020ModelPromptHardcodeAnalyzer(), new SS021StreisandAnalyzer());
        var diags = await comp.WithAnalyzers(analyzers).GetAnalyzerDiagnosticsAsync();
        return diags.Where(d => d.Id.StartsWith("SS")).ToList();
    }

    // --gate: fail on any SS finding NOT in the baseline (the ratchet — new code bleeds red, legacy
    // is tracked). --write-baseline: regenerate the baseline from the current tree (shrink-only by
    // policy: regenerating to a LARGER file is the drift the gate exists to refuse — review the diff).
    // Keys are "SSxxx|file|message" WITHOUT line numbers, so unrelated edits don't false-positive;
    // duplicate keys are counted (N identical findings in a file = N baseline entries).
    static int GateMode(IReadOnlyList<Diagnostic> ss, string baselinePath, bool write)
    {
        var keys = ss.Where(d => d.Id.StartsWith("SS"))
                     .Select(d => $"{d.Id}|{Path.GetFileName(d.Location.GetLineSpan().Path)}|{d.GetMessage()}")
                     .OrderBy(k => k, StringComparer.Ordinal)
                     .ToList();

        if (write)
        {
            File.WriteAllLines(baselinePath, keys);
            Console.WriteLine($"gate: baseline written — {keys.Count} entries -> {baselinePath}");
            return 0;
        }

        var baseline = File.Exists(baselinePath)
            ? File.ReadAllLines(baselinePath).ToList()
            : new List<string>();
        var budget = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var k in baseline) budget[k] = budget.TryGetValue(k, out var n) ? n + 1 : 1;

        var fresh = new List<string>();
        foreach (var k in keys)
        {
            if (budget.TryGetValue(k, out var n) && n > 0) budget[k] = n - 1;
            else fresh.Add(k);
        }

        int retired = budget.Values.Where(v => v > 0).Sum();
        Console.WriteLine($"gate: {keys.Count} findings; baseline {baseline.Count}; new {fresh.Count}; retired {retired}");
        if (retired > 0)
            Console.WriteLine("gate: baseline entries no longer firing — shrink the baseline (--write-baseline) and commit the diff.");
        if (fresh.Count > 0)
        {
            Console.WriteLine("\ngate: NEW violations (not in baseline) — the gate bleeds red here:");
            foreach (var k in fresh) Console.WriteLine("  " + k);
            return 1;
        }
        Console.WriteLine("gate: GREEN — no new violations.");
        return 0;
    }

    // Default: run SS001-009 over the whole project, grouped report.
    static int CheckMode(IReadOnlyList<Diagnostic> diags)
    {
        var ss = diags.Where(d => d.Id.StartsWith("SS"))
                      .OrderBy(d => d.Id)
                      .ThenBy(d => d.Location.GetLineSpan().Path)
                      .ToList();

        foreach (var group in ss.GroupBy(d => d.Id).OrderBy(g => g.Key))
        {
            Console.WriteLine($"\n=== {group.Key} ({group.Count()}) — {group.First().Descriptor.Title} ===");
            foreach (var d in group)
            {
                var ls = d.Location.GetLineSpan();
                var file = Path.GetFileName(ls.Path);
                Console.WriteLine($"  {file}:{ls.StartLinePosition.Line + 1}  {d.GetMessage()}");
            }
        }
        Console.WriteLine($"\n--- {ss.Count} findings across {ss.Select(d => d.Location.GetLineSpan().Path).Distinct().Count()} files ---");
        return 0;
    }

    // --refs <Symbol>: every real reference to a named type/member, via SymbolFinder (NOT a text scan).
    static async Task<int> RefsMode(Microsoft.CodeAnalysis.Project project, Microsoft.CodeAnalysis.Compilation compilation, string symbolName)
    {
        var solution = project.Solution;
        var matches = new List<Microsoft.CodeAnalysis.ISymbol>();

        foreach (var type in AllTypes(compilation.GlobalNamespace))
        {
            if (type.Name == symbolName) matches.Add(type);
            foreach (var m in type.GetMembers())
                if (m.Name == symbolName) matches.Add(m);
        }
        if (matches.Count == 0) { Console.WriteLine($"refs: no symbol named '{symbolName}' in the compilation."); return 1; }

        foreach (var sym in matches.Distinct(SymbolEqualityComparer.Default).Cast<Microsoft.CodeAnalysis.ISymbol>())
        {
            Console.WriteLine($"\n=== {sym.Kind} {sym.ToDisplayString()} ===");
            var found = await Microsoft.CodeAnalysis.FindSymbols.SymbolFinder.FindReferencesAsync(sym, solution);
            int n = 0;
            foreach (var r in found)
                foreach (var loc in r.Locations)
                {
                    var ls = loc.Location.GetLineSpan();
                    Console.WriteLine($"  {Path.GetFileName(ls.Path)}:{ls.StartLinePosition.Line + 1}");
                    n++;
                }
            if (n == 0) Console.WriteLine("  (declared, no references)");
        }
        return 0;
    }

    static IEnumerable<Microsoft.CodeAnalysis.INamedTypeSymbol> AllTypes(Microsoft.CodeAnalysis.INamespaceSymbol ns)
    {
        foreach (var t in ns.GetTypeMembers()) yield return t;
        foreach (var child in ns.GetNamespaceMembers())
            foreach (var t in AllTypes(child)) yield return t;
    }

    // The analyzer roster: every rule this published checker enforces, id + title. No semantic load.
    static int ListMode()
    {
        var analyzers = LoadSubsystemAnalyzers();
        var rules = analyzers
            .SelectMany(a => a.SupportedDiagnostics)
            .GroupBy(d => d.Id).Select(g => g.First())
            .OrderBy(d => d.Id, StringComparer.Ordinal)
            .ToList();
        Console.WriteLine($"Subsystem analyzers — {analyzers.Length} loaded, {rules.Count} rules (this IS the gate's suite):");
        foreach (var d in rules)
            Console.WriteLine($"  {d.Id}  [{d.DefaultSeverity}]  {d.Title}");
        return 0;
    }

    static ImmutableArray<Microsoft.CodeAnalysis.Diagnostics.DiagnosticAnalyzer> LoadSubsystemAnalyzers()
    {
        var asm = typeof(SS001PowerShellStringAnalyzer).Assembly;
        var list = asm.GetTypes()
            .Where(t => !t.IsAbstract && typeof(Microsoft.CodeAnalysis.Diagnostics.DiagnosticAnalyzer).IsAssignableFrom(t))
            .Select(t => (Microsoft.CodeAnalysis.Diagnostics.DiagnosticAnalyzer)Activator.CreateInstance(t)!)
            .ToImmutableArray();
        return list;
    }

    static string FindRepoRoot()
    {
        // Walk up from the executable to the dir containing 'src\runspace\Subsystem.csproj'.
        var dir = AppContext.BaseDirectory;
        for (var d = new DirectoryInfo(dir); d != null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "src", "runspace", "Subsystem.csproj")))
                return d.FullName;
        // Fallback: assume <drive>\subsystem relative to a <drive>\bin install.
        var driveRoot = Path.GetPathRoot(dir)
            ?? throw new InvalidOperationException("cannot resolve the repo root or a drive root from " + dir);
        return Path.Combine(driveRoot, "subsystem");
    }
}
