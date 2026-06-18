using System.Management.Automation;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Subsystem.Pwsh.Cmdlets;

namespace Subsystem.Pwsh.Cmdlets.Zoo;

[Cmdlet(VerbsCommon.Get, "AndroidCpu")]
public sealed class GetAndroidCpuCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        var result = new Dictionary<string, object>();
        try
        {
            string raw = AdbCommands.Shell("dumpsys cpuinfo");
            var lines = raw.Split(new[] { "\r\n", "\r", "\n" }, System.StringSplitOptions.RemoveEmptyEntries);

            string? load = null;
            if (lines.Length > 0)
            {
                var loadMatch = Regex.Match(lines[0], @"Load:\s*(.*)");
                if (loadMatch.Success) load = loadMatch.Groups[1].Value.Trim();
            }

            string? totalCpu = null;
            foreach (var line in lines)
            {
                var totalMatch = Regex.Match(line, @"^\s*([0-9.]+%)\s*TOTAL:");
                if (totalMatch.Success)
                {
                    totalCpu = totalMatch.Groups[1].Value;
                    break;
                }
            }

            var procList = new List<Dictionary<string, string>>();
            foreach (var line in lines)
            {
                var procMatch = Regex.Match(line, @"^\s*([0-9.]+%)\s+(\d+)/([^:]+):\s*(.*)$");
                if (procMatch.Success)
                {
                    procList.Add(new Dictionary<string, string>
                    {
                        ["Usage"] = procMatch.Groups[1].Value,
                        ["PID"] = procMatch.Groups[2].Value,
                        ["Name"] = procMatch.Groups[3].Value,
                        ["Details"] = procMatch.Groups[4].Value.Trim()
                    });
                }
            }

            result["Load"] = load ?? "Unknown";
            result["TotalCpu"] = totalCpu ?? "Unknown";
            result["Processes"] = procList;
        }
        catch (System.Exception ex)
        {
            result["Error"] = ex.Message;
        }
        Emit(result);
    }
}
