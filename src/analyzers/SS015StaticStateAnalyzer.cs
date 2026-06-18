using System;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS015 — statics may compute, never remember (CONTRACT.md axiom 8). A static mutable field in a
    /// registered component is ambient state: a global root, a rendezvous, or a second truth. The law
    /// libraries (Ob/Ps/Cm routine groups) hold verbs; state lives in nodes. Flags: any non-readonly
    /// static field, and readonly statics of known-mutable shapes (collections, StringBuilder, arrays).
    /// const and readonly immutables (string, primitives, ImmutableX, Regex) pass.
    /// Known census load: Vom._owners (ratchet R2 — doubly mandated), Dg's ring, Cm._records.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS015StaticStateAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS015";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Static field remembers state in a component",
            "Static field '{0}' ({1}) — statics compute, never remember/authorize/rendezvous; state belongs in a node (axiom 8, ratchet R2)",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "No state in statics, no authority without a possessed handle, no meeting point that wasn't granted. Census-pending ratchet; baselines hold the legacy.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        private static readonly ImmutableHashSet<string> MutableShapes = ImmutableHashSet.Create(
            StringComparer.Ordinal,
            "Dictionary", "ConcurrentDictionary", "List", "HashSet", "Queue", "Stack",
            "ConcurrentQueue", "ConcurrentStack", "ConcurrentBag", "StringBuilder",
            "MemoryStream", "CancellationTokenSource", "Dictionary`2", "List`1");

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;

                start.RegisterSymbolAction(ctx => Analyze(ctx, cat), SymbolKind.Field);
            });
        }

        private static void Analyze(SymbolAnalysisContext ctx, SystemCatalogFile cat)
        {
            var f = (IFieldSymbol)ctx.Symbol;
            if (!f.IsStatic || f.IsConst || f.IsImplicitlyDeclared) return;

            var loc = f.Locations.FirstOrDefault(l => l.IsInSource);
            if (loc == null) return;
            var component = cat.ComponentOfPath(loc.SourceTree?.FilePath);
            if (component == null || component == "(host)") return;   // component folders only

            string verdict;
            if (!f.IsReadOnly)
                verdict = "mutable";
            else if (f.Type is IArrayTypeSymbol)
                verdict = "readonly array — contents still mutate";
            else if (f.Type is INamedTypeSymbol nt && MutableShapes.Contains(nt.OriginalDefinition.Name))
                verdict = "readonly " + nt.OriginalDefinition.Name + " — the reference is pinned, the state is not";
            else
                return;

            ctx.ReportDiagnostic(Diagnostic.Create(Rule, loc, f.Name, verdict));
        }
    }
}
