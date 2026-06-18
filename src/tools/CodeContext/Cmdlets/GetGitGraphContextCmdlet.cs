using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Management.Automation;
using System.Collections.Generic;

namespace Subsystem.Tools.CodeContext.Cmdlets;

// Get-GitGraphContext — git as OBJECTS, parsed straight from `.git/` in pure C#: NO git.exe, NO bash, no
// text-scraping. So it works for a naive agent (nothing on PATH) and it can't be lied to by porcelain.
// Projects a structured graph: the current Head/Branch, every local Branch, a recent Commit log (walked by
// decompressing loose objects), and the staged Index. The .git/index parse is the original; the rest is the
// 2026-06-16 expansion. (Endgame: libgit2 for packfile/delta reads + write verbs — this is the read graph.)
[Cmdlet(VerbsCommon.Get, "GitGraphContext")]
public class GetGitGraphContextCmdlet : PSCmdlet
{
    [Parameter(Position = 0, Mandatory = false)]
    public string GitRoot { get; set; } = Directory.GetCurrentDirectory();

    // How many commits to walk back from HEAD (first-parent). Loose objects only; packed history stops early.
    [Parameter(Mandatory = false)]
    public int CommitDepth { get; set; } = 20;

    protected override void ProcessRecord()
    {
        var gitDir = Path.Combine(GitRoot, ".git");
        if (!Directory.Exists(gitDir))
        {
            WriteWarning($"No .git folder at {GitRoot}. (Default scans the current dir; pass -GitRoot to point elsewhere.)");
            return;
        }

        var (branch, headSha) = ReadHead(gitDir);
        WriteObject(new
        {
            Root     = Path.GetFullPath(GitRoot),
            Branch   = branch,
            Head     = Short(headSha),
            Branches = ReadBranches(gitDir),
            Commits  = ReadLog(gitDir, headSha, CommitDepth),
            Index    = ReadIndex(gitDir),
        });
    }

    // --- HEAD: .git/HEAD is "ref: refs/heads/<branch>" (attached) or a raw 40-hex SHA (detached). ---
    private (string Branch, string? Sha) ReadHead(string gitDir)
    {
        var headFile = Path.Combine(gitDir, "HEAD");
        if (!File.Exists(headFile)) return ("(none)", null);
        var content = File.ReadAllText(headFile).Trim();
        if (content.StartsWith("ref: ", StringComparison.Ordinal))
        {
            var refPath = content.Substring(5).Trim();
            var branch = refPath.StartsWith("refs/heads/", StringComparison.Ordinal) ? refPath.Substring(11) : refPath;
            return (branch, ResolveRef(gitDir, refPath));
        }
        return ("(detached)", content);
    }

    // A ref resolves to a loose file (.git/refs/...) or a line in .git/packed-refs.
    private static string? ResolveRef(string gitDir, string refPath)
    {
        var loose = Path.Combine(gitDir, refPath.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(loose)) return File.ReadAllText(loose).Trim();
        var packed = Path.Combine(gitDir, "packed-refs");
        if (File.Exists(packed))
            foreach (var line in File.ReadAllLines(packed))
            {
                if (line.Length == 0 || line[0] == '#' || line[0] == '^') continue;
                var sp = line.Split(' ', 2);
                if (sp.Length == 2 && sp[1].Trim() == refPath) return sp[0].Trim();
            }
        return null;
    }

    // --- Branches: every file under .git/refs/heads + any refs/heads/* in packed-refs. ---
    private static object[] ReadBranches(string gitDir)
    {
        var list = new List<object>();
        var headsDir = Path.Combine(gitDir, "refs", "heads");
        if (Directory.Exists(headsDir))
            foreach (var f in Directory.EnumerateFiles(headsDir, "*", SearchOption.AllDirectories))
            {
                var name = Path.GetRelativePath(headsDir, f).Replace('\\', '/');
                try { list.Add(new { Name = name, Sha = Short(File.ReadAllText(f).Trim()) }); } catch { }
            }
        var packed = Path.Combine(gitDir, "packed-refs");
        if (File.Exists(packed))
            foreach (var line in File.ReadAllLines(packed))
            {
                if (line.Length == 0 || line[0] == '#' || line[0] == '^') continue;
                var sp = line.Split(' ', 2);
                if (sp.Length == 2 && sp[1].Trim().StartsWith("refs/heads/", StringComparison.Ordinal))
                    list.Add(new { Name = sp[1].Trim().Substring(11), Sha = Short(sp[0].Trim()) });
            }
        return list.ToArray();
    }

