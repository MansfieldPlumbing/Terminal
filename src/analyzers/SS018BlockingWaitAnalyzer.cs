using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;
using System.Collections.Immutable;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS018 — No async in the core. The VOM mesh is brutally synchronous: every node owns a real thread
    /// and hands off through a Fence (push, best-effort, copy-then-share). async/await earns nothing here
    /// and costs plenty — it colors callers (infects every caller's signature), hides which thread owns the
    /// work, allocates hidden state machines, and births the sync-over-async deadlock (.Result / .Wait() /
    /// .GetAwaiter().GetResult() block a thread that then can't observe cancellation). So async is the
    /// host/seam's job, not the core's: <c>await</c> and sync-over-async are refused in component code.
    /// Exempt: the host/seam (catalog hostPaths — the boundary where async legitimately lives) and foreign
    /// generated code (obj/). Warning, census-pending; the message states the WHY so it never needs re-explaining.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS018BlockingWaitAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS018";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Async in the core (the core is synchronous)",
            "{0} in core component code — the core is synchronous (real threads + Fence handoff, push/best-effort); async colors callers, hides the owning thread, and enables the sync-over-async deadlock. Make it synchronous, or move it to the host/seam",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "The VOM passes data via fences (best-effort push, copy-then-share), not Task continuations — so async buys nothing in the core and costs caller-coloring, a hidden thread model, state-machine allocations, and the sync-over-async deadlock. Host/seam (hostPaths) and generated code (obj/) are exempt. Census-pending ratchet.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;   // SS000 fail-closed; stay silent rather than guess
                start.RegisterSyntaxNodeAction(ctx => AnalyzeAwait(ctx, cat), SyntaxKind.AwaitExpression);
                start.RegisterSyntaxNodeAction(ctx => AnalyzeInvocation(ctx, cat), SyntaxKind.InvocationExpression);
                start.RegisterSyntaxNodeAction(ctx => AnalyzeMemberAccess(ctx, cat), SyntaxKind.SimpleMemberAccessExpression);
            });
        }

        // In scope ONLY for the synchronous-core components (catalog `synchronousCore` — Vom/Cm/Pp/Dg today).
        // The seams (Hb=LLM, Rs=pwsh, Host=web, Adb=network) and foreign generated code keep their async;
        // the no-async boundary ratchets OUTWARD by editing the catalog, never by silent default.
        private static bool OutOfScope(SystemCatalogFile cat, string path)
        {
            if (SystemCatalogFile.IsGeneratedPath(path)) return true;
            var c = cat.ComponentOfPath(path);
            return c == null || !cat.SynchronousCore.Contains(c);
        }

        // `await` — the universal async signal in source (an async method with no await is degenerate).
        private static void AnalyzeAwait(SyntaxNodeAnalysisContext ctx, SystemCatalogFile cat)
        {
            if (OutOfScope(cat, ctx.Node.SyntaxTree.FilePath)) return;
            var aw = (AwaitExpressionSyntax)ctx.Node;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, aw.AwaitKeyword.GetLocation(), "await"));
        }

        // Sync-over-async: .Wait()/.WaitAll()/.WaitAny() on Task, and explicit .GetResult() on an awaiter.
        private static void AnalyzeInvocation(SyntaxNodeAnalysisContext ctx, SystemCatalogFile cat)
        {
            if (OutOfScope(cat, ctx.Node.SyntaxTree.FilePath)) return;
            var inv = (InvocationExpressionSyntax)ctx.Node;
            if (ctx.SemanticModel.GetSymbolInfo(inv, ctx.CancellationToken).Symbol is not IMethodSymbol m) return;
            if ((m.Name == "Wait" || m.Name == "WaitAll" || m.Name == "WaitAny") && IsTaskType(m.ContainingType))
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, inv.GetLocation(), "Task." + m.Name + "()"));
            else if (m.Name == "GetResult" && IsAwaiterType(m.ContainingType))
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, inv.GetLocation(), ".GetAwaiter().GetResult()"));
        }

        // Sync-over-async: .Result on Task<T> / ValueTask<T>.
        private static void AnalyzeMemberAccess(SyntaxNodeAnalysisContext ctx, SystemCatalogFile cat)
        {
            if (OutOfScope(cat, ctx.Node.SyntaxTree.FilePath)) return;
            var ma = (MemberAccessExpressionSyntax)ctx.Node;
            if (ma.Name.Identifier.Text != "Result") return;
            if (IsTaskType(ctx.SemanticModel.GetTypeInfo(ma.Expression, ctx.CancellationToken).Type))
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, ma.Name.GetLocation(), ".Result"));
        }

        private static bool IsTaskType(ITypeSymbol? t)
        {
            for (var b = t; b != null; b = b.BaseType)
            {
                var n = b.OriginalDefinition?.ToDisplayString();
                if (n == "System.Threading.Tasks.Task" || n == "System.Threading.Tasks.Task<TResult>"
                    || n == "System.Threading.Tasks.ValueTask" || n == "System.Threading.Tasks.ValueTask<TResult>")
                    return true;
            }
            return false;
        }

        private static bool IsAwaiterType(ITypeSymbol? t)
        {
            var n = t?.OriginalDefinition?.ToDisplayString() ?? "";
            return n.StartsWith("System.Runtime.CompilerServices.") && n.Contains("Awaiter");
        }
    }
}
