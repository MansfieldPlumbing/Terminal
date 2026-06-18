using System;
using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS021 — No ambient host-path bleed in the portable core. A component-folder file (src/runspace, the
    /// host-agnostic core) must not reach past Vom/Cm into the host's directory model: Environment.GetFolderPath
    /// and Path.GetTempPath() bind the code to one OS's layout (C:\Users\… vs /data/user/0/…), so the same
    /// source can't compile against a second head. Directories enter through the HOST SEAM at boot
    /// (MainActivity / Program.cs, which are hostPaths-exempt) and resolve from Cm (\System\Config\*). This is
    /// the build-level expression of "three heads, one core": the core asks the registry, never the OS.
    /// Complements SS010 (literal path strings); semantic, so an alias or `using static` can't dodge it.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS021AmbientHostPathAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS021";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Ambient host path in the portable core",
            "'{0}' reaches into the host OS for a directory — the core must stay host-agnostic; provide the path through the host seam at boot and resolve it from Cm (\\System\\Config\\*), not the ambient environment",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "The core resolves directories from Cm (set by the Host seam at boot), never from Environment.GetFolderPath / Path.GetTempPath — that bleed breaks the second head. Host-seam files are exempt via SystemCatalog.json hostPaths.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;
                start.RegisterSyntaxNodeAction(ctx => Analyze(ctx, cat), SyntaxKind.InvocationExpression);
            });
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx, SystemCatalogFile cat)
        {
            var path = ctx.Node.SyntaxTree?.FilePath;
            if (SystemCatalogFile.IsGeneratedPath(path)) return;
            var component = cat.ComponentOfPath(path);
            if (component == null || component == "(host)") return;   // component folders only; the host seam is exempt

            var inv = (InvocationExpressionSyntax)ctx.Node;

            // Cheap syntactic prefilter (the method name) before paying for the semantic resolve.
            string leaf = inv.Expression is MemberAccessExpressionSyntax ma ? ma.Name.Identifier.ValueText
                        : inv.Expression is IdentifierNameSyntax id ? id.Identifier.ValueText
                        : "";
            if (leaf != "GetFolderPath" && leaf != "GetTempPath") return;

            if (!(ctx.SemanticModel.GetSymbolInfo(inv).Symbol is IMethodSymbol sym)) return;
            string container = sym.ContainingType?.ToDisplayString() ?? "";
            bool banned =
                (sym.Name == "GetFolderPath" && container == "System.Environment") ||
                (sym.Name == "GetTempPath" && container == "System.IO.Path");
            if (!banned) return;

            ctx.ReportDiagnostic(Diagnostic.Create(Rule, inv.GetLocation(), container + "." + sym.Name + "()"));
        }
    }
}
