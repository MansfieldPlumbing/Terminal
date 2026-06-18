using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS006 — No per-call <c>new Random()</c>. Constructed inside a method body it reseeds from the clock
    /// each call (collisions, bias, predictable ids). A Random held in a static field is fine. Warning.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS006PerCallRandomAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS006";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Per-call new Random()",
            "new Random() inside a method — reseeds per call (collisions/bias); use a shared static Random or RandomNumberGenerator",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Construct Random once (static field). Per-call construction yields colliding/predictable values.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze,
                SyntaxKind.ObjectCreationExpression, SyntaxKind.ImplicitObjectCreationExpression);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            var creation = (BaseObjectCreationExpressionSyntax)ctx.Node;
            if (ctx.SemanticModel.GetTypeInfo(creation, ctx.CancellationToken).Type is not INamedTypeSymbol t) return;
            if (t.Name != "Random" || t.ContainingNamespace?.ToDisplayString() != "System") return;

            // A Random initialized into a field (e.g. `static readonly Random _rng = new();`) is fine.
            if (creation.FirstAncestorOrSelf<FieldDeclarationSyntax>() != null) return;

            ctx.ReportDiagnostic(Diagnostic.Create(Rule, creation.GetLocation()));
        }
    }
}
