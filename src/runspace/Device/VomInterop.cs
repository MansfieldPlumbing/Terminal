using System;
using System.Runtime.InteropServices;
using Subsystem.Vom;              // VomFormat (the layout enum) lives in the namespace, not the Vom class
using static Subsystem.Vom.Vom;   // the kernel class (Subsystem.Vom.Vom) — bare 'Vom' would bind the namespace

namespace Subsystem;

// VomInterop — the native/unmanaged interop surface of the VOM: publish +
// resolve Float32 regions by canonical \Capability\IPC\TextureBridge\<name> path, served to the WebView
// via the vom:// scheme. Per VOM-SPEC §2 a region is a FIRST-CLASS kernel handle
// (Vom.Register, named leaf): enumerable in the Task Manager, refcounted, and reclaimed by the same
// DropPrefix/Terminate loop as everything else — NOT an untracked Handle in a side dictionary, and not a
// pinned GCHandle that leaks on every publish. Callers always receive a COPY, never the source.
public static class VomInterop
{
    private const string IpcOwnerPath  = "\\Capability\\IPC";
    private const string TextureSubdir = "TextureBridge";

    private static string PathFor(string handleName)
        => $"{IpcOwnerPath}\\{TextureSubdir}\\{handleName}";

    public static void SetTexture(string handleName, float[] data)
    {
        var owner = CreateOwner(IpcOwnerPath);
        // Re-publish under the same name: free the prior region before allocating the replacement,
        // so a hot texture name does not accumulate stale handles.
        Close(owner, PathFor(handleName));
        // NATIVE Float32 region (VOM-SPEC §2/§3): Alloc gives 256-byte-aligned UNMANAGED memory the
        // kernel tracks by byte count and reclaims via NativeMemory.AlignedFree on free-at-zero —
        // NOT a pinned GCHandle over a managed float[] (that was the managed-entry flavor: real
        // handle, but bytes=0 in the owner table and a GC/GREF hazard for bulk data). Copy the
        // floats into the native region; the descriptor's Resource is the raw pointer.
        int byteCount = data.Length * sizeof(float);
        var h = Alloc(owner, byteCount, VomFormat.Float32, "Float32Texture",
                      subdir: TextureSubdir, name: handleName);
        if (byteCount > 0) Marshal.Copy(data, 0, h.Resource, data.Length);
    }

    // Explicit release for one-shot lanes (file staging): refcount free-at-zero, the same Close the
    // re-publish path uses. Without this, a staged file region would linger until owner termination.
    public static void Release(string handleName)
    {
        var owner = GetOwner(IpcOwnerPath);
        if (owner != null) Close(owner, PathFor(handleName));
    }

    public static byte[] GetTextureBytes(string handleName)
    {
        var owner = GetOwner(IpcOwnerPath);
        if (owner != null && TryGetByPath(owner, PathFor(handleName), out var handle) && handle.Resource != 0)
        {
            // Copy OUT of the native region into a fresh managed buffer for the transport (the
            // kernel's memory is never handed out). ByteCount is the padded-to-256 region size;
            // the consumer (lib/download.js fetchVomLane) slices to the true length by Size.
            var bytes = new byte[handle.ByteCount];
            if (handle.ByteCount > 0) Marshal.Copy(handle.Resource, bytes, 0, handle.ByteCount);
            return bytes;
        }
        return Array.Empty<byte>();
    }
}
