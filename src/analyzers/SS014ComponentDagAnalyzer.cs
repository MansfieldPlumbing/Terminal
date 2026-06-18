using System;
using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Diagnostics;
using Microsoft.CodeAnalysis.Operations;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS014 — the component dependency DAG (CONTRACT.md axiom: reference direction). A registered
    /// component may reference: the SDK/BCL, itself, and the components in its catalog dependsOn —
    /// nothing else. Not sideways into a peer it wasn't granted, not upward into hosts, not into the
    /// unassigned core. This is the rule that makes Cm→MainActivity and Dg→Hb permanently impossible.
    ///
    /// Attribution is by FILE PATH against the catalog's component folders (not by namespace) because
    /// pre-R1 the namespaces lie (Host/ and Diagnostics/ declare flat 'Subsystem'). When R1 lands,
    /// path attribution and namespace attribution converge and either works.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS014ComponentDagAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS014";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Reference violates the component DAG",
            "{0} may not reference {1} ('{2}') — dependsOn: [{3}]; grant the dependency in SystemCatalog.json deliberately or route through a granted seam",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Components depend only downward, per the catalog DAG. Violations are the seams the Windows head measured (Cm->MainActivity, Dg->Hb). Census-pending ratchet.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;

                // path -> component attribution cache for the whole compilation.
                var pathCache = new ConcurrentDictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

                start.RegisterOperationAction(ctx => Analyze(ctx, cat, pathCache),
                    OperationKind.Invocation, OperationKind.ObjectCreation,
                    OperationKind.FieldReference, OperationKind.PropertyReference,
                    OperationKind.MethodReference, OperationKind.EventReference);
            });
        }

        private static void Analyze(OperationAnalysisContext ctx, SystemCatalogFile cat,
                                    ConcurrentDictionary<string, string?> pathCache)
        {
            var sourcePath = ctx.Operation.Syntax.SyntaxTree.FilePath;
            if (SystemCatalogFile.IsGeneratedPath(sourcePath)) return;   // generated code isn't bound by the DAG
            var source = pathCache.GetOrAdd(sourcePath, p => cat.ComponentOfPath(p));
            if (source == null || source == "(host)") return;   // only registered components are bound by the DAG

            ISymbol? target = ctx.Operation switch
            {
                IInvocationOperation inv => inv.TargetMethod,
                IObjectCreationOperation oc => oc.Constructor,
                IMemberReferenceOperation mr => mr.Member,
                _ => null,
            };
            var targetType = target?.ContainingType;
            if (targetType == null) return;

            // Resolve the TARGET's home by its source location; metadata (BCL/SDK) has none -> always allowed.
            var targetTree = targetType.Locations.FirstOrDefault(l => l.IsInSource)?.SourceTree;
            if (targetTree == null) return;
            if (SystemCatalogFile.IsGeneratedPath(targetTree.FilePath)) return;   // ref to a foreign generated binding = external, like the BCL
            var targetHome = pathCache.GetOrAdd(targetTree.FilePath, p => cat.ComponentOfPath(p));

            string? offense = null;
            if (targetHome == "(host)")
                offense = "host code";
            else if (targetHome == null)
                offense = "the unassigned core";
            else if (targetHome != source && !cat.Components[source].DependsOn.Contains(targetHome))
                offense = "component " + targetHome;
            if (offense == null) return;

            var deps = string.Join(", ", cat.Components[source].DependsOn.OrderBy(s => s, StringComparer.Ordinal));
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, ctx.Operation.Syntax.GetLocation(),
                source, offense, targetType.Name, deps));
        }
    }
}
