using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS017 — lexical hygiene (the anti-slop dictionary), SCOPED so it is not a string scraper:
    ///   (a) banned.alwaysFlag — anthropomorphic / metaphor words refused in IDENTIFIERS (a type/member
    ///       named Brain/Soul/Ouroboros is an ontology error: name the mechanism, never the metaphor —
    ///       CONTRACT.md §3). Read from the symbol-name tokens, NOT from comments or string literals: a
    ///       comment may legitimately name the very concept it is telling you not to encode, and prose is
    ///       not API surface. Scope to names.
    ///   (b) banned.commentPatterns — casual / inflammatory comment tells (lol, hacky, blazingly, …). These
    ///       ARE a comment smell, so they stay scoped to comments.
    /// Census-pending ratchet: existing hits ride SS-BASELINE.txt; NEW slop bleeds red at the gate.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS017LexicalHygieneAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS017";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Banned word in a name, or casual/inflammatory comment",
            "{0}",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Anthropomorphic/metaphor IDENTIFIERS and casual/inflammatory comments are slop the contract refuses (CONTRACT.md §3; SystemCatalog.json banned.alwaysFlag / banned.commentPatterns). Census-pending ratchet.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;
                if (cat.AlwaysFlag.Count == 0 && cat.CommentPatterns.Count == 0) return;
                start.RegisterSyntaxTreeAction(ctx => Analyze(ctx, cat));
            });
        }

        private static void Analyze(SyntaxTreeAnalysisContext ctx, SystemCatalogFile cat)
        {
            var root = ctx.Tree.GetRoot(ctx.CancellationToken);

            // 1. Comments — casual/inflammatory PATTERNS only (a comment smell). Banned metaphor WORDS are
            //    NOT scraped from prose: a comment may legitimately name a concept it tells you not to
            //    encode in a type. The metaphor rule is enforced on NAMES below.
            if (cat.CommentPatterns.Count > 0)
            {
                foreach (var trivia in root.DescendantTrivia())
                {
                    if (!trivia.IsKind(SyntaxKind.SingleLineCommentTrivia) &&
                        !trivia.IsKind(SyntaxKind.MultiLineCommentTrivia) &&
                        !trivia.IsKind(SyntaxKind.SingleLineDocumentationCommentTrivia) &&
                        !trivia.IsKind(SyntaxKind.MultiLineDocumentationCommentTrivia))
                        continue;

                    var text = trivia.ToString();
                    foreach (var pat in cat.CommentPatterns)
                    {
                        if (text.IndexOf(pat, StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            ctx.ReportDiagnostic(Diagnostic.Create(Rule, trivia.GetLocation(),
                                "casual/inflammatory comment ('" + pat + "') — record facts, not editorializing"));
                            break;
                        }
                    }
                }
            }

            // 2. Identifiers — a banned metaphor word as a camel token in a NAME is the ontology error.
            //    This reads identifier tokens (mechanism, never metaphor), not arbitrary text.
            if (cat.AlwaysFlag.Count > 0)
            {
                foreach (var token in root.DescendantTokens())
                {
                    if (!token.IsKind(SyntaxKind.IdentifierToken)) continue;
                    foreach (var part in SystemCatalogFile.Tokens(token.Text))
                        if (cat.AlwaysFlag.Contains(part))
                        {
                            ctx.ReportDiagnostic(Diagnostic.Create(Rule, token.GetLocation(),
                                "identifier '" + token.Text + "' contains the banned word '" + part.ToLowerInvariant() + "' — mechanism names only"));
                            break;
                        }
                }
            }
        }
    }
}
