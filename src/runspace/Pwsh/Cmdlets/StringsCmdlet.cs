using System;
using System.IO;
using System.Management.Automation;
using System.Runtime.InteropServices;
using Subsystem.Device;

namespace Subsystem.Pwsh.Cmdlets;

[Cmdlet(VerbsLifecycle.Invoke, "Strings")]
public sealed class InvokeStringsCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string BinaryPath { get; set; } = string.Empty;

    [Parameter(Mandatory = true, Position = 1)]
    public string FilePath { get; set; } = string.Empty;

    [Parameter(Position = 2)]
    public int MinLength { get; set; } = 4;

    protected override void ProcessRecord()
    {
        try
        {
            string resolvedBinaryPath = BinaryPath;
            string resolvedFilePath = FilePath;

            if (!File.Exists(resolvedBinaryPath))
            {
                WriteError(new ErrorRecord(new FileNotFoundException("Binary file not found", resolvedBinaryPath), "FileNotFound", ErrorCategory.ObjectNotFound, resolvedBinaryPath));
                return;
            }

            if (!File.Exists(resolvedFilePath))
            {
                WriteError(new ErrorRecord(new FileNotFoundException("Target file not found", resolvedFilePath), "FileNotFound", ErrorCategory.ObjectNotFound, resolvedFilePath));
                return;
            }

            Console.WriteLine($"[INFO][hle] Initializing PE Loader for \\Device\\Android\\FileSystem\\{Path.GetFileName(resolvedBinaryPath)}");

            var loader = new PeLoader();
            loader.Load(resolvedBinaryPath);

            // Construct command line: strings.exe -n <MinLength> <FilePath>
            string cmdLine = $"strings.exe -n {MinLength} \"{resolvedFilePath}\"";
            loader.SetCommandLine(cmdLine);

            int exitCode = loader.Execute();
            Emit($"Execution finished with exit code: {exitCode}");
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(new Exception(ex.ToString()), "ExecutionFailed", ErrorCategory.NotSpecified, null));
        }
    }
}
