using System;
using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

[Cmdlet(VerbsLifecycle.Invoke, "RdConsult")]
public sealed class InvokeRdConsultCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)]
    public string Question { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            var obj = new PSObject();
            obj.Properties.Add(new PSNoteProperty("tool", "rd_consult"));
            obj.Properties.Add(new PSNoteProperty("status", "driver-pending"));
            obj.Properties.Add(new PSNoteProperty("question", Question));
            obj.Properties.Add(new PSNoteProperty("answer", null));
            obj.Properties.Add(new PSNoteProperty("note", "The Rd browse driver is not running on this host yet (WebView on Android / WebView2 host on Windows)."));
            Emit(obj);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "InvokeRdConsultFailed", ErrorCategory.InvalidOperation, Question));
        }
    }
}
