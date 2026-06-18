using System;
using System.Collections.Generic;
using System.Management.Automation;
using Subsystem;

namespace Subsystem.Pwsh.Cmdlets;

internal static class SessionCmdletsHelper
{
    public static void SetSessionBackgroundHelper(PSCmdlet cmdlet, string name, bool enabled)
    {
        var s = SessionManager.Get(name);
        if (s != null)
        {
            s.Background = enabled;
            cmdlet.Host.UI.WriteLine(
                ConsoleColor.Cyan,
                cmdlet.Host.UI.RawUI.BackgroundColor,
                $"Session '{name}' background={enabled}");
        }
        else
        {
            cmdlet.Host.UI.WriteLine(
                ConsoleColor.Red,
                cmdlet.Host.UI.RawUI.BackgroundColor,
                $"No session '{name}'");
        }
    }
}

[Cmdlet(VerbsCommon.New, "Session")]
public sealed class NewSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Name { get; set; } = string.Empty;

    [Parameter]
    public SwitchParameter Background { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            SessionManager.Create(Name, Background.IsPresent);
            Host.UI.WriteLine(
                ConsoleColor.Green,
                Host.UI.RawUI.BackgroundColor,
                $"Session '{Name}' ready{(Background.IsPresent ? " (background)" : "")}");
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "NewSessionFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}

[Cmdlet(VerbsCommon.Get, "Session")]
public sealed class GetSessionCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try
        {
            var sessions = SessionManager.List();
            var results = new List<PSObject>();
            foreach (var s in sessions)
            {
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Name", s.Name));
                obj.Properties.Add(new PSNoteProperty("Background", s.Background));
                obj.Properties.Add(new PSNoteProperty("Busy", s.Busy));
                obj.Properties.Add(new PSNoteProperty("Created", s.Created));
                obj.Properties.Add(new PSNoteProperty("LastUsed", s.LastUsed));
                results.Add(obj);
            }
            Emit(results);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "GetSessionFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}

[Cmdlet(VerbsLifecycle.Invoke, "Session")]
public sealed class InvokeSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Name { get; set; } = string.Empty;

    [Parameter(Mandatory = true, Position = 1, ValueFromRemainingArguments = true)]
    public string[] Command { get; set; } = Array.Empty<string>();

    protected override void ProcessRecord()
    {
        try
        {
            var s = SessionManager.GetOrCreate(Name);
            var result = s.Invoke(string.Join(" ", Command));
            Emit(result);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "InvokeSessionFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}

[Cmdlet(VerbsCommon.Set, "SessionBackground")]
public sealed class SetSessionBackgroundCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Name { get; set; } = string.Empty;

    [Parameter]
    public bool Enabled { get; set; } = true;

    protected override void ProcessRecord()
    {
        try
        {
            SessionCmdletsHelper.SetSessionBackgroundHelper(this, Name, Enabled);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "SetSessionBackgroundFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}

[Cmdlet("Detach", "Session")]
public sealed class DetachSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Name { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            SessionCmdletsHelper.SetSessionBackgroundHelper(this, Name, true);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "DetachSessionFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}

// --- PSRP sessions (Rs — \Capability\Remoting\Psrp). Same verbs, different transport: these are
//     remote runspaces over the Subsystem.Psrp named pipe, VOM-owned under \Sessions\Psrp\{id}. ---

[Cmdlet(VerbsCommon.Get, "PsrpSession")]
public sealed class GetPsrpSessionCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try
        {
            var results = new List<PSObject>();
            foreach (var s in Rs.List())
            {
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Id", s.Id));
                obj.Properties.Add(new PSNoteProperty("Owner", s.OwnerTag));
                obj.Properties.Add(new PSNoteProperty("State", s.State));
                obj.Properties.Add(new PSNoteProperty("Busy", s.Busy));
                obj.Properties.Add(new PSNoteProperty("Created", s.Created));
                obj.Properties.Add(new PSNoteProperty("LastUsed", s.LastUsed));
                obj.Properties.Add(new PSNoteProperty("Pipe", Rs.PipeName));
                results.Add(obj);
            }
            Emit(results);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "GetPsrpSessionFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}

[Cmdlet(VerbsCommon.Remove, "PsrpSession")]
public sealed class RemovePsrpSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Id { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            Emit(Rs.Close(Id));
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "RemovePsrpSessionFailed", ErrorCategory.InvalidOperation, Id));
        }
    }
}

[Cmdlet(VerbsCommon.Remove, "Session")]
public sealed class RemoveSessionCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Name { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            if (SessionManager.Remove(Name))
            {
                Host.UI.WriteLine(ConsoleColor.Yellow, Host.UI.RawUI.BackgroundColor, $"Removed session '{Name}'");
            }
            else
            {
                Host.UI.WriteLine(ConsoleColor.Red, Host.UI.RawUI.BackgroundColor, $"No session '{Name}'");
            }
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "RemoveSessionFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}
