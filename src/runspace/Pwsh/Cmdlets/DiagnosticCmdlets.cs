using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

// Compiled pillar cmdlets (SS001 graduation): kernel / registry / diagnostic self-tests that wrap a
// proven static entry point. These are System-tier canon — compiled, no embedded PowerShell source.
// Bodies were verbatim PowerShell strings in SubsystemAliases (SessionStateFunctionEntry); now C#.

[Cmdlet(VerbsDiagnostic.Test, "Vom")]
public sealed class TestVomCmdlet : PSCmdlet
{
    // VOM kernel termination token self-test (VOM-SPEC §11.4).
    protected override void ProcessRecord() => WriteObject(Subsystem.Vom.Vom.SelfTest());
}

[Cmdlet(VerbsDiagnostic.Test, "Ps")]
public sealed class TestPsCmdlet : PSCmdlet
{
    // Ps dispatcher nested-spawn termination test (VOM-SPEC §4d): cascade cancel + bulk reclaim down the tree.
    protected override void ProcessRecord() => WriteObject(Subsystem.Vom.Vom.SpawnKillTest());
}

[Cmdlet(VerbsDiagnostic.Test, "Sqlite")]
public sealed class TestSqliteCmdlet : PSCmdlet
{
    // De-risk probe: does Microsoft.Data.Sqlite round-trip on Android? (registry durable plane)
    protected override void ProcessRecord() => WriteObject(Subsystem.SqliteProbe.SmokeTest());
}

[Cmdlet(VerbsDiagnostic.Test, "Cm")]
public sealed class TestCmCmdlet : PSCmdlet
{
    // Cm (Configuration Manager / registry) self-test: capabilities persist to SQLite + rehydrate.
    protected override void ProcessRecord() => WriteObject(Subsystem.Cm.Cm.SelfTest());
}

[Cmdlet(VerbsCommon.Get, "Diagnostics")]
public sealed class GetDiagnosticsCmdlet : PSCmdlet
{
    // Dg — the Diagnostics runtime snapshot (also served at GET /diag).
    protected override void ProcessRecord() => WriteObject(Subsystem.Dg.Snapshot());
}

[Cmdlet(VerbsCommon.Get, "AndroidScreen")]
public sealed class GetAndroidScreenCmdlet : PSCmdlet
{
    // The current distilled screen frame (AGENT-SPEC §4 perception): numbered, actionable elements
    // the Broker SELECTS by id. Captured by TerminalAccessibilityService on screen change. Empty frame
    // = a11y service not connected / nothing captured yet.
    protected override void ProcessRecord() => WriteObject(Subsystem.TerminalAccessibilityService.CurrentScreenJson());
}
