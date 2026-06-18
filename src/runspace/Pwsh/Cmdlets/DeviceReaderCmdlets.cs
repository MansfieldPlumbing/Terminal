using System.Management.Automation;

namespace Subsystem.Pwsh.Cmdlets;

// Compiled device-introspection cmdlets over the \Device\Android\* reader drivers (SS001 graduation +
// Stage-2 decompose). Each wraps a proven driver method; the cmdlet->driver reference is now compiler-
// checked C# instead of a runtime string.

[Cmdlet(VerbsCommon.Get, "AndroidBattery")]
public sealed class GetAndroidBatteryCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Power.GetBatteryStatus());
}

[Cmdlet(VerbsCommon.Get, "AndroidDevice")]
public sealed class GetAndroidDeviceCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Info.GetDeviceInfo());
}

[Cmdlet(VerbsCommon.Get, "AndroidStorage")]
public sealed class GetAndroidStorageCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Storage.GetStorageInfo());
}

[Cmdlet(VerbsCommon.Get, "AndroidMemory")]
public sealed class GetAndroidMemoryCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Memory.GetMemoryInfo());
}

[Cmdlet(VerbsCommon.Get, "AndroidSensor")]
public sealed class GetAndroidSensorCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Sensors.GetSensors());
}

[Cmdlet(VerbsCommon.Get, "AndroidNetwork")]
public sealed class GetAndroidNetworkCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(Subsystem.Device.Network.GetNetworkInfo());
}
