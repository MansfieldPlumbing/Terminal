using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Management.Automation;
using System.Collections.Generic;

namespace Subsystem.Tools.CodeContext.Cmdlets;

[Cmdlet(VerbsCommon.Get, "CodeContext")]
[OutputType(typeof(string))]
public class GetCodeContextCmdlet : PSCmdlet
{
    [Parameter(Position = 0, Mandatory = false)]
    public string TargetFolder { get; set; } = Directory.GetCurrentDirectory();

    [Parameter(Mandatory = false)]
    public int MaxFileSizeKB { get; set; } = 500;

    [Parameter(Mandatory = false)]
    public string OutputPath { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        var targetInfo = new DirectoryInfo(TargetFolder);
        if (!targetInfo.Exists)
        {
            ThrowTerminatingError(new ErrorRecord(new DirectoryNotFoundException(), "DirectoryNotFound", ErrorCategory.ObjectNotFound, TargetFolder));
        }

        string projName = targetInfo.Name;
        if (string.IsNullOrEmpty(OutputPath))
        {
            string tempDir = Path.GetTempPath();
            string timestamp = DateTime.Now.ToString("yyyy-MM-dd--HH-mm-ss");
            OutputPath = Path.Combine(tempDir, $"{projName}_{timestamp}.txt");
        }

        var validFiles = ScanFolder(targetInfo);
        
        // Build the optimized segmented document
        var finalDoc = new List<string>();
        finalDoc.Add($"♦ repo: {projName} | {DateTime.UtcNow:o}");

        // Build file list index
        int startLine = validFiles.Count + 2; 
        var fileBlocks = new List<(string RelPath, string[] Lines, int StartLine)>();

        foreach (var file in validFiles)
        {
            string relPath = Path.GetRelativePath(TargetFolder, file.FullName).Replace('\\', '/');
            string[] lines;
            try
            {
                lines = File.ReadAllLines(file.FullName);
            }
            catch (Exception ex)
            {
                WriteWarning($"Failed to read file: {relPath}. Error: {ex.Message}");
                continue;
            }

            if (lines.Length == 0) continue;

            fileBlocks.Add((relPath, lines, startLine));
            finalDoc.Add($"{relPath} | {startLine}");
            startLine += lines.Length + 1; // +1 accounts for the ♠ path boundary line
        }

        // Add file contents
        foreach (var block in fileBlocks)
        {
            finalDoc.Add($"♠ {block.RelPath}");
            finalDoc.AddRange(block.Lines);
        }

        try
        {
            File.WriteAllLines(OutputPath, finalDoc, Encoding.UTF8);
            WriteObject(OutputPath);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "WriteOutputFileFailed", ErrorCategory.WriteError, OutputPath));
        }
    }

    private List<FileInfo> ScanFolder(DirectoryInfo root)
    {
        var files = new List<FileInfo>();
        var blockedDirs = new[] { "node_modules", "bin", "obj", "dist", "build", ".git", ".vs", "packages", "vendor", "reference" };
        var whitelistedExts = new[] { ".cs", ".ps1", ".js", ".ts", ".html", ".css", ".json", ".md", ".csproj", ".xml", ".config", ".props", ".targets", ".sln" };

        var queue = new Queue<DirectoryInfo>();
        queue.Enqueue(root);

        while (queue.Count > 0)
        {
            var currentDir = queue.Dequeue();
            
            // Skip blocked folders
            if (blockedDirs.Any(d => currentDir.Name.Equals(d, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            try
            {
                foreach (var dir in currentDir.GetDirectories())
                {
                    queue.Enqueue(dir);
                }
            }
            catch (UnauthorizedAccessException) { continue; }
            catch (DirectoryNotFoundException) { continue; }

            try
            {
                foreach (var file in currentDir.GetFiles())
                {
                    if (!whitelistedExts.Contains(file.Extension.ToLowerInvariant())) continue;
                    if (file.Length > MaxFileSizeKB * 1024) continue;
                    files.Add(file);
                }
            }
            catch (UnauthorizedAccessException) { continue; }
            catch (FileNotFoundException) { continue; }
        }

        return files;
    }
}
