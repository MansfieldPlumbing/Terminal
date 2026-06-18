using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS022 — No HTTP server for the UI. A loopback <c>HttpListener</c> serving the shell/UI is a
    /// security antipattern: on Android <c>127.0.0.1</c> is NOT app-private, so any installed app can
    /// reach the port (a cap token only papers over it). The UI⇄backend transport is the DirectPort
    /// 256-aligned row-major float32 region + fence (→ Android postMessage → base64) — in-process shared
    /// memory, no port, no attack surface.
    ///
    /// Flags <c>new HttpListener(...)</c>. The device→adbd connection and the <c>ss adb</c> :5037
    /// adb-server-compat face speak the raw adb/smart-socket protocol over <c>TcpListener</c>/<c>Socket</c>
    /// (NOT HttpListener) — they are foreign/device channels, not the UI, and are deliberately not flagged.
    ///
    /// Warning + census ratchet: the existing ProjectionServer use baselines as the retirement worklist;
    /// any NEW HttpListener bleeds red at the gate.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS022HttpUiTransportAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS022";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "HTTP server for the UI",
            "HttpListener serves the UI over a localhost port reachable by any app — a security antipattern; carry the UI on the DirectPort region + fence (→ postMessage → base64), never HTTP",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "The UI must not ride an HTTP/loopback server. Use the DirectPort 256-aligned float32 region + fence; device and :5037 adb-compat sockets are not the UI and use TcpListener/Socket, not HttpListener.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze, SyntaxKind.ObjectCreationExpression);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            var creation = (ObjectCreationExpressionSyntax)ctx.Node;
            if (LastSegment(creation.Type) != "HttpListener") return;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, creation.GetLocation()));
        }

        // The trailing identifier of a type reference: "HttpListener" or "System.Net.HttpListener" -> "HttpListener".
        private static string LastSegment(TypeSyntax type) => type switch
        {
            IdentifierNameSyntax id => id.Identifier.Text,
            QualifiedNameSyntax q   => q.Right.Identifier.Text,
            _                       => type.ToString()
        };
    }
}
