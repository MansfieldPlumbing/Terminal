using System;

namespace Subsystem.Vom;

// Thrown when an owner exceeds its hard quota (VOM-SPEC §4). In Phase 1 quotas are ADVISORY
// (counted + logged, never thrown); this type exists so the Phase 3 flip to hard enforcement is a
// one-line change, not a new contract.
public sealed class VomQuotaExceededException : Exception
{
    public VomQuotaExceededException(string message) : base(message) { }
}
