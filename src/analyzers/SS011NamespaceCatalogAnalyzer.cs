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
    /// SS011 — every namespace is Root("."Component)+ with Component registered in SystemCatalog.json
    /// (CONTRACT.md §3). A namespace an LLM coins mid-PR ("Subsystem.Orchestration") does not compile;
    /// a root-only namespace ("namespace Subsystem") carries no component and is the R1 migration debt.
    /// Hosts (heads) are exempt — the host IS the context.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS011NamespaceCatalogAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS011";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Namespace not in the component catalog",
            "Namespace '{0}' {1} — registering a component in SystemCatalog.json is a deliberate event, never a PR side effect",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "The grammar is Root(\".\"Component)+ over the closed component catalog (CONTRACT.md §3). Census-pending ratchet: warning until baselines exist.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;   // SS000 is screaming; stay silent rather than guess

                start.RegisterSyntaxNodeAction(ctx => Analyze(ctx, cat),
                    SyntaxKind.NamespaceDeclaration, SyntaxKind.FileScopedNamespaceDeclaration);
            });
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx, SystemCatalogFile cat)
        {
            var path = ctx.Node.SyntaxTree.FilePath;
            if (SystemCatalogFile.IsGeneratedPath(path)) return;   // foreign generated bindings (obj/) — external surface
            if (cat.IsHostPath(path)) return;

            var nameSyntax = ctx.Node is FileScopedNamespaceDeclarationSyntax fs ? fs.Name
                           : ctx.Node is NamespaceDeclarationSyntax ns ? ns.Name : null;
            if (nameSyntax == null) return;

            var full = nameSyntax.ToString();
            var segments = full.Split('.');

            if (segments[0] != cat.RootToday && segments[0] != cat.Root)
            {
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, nameSyntax.GetLocation(), full,
                    "does not start at the root ('" + cat.RootToday + "')"));
                return;
            }
            if (segments.Length == 1)
            {
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, nameSyntax.GetLocation(), full,
                    "carries no component segment (root-only — the R1 folder=namespace debt)"));
                return;
            }
            for (int i = 1; i < segments.Length; i++)
            {
                if (!cat.Components.ContainsKey(segments[i]))
                {
                    ctx.ReportDiagnostic(Diagnostic.Create(Rule, nameSyntax.GetLocation(), full,
                        "segment '" + segments[i] + "' is not a registered component"));
                    return;
                }
            }
        }
    }
}
