using System;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Diagnostics;

namespace Subsystem.Analyzers
{
    /// <summary>
    /// SS012 — the type grammar (CONTRACT.md §3): no enterprise suffixes (Repository/Factory/Helper/
    /// Store/...), no context words in names (Win/Global/V2/... — context lives in the handle, never
    /// the name), no platform-name collisions (AOSP/Linux/NT reserved) unless the type IS the platform
    /// thing (inherits the base it names) or is a catalog-shipped NT analog (Bind, Port in the kernel).
    /// Hosts are exempt: WinDg is named BY its context, correctly.
    /// </summary>
    [DiagnosticAnalyzer(LanguageNames.CSharp)]
    public sealed class SS012TypeGrammarAnalyzer : DiagnosticAnalyzer
    {
        public const string DiagnosticId = "SS012";

        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor(
            DiagnosticId, "Type name violates the closed grammar",
            "Type '{0}' {1}",
            "Subsystem.NT", DiagnosticSeverity.Warning, isEnabledByDefault: true,
            "Name = MechanismNoun [+ approved Suffix]; banned suffixes, context words and platform collisions are ontology errors caught at birth (CONTRACT.md §3, SystemCatalog.json). Census-pending ratchet.");

        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);

        public override void Initialize(AnalysisContext context)
        {
            context.ConfigureGeneratedCodeAnalysis(GeneratedCodeAnalysisFlags.None);
            context.EnableConcurrentExecution();
            context.RegisterCompilationStartAction(start =>
            {
                var cat = SystemCatalogFile.TryLoad(start.Options, out _);
                if (cat == null) return;

                start.RegisterSymbolAction(ctx => Analyze(ctx, cat), SymbolKind.NamedType);
            });
        }

        private static void Analyze(SymbolAnalysisContext ctx, SystemCatalogFile cat)
        {
            var type = (INamedTypeSymbol)ctx.Symbol;
            if (type.IsImplicitlyDeclared) return;
            var loc = type.Locations.FirstOrDefault(l => l.IsInSource);
            if (loc == null) return;
            if (cat.IsHostPath(loc.SourceTree?.FilePath)) return;

            var name = type.Name;

            // 1. Banned suffix (longest match wins when suffixes nest).
            string? hit = null;
            foreach (var s in cat.BannedSuffixes)
                if (name.Length > s.Length && name.EndsWith(s, StringComparison.Ordinal) && (hit == null || s.Length > hit.Length))
                    hit = s;
            if (hit == null && cat.BannedSuffixes.Contains(name)) hit = name;
            if (hit != null)
            {
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, loc, name,
                    "carries banned suffix '" + hit + "' — name the mechanism (approved suffixes live in SystemCatalog.json)"));
                return;
            }

            // 2. Context word as a camel token — context lives in the handle, never the name.
            //    Interfaces drop the leading I before tokenizing (IProvisioningHandler -> Provisioning, Handler).
            var tokenSource = type.TypeKind == TypeKind.Interface && name.Length > 1 && name[0] == 'I' && char.IsUpper(name[1])
                ? name.Substring(1) : name;
            foreach (var token in SystemCatalogFile.Tokens(tokenSource))
            {
                if (cat.ContextWords.Contains(token))
                {
                    ctx.ReportDiagnostic(Diagnostic.Create(Rule, loc, name,
                        "encodes context '" + token + "' in the name — context belongs to the handle/host, not the identifier"));
                    return;
                }
            }

            // 3. Banned noun (exact) — refused fusions like "Endpoint".
            if (cat.BannedNouns.Contains(name))
            {
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, loc, name,
                    "is a refused noun (see CONTRACT.md §4 — e.g. Endpoint = Port+Manifest+DispatchTable fused)"));
                return;
            }

            // 4. Platform collision — exempt when the type IS the platform thing (a base in its
            //    inheritance chain carries the same name) or is a catalog-shipped kernel analog.
            if (cat.PlatformNames.Contains(name))
            {
                if (cat.ShippedTypes.Contains(name)) return;
                for (var b = type.BaseType; b != null; b = b.BaseType)
                    if (string.Equals(b.Name, name, StringComparison.Ordinal)) return;
                ctx.ReportDiagnostic(Diagnostic.Create(Rule, loc, name,
                    "collides with a platform-reserved name (AOSP/Linux/NT) without inheriting it — LLM coders will conflate them"));
            }
        }
    }
}
