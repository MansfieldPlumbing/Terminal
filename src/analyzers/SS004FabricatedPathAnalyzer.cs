using System;
using System.Collections.Immutable;
using System.Text.RegularExpressions;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS004 — No fabricated namespace-path literals. A backslash-rooted string is a claim on the one
    /// namespace; it must root in a real hive (\Capability, \Shell, \Device, \Sessions, \Agent, \System,
    /// …). Codename roots, "HKOM"-style fake hives, and ".ini" file paths are a second store masquerading
    /// as the namespace. Identifier-shaped first segments only, so regex/escape literals don't trip it.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS004FabricatedPathAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS004";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Fabricated namespace path",
            "Path literal '{0}' is not a real namespace root — codename/HKOM/.ini paths are a store outside the one namespace (\\Capability, \\Shell, \\Device, \\Sessions, \\Agent, \\System)",
            "Subsystem.NT", DiagnosticSeverity.Error, isEnabledByDefault: true,
            "The registry is a projection of the one namespace. Root every path in a real hive; never invent a parallel one.");

        // The real namespace roots. Extend as the hive grows (kept here, not text-scattered).
        private static readonly ImmutableHashSet<string> Roots = ImmutableHashSet.Create(
            "Capability", "Shell", "Device", "Sessions", "Agent", "System", "Diag", "Capture", "Object",
            "Handle", "Thread");   // Thread = real kernel namespace segment (threads-as-handles)

        private static readonly Regex Identifier = new Regex("^[A-Za-z][A-Za-z0-9_]*$", RegexOptions.Compiled);

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze, SyntaxKind.StringLiteralExpression);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            var lit = (LiteralExpressionSyntax)ctx.Node;
            var val = lit.Token.ValueText;
            if (string.IsNullOrEmpty(val)) return;

            bool bad = false;
            if (val.IndexOf("HKOM", StringComparison.OrdinalIgnoreCase) >= 0) bad = true;
            else if (val.EndsWith(".ini", StringComparison.OrdinalIgnoreCase)) bad = true;
            else if (val[0] == '\\')
            {
                // Require a rooted path with at least one child (\Root\child…). A bare single-segment
                // fragment like "\command" is a registry-verb suffix / string predicate, not a namespace
                // root — flagging it is a false positive (HKOM/.ini are still caught explicitly above).
                var parts = val.Split('\\');
                // Require a rooted path with a NON-EMPTY child (\Root\child). A trailing-fragment like
                // "\bin\" or "\obj\" (empty child) is a filesystem dir-name substring check in host/build
                // tooling, not a claim on the one namespace — flagging it is a false positive.
                if (parts.Length >= 3 && parts[2].Length > 0)
                {
                    var seg = parts[1];
                    if (Identifier.IsMatch(seg) && !Roots.Contains(seg)) bad = true;
                }
            }
            if (!bad) return;

            var shown = val.Length > 48 ? val.Substring(0, 48) + "…" : val;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, lit.GetLocation(), shown));
        }
    }
}
