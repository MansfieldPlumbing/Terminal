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
    /// SS020 — No hardcoded model or system prompt. Both are CONTRACTS that live in the registry
    /// (\Capability\Model — discovered/projected by ModelCatalog; \Capability\Prompt — seeded from
    /// shell/prompts.json) and are resolved by id at runtime. A model FILE baked into source
    /// (<c>gemma-4-E2B-it.litertlm</c>) or a system PROMPT baked into source (a string assigned to a
    /// <c>SystemPrompt</c>/<c>systemInstruction</c> sink) is truth held by a head — exactly the slop that
    /// escaped the gate once because host-windows was ungated. Syntax-only, so it runs anywhere (the
    /// checker scans both the runspace project AND the host-windows tree with it). Complements SS010
    /// (drive paths/URLs) and SS017 (the banned-word dictionary). Census-pending ratchet.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS020ModelPromptHardcodeAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS020";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Hardcoded model or system prompt",
            "Hardcoded {0} '{1}' — models and system prompts are registry contracts (\\Capability\\Model is discovered/projected; \\Capability\\Prompt is seeded from data); resolve by id from Cm or discover from disk, never a source literal",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "A model file or a system prompt baked into source is truth a head holds — it must live in the registry (one store) and be resolved/discovered. No literal model paths, no literal prompts.");

        // A model weight file: a real name, then a known inference-format extension. The leading name
        // requirement keeps a bare extension map ("\".litertlm\"" -> format) from tripping it.
        private static readonly Regex ModelFile = new Regex(
            @"[\w\-.]+\.(litertlm|gguf|onnx|task|tflite)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

        // A system-prompt sink: a parameter/field/property/local named for the model's system instruction.
        private static readonly Regex PromptName = new Regex(
            @"(?i)system(prompt|instruction|message)", RegexOptions.Compiled);

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterSyntaxNodeAction(Analyze, SyntaxKind.StringLiteralExpression);
        }

        private static void Analyze(SyntaxNodeAnalysisContext ctx)
        {
            // Generated trees (the AAR Java->C# bindings, obj/) are foreign surface — a Java package like
            // com.google.ai.edge.litertlm is not a model file. Skip them, exactly as SS011/SS014 do.
            if (SystemCatalogFile.IsGeneratedPath(ctx.Node.SyntaxTree.FilePath)) return;

            var lit = (LiteralExpressionSyntax)ctx.Node;
            var val = lit.Token.ValueText;
            if (string.IsNullOrEmpty(val) || val.Length < 4) return;

            string? kind = null;
            // A model file literal — but NOT a URL (that is SS010's domain; a download URL ending in a model
            // extension is the registry's seed source, not a baked file path the loader opens).
            if (val.IndexOf("://", StringComparison.Ordinal) < 0 && ModelFile.IsMatch(val)) kind = "model file";
            else if (IsPromptSink(lit)) kind = "system prompt";
            if (kind is null) return;

            var shown = val.Length > 48 ? val.Substring(0, 48) + "…" : val;
            ctx.ReportDiagnostic(Diagnostic.Create(Rule, lit.GetLocation(), kind, shown));
        }

        // The literal is a system prompt when it sits directly in a prompt-named sink: a named argument
        // (systemInstruction: "…"), or the initializer of a field/property/local named *SystemPrompt* /
        // *systemInstruction*. Direct initializers only — deliberately narrow, so a stray string nowhere
        // near a prompt never trips.
        private static bool IsPromptSink(LiteralExpressionSyntax lit)
        {
            if (lit.Parent is ArgumentSyntax arg && arg.NameColon is { } nc && PromptName.IsMatch(nc.Name.Identifier.Text))
                return true;
            if (lit.Parent is EqualsValueClauseSyntax eq)
            {
                if (eq.Parent is VariableDeclaratorSyntax vd && PromptName.IsMatch(vd.Identifier.Text)) return true;
                if (eq.Parent is PropertyDeclarationSyntax pd && PromptName.IsMatch(pd.Identifier.Text)) return true;
            }
            return false;
        }
    }
}
