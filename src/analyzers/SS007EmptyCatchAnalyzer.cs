using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS007 — No silent swallow. An empty <c>catch {}</c> erases a failure with no trace. Cmdlets and the
    /// substrate must degrade gracefully AND report to Dg (the one diagnostic surface, queryable at /diag) —
    /// never vanish. Warning until each of the ~28 empties is triaged to log-and-degrade.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS007EmptyCatchAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS007";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Empty catch swallows the error",
            "Empty catch block — a failure must degrade AND report to Dg (/diag), never vanish silently",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Log the failure to Dg and return a typed degraded marker. Silent empty catch hides rot.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze, SyntaxKind.CatchClause);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            var clause = (CatchClauseSyntax)ctx.Node;
            if (clause.Block is { Statements.Count: 0 })
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, clause.CatchKeyword.GetLocation()));
        }
    }
}
