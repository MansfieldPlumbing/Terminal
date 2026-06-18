using System;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Diagnostics;
using Microsoft.CodeAnalysis.Operations;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS016 — handle values are opaque outside the kernel (CONTRACT.md axiom 4: identity in the
    /// value, authority in the entry; holders may QUERY a handle, never PARSE one). Bit/shift/mask
    /// arithmetic on a Handle's Id outside Subsystem.Vom is a holder parsing the kernel's closed
    /// layout — the Win32 tag-bit junk drawer (NULL vs INVALID_HANDLE_VALUE) is how that ends.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS016HandleOpacityAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS016";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Handle value parsed outside the kernel",
            "Bitwise '{0}' on Handle.{1} outside Subsystem.Vom — the value's layout is the kernel's, closed; query the handle instead",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Smuggling is the kernel's privilege: generation/index packing belongs to HandleAllocator alone. Holders treat handle values as opaque words.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;

                start.RegisterOperationAction(ctx => Analyze(ctx, cat), OperationKind.Binary);
            });
        }

        private static void Analyze(OperationAnalysisContext ctx, SystemCatalogFile cat)
        {
            var op = (IBinaryOperation)ctx.Operation;
            switch (op.OperatorKind)
            {
                case BinaryOperatorKind.And:
                case BinaryOperatorKind.Or:
                case BinaryOperatorKind.ExclusiveOr:
                case BinaryOperatorKind.LeftShift:
                case BinaryOperatorKind.RightShift:
                    break;
                default:
                    return;
            }

            // Inside the kernel, packing is legitimate — that's where the smuggling privilege lives.
            var home = cat.ComponentOfPath(ctx.Operation.Syntax.SyntaxTree.FilePath);
            if (home == "Vom") return;

            var member = HandleMember(op.LeftOperand) ?? HandleMember(op.RightOperand);
            if (member == null) return;

            ctx.ReportDiagnostic(Diagnostic.Create(Rule, op.Syntax.GetLocation(),
                Spell(op.OperatorKind), member));
        }

        /// <summary>Peels conversions; returns the member name if the operand reads a field/property of Vom's Handle.</summary>
        private static string? HandleMember(IOperation operand)
        {
            while (operand is IConversionOperation conv) operand = conv.Operand;
            if (!(operand is IMemberReferenceOperation mr)) return null;
            var t = mr.Member.ContainingType;
            if (t == null || t.Name != "Handle") return null;
            var ns = t.ContainingNamespace?.ToDisplayString() ?? "";
            return ns.EndsWith(".Vom", StringComparison.Ordinal) || ns == "Vom" ? mr.Member.Name : null;
        }

        private static string Spell(BinaryOperatorKind k) => k switch
        {
            BinaryOperatorKind.And => "&",
            BinaryOperatorKind.Or => "|",
            BinaryOperatorKind.ExclusiveOr => "^",
            BinaryOperatorKind.LeftShift => "<<",
            BinaryOperatorKind.RightShift => ">>",
            _ => k.ToString(),
        };
    }
}
