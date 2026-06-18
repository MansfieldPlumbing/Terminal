using System;
using System.Collections.Generic;
using System.Linq;

namespace Subsystem.Pp;

// Pp — the Plug-and-Play manager (NT's real PnP prefix). The provisioning ENGINE that sits beside Cm
// (the Configuration Manager / registry). Cm holds the capability hives; Pp enumerates, EXTRACTS device
// state into a portable template, and APPLIES a template back onto a device. This is the PnP provisioning
// pattern, modeled on Microsoft's own contract (github.com/microsoft/json-schemas:
//   pnp/provisioning/202102/extract-configuration.schema.json — "pnp is our capability design").
//
// A template is a declarative document (the unified surface): per-domain sections + a handlers[] set.
// Each IProvisioningHandler owns one domain and can Extract (device -> section) and Apply (section -> device).
// Passing a subset of handlers = selective apply = ATTENUATION. Extract+Apply = rehydration / OOBE-seed /
// "everything hydrating, in lockstep" (VOM-SPEC §6/§7). Handlers are additive: register a new domain and the
// engine picks it up — nothing else changes (additive substrate, disposable leaves).
//
// Status: structural scaffold. NOT yet boot-wired or cmdlet-exposed; the concrete handler set is filled in
// when the unified config surface lands (domains: Profiles · Schemes · Themes · Keybindings · Actions · Capabilities).
public static class Pp
{
    private static readonly Dictionary<string, IProvisioningHandler> _handlers =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Register a domain handler. Idempotent by Name (matches the template's handlers[] enum).</summary>
    public static void RegisterHandler(IProvisioningHandler h)
    {
        if (h == null || string.IsNullOrEmpty(h.Name)) return;
        _handlers[h.Name] = h;
        Dg.Log("pp", $"handler registered: {h.Name}");
    }

    /// <summary>The handler names available to put in a template's handlers[] set.</summary>
    public static string[] Handlers =>
        _handlers.Keys.OrderBy(k => k, StringComparer.OrdinalIgnoreCase).ToArray();

    /// <summary>
    /// Extract a provisioning template from the device. Runs the named handlers (or ALL if null/empty),
    /// PnP-style. Each handler contributes its section under its own Name. Returns the template document.
    /// </summary>
    public static Dictionary<string, object?> Extract(string[]? handlers = null, ExtractOptions? opts = null)
    {
        opts ??= new ExtractOptions();
        var doc = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
        {
            ["version"] = "1.0",
        };
        var ran = new List<string>();
        foreach (var h in Select(handlers))
        {
            try { var section = h.Extract(opts); if (section != null) { doc[h.Name] = section; ran.Add(h.Name); } }
            catch (Exception ex) { Dg.Log("pp", $"EXTRACT {h.Name} failed: {ex.Message}"); }
        }
        Dg.Log("pp", $"EXTRACT [{string.Join(",", ran)}]");
        return doc;
    }

    /// <summary>
    /// Apply a provisioning template onto the device. Runs the named handlers (or ALL present in the doc).
    /// A handler only runs if the doc carries its section. Errors are isolated + logged (never crash — DOM autopsy).
    /// </summary>
    public static void Apply(IDictionary<string, object?> doc, string[]? handlers = null, ApplyOptions? opts = null)
    {
        if (doc == null) return;
        opts ??= new ApplyOptions();
        var ran = new List<string>();
        foreach (var h in Select(handlers))
        {
            if (!doc.TryGetValue(h.Name, out var section) || section == null) continue;
            try { h.Apply(section, opts); ran.Add(h.Name); }
            catch (Exception ex) { Dg.Log("pp", $"APPLY {h.Name} failed: {ex.Message}"); }
        }
        Dg.Log("pp", $"APPLY [{string.Join(",", ran)}]");
    }

    // null/empty selector => all registered handlers; otherwise the named subset that exists.
    private static IEnumerable<IProvisioningHandler> Select(string[]? names)
        => (names == null || names.Length == 0)
            ? _handlers.Values
            : names.Where(_handlers.ContainsKey).Select(n => _handlers[n]);

    /// <summary>Round-trip proof (like Test-Vom/Test-Cm): register a probe handler, Extract → Apply → verify.</summary>
    public static object SelfTest()
    {
        var probe = new ProbeHandler();
        var saved = _handlers.TryGetValue(probe.Name, out var prev) ? prev : null;
        RegisterHandler(probe);
        try
        {
            var doc = Extract(new[] { probe.Name });
            bool extracted = doc.ContainsKey(probe.Name);
            probe.Applied = false;
            Apply(doc, new[] { probe.Name });
            return new
            {
                ok = extracted && probe.Applied,
                extracted,
                applied = probe.Applied,
                handlers = Handlers,
                note = "registered a probe handler, extracted a section, applied it back",
            };
        }
        finally
        {
            if (saved != null) _handlers[probe.Name] = saved; else _handlers.Remove(probe.Name);
        }
    }

    private sealed class ProbeHandler : IProvisioningHandler
    {
        public string Name => "__pptest";
        public bool Applied;
        public object? Extract(ExtractOptions opts) => new { probe = true };
        public void Apply(object section, ApplyOptions opts) => Applied = true;
    }
}

/// <summary>A domain provider: owns one section of the provisioning template (the PnP "handler" unit).</summary>
public interface IProvisioningHandler
{
    /// <summary>Matches the handlers[] enum value (e.g. "Capabilities", "Schemes", "Themes").</summary>
    string Name { get; }
    /// <summary>Device -> a serializable template section (return null to contribute nothing).</summary>
    object? Extract(ExtractOptions opts);
    /// <summary>Template section -> device.</summary>
    void Apply(object section, ApplyOptions opts);
}

/// <summary>Per-extract knobs (mirrors PnP's persistAssetFiles etc.). Extend per handler as needed.</summary>
public sealed class ExtractOptions
{
    public bool PersistAssets { get; set; }
}

/// <summary>Per-apply knobs. RemoveExisting = replace vs. merge (PnP's removeExistingNodes).</summary>
public sealed class ApplyOptions
{
    public bool RemoveExisting { get; set; }
}
