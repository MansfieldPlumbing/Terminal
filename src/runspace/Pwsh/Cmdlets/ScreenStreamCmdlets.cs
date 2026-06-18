using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using Android.Hardware.Display;
using Android.Media;
using Android.Views;

namespace Subsystem.Pwsh.Cmdlets;

// ---------------------------------------------------------------------------
// Screen streaming — scrcpy's ScreenCapture + SurfaceEncoder pipeline mapped
// to PowerShell cmdlets.  Android 16+, no legacy compat.
//
// Mapping:
//   scrcpy ScreenCapture.start()        → Start-AndroidScreenStream
//   scrcpy SurfaceEncoder (H.264/H.265) → same; codec/bitrate params
//   scrcpy DisplayMonitor               → Get-AndroidDisplayInfo
//   scrcpy SurfaceCapture.stop/release  → Stop-AndroidScreenStream
// ---------------------------------------------------------------------------

/// <summary>
/// Starts an H.264 (or H.265) screen stream served over a raw TCP socket on
/// the specified port.  Powered by MediaProjection + VirtualDisplay + MediaCodec.
///
/// The session token is a Guid that can be passed to Stop-AndroidScreenStream.
///
/// Equivalent to starting scrcpy's SurfaceEncoder pipeline:
///   SurfaceEncoder.encode() → ScreenCapture.start(surface) → VirtualDisplay
/// </summary>
[Cmdlet(VerbsLifecycle.Start, "AndroidScreenStream")]
[OutputType(typeof(PSObject))]
public sealed class StartAndroidScreenStreamCmdlet : WrapperCmdlet
{
    // Port that the raw H.264/H.265 annex-B byte stream is served on.
    [Parameter(Position = 0)]
    public int Port { get; set; } = 27183; // scrcpy default video port

    // Encoder MIME.  "video/avc" = H.264, "video/hevc" = H.265.
    [Parameter]
    [ValidateSet("video/avc", "video/hevc", "video/av01")]
    public string Codec { get; set; } = "video/avc";

    // Target bitrate in bits per second.  Default matches scrcpy 4 Mbps.
    [Parameter]
    public int Bitrate { get; set; } = 4_000_000;

    // Target frame rate (fps).  Android 16 hardware encoders support up to 120.
    [Parameter]
    [ValidateRange(1, 120)]
    public int FrameRate { get; set; } = 60;

    // Maximum dimension (longer edge) in pixels.  0 = use native resolution.
    [Parameter]
    public int MaxSize { get; set; } = 0;

    // Display to mirror.  0 = primary.
    [Parameter]
    public int DisplayId { get; set; } = 0;

    // I-frame interval in seconds (scrcpy default = 10).
    [Parameter]
    public int KeyFrameInterval { get; set; } = 10;

