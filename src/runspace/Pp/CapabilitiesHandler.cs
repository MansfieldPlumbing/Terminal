using System.Collections.Generic;
using System.Linq;
using Subsystem.Cm;              // CapabilityRecord
using CmReg = Subsystem.Cm.Cm;  // the registry class — aliased to avoid the namespace/type name clash

namespace Subsystem.Pp;

// CapabilitiesHandler — the first concrete Pp handler, backed by Cm (the registry).
// Extract: snapshot the capability ledger into the template. Apply: rehydrate it into Cm.
// This is the load-bearing handler: it's how a device's accumulated capabilities travel in a
// provisioning template (extract from one device -> apply to another, or re-apply after reinstall).
//
// Register at boot with:  Pp.RegisterHandler(new CapabilitiesHandler());   // not yet wired.
public sealed class CapabilitiesHandler : IProvisioningHandler
{
    public string Name => "Capabilities";

    // Device -> section: the full capability ledger (Cm rehydrates from SQLite, so this is durable state).
    public object? Extract(ExtractOptions opts)
    {
        var records = CmReg.List();
        return records.Length == 0 ? null : records;
    }

    // Section -> device: register each capability back into Cm (in-memory + durable plane).
    // ApplyOptions.RemoveExisting => clear capabilities not present in the template first (replace vs merge).
    public void Apply(object section, ApplyOptions opts)
    {
        var incoming = AsRecords(section);
        if (incoming == null) return;

        if (opts.RemoveExisting)
        {
            var keep = new HashSet<string>(incoming.Select(r => r.Path), System.StringComparer.OrdinalIgnoreCase);
            foreach (var existing in CmReg.List())
                if (!keep.Contains(existing.Path)) CmReg.Unregister(existing.Path);
        }

        foreach (var r in incoming) CmReg.Register(r);
    }

    // Tolerant unwrap: in-process the section is CapabilityRecord[]; after a JSON round-trip it may be a
    // generic list. Only the strongly-typed path is wired here; broader deserialization lands with the
    // unified-surface JSON contract.
    private static IReadOnlyList<CapabilityRecord>? AsRecords(object section)
    {
        if (section is IReadOnlyList<CapabilityRecord> ro) return ro;
        if (section is IEnumerable<CapabilityRecord> en) return en.ToList();
        return null;
    }
}