    // --- Commit log: walk first-parent from HEAD, decompressing each loose commit object. ---
    private object[] ReadLog(string gitDir, string? sha, int depth)
    {
        var list = new List<object>();
        var seen = new HashSet<string>();
        while (sha != null && sha.Length >= 40 && depth-- > 0 && seen.Add(sha))
        {
            var body = ReadLooseObject(gitDir, sha);
            if (body == null) break;   // packed or missing — loose-only read stops here
            var lines = body.Split('\n');
            string? parent = null, author = null; string subject = "";
            int i = 0;
            for (; i < lines.Length; i++)
            {
                var l = lines[i];
                if (l.Length == 0) { i++; break; }            // blank line → message follows
                if (parent == null && l.StartsWith("parent ", StringComparison.Ordinal)) parent = l.Substring(7).Trim();
                else if (l.StartsWith("author ", StringComparison.Ordinal)) author = l.Substring(7);
            }
            if (i < lines.Length) subject = lines[i];
            var (name, when) = ParseAuthor(author);
            list.Add(new { Sha = Short(sha), Subject = subject, Author = name, Date = when, Parent = Short(parent) });
            sha = parent;
        }
        return list.ToArray();
    }

    // A loose object is zlib(2-byte header + DEFLATE). Strip "commit <size>\0", return the rest.
    private static string? ReadLooseObject(string gitDir, string sha)
    {
        try
        {
            var p = Path.Combine(gitDir, "objects", sha.Substring(0, 2), sha.Substring(2));
            if (!File.Exists(p)) return null;
            var raw = File.ReadAllBytes(p);
            if (raw.Length < 3) return null;
            using var ms = new MemoryStream(raw, 2, raw.Length - 2);     // skip the 2-byte zlib header
            using var def = new DeflateStream(ms, CompressionMode.Decompress);
            using var outp = new MemoryStream();
            def.CopyTo(outp);
            var text = Encoding.UTF8.GetString(outp.ToArray());
            var nul = text.IndexOf('\0');
            return nul >= 0 ? text.Substring(nul + 1) : text;
        }
        catch { return null; }
    }

    // "Name <email> <unixtime> <tz>" → (Name, ISO date).
    private static (string Name, string? Date) ParseAuthor(string? author)
    {
        if (string.IsNullOrEmpty(author)) return ("", null);
        var lt = author!.IndexOf('<');
        var name = lt > 0 ? author.Substring(0, lt).Trim() : author.Trim();
        var gt = author.IndexOf('>');
        string? date = null;
        if (gt > 0 && gt + 2 < author.Length)
        {
            var rest = author.Substring(gt + 1).Trim().Split(' ');
            if (rest.Length >= 1 && long.TryParse(rest[0], out var unix))
                date = DateTimeOffset.FromUnixTimeSeconds(unix).ToString("u");
        }
        return (name, date);
    }

    // --- Index: the original native parse of .git/index (DIRC) — the staged files. ---
    private object[] ReadIndex(string gitDir)
    {
        var indexPath = Path.Combine(gitDir, "index");
        if (!File.Exists(indexPath)) return Array.Empty<object>();
        var results = new List<object>();
        try
        {
            using var stream = File.OpenRead(indexPath);
            using var reader = new BinaryReader(stream);
            if (stream.Length < 12) return Array.Empty<object>();
            if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "DIRC") return Array.Empty<object>();
            ReadUInt32BE(reader);                       // version
            uint entryCount = ReadUInt32BE(reader);
            for (int i = 0; i < entryCount; i++)
            {
                if (stream.Position + 62 > stream.Length) break;
                stream.Seek(40, SeekOrigin.Current);                       // ctime..size metadata
                byte[] sha = reader.ReadBytes(20);
                ushort flags = ReadUInt16BE(reader);
                int nameLength = flags & 0x0FFF;
                if (stream.Position + nameLength > stream.Length) break;
                string name = Encoding.UTF8.GetString(reader.ReadBytes(nameLength));
                int pad = 8 - ((62 + nameLength) % 8);
                stream.Seek(pad, SeekOrigin.Current);
                results.Add(new { Path = name, Sha = BitConverter.ToString(sha).Replace("-", "").ToLowerInvariant().Substring(0, 8) });
            }
        }
        catch (Exception ex) { WriteWarning("index parse stopped: " + ex.Message); }
        return results.ToArray();
    }

    private static string Short(string? sha) => string.IsNullOrEmpty(sha) ? "" : sha!.Substring(0, Math.Min(8, sha.Length));
    private static uint ReadUInt32BE(BinaryReader r) { var b = r.ReadBytes(4); Array.Reverse(b); return BitConverter.ToUInt32(b, 0); }
    private static ushort ReadUInt16BE(BinaryReader r) { var b = r.ReadBytes(2); Array.Reverse(b); return BitConverter.ToUInt16(b, 0); }
}
