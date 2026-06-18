using System;
using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS019 — the Streisand effect. Removing a name and then NARRATING the removal in a comment
    /// ("renamed from X", "formerly X", "(was: …)") re-introduces the dead name into the source — the
    /// exact thing the removal meant to kill. The clean delete IS the point; rename/removal history
    /// lives in git + the records (memory), never in a comment. Syntax-only (comments), so it runs
    /// everywhere — including the host-windows tree the checker scans separately. Census-pending ratchet.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS019StreisandAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS019";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Streisand effect — a comment narrates a removal/rename",
            "Comment narrates a removal/rename ('{0}') — that keeps the dead name alive; delete it cleanly, the history lives in git + the records, not in source",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Removing a name then explaining the removal in a comment is the Streisand effect — the ghost outlives the rename. Delete cleanly; rename history belongs to git + memory, not the code.");

        // The tells of explaining-a-removal. Hardcoded (catalog-independent) so the rule runs on the bare
        // host-windows scan too — high-precision phrases, not bare words, to avoid false positives
        // ("no longer exists/firing" is legitimate; "no longer called X" is the Streisand pattern).
        private static readonly string[] Tells =
        {
            "renamed", "formerly", "(was:", "used to be", "previously named",
            "previously called", "no longer called", "no longer named", "f.k.a",
        };

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxTreeAction(Analyze);
        }

        private static void Analyze(SyntaxTreeAnalysisContext ctx)
        {
            if (SystemCatalogFile.IsGeneratedPath(ctx.Tree.FilePath)) return;
            var root = ctx.Tree.GetRoot(ctx.CancellationToken);
            foreach (var trivia in root.DescendantTrivia())
            {
                if (!trivia.IsKind(SyntaxKind.SingleLineCommentTrivia) &&
                    !trivia.IsKind(SyntaxKind.MultiLineCommentTrivia) &&
                    !trivia.IsKind(SyntaxKind.SingleLineDocumentationCommentTrivia) &&
                    !trivia.IsKind(SyntaxKind.MultiLineDocumentationCommentTrivia))
                    continue;

                var text = trivia.ToString();
                foreach (var tell in Tells)
                {
                    if (text.IndexOf(tell, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        ctx.ReportDiagnostic(Diagnostic.Create(Rule, trivia.GetLocation(), tell));
                        break;
                    }
                }
            }
        }
    }
}
