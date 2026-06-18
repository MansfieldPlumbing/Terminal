using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace Subsystem.Vom;

// The VOM kernel (VOM-SPEC). A path-named, per-owner GENERATIONAL handle table over NATIVE-allocated,
// 256-byte-aligned memory. The data plane is NOT on the .NET GC: DropPrefix / Terminate reclaim
// deterministically; the GC only sweeps unrooted managed graphs afterward. Lean by design — device
// capabilities are drivers/mounts, not methods here (§1).
public static unsafe partial class Vom
{
    private static readonly ConcurrentDictionary<string, Owner> _owners =
        new(StringComparer.OrdinalIgnoreCase);

    public const int  Alignment          = 256;                 // VOM-SPEC §3: row-pitch / DMA / cache line
    public const long DefaultMaxBytes    = 256L * 1024 * 1024;  // advisory
    public const int  DefaultMaxElements = 100_000;             // advisory

    // --- Owners ---

    public static Owner CreateOwner(string path, long maxBytes = DefaultMaxBytes, int maxElements = DefaultMaxElements)
        => _owners.GetOrAdd(path, p =>
        {
            Dg.Log("vom", $"OWNER + {p} (quota {maxBytes}B / {maxElements} elem)");
            return new Owner(p, maxBytes, maxElements);
        });

    public static Owner? GetOwner(string path) => _owners.TryGetValue(path, out var o) ? o : null;
    public static int OwnerCount => _owners.Count;

    // --- Allocation (immutable, 256-byte aligned native region; optional Fence/doorbell) ---

    public static Handle Alloc(Owner owner, int byteCount, VomFormat format = VomFormat.Float32,
                               string type = "VomRegion", bool withFence = false,
                               string subdir = "Objects", string? name = null)
    {
        int padded = (byteCount + (Alignment - 1)) & ~(Alignment - 1);   // pad stride to 256 (VOM-SPEC §3)
        void* ptr = NativeMemory.AlignedAlloc((nuint)padded, (nuint)Alignment);

        var entry = new HandleEntry
        {
            RefCount = 1,
            Reclaim  = () => NativeMemory.AlignedFree(ptr),
            Fence    = withFence ? new CpuFence() : null,
        };
        uint id = owner.Handles.Allocate(entry);
        // A caller may pin the native region to a stable named leaf (e.g. the byte lane's
        // \…\TextureBridge\<name>) so it re-resolves by path; default stays the id-derived leaf.
        string path = $"{owner.Path}\\{subdir}\\{name ?? $"0x{id:X8}"}";
        var h = new Handle
        {
            Path = path, Type = type, Owner = owner.Path, Format = format,
            ByteCount = padded, Resource = (nint)ptr, Fence = withFence ? 1 : 0, Id = id,
        };
        entry.Descriptor = h;
        owner.PathToId[path] = id;
        Interlocked.Add(ref owner.CurrentBytes, padded);
        Interlocked.Increment(ref owner.CurrentElements);
        CheckQuota(owner);
        return h;
    }

    // Register a MANAGED object as a first-class handle (VOM-SPEC §2 "managed entry": Resource is a
    // pinned GCHandle, ByteCount 0, no native memory). This is how a Thread, a Sub-VOM, or any managed
    // object becomes a handle in an owner's table — enumerable (the Task Manager), refcounted, and
    // reclaimed by the SAME DropPrefix/Terminate loop as native memory. onReclaim is the close
    // procedure (e.g. quarantine/residual-log); the GCHandle is always freed after it.
    public static Handle Register(Owner owner, string type, object managed,
                                  Action? onReclaim = null, string subdir = "Objects", string? name = null)
    {
        var gch = GCHandle.Alloc(managed);   // Normal handle: keeps it alive + retrievable, address not pinned
        var entry = new HandleEntry
        {
            RefCount = 1,
            Reclaim  = () => { try { onReclaim?.Invoke(); } finally { if (gch.IsAllocated) gch.Free(); } },
            Fence    = null,
        };
        uint id = owner.Handles.Allocate(entry);
        // A caller may pin the leaf to a stable name (a named \Device\<name>-style object) so it can be
        // re-resolved by path; default stays the id-derived leaf. The name does NOT replace the id —
        // the entry is still a generational handle in the table, reclaimed by the same loop.
        string path = $"{owner.Path}\\{subdir}\\{name ?? $"0x{id:X8}"}";
        var h = new Handle
        {
            Path = path, Type = type, Owner = owner.Path, Format = VomFormat.Bytes,
            ByteCount = 0, Resource = GCHandle.ToIntPtr(gch), Fence = 0, Id = id,
        };
        entry.Descriptor = h;
        owner.PathToId[path] = id;
        Interlocked.Increment(ref owner.CurrentElements);
        return h;
    }

    // Phase 1: ADVISORY — log, do not throw. Phase 3 flips this to throw VomQuotaExceededException.
    private static void CheckQuota(Owner o)
    {
        if (o.MaxBytes > 0 && Interlocked.Read(ref o.CurrentBytes) > o.MaxBytes)
            Dg.Log("vom", $"QUOTA(advisory) {o.Path} bytes {o.CurrentBytes}/{o.MaxBytes}");
        if (o.MaxElements > 0 && Volatile.Read(ref o.CurrentElements) > o.MaxElements)
            Dg.Log("vom", $"QUOTA(advisory) {o.Path} elements {o.CurrentElements}/{o.MaxElements}");
    }

    // --- Resolve / refcount (generational: a stale id fails O(1)) ---

    public static bool TryResolve(Owner owner, uint id, out Handle handle)
    {
        if (owner.Handles.TryGet(id, out var e) && e != null) { handle = e.Descriptor; return true; }
        handle = default; return false;
    }

