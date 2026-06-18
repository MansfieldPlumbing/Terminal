using System;
using System.Collections.Concurrent;
using System.Text;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using Subsystem.Vom;
using static Subsystem.Vom.Vom;

namespace Subsystem;

// Bonafide named PowerShell session management.
//
// Each ManagedSession owns ONE persistent Runspace, so state (variables, loaded modules,
// $PWD, functions, history) survives across commands. A runspace is single-threaded, so
// commands to a given session are serialized behind a lock — that's correct shell semantics.
//
// Lifecycle: ephemeral by default. When the owning tab/socket closes, the session is
// disposed UNLESS it was opted into Background (detached), in which case it stays alive in
// the registry and is reattachable. Backgrounded sessions are the only ones that hold RAM,
// so they're explicit, listable (Get-Session), and reclaimable (Remove-Session).
public sealed class ManagedSession : IDisposable
{
    public string   Name       { get; }
    public DateTime Created    { get; } = DateTime.Now;
    public DateTime LastUsed   { get; private set; } = DateTime.Now;
    public bool     Background { get; set; }
    public bool     Busy       { get; private set; }

    // VOM-SPEC §4: each session is an Owner. Its unmanaged handles live under \Sessions\{Name}; on
    // Remove the kernel cancels its token and DropPrefix-reclaims everything it allocated.
    public Owner VomOwner { get; }

    private readonly Runspace _rs;
    private readonly object   _gate = new();

    public ManagedSession(string name, InitialSessionState iss, PSHost host)
    {
        Name = name;
        VomOwner = CreateOwner($"\\Sessions\\{name}");
        _rs = RunspaceFactory.CreateRunspace(host, iss);
        _rs.Open();
    }

    // Runs a command in this session's persistent runspace. Serialized (single-threaded
    // runspace). Returns combined output + errors as plain text; state persists for next call.
    public string Invoke(string command)
    {
        lock (_gate)
        {
            Busy = true;
            LastUsed = DateTime.Now;
            try
            {
                using var ps = PowerShell.Create();
                ps.Runspace = _rs;
                ps.AddScript(command);
                var output = ps.Invoke();

                var sb = new StringBuilder();
                foreach (var o in output) if (o != null) sb.AppendLine(o.ToString());
                foreach (var err in ps.Streams.Error) sb.AppendLine("ERROR: " + err);
                return sb.ToString().TrimEnd('\r', '\n');
            }
            catch (Exception ex) { return "ERROR: " + ex.Message; }
            finally { Busy = false; }
        }
    }

    public void Dispose()
    {
        try { _rs.Close(); _rs.Dispose(); } catch { }
    }
}

public static class SessionManager
{
    private static InitialSessionState? _iss;
    private static PSHost? _host;
    private static readonly ConcurrentDictionary<string, ManagedSession> _sessions =
        new(StringComparer.OrdinalIgnoreCase);

    // Captured from the live runspace bootstrap so new sessions match (same cmdlets/aliases/modules).
    public static void Initialize(InitialSessionState iss, PSHost host)
    {
        _iss = iss;
        _host = host;
    }

    public static ManagedSession Create(string name, bool background = false)
    {
        if (_iss == null || _host == null)
            throw new InvalidOperationException("SessionManager not initialized yet.");
        var s = _sessions.GetOrAdd(name, n => new ManagedSession(n, _iss, _host));
        if (background) s.Background = true;
        return s;
    }

    public static ManagedSession GetOrCreate(string name) => Create(name, false);

    public static ManagedSession? Get(string name)
        => _sessions.TryGetValue(name, out var s) ? s : null;

    public static ManagedSession[] List()
    {
        var arr = new ManagedSession[_sessions.Count];
        _sessions.Values.CopyTo(arr, 0);
        return arr;
    }

    public static bool Remove(string name)
    {
        if (_sessions.TryRemove(name, out var s))
        {
            Terminate(s.VomOwner);   // VOM termination token: cancel + DropPrefix(\Sessions\{name}); DOM logs the autopsy
            s.Dispose();
            return true;
        }
        return false;
    }

    // Call when an owning tab/socket closes: dispose UNLESS opted into Background.
    public static void OnOwnerClosed(string name)
    {
        if (_sessions.TryGetValue(name, out var s) && !s.Background)
            Remove(name);
    }
}
