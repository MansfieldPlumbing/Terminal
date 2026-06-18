using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

// Compiled device-surface cmdlets over the \Device\Android\* surface drivers (SS001 graduation +
// Stage-2 decompose). cmdlet->driver references are compiler-checked C#.

[Cmdlet(VerbsCommon.Get, "Clipboard")]
public sealed class GetClipboardCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Clipboard.GetClipboardText());
}

[Cmdlet(VerbsCommon.Set, "Clipboard")]
public sealed class SetClipboardCmdlet : PSCmdlet
{
    [Parameter(Mandatory = true, ValueFromPipeline = true)] public string Text { get; set; } = string.Empty;
    protected override void ProcessRecord() => Subsystem.Device.Clipboard.SetClipboardText(Text);
}

[Cmdlet(VerbsCommon.Get, "AndroidMessage")]
public sealed class GetAndroidMessageCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Notifications.GetAndroidMessages());
}

[Cmdlet(VerbsCommon.Get, "AndroidDisplay")]
public sealed class GetAndroidDisplayCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Display.GetDisplayInfo());
}

[Cmdlet(VerbsCommon.Get, "Screenshot")]
public sealed class GetScreenshotCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Display.GetScreenshot());
}

[Cmdlet(VerbsCommon.Get, "InstalledApp")]
public sealed class GetInstalledAppCmdlet : WrapperCmdlet
{
    [Parameter] public SwitchParameter IncludeSystem { get; set; }
    protected override void ProcessRecord() => Emit(Subsystem.Device.Apps.GetInstalledApps(IncludeSystem.IsPresent));
}

[Cmdlet(VerbsCommunications.Send, "AndroidNotification")]
public sealed class SendAndroidNotificationCmdlet : PSCmdlet
{
    [Parameter(Mandatory = true)] public string Title { get; set; } = string.Empty;
    [Parameter(Mandatory = true)] public string Text { get; set; } = string.Empty;
    protected override void ProcessRecord() => Subsystem.Device.Notifications.SendNotification(Title, Text);
}

[Cmdlet(VerbsLifecycle.Start, "AndroidIntent")]
public sealed class StartAndroidIntentCmdlet : PSCmdlet
{
    [Parameter(Mandatory = true)] public string Uri { get; set; } = string.Empty;
    protected override void ProcessRecord() => Subsystem.Device.Shell.StartIntent(Uri);
}

[Cmdlet(VerbsCommon.Show, "Toast")]
public sealed class ShowToastCmdlet : PSCmdlet
{
    [Parameter(Mandatory = true)] public string Message { get; set; } = string.Empty;
    [Parameter] public SwitchParameter Long { get; set; }
    protected override void ProcessRecord() => Subsystem.Device.Shell.ShowToast(Message, Long.IsPresent);
}
