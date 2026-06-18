using System.Collections.Generic;

namespace Subsystem.Vom;

// Byte layout only (VOM-SPEC §2) — NOT a semantic type. Float32 is the universal element; a region
// may be a texture row, audio PCM, an ML tensor, or UTF-8/JSON control-plane bytes. The Type string
// says what the bytes MEAN; Format says what they ARE.
public enum VomFormat
{
    Float32 = 0,   // the universal element
    Half    = 1,
    Raw32   = 2,
    Bytes   = 3,   // control plane: commands / JSON / CLI text ride here, same lifecycle rules
}

// The lean NT-style object header (VOM-SPEC §2). Immutable + pointer-stable for its whole lifetime
// (no realloc — grow by allocating a new chunk and appending). Id is a GENERATIONAL handle:
// [16-bit generation | 16-bit index] — a stale handle fails resolution in O(1). NO DXGI in the core:
// Format is a layout enum; backends (NativeMemory / pinned GCHandle / AHardwareBuffer) are swappable.
public readonly struct Handle
{
    public string    Path      { get; init; }   // canonical name, e.g. \Sessions\foo\Objects\0x00010001
    public string    Type      { get; init; }   // semantic contract == PSObject.TypeNames[0]
    public string    Owner     { get; init; }   // owning Module/Session path
    public VomFormat Format    { get; init; }   // byte layout only
    public int       ByteCount { get; init; }   // 256-byte aligned (VOM-SPEC §3)
    public nint      Resource  { get; init; }   // NativeMemory ptr | pinned GCHandle | AHardwareBuffer
    public nint      Fence     { get; init; }   // 0 = unsynced; 1 = has a Fence (see Vom.GetFence)
    public uint      Id        { get; init; }   // [16-bit generation | 16-bit index]
}

// A mount's callable surface (VOM-SPEC §6). ONE JSON that is simultaneously the agent/FunctionGemma
// tool schema, the UI widget type, AND the permission surface. Registered into the control plane when
// a capability or a real-time cmdlet mounts.
public sealed record Manifest(string Prefix, string Type, IReadOnlyList<Verb> Verbs, int SchemaVersion);
public sealed record Verb(string Name, string Summary, IReadOnlyList<Param> Parameters, string ReturnType);
public sealed record Param(string Name, string Type, bool Required, string? Summary);
