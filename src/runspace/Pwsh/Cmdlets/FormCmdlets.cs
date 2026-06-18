using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

[Cmdlet(VerbsCommon.Show, "Command")]
public sealed class ShowCommandCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)]
    public string Name { get; set; } = string.Empty;

    private static readonly HashSet<string> ExcludedParameters = new(StringComparer.OrdinalIgnoreCase)
    {
        "Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction",
        "ErrorVariable", "WarningVariable", "InformationVariable", "OutVariable",
        "OutBuffer", "PipelineVariable"
    };

    protected override void ProcessRecord()
    {
        try
        {
            CommandInfo? cmd = null;
            try
            {
                cmd = SessionState.InvokeCommand.GetCommand(Name, CommandTypes.All);
            }
            catch (Exception ex)
            {
                Subsystem.Dg.Log("form", $"GetCommand failed: {ex.Message}");
            }

            if (cmd == null)
            {
                throw new InvalidOperationException($"Command not found: {Name}");
            }

            var fields = new List<PSObject>();
            foreach (var p in cmd.Parameters.Values)
            {
                if (ExcludedParameters.Contains(p.Name)) continue;

                string type = "text";
                string[]? options = null;

                if (p.ParameterType.Name == "SwitchParameter")
                {
                    type = "switch";
                }
                else if (p.ParameterType.Name == "Int32" || p.ParameterType.Name == "Int64" || p.ParameterType.Name == "Double")
                {
                    type = "int";
                }

                foreach (var attr in p.Attributes)
                {
                    if (attr is ValidateSetAttribute valSet)
                    {
                        type = "select";
                        options = valSet.ValidValues.ToArray();
                    }
                }

                var field = new PSObject();
                field.Properties.Add(new PSNoteProperty("name", p.Name));
                field.Properties.Add(new PSNoteProperty("type", type));
                if (options != null)
                {
                    field.Properties.Add(new PSNoteProperty("options", options));
                }
                fields.Add(field);
            }

            var form = new PSObject();
            form.Properties.Add(new PSNoteProperty("_type", "InteractiveForm"));
            form.Properties.Add(new PSNoteProperty("command", Name));
            form.Properties.Add(new PSNoteProperty("title", $"Execute: {Name}"));
            form.Properties.Add(new PSNoteProperty("fields", fields.ToArray()));

            Emit(form);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "ShowCommandFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}

[Cmdlet(VerbsCommon.Get, "Help")]
public sealed class GetHelpCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)]
    public string? Name { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            if (string.IsNullOrEmpty(Name))
            {
                Host.UI.WriteLine(ConsoleColor.Cyan, Host.UI.RawUI.BackgroundColor, "Usage: Get-Help <topic>");
                Host.UI.WriteLine(ConsoleColor.Gray, Host.UI.RawUI.BackgroundColor, "Available topics include about_* help files.");
                return;
            }

            string helpText = Subsystem.HelpSystem.GetHelp(Name);
            if (helpText.StartsWith("Multiple topics match") || helpText.StartsWith("Usage:"))
            {
                Host.UI.WriteLine(ConsoleColor.Yellow, Host.UI.RawUI.BackgroundColor, helpText);
            }
            else if (helpText.StartsWith("Help topic") && helpText.EndsWith("not found."))
            {
                WriteWarning(helpText);
            }
            else
            {
                Emit(helpText);
            }
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "GetHelpFailed", ErrorCategory.InvalidOperation, Name));
        }
    }
}
