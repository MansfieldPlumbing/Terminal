using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS008 — Cmdlets operate through handles, not raw memory. A method on a Cmdlet/PSCmdlet that returns
    /// a managed <c>byte[]</c> or a raw pointer (IntPtr/nint) ships memory-bearing data across the boundary
    /// the kernel can't own — it can leak/dangle and (across JNI) exhausts GREFs. Memory-bearing data must
    /// travel as a VOM handle (owned, refcounted, fenced, quota'd).
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS008CmdletRawMemoryAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS008";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Cmdlet returns raw memory instead of a VOM handle",
            "Cmdlet method '{0}' returns {1} — memory-bearing data must travel as a VOM handle (owned, refcounted, fenced), never a raw buffer/pointer across the boundary",
            "Subsystem.NT", DiagnosticSeverity.Error, isEnabledByDefault: true,
            "Return a VOM handle. Raw byte[]/pointers from a cmdlet can leak or dangle and exhaust JNI GREFs.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze, SyntaxKind.MethodDeclaration);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            var method = (MethodDeclarationSyntax)ctx.Node;
            if (ctx.SemanticModel.GetDeclaredSymbol(method, ctx.CancellationToken) is not IMethodSymbol sym) return;
            if (!DerivesFromCmdlet(sym.ContainingType)) return;

            var rt = sym.ReturnType;
            string? kind = null;
            if (rt is IArrayTypeSymbol arr && arr.ElementType.SpecialType == SpecialType.System_Byte) kind = "byte[]";
            else if (rt.SpecialType == SpecialType.System_IntPtr || rt.Name == "IntPtr") kind = rt.Name;
            if (kind is null) return;

            ctx.ReportDiagnostic(Diagnostic.Create(Rule, method.Identifier.GetLocation(), sym.Name, kind));
        }

        private static bool DerivesFromCmdlet(INamedTypeSymbol? type)
        {
            for (var t = type; t != null; t = t.BaseType)
            {
                if (t.Name is "Cmdlet" or "PSCmdlet"
                    && t.ContainingNamespace?.ToDisplayString() == "System.Management.Automation")
                    return true;
            }
            return false;
        }
    }
}