    // When set, the cmdlet returns immediately and the stream runs in the
    // background (same semantics as scrcpy --no-control background mode).
    [Parameter]
    public SwitchParameter Background { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            var ctx = MainActivity.Instance
                ?? throw new InvalidOperationException("MainActivity is not available.");

            // --- Obtain display metrics ---
            var dm = ctx.Resources?.DisplayMetrics
                ?? throw new InvalidOperationException("Cannot read DisplayMetrics.");

            int width  = dm.WidthPixels;
            int height = dm.HeightPixels;

            if (MaxSize > 0)
            {
                float scale = (float)MaxSize / Math.Max(width, height);
                if (scale < 1f)
                {
                    width  = (int)(width  * scale) & ~1; // must be even for AVC
                    height = (int)(height * scale) & ~1;
                }
            }

            var sessionId = Guid.NewGuid().ToString("N")[..8];

            // --- Build MediaFormat ---
            var fmt = MediaFormat.CreateVideoFormat(Codec, width, height)!;
            fmt.SetInteger(MediaFormat.KeyColorFormat,
                (int)MediaCodecCapabilities.Formatsurface);
            fmt.SetInteger(MediaFormat.KeyBitRate,   Bitrate);
            fmt.SetInteger(MediaFormat.KeyFrameRate, FrameRate);
            fmt.SetInteger(MediaFormat.KeyIFrameInterval, KeyFrameInterval);
            // Android 16: enable low-latency encoding path
            fmt.SetInteger("low-latency", 1);

            var encoder = MediaCodec.CreateEncoderByType(Codec)
                ?? throw new InvalidOperationException($"No encoder for {Codec}.");
            encoder.Configure(fmt, null, null, MediaCodecConfigFlags.Encode);

            // --- Create encoder input Surface → feed into VirtualDisplay ---
            var inputSurface = encoder.CreateInputSurface()
                ?? throw new InvalidOperationException("CreateInputSurface returned null.");
            encoder.Start();

            var displayManager = (DisplayManager?)
                ctx.GetSystemService(Android.Content.Context.DisplayService)
                ?? throw new InvalidOperationException("DisplayManager unavailable.");

            var flags = Android.Hardware.Display.VirtualDisplayFlags.Presentation
                      | Android.Hardware.Display.VirtualDisplayFlags.Secure;
            var vd = displayManager.CreateVirtualDisplay(
                $"scrcpy-stream-{sessionId}",
                width, height, (int)dm.DensityDpi,
                inputSurface,
                flags)
                ?? throw new InvalidOperationException("CreateVirtualDisplay failed.");

            // --- TCP listener ---
            var listener = new TcpListener(IPAddress.Loopback, Port);
            listener.Start();

            var cts = new CancellationTokenSource();
            ScreenStreamRegistry.Register(sessionId, new ScreenStreamSession(encoder, vd, listener, cts));

            Task.Run(() => PumpFrames(encoder, listener, cts.Token), cts.Token);

            var result = new PSObject();
            result.Properties.Add(new PSNoteProperty("SessionId", sessionId));
            result.Properties.Add(new PSNoteProperty("Port",      Port));
            result.Properties.Add(new PSNoteProperty("Codec",     Codec));
            result.Properties.Add(new PSNoteProperty("Width",     width));
            result.Properties.Add(new PSNoteProperty("Height",    height));
            result.Properties.Add(new PSNoteProperty("Bitrate",   Bitrate));
            result.Properties.Add(new PSNoteProperty("FrameRate", FrameRate));
            Emit(result);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "StartScreenStreamFailed",
                ErrorCategory.InvalidOperation, null));
        }
    }

    // Dequeue encoded NALUs from MediaCodec and write them to the connected TCP client.
    // Mirrors scrcpy's Streamer.writePacket() loop.
    private static async Task PumpFrames(
        MediaCodec encoder, TcpListener listener, CancellationToken ct)
    {
        try
        {
            using var client = await listener.AcceptTcpClientAsync(ct);
            await using var stream = client.GetStream();
            var info = new MediaCodec.BufferInfo();

            while (!ct.IsCancellationRequested && client.Connected)
            {
                int idx = encoder.DequeueOutputBuffer(info, timeoutUs: 10_000);
                if (idx >= 0)
                {
                    var buf = encoder.GetOutputBuffer(idx);
                    if (buf != null && info.Size > 0)
                    {
                        var data = new byte[info.Size];
                        buf.Position(info.Offset);
                        buf.Get(data);
                        await stream.WriteAsync(data, ct);
                    }
                    encoder.ReleaseOutputBuffer(idx, render: false);
                }
                else if (idx == (int)Android.Media.MediaCodecInfoState.TryAgainLater)
                {
                    await Task.Delay(1, ct);
                }
            }
        }
        catch (OperationCanceledException) { /* normal shutdown */ }
        catch (Exception ex)
        {
            Dg.Log("screen-stream", $"PumpFrames error: {ex.Message}");
        }
    }
}

/// <summary>
/// Stops a running screen stream session started by Start-AndroidScreenStream.
/// Releases the VirtualDisplay, stops the encoder, and closes the TCP listener.
///
/// Equivalent to scrcpy's CleanUp + SurfaceCapture.release().
/// </summary>
[Cmdlet(VerbsLifecycle.Stop, "AndroidScreenStream")]
[OutputType(typeof(bool))]
public sealed class StopAndroidScreenStreamCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string SessionId { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            Emit(ScreenStreamRegistry.Stop(SessionId));
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "StopScreenStreamFailed",
                ErrorCategory.InvalidOperation, SessionId));
        }
    }
}

/// <summary>
/// Lists all active screen-stream sessions (session ID, port, codec).
/// </summary>
[Cmdlet(VerbsCommon.Get, "AndroidScreenStream")]
[OutputType(typeof(PSObject))]
public sealed class GetAndroidScreenStreamCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(ScreenStreamRegistry.List());
}

// ---------------------------------------------------------------------------
// Internal session registry — keeps the encoder / VD alive between cmdlet
// invocations (mirrors scrcpy's AsyncProcessor lifetime model).
// ---------------------------------------------------------------------------
internal sealed class ScreenStreamSession(
    MediaCodec encoder,
    VirtualDisplay virtualDisplay,
    TcpListener listener,
    CancellationTokenSource cts)
{
    public MediaCodec      Encoder        { get; } = encoder;
    public VirtualDisplay  VirtualDisplay { get; } = virtualDisplay;
    public TcpListener     Listener       { get; } = listener;
    public CancellationTokenSource Cts   { get; } = cts;

    public PSObject ToInfo(string id) =>
        new PSObject().Also(o =>
        {
            o.Properties.Add(new PSNoteProperty("SessionId", id));
            o.Properties.Add(new PSNoteProperty("Active",    !Cts.IsCancellationRequested));
        });
}

internal static class ScreenStreamRegistry
{
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, ScreenStreamSession>
        _sessions = new();

    public static void Register(string id, ScreenStreamSession s) => _sessions[id] = s;

    public static bool Stop(string id)
    {
        if (!_sessions.TryRemove(id, out var s)) return false;
        s.Cts.Cancel();
        s.Encoder.Stop();
        s.Encoder.Release();
        s.VirtualDisplay.Release();
        s.Listener.Stop();
        return true;
    }

    public static System.Collections.Generic.IEnumerable<PSObject> List()
    {
        foreach (var (id, s) in _sessions)
            yield return s.ToInfo(id);
    }
}

// Tiny extension so PSObject initialisation reads cleanly.
internal static class PsoExtensions
{
    public static PSObject Also(this PSObject o, Action<PSObject> configure) { configure(o); return o; }
}
