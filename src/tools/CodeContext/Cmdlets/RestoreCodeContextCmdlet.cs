using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Management.Automation;
using System.Collections.Generic;

namespace Subsystem.Tools.CodeContext.Cmdlets;

[Cmdlet(VerbsData.Restore, "CodeContext", SupportsShouldProcess = true)]
public class RestoreCodeContextCmdlet : PSCmdlet
{
    [Parameter(Position = 0, Mandatory = true, ValueFromPipeline = true)]
    public string Path { get; set; } = string.Empty;

    [Parameter(Position = 1, Mandatory = true)]
    public string DestinationFolder { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        string fullPath = System.IO.Path.GetFullPath(Path);
        if (!File.Exists(fullPath))
        {
            ThrowTerminatingError(new ErrorRecord(new FileNotFoundException(), "FileNotFound", ErrorCategory.ObjectNotFound, Path));
        }

        string[] lines;
        try
        {
            lines = File.ReadAllLines(fullPath);
        }
        catch (Exception ex)
        {
            ThrowTerminatingError(new ErrorRecord(ex, "ReadDumpFileFailed", ErrorCategory.ReadError, fullPath));
            return;
        }

        if (lines.Length == 0)
        {
            WriteWarning("Dump file is empty.");
            return;
        }

        // Parse Header: ♦ repo: <RepoName> | <Timestamp>
        string firstLine = lines[0];
        if (!firstLine.StartsWith("♦ repo:"))
        {
            ThrowTerminatingError(new ErrorRecord(new InvalidDataException("Invalid dump file: missing header marker ♦"), "InvalidHeader", ErrorCategory.InvalidData, fullPath));
            return;
        }

        // Standardize destination folder path for prefix checks
        string destFolder = System.IO.Path.GetFullPath(DestinationFolder);
        if (!destFolder.EndsWith(System.IO.Path.DirectorySeparatorChar.ToString()))
        {
            destFolder += System.IO.Path.DirectorySeparatorChar;
        }

        // SAFETY GATE: Absolutely refuse to proceed if destination folder contains any entries
        if (Directory.Exists(destFolder))
        {
            try
            {
                if (Directory.EnumerateFileSystemEntries(destFolder).Any())
                {
                    ThrowTerminatingError(new ErrorRecord(
                        new InvalidOperationException($"Safety violation: Destination folder is not empty: {DestinationFolder.TrimEnd('\\', '/')}. Restore aborted to prevent any file destruction or mixing."),
                        "DestinationFolderNotEmpty",
                        ErrorCategory.InvalidOperation,
                        DestinationFolder
                    ));
                    return;
                }
            }
            catch (Exception ex) when (ex is not PipelineStoppedException)
            {
                ThrowTerminatingError(new ErrorRecord(ex, "CheckDestinationFolderFailed", ErrorCategory.ReadError, destFolder));
                return;
            }
        }

        WriteVerbose($"Restoring source tree to: {destFolder}");

        // Parse Index of files to expect
        var expectedFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int lineIndex = 1;
        for (; lineIndex < lines.Length; lineIndex++)
        {
            string line = lines[lineIndex];
            if (line.StartsWith("♠ "))
            {
                break;
            }

            int pIndex = line.LastIndexOf('|');
            if (pIndex > 0)
            {
                string relPath = line.Substring(0, pIndex).Trim();
                if (!string.IsNullOrEmpty(relPath))
                {
                    expectedFiles.Add(relPath);
                }
            }
        }

        if (expectedFiles.Count == 0)
        {
            WriteWarning("No files found in the dump index.");
            return;
        }

        // Parse Content Blocks and write them
        string? currentFile = null;
        var currentFileLines = new List<string>();
        int restoredCount = 0;

        for (; lineIndex < lines.Length; lineIndex++)
        {
            string line = lines[lineIndex];

            if (line.StartsWith("♠ "))
            {
                string parsedPath = line.Substring(2).Trim();
                if (expectedFiles.Contains(parsedPath))
                {
                    if (currentFile != null)
                    {
                        if (WriteFile(destFolder, currentFile, currentFileLines))
                        {
                            restoredCount++;
                        }
                    }

                    currentFile = parsedPath;
                    currentFileLines.Clear();
                    continue;
                }
            }

            if (currentFile != null)
            {
                currentFileLines.Add(line);
            }
        }

        if (currentFile != null)
        {
            if (WriteFile(destFolder, currentFile, currentFileLines))
            {
                restoredCount++;
            }
        }

        WriteObject($"Successfully restored source tree. Recreated {restoredCount} files under {destFolder}");
    }

    private bool WriteFile(string destFolder, string relPath, List<string> lines)
    {
        // Enforce path safety and prevent directory traversal (e.g. using "../")
        string fullOutputPath = System.IO.Path.GetFullPath(System.IO.Path.Combine(destFolder, relPath.Replace('/', System.IO.Path.DirectorySeparatorChar)));
        
        if (!fullOutputPath.StartsWith(destFolder, StringComparison.OrdinalIgnoreCase))
        {
            WriteError(new ErrorRecord(
                new UnauthorizedAccessException($"Path traversal escape detected and blocked. RelPath: {relPath}"),
                "PathTraversalBlocked", 
                ErrorCategory.SecurityError, 
                relPath
            ));
            return false;
        }

        // Leverage standard PowerShell ShouldProcess safety framework
        if (!ShouldProcess(fullOutputPath, "Write restored file"))
        {
            return false;
        }

        try
        {
            string? parentDir = System.IO.Path.GetDirectoryName(fullOutputPath);
            if (parentDir != null && !Directory.Exists(parentDir))
            {
                Directory.CreateDirectory(parentDir);
            }

            File.WriteAllLines(fullOutputPath, lines, Encoding.UTF8);
            WriteVerbose($"Restored: {relPath}");
            return true;
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "WriteFileFailed", ErrorCategory.WriteError, fullOutputPath));
            return false;
        }
    }
}
