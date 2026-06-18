using System;

namespace Subsystem.Cm;

// Security — the capability access gate (NT access-token + Mandatory Integrity Control analog). The
// Cm ledger already records each capability's Integrity tier and Enabled state; this is the primitive
// that ENFORCES them, fail-closed, instead of leaving Integrity an advisory field. Authority is
// possession (the VOM handle you walk away with), and THIS decides whether that handle is minted.
//
// Design (zero exceptions): default-deny. An operation is permitted only if its capability exists, is
// granted (.Enabled), the caller dominates the required integrity, and every consent it depends on is
// itself granted. Built in from the start so a privileged surface (a DirectPort producer, a non-loopback
// bind, screen capture) is gated on day one — not retrofitted later.

// The integrity lattice (NT MIC): a higher tier dominates the ones below it.
public enum IntegrityLevel { Untrusted = 0, User = 1, Admin = 2, System = 3 }

// A caller: the subject performing an operation and the integrity it carries — the NT access-token /
// subject-context analog. Named Caller (not the bare NT-reserved "Token") so it never gets conflated
// with a kernel token. Minted by the host seam (a CLI operator, a remote session, the agent) — never
// assumed System without evidence.
public sealed class Caller
{
    public string         Subject { get; }
    public IntegrityLevel Level   { get; }
    public string         Source  { get; }   // audit: how this caller was minted

    public Caller(string subject, IntegrityLevel level, string source)
    {
        Subject = subject ?? "";
        Level   = level;
        Source  = source ?? "";
    }

    // Map the persisted Integrity string to the lattice. An unknown/blank value floors to User — fail
    // toward least privilege, never silently grant a higher tier.
    public static IntegrityLevel Parse(string? integrity) => integrity switch
    {
        "System"    => IntegrityLevel.System,
        "Admin"     => IntegrityLevel.Admin,
        "Untrusted" => IntegrityLevel.Untrusted,
        _           => IntegrityLevel.User,
    };

    // The ambient local-operator caller. Defaults to User; a higher tier must be supplied with evidence
    // by the host (an elevation check or the DEV posture policy). The host head refines this.
    public static Caller Local(IntegrityLevel level = IntegrityLevel.User, string source = "local")
        => new Caller(SafeUserName(), level, source);

    private static string SafeUserName()
    {
        try { return Environment.UserName; } catch { return "operator"; }
    }
}

// The outcome of an access check: granted/denied plus a human-readable reason for the audit trail.
public readonly record struct AccessResult(bool Granted, string Reason)
{
    public static AccessResult Grant(string path) => new(true, "granted " + path);
}

// AccessCheck — fail-closed authorization over the capability ledger.
public static class AccessCheck
{
    // DENY unless ALL hold:
    //   1. the capability exists,
    //   2. it is granted (.Enabled) — default-deny: a seeded-disabled record refuses,
    //   3. the caller dominates the required integrity (caller.Level >= record.Integrity), and
    //   4. every DependsOn consent capability is itself granted (the informed opt-in chain).
    public static AccessResult Resolve(Caller caller, string capabilityPath)
    {
        var rec = Cm.Get(capabilityPath);
        if (rec is null)   return new AccessResult(false, "no such capability: " + capabilityPath);
        if (!rec.Enabled)  return new AccessResult(false, capabilityPath + " is not granted (disabled)");

        var required = Caller.Parse(rec.Integrity);
        if (caller.Level < required)
            return new AccessResult(false, $"{capabilityPath} requires {required} integrity; caller is {caller.Level}");

        foreach (var dep in rec.DependsOn)
        {
            var d = Cm.Get(dep);
            if (d is null || !d.Enabled)
                return new AccessResult(false, $"{capabilityPath} depends on consent {dep}, which is not granted");
        }
        return AccessResult.Grant(capabilityPath);
    }

    public static bool IsGranted(Caller caller, string capabilityPath) => Resolve(caller, capabilityPath).Granted;
}
