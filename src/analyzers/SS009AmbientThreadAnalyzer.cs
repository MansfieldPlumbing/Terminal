using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS009 — No ambient threading. A free <c>Task.Run(...)</c> or <c>new Thread(...)</c> spawns work the
    /// kernel doesn't own: no Sub-VOM, no quota, no termination token — invisible to Terminate/DropPrefix.
    /// Route it through Vom.Spawn (Ps) so it becomes an owned, refcounted, cancellable handle. Warning,
    /// because this is pervasive (plan D4 — phase in); the kernel itself (Vom/Ps) is exempt.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS009AmbientThreadAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS009";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Ambient thread outside the kernel",
            "{0} spawns work the VOM does not own — no Sub-VOM, quota, or termination token; route it through Vom.Spawn (Ps) so it is owned, quota'd, and cancellable",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "The VOM owns threads. Free Task.Run / new Thread is invisible to Terminate/DropPrefix — phase it onto Ps/Spawn.");

        // The kernel legitimately creates threads (that IS Spawn). Don't flag it spawning them.
        private static readonly ImmutableHashSet<string> Exempt = ImmutableHashSet.Create("Vom", "Ps", "HandleAllocator");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(AnalyzeInvocation, SyntaxKind.InvocationExpression);
            context.RegisterSyntaxNodeAction(AnalyzeCreation,
                SyntaxKind.ObjectCreationExpression, SyntaxKind.ImplicitObjectCreationExpression);
        }

        private static bool InExemptType(SyntaxNode node)
        {
            var td = node.FirstAncestorOrSelf<TypeDeclarationSyntax>();
            return td != null && Exempt.Contains(td.Identifier.Text);
        }

        private static void AnalyzeInvocation(SyntaxNodeAnalysisContext ctx)
        {
            var inv = (InvocationExpressionSyntax)ctx.Node;
            if (ctx.SemanticModel.GetSymbolInfo(inv, ctx.CancellationToken).Symbol is not IMethodSymbol m) return;
            if (m.Name != "Run" || m.ContainingType?.ToDisplayString() != "System.Threading.Tasks.Task") return;
            if (InExemptType(inv)) return;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, inv.GetLocation(), "Task.Run"));
        }

        private static void AnalyzeCreation(SyntaxNodeAnalysisContext ctx)
        {
            var creation = (BaseObjectCreationExpressionSyntax)ctx.Node;
            if (ctx.SemanticModel.GetTypeInfo(creation, ctx.CancellationToken).Type is not INamedTypeSymbol t) return;
            if (t.Name != "Thread" || t.ContainingNamespace?.ToDisplayString() != "System.Threading") return;
            if (InExemptType(creation)) return;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, creation.GetLocation(), "new Thread"));
        }
    }
}
