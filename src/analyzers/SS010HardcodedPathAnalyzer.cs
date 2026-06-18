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
    /// SS010 — No hardcoded absolute paths or URLs. A drive path (<c>C:\</c>), a POSIX system path
    /// (<c>/sdcard</c>, <c>/data</c>, <c>/system</c>, …), or a wired endpoint (<c>http://</c>, <c>ws://</c>,
    /// <c>file://</c>) baked into source is truth held outside the registry — it should resolve by id from
    /// Cm, not live as a literal. Complements SS004 (which guards \-namespace paths). Warning: some are
    /// loopback/dev defaults that graduate to config; each is triaged.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS010HardcodedPathAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS010";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Hardcoded absolute path or URL",
            "Hardcoded {0} '{1}' — absolute paths and endpoints are truth outside the registry; resolve by id from Cm (or a config record), not a literal",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "No file or endpoint literal as a source of truth. Move it into Cm / a config record and resolve by id.");

        // X:\…  (drive path)
        private static readonly Regex DrivePath = new Regex(@"^[A-Za-z]:\\", RegexOptions.Compiled);
        // scheme://…  (http/https/ws/wss/file)
        private static readonly Regex Url = new Regex(@"^(https?|wss?|file)://", RegexOptions.Compiled);
        // POSIX system roots that are the Linuxbro hardcode tell.
        private static readonly string[] PosixRoots = { "/sdcard", "/storage", "/data/", "/system/", "/proc/", "/dev/", "/mnt/" };

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
            if (string.IsNullOrEmpty(val) || val.Length < 4) return;

            string? kind = null;
            if (DrivePath.IsMatch(val)) kind = "drive path";
            else if (Url.IsMatch(val)) kind = "URL";
            else
            {
                foreach (var root in PosixRoots)
                    if (val.StartsWith(root, StringComparison.Ordinal)) { kind = "POSIX path"; break; }
            }
            if (kind is null) return;

            var shown = val.Length > 48 ? val.Substring(0, 48) + "…" : val;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, lit.GetLocation(), kind, shown));
        }
    }
}
