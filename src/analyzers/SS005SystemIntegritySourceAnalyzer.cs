using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS005 — A System-integrity capability may not carry a Source body. Pillars are compiled,
    /// System-integrity, with no embedded script. A <c>CapabilityRecord</c> initialized to
    /// Integrity="System" while also setting a non-null Source is a string wearing pillar integrity —
    /// graduation must be an integrity promotion of compiled code, not a System-tier blob of script.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS005SystemIntegritySourceAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS005";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "System-integrity capability carries a script body",
            "CapabilityRecord set to System integrity while carrying a Source body — a string wearing pillar integrity; System pillars are compiled with no embedded source",
            "Subsystem.NT", DiagnosticSeverity.Error, isEnabledByDefault: true,
            "Scripts are larval (User tier). Graduation to System is an integrity promotion of compiled code — never a System-tier Source string.");

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
            if (t.Name != "CapabilityRecord" || t.ContainingNamespace?.ToDisplayString() != "Subsystem.Cm") return;
            if (creation.Initializer is null) return;

            bool systemIntegrity = false, hasSource = false;
            foreach (var expr in creation.Initializer.Expressions)
            {
                if (expr is not AssignmentExpressionSyntax a || a.Left is not IdentifierNameSyntax id) continue;
                switch (id.Identifier.Text)
                {
                    case "Integrity":
                        if (ctx.SemanticModel.GetConstantValue(a.Right, ctx.CancellationToken).Value as string == "System")
                            systemIntegrity = true;
                        break;
                    case "Source":
                        if (!a.Right.IsKind(SyntaxKind.NullLiteralExpression)) hasSource = true;
                        break;
                }
            }
            if (systemIntegrity && hasSource)
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, creation.GetLocation()));
        }
    }
}
