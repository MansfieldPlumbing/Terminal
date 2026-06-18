using System;
using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

// Compiled device-actuator cmdlets over the \Device\Android\* actuator drivers (SS001 graduation +
// Stage-2 decompose). cmdlet->driver references are compiler-checked C#, not runtime strings.

[Cmdlet(VerbsLifecycle.Invoke, "Vibration")]
public sealed class InvokeVibrationCmdlet : PSCmdlet
{
    [Parameter] public int Duration { get; set; } = 200;
    protected override void ProcessRecord() => Subsystem.Device.Haptics.Vibrate(Duration);
}

[Cmdlet(VerbsLifecycle.Invoke, "AndroidTap")]
public sealed class InvokeAndroidTapCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public float X { get; set; }
    [Parameter(Mandatory = true)] public float Y { get; set; }
    protected override void ProcessRecord() => Emit(Subsystem.Device.Input.InvokeTap(X, Y));
}

[Cmdlet(VerbsLifecycle.Invoke, "AndroidSwipe")]
public sealed class InvokeAndroidSwipeCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public float X1 { get; set; }
    [Parameter(Mandatory = true)] public float Y1 { get; set; }
    [Parameter(Mandatory = true)] public float X2 { get; set; }
    [Parameter(Mandatory = true)] public float Y2 { get; set; }
    [Parameter] public long DurationMs { get; set; } = 300;
    protected override void ProcessRecord() => Emit(Subsystem.Device.Input.InvokeSwipe(X1, Y1, X2, Y2, DurationMs));
}

[Cmdlet(VerbsCommon.Set, "Flashlight")]
public sealed class SetFlashlightCmdlet : PSCmdlet
{
    [Parameter(Position = 0)]
    [ValidateSet("On", "Off", "Toggle")]
    public string State { get; set; } = "Toggle";
    [Parameter] public int DurationSeconds { get; set; } = 0;   // kept for signature compatibility
    [Parameter] public SwitchParameter Strobe { get; set; }     // kept for signature compatibility
    protected override void ProcessRecord()
    {
        Subsystem.Device.Torch.SetFlashlight(State);
        Host.UI.WriteLine(ConsoleColor.Yellow, Host.UI.RawUI.BackgroundColor, $"Flashlight: {State}");
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidVolume")]
public sealed class GetAndroidVolumeCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Audio.GetAudioVolume());
}

[Cmdlet(VerbsCommon.Set, "AndroidVolume")]
public sealed class SetAndroidVolumeCmdlet : PSCmdlet
{
    [Parameter]
    [ValidateSet("Media", "Ring", "Alarm")]
    public string Stream { get; set; } = "Media";
    [Parameter] public int Level { get; set; }
    protected override void ProcessRecord() => Subsystem.Device.Audio.SetAudioVolume(Stream, Level);
}

[Cmdlet(VerbsLifecycle.Invoke, "Beep")]
public sealed class InvokeBeepCmdlet : PSCmdlet
{
    protected override void ProcessRecord() => Subsystem.Device.Audio.PlayBeep();
}
