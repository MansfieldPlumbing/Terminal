using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Text.RegularExpressions;

namespace Subsystem.Pwsh.Cmdlets;

internal static class AdbProcessParser
{
    public static IEnumerable<PSObject> ParsePsOutput(string output)
    {
        var lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        bool first = true;
        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed)) continue;
            if (first)
            {
                first = false;
                continue;
            }

            var parts = trimmed.Split(new[] { ' ', '\t' }, 5, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 5)
            {
                if (int.TryParse(parts[0], out int pid) && 
                    int.TryParse(parts[1], out int ppid) && 
                    int.TryParse(parts[3], out int rss))
                {
                    var obj = new PSObject();
                    obj.Properties.Add(new PSNoteProperty("PID", pid));
                    obj.Properties.Add(new PSNoteProperty("PPID", ppid));
                    obj.Properties.Add(new PSNoteProperty("User", parts[2]));
                    obj.Properties.Add(new PSNoteProperty("RSS_KB", rss));
                    obj.Properties.Add(new PSNoteProperty("Name", parts[4]));
                    yield return obj;
                }
            }
        }
    }
}

[Cmdlet(VerbsCommon.Get, "AdbProcess")]
public sealed class GetAdbProcessCmdlet : WrapperCmdlet
{
    [Parameter] public SwitchParameter Raw { get; set; }

    protected override void ProcessRecord()
    {
        var output = Subsystem.AdbCommands.Shell("ps -A -o PID,PPID,USER,RSS,NAME");
        if (Raw.IsPresent)
        {
            Emit(output);
            return;
        }

        Emit(AdbProcessParser.ParsePsOutput(output));
    }
}

[Cmdlet(VerbsCommon.Get, "AdbProp")]
public sealed class GetAdbPropCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        var output = Subsystem.AdbCommands.Shell("getprop");
        var lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        var regex = new Regex(@"^\[(.+?)\]:\s*\[(.*)\]$");
        
        var results = new List<PSObject>();
        foreach (var line in lines)
        {
            var match = regex.Match(line);
            if (match.Success)
            {
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Key", match.Groups[1].Value));
                obj.Properties.Add(new PSNoteProperty("Value", match.Groups[2].Value));
                results.Add(obj);
            }
        }
        Emit(results);
    }
}

[Cmdlet(VerbsCommon.Get, "AdbPackage")]
public sealed class GetAdbPackageCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        var output = Subsystem.AdbCommands.Shell("pm list packages -f");
        var lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        
        var results = new List<PSObject>();
        foreach (var line in lines)
        {
            if (line.StartsWith("package:"))
            {
                var withoutPrefix = line.Substring("package:".Length);
                int eqIndex = withoutPrefix.LastIndexOf('=');
                if (eqIndex > 0)
                {
                    var obj = new PSObject();
                    obj.Properties.Add(new PSNoteProperty("Package", withoutPrefix.Substring(eqIndex + 1)));
                    obj.Properties.Add(new PSNoteProperty("Apk", withoutPrefix.Substring(0, eqIndex)));
                    results.Add(obj);
                }
            }
        }
        Emit(results);
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidProcessTree")]
public sealed class GetAndroidProcessTreeCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        if (!Subsystem.AdbCommands.IsElevated)
        {
            var obj = new PSObject();
            obj.Properties.Add(new PSNoteProperty("elevated", false));
            obj.Properties.Add(new PSNoteProperty("processes", Array.Empty<object>()));
            Emit(obj);
            return;
        }

        var output = Subsystem.AdbCommands.Shell("ps -A -o PID,PPID,USER,RSS,NAME");
        var processes = new List<PSObject>();
        foreach (var p in AdbProcessParser.ParsePsOutput(output))
        {
            var treeProc = new PSObject();
            treeProc.Properties.Add(new PSNoteProperty("id", p.Properties["PID"].Value.ToString()));
            treeProc.Properties.Add(new PSNoteProperty("name", p.Properties["Name"].Value));
            treeProc.Properties.Add(new PSNoteProperty("cpu", 0));
            
            double rssKb = Convert.ToDouble(p.Properties["RSS_KB"].Value);
            treeProc.Properties.Add(new PSNoteProperty("memory", Math.Round(rssKb / 1024.0, 1)));
            treeProc.Properties.Add(new PSNoteProperty("disk", 0));
            treeProc.Properties.Add(new PSNoteProperty("network", 0));
            treeProc.Properties.Add(new PSNoteProperty("user", p.Properties["User"].Value));
            treeProc.Properties.Add(new PSNoteProperty("ppid", p.Properties["PPID"].Value.ToString()));
            processes.Add(treeProc);
        }

        var result = new PSObject();
        result.Properties.Add(new PSNoteProperty("elevated", true));
        result.Properties.Add(new PSNoteProperty("processes", processes.ToArray()));
        Emit(result);
    }
}

[Cmdlet(VerbsLifecycle.Stop, "AndroidProcess")]
public sealed class StopAndroidProcessCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public int ProcessId { get; set; }

    protected override void ProcessRecord()
    {
        var output = Subsystem.AdbCommands.Shell($"kill {ProcessId} 2>&1");
        var obj = new PSObject();
        if (string.IsNullOrWhiteSpace(output))
        {
            obj.Properties.Add(new PSNoteProperty("ok", true));
            obj.Properties.Add(new PSNoteProperty("message", $"Killed PID {ProcessId}"));
        }
        else
        {
            obj.Properties.Add(new PSNoteProperty("ok", false));
            obj.Properties.Add(new PSNoteProperty("message", output.Trim()));
        }
        Emit(obj);
    }
}

[Cmdlet(VerbsCommon.Get, "AndroidStartup")]
public sealed class GetAndroidStartupCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord()
    {
        var output = Subsystem.AdbCommands.Shell("cmd package query-receivers --brief -a android.intent.action.BOOT_COMPLETED");
        var lines = output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        int prio = 0;
        var results = new List<PSObject>();
        
        var prioRegex = new Regex(@"priority=(-?\d+)");
        foreach (var line in lines)
        {
            var match = prioRegex.Match(line);
            if (match.Success)
            {
                if (int.TryParse(match.Groups[1].Value, out int p))
                {
                    prio = p;
                }
            }
            else if (line.Contains("/") && !line.Contains("=") && !string.IsNullOrWhiteSpace(line))
            {
                var c = line.Trim();
                var pkg = c.Split(new[] { '/' }, 2)[0];
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("package", pkg));
                obj.Properties.Add(new PSNoteProperty("receiver", c));
                obj.Properties.Add(new PSNoteProperty("label", pkg));
                obj.Properties.Add(new PSNoteProperty("priority", prio));
                obj.Properties.Add(new PSNoteProperty("enabled", true));
                obj.Properties.Add(new PSNoteProperty("impact", "unknown"));
                results.Add(obj);
            }
        }
        Emit(results);
    }
}

[Cmdlet(VerbsCommon.Set, "AndroidStartup")]
public sealed class SetAndroidStartupCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true)] public string Receiver { get; set; } = string.Empty;
    [Parameter(Mandatory = true)] public bool Enabled { get; set; }

    protected override void ProcessRecord()
    {
        string verb = Enabled ? "enable" : "disable";
        var output = Subsystem.AdbCommands.Shell($"pm {verb} {Receiver} 2>&1");
        
        var obj = new PSObject();
        obj.Properties.Add(new PSNoteProperty("ok", output.Contains("new state")));
        obj.Properties.Add(new PSNoteProperty("message", output.Trim()));
        Emit(obj);
    }
}
