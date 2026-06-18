using System;

namespace Subsystem;

// The bridge between the PowerShell cmdlet surface and the elevated adb channel (SubsystemService.
// ElevatedAdb, established by the loopback pair+connect). Invoke-AdbShell runs a command as uid=2000;
// the object-returning cmdlets (Get-AdbProcess/Get-AdbProp/Get-AdbPackage) are PowerShell that parses
// this raw output into PSObjects — that's the "superior to adb" surface (adb returns strings, we pipe).
public static class AdbCommands
{
    public static bool IsElevated => SubsystemService.ElevatedAdb != null;

    // Run a shell command over the elevated channel and return its stdout. Throws if not connected.
    public static string Shell(string command)
    {
        var conn = SubsystemService.ElevatedAdb
            ?? throw new InvalidOperationException(
                "No elevated adb connection. Pair (wireless debugging) then connect first.");
        return conn.ExecuteShellAsync(command).GetAwaiter().GetResult();
    }
}
