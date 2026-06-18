using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace Subsystem.Vom;

// ObQuery (TRIAGE "Task Manager" / VOM-SPEC §6a): on-demand, System-integrity enumeration of the
// owner/handle table. NOT an ambient monitor — these walk the live maps only when asked. Backs
// Get-VomOwner / Get-VomThread / Stop-VomThread (the Task Manager's Processes/Threads tabs).
// Returns plain objects; /api/exec pipes them through ConvertTo-Json, so the UI gets real records.
public static unsafe partial class Vom
{
    // Get-VomOwner — every Owner with its quota / handle / lifecycle stats and tree position.
    public static object[] EnumerateOwners()
        => _owners.Values
            .OrderBy(o => o.Path, StringComparer.OrdinalIgnoreCase)
            .Select(o => (object)new
            {
                path      = o.Path,
                parent    = o.Parent?.Path,
                handles   = o.PathToId.Count,
                children  = o.Children.Count,
                bytes     = Interlocked.Read(ref o.CurrentBytes),
                maxBytes  = o.MaxBytes,
                elements  = Volatile.Read(ref o.CurrentElements),
                cancelled = o.Cts.IsCancellationRequested,
                hasThread = o.PathToId.Keys.Any(k => k.Contains("\\Thread\\")),
            })
            .ToArray();

    // Get-VomThread — every Type="Thread" handle (threads are first-class handles, VOM-SPEC §2). A
    // spawned thread IS a Sub-VOM owner, so its reclaimable identity is the owner path. A residual context = the
    // handle's owner is cancelled/gone but the managed Thread is still alive.
    public static object[] EnumerateThreads()
    {
        var list = new System.Collections.Generic.List<object>();
        foreach (var o in _owners.Values)
        {
            foreach (var kv in o.PathToId.ToArray())
            {
                if (!o.Handles.TryGet(kv.Value, out var e) || e == null) continue;
                if (!string.Equals(e.Descriptor.Type, "Thread", StringComparison.Ordinal)) continue;

                Thread? t = null;
                try { t = GCHandle.FromIntPtr(e.Descriptor.Resource).Target as Thread; } catch { }
                bool cancelled = o.Cts.IsCancellationRequested;
                string status = cancelled ? "cancelling" : (t == null ? "unknown" : (t.IsAlive ? "running" : "dead"));

                list.Add(new
                {
                    id       = o.Path,                                  // reclaimable identity (the Sub-VOM)
                    handle   = kv.Key,                                  // the \…\Thread\0x… handle path
                    name     = t?.Name ?? o.Path,
                    owner    = (o.Parent?.Path ?? o.Path).Split('\\').Last(),
                    type     = "Thread",
                    status   = status,
                    threadId = t?.ManagedThreadId ?? 0,
                    memory   = Math.Round(Interlocked.Read(ref o.CurrentBytes) / 1048576.0, 2),
                });
            }
        }
        return list.ToArray();
    }

    // Stop-VomThread — Terminate the Sub-VOM that owns the thread (cooperative cancel + reclaim). Id is
    // the owner path from EnumerateThreads. CoreCLR can't abort a wedged thread — Terminate makes it
    // resourceless (VOM-SPEC §5).
    public static object StopThread(string id)
    {
        var o = GetOwner(id);
        if (o == null) return new { ok = false, message = $"No VOM owner '{id}' (already gone?)." };
        Terminate(o);
        return new { ok = true, message = $"Terminated {id} (cancel + reclaim).", removed = GetOwner(id) == null };
    }
}