    public static Fence? GetFence(Owner owner, uint id)
        => owner.Handles.TryGet(id, out var e) ? e?.Fence : null;

    // Resolve a handle by its full namespace path within an owner (no refcount change). Returns the
    // immutable descriptor; for a Register'd managed entry the object is reachable via
    // GCHandle.FromIntPtr(handle.Resource).Target. Used by named-object consumers (e.g. the texture
    // bridge) that key by path rather than by raw id.
    public static bool TryGetByPath(Owner owner, string path, out Handle handle)
    {
        if (owner.PathToId.TryGetValue(path, out var id) &&
            owner.Handles.TryGet(id, out var e) && e != null)
        { handle = e.Descriptor; return true; }
        handle = default; return false;
    }

    public static bool Open(Owner owner, string path)
    {
        if (!owner.PathToId.TryGetValue(path, out var id)) return false;
        if (!owner.Handles.TryGet(id, out var e) || e == null) return false;
        Interlocked.Increment(ref e.RefCount);
        return true;
    }

    public static bool Close(Owner owner, string path)
    {
        if (!owner.PathToId.TryGetValue(path, out var id)) return false;
        if (!owner.Handles.TryGet(id, out var e) || e == null) return false;
        if (Interlocked.Decrement(ref e.RefCount) > 0) return false;
        if (owner.PathToId.TryRemove(path, out _) && owner.Handles.Free(id, out var removed) && removed != null)
            FreeEntry(owner, removed);
        return true;
    }

    private static void FreeEntry(Owner owner, HandleEntry e)
    {
        try { e.Reclaim?.Invoke(); } catch { }
        Interlocked.Add(ref owner.CurrentBytes, -e.Descriptor.ByteCount);
        Interlocked.Decrement(ref owner.CurrentElements);
    }

    // --- Teardown and Reclaim (VOM-SPEC §5) ---

    // Bulk-free every handle whose path is under prefix. Returns what was reclaimed.
    public static (int handles, long bytes) DropPrefix(string prefix)
    {
        int n = 0; long bytes = 0;
        foreach (var owner in _owners.Values)
            foreach (var kv in owner.PathToId.ToArray())
                if (kv.Key.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
                    owner.PathToId.TryRemove(kv.Key, out var id) &&
                    owner.Handles.Free(id, out var e) && e != null)
                {
                    bytes += e.Descriptor.ByteCount; n++;
                    FreeEntry(owner, e);
                }
        return (n, bytes);
    }

    // Cancel the owner's token (cooperative), CASCADE to its spawned children (VOM-SPEC §4d), then
    // revoke + reclaim all its handles and drop the owner. A wedged thread is now resourceless; its
    // next handle use fails. Idempotent (safe under the spawn-thread's self-cleanup). DOM records the autopsy.
    public static void Terminate(Owner owner)
    {
        try { owner.Cts.Cancel(); } catch { }                 // linked child tokens cancel with us
        foreach (var child in owner.Children.Values.ToArray()) // cascade down the tree (depth-first)
            Terminate(child);
        owner.Parent?.Children.TryRemove(owner.Path, out _);
        var (n, bytes) = DropPrefix(owner.Path);
        _owners.TryRemove(owner.Path, out _);
        Dg.Log("vom", $"TERMINATE {owner.Path}: cancelled, reclaimed {n} handles / {bytes} bytes");
    }

    // --- Introspection (/diag, the state texture) ---

    // Kernel-wide totals as plain numbers — the data-plane consumers (Dg's Float32 state texture)
    // read these without reflecting over the per-owner snapshot objects.
    public static (int Owners, long Handles, long Bytes) Totals()
    {
        int owners = 0; long handles = 0, bytes = 0;
        foreach (var o in _owners.Values)
        {
            owners++;
            handles += o.PathToId.Count;
            bytes += Interlocked.Read(ref o.CurrentBytes);
        }
        return (owners, handles, bytes);
    }

    public static object Snapshot()
        => _owners.Values.Select(o => new
        {
            owner = o.Path,
            handles = o.PathToId.Count,
            bytes = Interlocked.Read(ref o.CurrentBytes),
            maxBytes = o.MaxBytes,
            cancelled = o.Cts.IsCancellationRequested,
        }).ToArray();

    // --- Teardown self-test (VOM-SPEC §11 step 4) ---

    // Create an owner, allocate native chunks (one with a Fence), exercise the doorbell, then
    // Terminate and report. Proves: deterministic native reclaim, generational stale-handle
    // rejection, and the Fence signal/complete cycle. Drives the DOM autopsy in events.log.
    public static string SelfTest(int chunks = 4, int chunkBytes = 1024 * 1024)
    {
        string name = $"\\Sessions\\__vomtest_{DateTime.Now:HHmmss}";
        var o = CreateOwner(name);

        uint firstId = 0;
        CpuFence? f = null;
        for (int i = 0; i < chunks; i++)
        {
            var h = Alloc(o, chunkBytes, VomFormat.Float32, "TestRegion", withFence: i == 0);
            if (i == 0) { firstId = h.Id; f = (CpuFence?)GetFence(o, h.Id); }
        }
        f?.Signal(1);
        bool fenceWorks = f != null && f.CompletedValue == 1;

        long allocated = Interlocked.Read(ref o.CurrentBytes);
        int handlesBefore = o.PathToId.Count;

        Terminate(o);

        bool stale = !o.Handles.IsValid(firstId);   // generational rejection after teardown

        return System.Text.Json.JsonSerializer.Serialize(new
        {
            owner = name,
            handlesBefore,
            allocatedBytes = allocated,
            fenceWorks,
            ownerRemoved = GetOwner(name) == null,
            staleHandleRejected = stale,
            note = "native memory reclaimed via NativeMemory.AlignedFree on Terminate; see /diag events for the autopsy",
        });
    }
}
