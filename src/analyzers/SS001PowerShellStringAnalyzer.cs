using System.Collections.Immutable;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS001 — No PowerShell-source strings in C#.
    ///
    /// Violation pattern: a PowerShell body baked into a .cs string literal is "truth held outside the one
    /// namespace" — canon wearing larval clothes. Canon cmdlets are compiled, System-integrity, no embedded
    /// source. A PowerShell script may live ONLY as data in <c>Cm.Source</c> at User tier, never as a
    /// literal in source.
    ///
    /// This analyzer anchors structurally on the <c>SessionStateFunctionEntry(name, definition, …)</c>
    /// constructor — the exact API boundary where a PS body is embedded in source — resolved through the
    /// semantic model. So a hit is a real reference, not a text coincidence (it does not lie the way grep does).
    /// It drives the string→compiled conversions (Stage 2b) and the alias/CoreMappings graduation.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS001PowerShellStringAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS001";

        private const string FunctionEntryTypeName = "SessionStateFunctionEntry";
        private const string FunctionEntryNamespace = "System.Management.Automation.Runspaces";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            id: DiagnosticId,
            title: "PowerShell source baked into C#",
            messageFormat: "PowerShell body passed to SessionStateFunctionEntry '{0}' — canon cmdlets are compiled; a script body belongs in Cm.Source at User tier, never as a string literal in .cs",
            category: "Subsystem.NT",
            defaultSeverity: DiagnosticSeverity.Error,
            isEnabledByDefault: true,
            description: "Truth held outside the one namespace. Graduate the function to a compiled PSCmdlet (System integrity), or store the script as Cm.Source data at User tier.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(
                AnalyzeCreation,
                SyntaxKind.ObjectCreationExpression,
                SyntaxKind.ImplicitObjectCreationExpression);
        }

        private static void AnalyzeCreation(SyntaxNodeAnalysisContext context)
        {
            var creation = (BaseObjectCreationExpressionSyntax)context.Node;

            // Resolve the constructed type through the semantic model — never by matching the typed text.
            if (context.SemanticModel.GetSymbolInfo(creation, context.CancellationToken).Symbol is not IMethodSymbol ctor)
                return;
            var type = ctor.ContainingType;
            if (type is null || type.Name != FunctionEntryTypeName) return;
            if (type.ContainingNamespace?.ToDisplayString() != FunctionEntryNamespace) return;

            var argList = creation.ArgumentList;
            if (argList is null || argList.Arguments.Count < 2) return;

            // Signature is (string name, string definition, …); the definition (PowerShell body) is arg[1].
            var nameArg = argList.Arguments[0].Expression;
            var bodyArg = argList.Arguments[1].Expression;
            if (!IsStringSource(bodyArg)) return;

            var name = context.SemanticModel.GetConstantValue(nameArg, context.CancellationToken).Value as string ?? "?";
            context.ReportDiagnostic(Diagnostic.Create(Rule, bodyArg.GetLocation(), name));
        }

        /// <summary>True if the expression is (or concatenates) a string literal / interpolation — i.e. inline source.</summary>
        private static bool IsStringSource(ExpressionSyntax expr)
        {
            switch (expr.Kind())
            {
                case SyntaxKind.StringLiteralExpression:        // "..." and verbatim @"..." and raw """..."""
                case SyntaxKind.Utf8StringLiteralExpression:
                case SyntaxKind.InterpolatedStringExpression:   // $"..."
                    return true;
            }
            if (expr is BinaryExpressionSyntax bin && bin.IsKind(SyntaxKind.AddExpression))
                return IsStringSource(bin.Left) || IsStringSource(bin.Right);
            if (expr is ParenthesizedExpressionSyntax paren)
                return IsStringSource(paren.Expression);
            return false;
        }
    }
}
