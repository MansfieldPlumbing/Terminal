using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS003 — No static dictionary as an object store. A <c>static Dictionary</c>/<c>ConcurrentDictionary</c>
    /// holding live state is a third store of truth beside Cm (definitions) and Vom (live objects). Warning,
    /// because some static dictionaries are legitimate lookup tables — triage each to Cm or Vom, or confirm
    /// it is a pure constant map.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS003StaticDictionaryAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS003";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Static dictionary as object store",
            "Static {0} — a parallel store of truth; live objects belong in Vom handles, durable definitions in Cm rows",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "No subsystem holds its own truth. Move the state into Cm (definitions) or Vom (live objects), or confirm it is a constant map.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze, SyntaxKind.FieldDeclaration, SyntaxKind.PropertyDeclaration);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            // A static Dictionary/ConcurrentDictionary is a backing store of truth whether held as a FIELD
            // or a PROPERTY — a get-only auto-property has a hidden backing field, so both must be checked
            // (the property case is how NotificationService.Notifications slipped the gate before this).
            SyntaxTokenList modifiers;
            TypeSyntax typeSyntax;
            Location loc;
            switch (ctx.Node)
            {
                case FieldDeclarationSyntax field:
                    modifiers = field.Modifiers;
                    typeSyntax = field.Declaration.Type;
                    loc = field.Declaration.Variables.FirstOrDefault()?.GetLocation() ?? field.GetLocation();
                    break;
                case PropertyDeclarationSyntax prop:
                    modifiers = prop.Modifiers;
                    typeSyntax = prop.Type;
                    loc = prop.Identifier.GetLocation();
                    break;
                default:
                    return;
            }

            if (!modifiers.Any(m => m.IsKind(SyntaxKind.StaticKeyword))) return;

            if (ctx.SemanticModel.GetTypeInfo(typeSyntax, ctx.CancellationToken).Type is not INamedTypeSymbol t)
                return;
            var name = t.OriginalDefinition?.Name;
            if (name != "Dictionary" && name != "ConcurrentDictionary") return;

            // The VOM kernel (Subsystem.Vom) IS the live-object store — its owner/handle tables are the
            // canonical store, not a third one. Don't flag the authority for being the authority.
            var typeDecl = ctx.Node.FirstAncestorOrSelf<TypeDeclarationSyntax>();
            if (typeDecl != null
                && ctx.SemanticModel.GetDeclaredSymbol(typeDecl, ctx.CancellationToken) is INamedTypeSymbol ts
                && ts.ContainingNamespace?.ToDisplayString() == "Subsystem.Vom")
                return;

            ctx.ReportDiagnostic(Diagnostic.Create(Rule, loc, name));
        }
    }
}
