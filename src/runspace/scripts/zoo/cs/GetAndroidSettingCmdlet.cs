using System.Management.Automation;
using System.Collections.Generic;
using Subsystem.Pwsh.Cmdlets;

namespace Subsystem.Pwsh.Cmdlets.Zoo;

[Cmdlet(VerbsCommon.Get, "AndroidSetting")]
public sealed class GetAndroidSettingCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)]
    public string? Key { get; set; }

    [Parameter(Position = 1)]
    [ValidateSet("global", "system", "secure")]
    public string Scope { get; set; } = "global";

    protected override void ProcessRecord()
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(Key))
            {
                string raw = AdbCommands.Shell($"settings get {Scope} {Key}");
                string val = raw.Trim();
                if (val == "null")
                {
                    Emit(null);
                }
                else
                {
                    Emit(val);
                }
            }
            else
            {
                string raw = AdbCommands.Shell($"settings list {Scope}");
                var dict = new Dictionary<string, string>(System.StringComparer.OrdinalIgnoreCase);
                var lines = raw.Split(new[] { "\r\n", "\r", "\n" }, System.StringSplitOptions.RemoveEmptyEntries);
                foreach (var line in lines)
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0)
                    {
                        string k = line.Substring(0, eq).Trim();
                        string v = line.Substring(eq + 1).Trim();
                        dict[k] = v;
                    }
                }
                Emit(dict);
            }
        }
        catch (System.Exception ex)
        {
            Emit(new Dictionary<string, object> { ["Error"] = ex.Message });
        }
    }
}
