using System.Management.Automation;

namespace Subsystem;

[Cmdlet(VerbsLifecycle.Start, "ScreenCapture")]
public class StartScreenCaptureCommand : PSCmdlet
{
    protected override void ProcessRecord()
    {
        // The Android host/context is the live MainActivity singleton (\Device drivers reach it the same way).
        if (MainActivity.Instance != null) {
            MainActivity.Instance.StartScreenCapture();
            WriteObject("Screen capture intent requested on device.");
        } else {
            WriteError(new ErrorRecord(new System.Exception("MainActivity not found."), "NoActivity", ErrorCategory.InvalidOperation, null));
        }
    }
}
