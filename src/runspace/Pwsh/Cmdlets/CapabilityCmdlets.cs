using System;
using System.Management.Automation;
using Subsystem.Cm;

namespace Subsystem.Pwsh.Cmdlets;

[Cmdlet(VerbsLifecycle.Register, "Capability")]
public sealed class RegisterCapabilityCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)]
    public string Path { get; set; } = string.Empty;

    [Parameter(Mandatory = true)]
    public string Name { get; set; } = string.Empty;

    [Parameter]
    public string Type { get; set; } = "Capability";

    [Parameter]
    public string? Source { get; set; }

    [Parameter]
    public string? Manifest { get; set; }

    [Parameter]
    [ValidateSet("System", "Admin", "User", "Untrusted")]
    public string Integrity { get; set; } = "User";

    [Parameter]
    [ValidateSet("auto", "manual", "disabled")]
    public string StartType { get; set; } = "manual";

    [Parameter]
    public SwitchParameter Enabled { get; set; }

    [Parameter]
    public string[] DependsOn { get; set; } = Array.Empty<string>();

    protected override void ProcessRecord()
    {
        try
        {
            var record = new CapabilityRecord
            {
                Path = Path,
                Name = Name,
                Type = Type,
                Source = Source,
                ManifestJson = Manifest,
                Integrity = Integrity,
                StartType = StartType,
                Enabled = Enabled.IsPresent,
                DependsOn = DependsOn
            };

            var result = Subsystem.Cm.Cm.Register(record);
            Emit(result);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "RegisterCapabilityFailed", ErrorCategory.InvalidOperation, Path));
        }
    }
}

[Cmdlet(VerbsCommon.Set, "Capability")]
public sealed class SetCapabilityCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)]
    public string Path { get; set; } = string.Empty;

    [Parameter]
    public bool Enabled { get; set; }

    [Parameter]
    public string? StartType { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            bool? enabledOrNull = null;
            if (MyInvocation.BoundParameters.ContainsKey("Enabled"))
            {
                enabledOrNull = Enabled;
            }

            var result = Subsystem.Cm.Cm.Set(Path, enabledOrNull, StartType);
            Emit(result);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "SetCapabilityFailed", ErrorCategory.InvalidOperation, Path));
        }
    }
}
