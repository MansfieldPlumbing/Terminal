using System;
using System.Threading;

namespace Subsystem.Vom;

// Vom.RegisterNative — register an EXTERNALLY-owned native resource (a raw pointer the VOM did NOT
// allocate) as a first-class, possession-gated handle, with a caller-supplied Reclaim that runs once at
// refcount-zero (the free-at-zero invariant). This is the third register shape, beside:
//   Alloc(object)         — VOM allocates 256-aligned native memory, Reclaim = AlignedFree (VOM owns it)
//   Register(object)      — a managed object behind a GCHandle (VOM roots it)
//   RegisterNative(ptr)   — a FOREIGN native object the VOM only TRACKS (the producer owns the bytes)
//
// It is how an interop leaf becomes an object in the namespace under e.g. \Surfaces\<name>: a DirectPort
// shared texture (Reclaim = dp12_close), a mapped section, an OS handle. Enumerable (the task manager),
// refcounted (Open/Close), and reclaimed by the SAME DropPrefix/Terminate loop as everything else — so
// Terminate(owner) closes the foreign resource deterministically (mount-the-interop, don't grow a leaf).
// ByteCount is ADVISORY only (the VRAM behind a shared texture is opaque to us); pass 0 to skip quota
// accounting, or the frame footprint to make it show in /diag.
public static unsafe partial class Vom
{
    public static Handle RegisterNative(Owner owner, string type, nint native, Action reclaim,
                                        int byteCount = 0, VomFormat format = VomFormat.Bytes,
                                        string subdir = "Surfaces", string? name = null)
    {
        var entry = new HandleEntry
        {
            RefCount = 1,
            Reclaim  = reclaim,   // the producer's close procedure (e.g. () => DirectPortNative.dp12_close(h))
            Fence    = null,
        };
        uint id = owner.Handles.Allocate(entry);
        string leaf = name ?? $"0x{id:X8}";
        // A named mount may sit DIRECTLY under its owner (subdir="") — e.g. \Surfaces\<name> — rather
        // than under an id-derived bucket; default keeps the \…\Surfaces\<leaf> shape.
        string path = string.IsNullOrEmpty(subdir) ? $"{owner.Path}\\{leaf}" : $"{owner.Path}\\{subdir}\\{leaf}";
        var h = new Handle
        {
            Path = path, Type = type, Owner = owner.Path, Format = format,
            ByteCount = byteCount, Resource = native, Fence = 0, Id = id,
        };
        entry.Descriptor = h;
        owner.PathToId[path] = id;
        if (byteCount > 0) Interlocked.Add(ref owner.CurrentBytes, byteCount);
        Interlocked.Increment(ref owner.CurrentElements);
        return h;
    }
}
