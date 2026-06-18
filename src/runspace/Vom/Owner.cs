using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Subsystem.Vom;

// A Module/Owner in the VOM (VOM-SPEC §4). Holds a cancellation token (cooperative termination), a
// generational handle table, advisory quota counters, and a canonical path -> handle-id namespace
// map. Terminate() cancels the token then reclaims everything here deterministically. Sessions are
// the first Owners; the Hb and capture modules become Owners / Sub-VOMs in Phase 2.
public sealed class Owner
{
    public string Path { get; }
    public Owner? Parent { get; }                 // the owner tree (VOM-SPEC §4d): null = a root owner
    public CancellationTokenSource Cts { get; }
    public CancellationToken Token => Cts.Token;
    public HandleAllocator Handles { get; } = new();
    // NB: a spawned owner's THREAD is not a property here — it's a Type="Thread" handle in this owner's
    // table (Vom.Register), so it's enumerable + reclaimed like every other resource. (VOM-SPEC §2.)

    // Child Sub-VOMs spawned under this owner (Ps). Keyed by path; the termination cascades over these.
    internal readonly ConcurrentDictionary<string, Owner> Children =
        new(StringComparer.OrdinalIgnoreCase);

    // Quotas (Phase 1: ADVISORY — counted + logged, not enforced). MaxBytes = unmanaged bytes only.
    public long MaxBytes;
    public int  MaxElements;
    public long CurrentBytes;     // mutated via Interlocked
    public int  CurrentElements;  // mutated via Interlocked

    internal readonly ConcurrentDictionary<string, uint> PathToId =
        new(StringComparer.OrdinalIgnoreCase);

    public Owner(string path, long maxBytes, int maxElements, Owner? parent = null)
    {
        Path = path;
        MaxBytes = maxBytes;
        MaxElements = maxElements;
        Parent = parent;
        // A spawned child's token is LINKED to its parent's: Terminate(parent) cascades cancellation
        // down the owner tree without the parent having to know its descendants.
        Cts = parent != null
            ? CancellationTokenSource.CreateLinkedTokenSource(parent.Token)
            : new CancellationTokenSource();
    }
}

// Mutable registry entry: the immutable Handle descriptor + a refcount + the typed reclaim (the NT
// "close procedure" — frees the native Resource) + an optional Fence (the doorbell for a
// producer/consumer region).
internal sealed class HandleEntry
{
    public Handle  Descriptor;
    public int     RefCount;
    public Action? Reclaim;
    public Fence?  Fence;
}
