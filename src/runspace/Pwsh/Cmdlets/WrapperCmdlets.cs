using System.Collections;
using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

// Base for compiled pillar cmdlets that wrap a proven static entry point (SS001 graduation).
// Emit reproduces PowerShell's pipeline-output semantics faithfully: enumerate collections, but treat a
// string as a single value (NOT a char sequence), and drop nulls — so behavior matches the old script body.
public abstract class WrapperCmdlet : PSCmdlet
{
    protected void Emit(object? value)
    {
        if (value is null) return;
        if (value is string s) { WriteObject(s); return; }
        // PowerShell does NOT unroll a dictionary/hashtable in the pipeline — it passes as one object.
        if (value is System.Collections.IDictionary dict) { WriteObject(dict); return; }
        if (value is IEnumerable e) { WriteObject(e, enumerateCollection: true); return; }
        WriteObject(value);
    }
}

// --- The front door: make a \Shell\FrontDoor swap take effect (reloads the shell WebView).
//     Swap the door first: Register-Capability -Path \Shell\FrontDoor … (file = the new .obp). ---
[Cmdlet(VerbsLifecycle.Invoke, "ShellReload")]
public sealed class InvokeShellReloadCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        Subsystem.MainActivity.Instance?.ReloadShell();
        Emit(true);
    }
}

// --- The eye (Task Manager): VOM owner/handle enumeration ---
[Cmdlet(VerbsCommon.Get, "VomOwner")]
public sealed class GetVomOwnerCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Vom.Vom.EnumerateOwners());
}

[Cmdlet(VerbsCommon.Get, "VomThread")]
public sealed class GetVomThreadCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Vom.Vom.EnumerateThreads());
}

[Cmdlet(VerbsLifecycle.Stop, "VomThread")]
public sealed class StopVomThreadCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public string HandleId { get; set; } = string.Empty;
    protected override void ProcessRecord() => Emit(Subsystem.Vom.Vom.StopThread(HandleId));
}

// --- Cm (registry) reads ---
[Cmdlet(VerbsCommon.Get, "Capability")]
public sealed class GetCapabilityCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)] public string? Path { get; set; }
    protected override void ProcessRecord()
        => Emit(string.IsNullOrEmpty(Path) ? Subsystem.Cm.Cm.List() : Subsystem.Cm.Cm.Get(Path));
}

[Cmdlet(VerbsLifecycle.Unregister, "Capability")]
public sealed class UnregisterCapabilityCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public string Path { get; set; } = string.Empty;
    protected override void ProcessRecord() => Emit(Subsystem.Cm.Cm.Unregister(Path));
}

// --- Object-oriented adb ---
[Cmdlet(VerbsDiagnostic.Test, "AdbElevated")]
public sealed class TestAdbElevatedCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.AdbCommands.IsElevated);
}

[Cmdlet(VerbsLifecycle.Invoke, "AdbShell")]
public sealed class InvokeAdbShellCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public string Command { get; set; } = string.Empty;
    protected override void ProcessRecord() => Emit(Subsystem.AdbCommands.Shell(Command));
}

// --- Saved chats (Agent sessions as Cm objects) ---
[Cmdlet(VerbsCommon.Get, "AgentSession")]
public sealed class GetAgentSessionCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)] public string? Id { get; set; }
    protected override void ProcessRecord()
        => Emit(string.IsNullOrEmpty(Id)
            ? Subsystem.RuntimeBroker.AgentSessionTable.ListSummaries()
            : Subsystem.RuntimeBroker.AgentSessionTable.LoadJson(Id));
}

[Cmdlet(VerbsCommon.New, "AgentSession")]
public sealed class NewAgentSessionCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)] public string? Title { get; set; }
    protected override void ProcessRecord() => Emit(Subsystem.RuntimeBroker.AgentSessionTable.Create(Title));
}

[Cmdlet(VerbsCommon.Remove, "AgentSession")]
public sealed class RemoveAgentSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)] public string Id { get; set; } = string.Empty;
    protected override void ProcessRecord() => Emit(Subsystem.RuntimeBroker.AgentSessionTable.Delete(Id));
}

[Cmdlet(VerbsCommon.Rename, "AgentSession")]
public sealed class RenameAgentSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)] public string Id { get; set; } = string.Empty;
    [Parameter(Mandatory = true, Position = 1)] public string Title { get; set; } = string.Empty;
    protected override void ProcessRecord() => Emit(Subsystem.RuntimeBroker.AgentSessionTable.Rename(Id, Title));
}

// --- Package metadata ---
[Cmdlet(VerbsCommon.Get, "PackageInfo")]
public sealed class GetPackageInfoCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public string Package { get; set; } = string.Empty;
    protected override void ProcessRecord() => Emit(Subsystem.PackageInfoDb.Lookup(Package));
}
