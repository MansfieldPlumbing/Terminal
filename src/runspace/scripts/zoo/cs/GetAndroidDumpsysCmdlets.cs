using System.Management.Automation;
using System.Collections.Generic;
using Subsystem.Pwsh.Cmdlets;

namespace Subsystem.Pwsh.Cmdlets.Zoo;

[Cmdlet(VerbsCommon.Get, "AndroidThermal")]
public sealed class GetAndroidThermalCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try { Emit(DumpsysTreeParser.Parse(AdbCommands.Shell("dumpsys thermalservice"))); }
        catch (System.Exception ex) { Emit(new Dictionary<string, object> { ["Error"] = ex.Message }); }
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidAlarm")]
public sealed class GetAndroidAlarmCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try { Emit(DumpsysTreeParser.Parse(AdbCommands.Shell("dumpsys alarm"))); }
        catch (System.Exception ex) { Emit(new Dictionary<string, object> { ["Error"] = ex.Message }); }
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidJob")]
public sealed class GetAndroidJobCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try { Emit(DumpsysTreeParser.Parse(AdbCommands.Shell("dumpsys jobscheduler"))); }
        catch (System.Exception ex) { Emit(new Dictionary<string, object> { ["Error"] = ex.Message }); }
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidDeviceIdle")]
public sealed class GetAndroidDeviceIdleCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try { Emit(DumpsysTreeParser.Parse(AdbCommands.Shell("dumpsys deviceidle"))); }
        catch (System.Exception ex) { Emit(new Dictionary<string, object> { ["Error"] = ex.Message }); }
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidNetstat")]
public sealed class GetAndroidNetstatCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        try { Emit(DumpsysTreeParser.Parse(AdbCommands.Shell("netstat -an"))); }
        catch (System.Exception ex) { Emit(new Dictionary<string, object> { ["Error"] = ex.Message }); }
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidGfx")]
public sealed class GetAndroidGfxCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)]
    public string? Package { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            string cmd = "dumpsys gfxinfo";
            if (!string.IsNullOrWhiteSpace(Package)) cmd += $" {Package}";
            Emit(DumpsysTreeParser.Parse(AdbCommands.Shell(cmd)));
        }
        catch (System.Exception ex) { Emit(new Dictionary<string, object> { ["Error"] = ex.Message }); }
    }
}
