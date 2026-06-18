using System;
using System.Management.Automation;
using Subsystem;

namespace Subsystem.Pwsh.Cmdlets;

[Cmdlet(VerbsCommon.Get, "AgentSettings")]
public sealed class GetAgentSettingsCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try
        {
            var context = MainActivity.Instance;
            if (context == null)
            {
                throw new InvalidOperationException("MainActivity.Instance is not initialized.");
            }

            var obj = new PSObject();
            obj.Properties.Add(new PSNoteProperty("ChatContext", AgentSettings.UseChatContext(context)));
            obj.Properties.Add(new PSNoteProperty("SystemContext", AgentSettings.UseSystemContext(context)));
            Emit(obj);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "GetAgentSettingsFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}

// --- The agent's model — a projection of \Capability\Model\* (the registry is the truth;
//     discovery registers sideloaded files; Set switches the active selection and reloads). ---

[Cmdlet(VerbsCommon.Get, "AgentModel")]
public sealed class GetAgentModelCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try
        {
            var context = MainActivity.Instance
                ?? throw new InvalidOperationException("MainActivity.Instance is not initialized.");
            var activeId = ModelCatalog.Active(context).Id;
            var results = new System.Collections.Generic.List<PSObject>();
            foreach (var spec in ModelCatalog.All(context))
            {
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Id", spec.Id));
                obj.Properties.Add(new PSNoteProperty("Name", spec.DisplayName));
                obj.Properties.Add(new PSNoteProperty("Format", spec.Format));
                obj.Properties.Add(new PSNoteProperty("File", spec.FileName));
                obj.Properties.Add(new PSNoteProperty("Present", ModelCatalog.IsPresent(context, spec)));
                obj.Properties.Add(new PSNoteProperty("Active", string.Equals(spec.Id, activeId, StringComparison.OrdinalIgnoreCase)));
                obj.Properties.Add(new PSNoteProperty("Discovered", spec.Discovered));
                obj.Properties.Add(new PSNoteProperty("Downloadable", spec.Downloadable));
                results.Add(obj);
            }
            Emit(results);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "GetAgentModelFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}

[Cmdlet(VerbsCommon.Set, "AgentModel")]
public sealed class SetAgentModelCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string Id { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            var context = MainActivity.Instance
                ?? throw new InvalidOperationException("MainActivity.Instance is not initialized.");
            // §6 transactional selection: blocks until the successor is verified serviceable (or
            // throws the typed fault after failover). Engine bring-up is ~10 s of native work.
            var spec = ModelCatalog.SelectAsync(context, Id).GetAwaiter().GetResult();
            Host.UI.WriteLine(
                ConsoleColor.Cyan,
                Host.UI.RawUI.BackgroundColor,
                $"Active model -> {spec.DisplayName} ({spec.Id}); verified serviceable");
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "SetAgentModelFailed", ErrorCategory.InvalidOperation, Id));
        }
    }
}

[Cmdlet(VerbsCommon.Set, "AgentContext")]
public sealed class SetAgentContextCmdlet : WrapperCmdlet
{
    [Parameter]
    public bool Chat { get; set; } = true;

    [Parameter]
    public bool System { get; set; } = false;

    protected override void ProcessRecord()
    {
        try
        {
            var context = MainActivity.Instance;
            if (context == null)
            {
                throw new InvalidOperationException("MainActivity.Instance is not initialized.");
            }

            AgentSettings.SetUseChatContext(context, Chat);
            AgentSettings.SetUseSystemContext(context, System);

            Host.UI.WriteLine(
                ConsoleColor.Cyan,
                Host.UI.RawUI.BackgroundColor,
                $"Agent context -> chat={Chat} system={System}");
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "SetAgentContextFailed", ErrorCategory.InvalidOperation, null));
        }
    }
}
