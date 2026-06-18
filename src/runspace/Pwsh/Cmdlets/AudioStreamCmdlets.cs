using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using Android.Media;
using Android.Media.Projection;

namespace Subsystem.Pwsh.Cmdlets;

// ---------------------------------------------------------------------------
// Audio streaming — maps scrcpy's AudioPlaybackCapture + AudioEncoder pipeline
// to PowerShell cmdlets.  Requires Android 13+ (API 33) for AudioPolicy-based
// loopback capture; the cmdlet checks compatibility and fails cleanly on older.
//
// Mapping:
//   scrcpy AudioPlaybackCapture.start()  → Start-AndroidAudioStream  (playback)
//   scrcpy AudioDirectCapture.start()    → Start-AndroidAudioStream -Source Mic
//   scrcpy AudioEncoder.encode() loop    → same; codec/bitrate params
//   scrcpy AudioRawRecorder              → Start-AndroidAudioStream -Raw
//   scrcpy AudioCapture.stop()           → Stop-AndroidAudioStream
// ---------------------------------------------------------------------------

/// <summary>
/// Captures device audio (system playback or microphone) and serves a raw
/// PCM-16 or AAC-encoded stream over TCP on the given port.
///
/// Audio playback capture (Source Playback) requires Android 13+ and uses
/// the AudioPolicy loopback path — matching scrcpy's AudioPlaybackCapture
/// implementation exactly.
/// </summary>
[Cmdlet(VerbsLifecycle.Start, "AndroidAudioStream")]
[OutputType(typeof(PSObject))]
public sealed class StartAndroidAudioStreamCmdlet : WrapperCmdlet
{
    [Parameter(Position = 0)]
    public int Port { get; set; } = 27184; // scrcpy default audio port

    // Playback = system audio loopback (AudioPolicy sink).
    // Mic = raw microphone (AudioRecord, no loopback).
    [Parameter]
    [ValidateSet("Playback", "Mic")]
    public string Source { get; set; } = "Playback";

    // Codec for the encoded stream.  "raw" = 16-bit PCM little-endian.
    [Parameter]
    [ValidateSet("audio/mp4a-latm", "audio/opus", "raw")]
    public string Codec { get; set; } = "audio/mp4a-latm"; // AAC-LC

    // Encoder bitrate (bits/sec).  Ignored when Codec = "raw".
    [Parameter]
    public int Bitrate { get; set; } = 128_000;

    // Sample rate.  48000 matches scrcpy's AudioConfig.
    [Parameter]
    [ValidateSet("44100", "48000")]
    public int SampleRate { get; set; } = 48_000;

    // Channel count.  scrcpy uses stereo (2).
    [Parameter]
    [ValidateRange(1, 2)]
    public int Channels { get; set; } = 2;

    // If set, keep playing audio on the device while loopback-recording
    // (scrcpy --audio-dup-output equivalent).
    [Parameter]
    public SwitchParameter KeepPlaying { get; set; }

    protected override void ProcessRecord()
    {
        try
        {
            if (Source == "Playback" && OperatingSystem.IsAndroidVersionAtLeast(33) == false)
            {
                WriteError(new ErrorRecord(
                    new PlatformNotSupportedException(
                        "Playback audio capture requires Android 13 (API 33) or newer."),
                    "AudioCaptureUnsupported",
                    ErrorCategory.InvalidOperation, null));
                return;
            }

            var sessionId = Guid.NewGuid().ToString("N")[..8];

            var cts = new CancellationTokenSource();
            var listener = new TcpListener(IPAddress.Loopback, Port);
            listener.Start();

            Task.Run(() => AudioPump(
                Source, Codec, Bitrate, SampleRate, Channels,
                KeepPlaying.IsPresent, listener, cts.Token), cts.Token);

            AudioStreamRegistry.Register(sessionId, new AudioStreamSession(listener, cts));

            var result = new PSObject();
            result.Properties.Add(new PSNoteProperty("SessionId", sessionId));
            result.Properties.Add(new PSNoteProperty("Port",      Port));
            result.Properties.Add(new PSNoteProperty("Source",    Source));
            result.Properties.Add(new PSNoteProperty("Codec",     Codec));
            result.Properties.Add(new PSNoteProperty("SampleRate",SampleRate));
            result.Properties.Add(new PSNoteProperty("Channels",  Channels));
            Emit(result);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "StartAudioStreamFailed",
                ErrorCategory.InvalidOperation, null));
        }
    }

    // Audio pump: builds the recorder (playback-loopback or mic), optionally
    // wraps it in a MediaCodec encoder, then streams to the TCP client.
    // Mirrors scrcpy's AudioEncoder.encode() + AudioRecordReader.read() loop.
    private static async Task AudioPump(
        string source, string codec, int bitrate, int sampleRate, int channels,
        bool keepPlaying, TcpListener listener, CancellationToken ct)
    {
        ChannelIn channelMask = channels == 2 ? ChannelIn.Stereo : ChannelIn.Mono;
        int bufferSize = AudioRecord.GetMinBufferSize(sampleRate, channelMask, Encoding.Pcm16bit) * 4;

        AudioRecord recorder;
        if (source == "Playback")
        {
            // Playback loopback via AudioPolicy (mirrors AudioPlaybackCapture.java).
            // On Android 16 the ROUTE_FLAG_LOOP_BACK_RENDER flag honours KeepPlaying.
            recorder = BuildLoopbackRecorder(sampleRate, channelMask, bufferSize, keepPlaying);
        }
        else
        {
            recorder = new AudioRecord(
                AudioSource.Mic, sampleRate, channelMask, Encoding.Pcm16bit, bufferSize);
        }

        recorder.StartRecording();

        try
        {
            using var client = await listener.AcceptTcpClientAsync(ct);
            await using var stream = client.GetStream();

            if (codec == "raw")
            {
                // Raw PCM path — mirrors scrcpy AudioRawRecorder.
                var buf = new byte[bufferSize];
                while (!ct.IsCancellationRequested && client.Connected)
                {
                    int n = recorder.Read(buf, 0, buf.Length);
                    if (n > 0) await stream.WriteAsync(buf.AsMemory(0, n), ct);
                }
            }
            else
            {
                // Encoded path — mirrors scrcpy AudioEncoder using MediaCodec.
                await EncodeAudio(recorder, codec, bitrate, sampleRate, channels,
                    bufferSize, stream, ct);
            }
        }
        finally
        {
            recorder.Stop();
            recorder.Release();
        }
    }

    // Build AudioRecord via AudioPolicy loopback.  Mirrors AudioPlaybackCapture.java
    // createAudioRecord() — uses reflection because AudioMixingRule / AudioPolicy
    // are @SystemApi and not exposed in the public SDK.
    private static AudioRecord BuildLoopbackRecorder(
        int sampleRate, ChannelIn channelMask, int bufferSize, bool keepPlaying)
    {
        try
        {
            var mixingRuleCls  = Java.Lang.Class.ForName("android.media.audiopolicy.AudioMixingRule");
            var mixingRuleBCls = Java.Lang.Class.ForName("android.media.audiopolicy.AudioMixingRule$Builder");
            var mixCls         = Java.Lang.Class.ForName("android.media.audiopolicy.AudioMix");
            var mixBCls        = Java.Lang.Class.ForName("android.media.audiopolicy.AudioMix$Builder");
            var policyBCls     = Java.Lang.Class.ForName("android.media.audiopolicy.AudioPolicy$Builder");
            var policyCls      = Java.Lang.Class.ForName("android.media.audiopolicy.AudioPolicy");

            // AudioMixingRule builder
            var mrb = mixingRuleBCls.NewInstance()!;
            int mixRolePlayers = (int)mixingRuleCls.GetField("MIX_ROLE_PLAYERS")!.GetInt(null)!;
            mixingRuleBCls.GetMethod("setTargetMixRole", Java.Lang.Integer.Type)!
                .Invoke(mrb, Java.Lang.Integer.ValueOf(mixRolePlayers));

            var attrs = new AudioAttributes.Builder()
                .SetUsage(AudioUsageKind.Media)!
                .Build()!;

            int ruleMatchUsage = (int)mixingRuleCls.GetField("RULE_MATCH_ATTRIBUTE_USAGE")!.GetInt(null)!;
            mixingRuleBCls.GetMethod("addMixRule", Java.Lang.Integer.Type, Java.Lang.Class.FromType(typeof(Java.Lang.Object)))!
                .Invoke(mrb, Java.Lang.Integer.ValueOf(ruleMatchUsage), attrs);

            var mixingRule = mixingRuleBCls.GetMethod("build")!.Invoke(mrb);

            // AudioMix builder
            var mb = mixBCls.GetConstructors()[0].NewInstance(mixingRule)!;

            var audioFormat = new AudioFormat.Builder()
                .SetEncoding(Encoding.Pcm16bit)!
                .SetSampleRate(sampleRate)!
                .SetChannelMask((Android.Media.ChannelOut)(int)channelMask)!
                .Build()!;
            mixBCls.GetMethod("setFormat", Java.Lang.Class.FromType(typeof(AudioFormat)))!.Invoke(mb, audioFormat);

            string routeFlag = keepPlaying ? "ROUTE_FLAG_LOOP_BACK_RENDER" : "ROUTE_FLAG_LOOP_BACK";
            int routeFlags = (int)mixCls.GetField(routeFlag)!.GetInt(null)!;
            mixBCls.GetMethod("setRouteFlags", Java.Lang.Integer.Type)!
                .Invoke(mb, Java.Lang.Integer.ValueOf(routeFlags));

            var mix = mixBCls.GetMethod("build")!.Invoke(mb);

            // AudioPolicy
            var ctx = Android.App.Application.Context;
            var pb  = policyBCls.GetConstructors()[0].NewInstance(ctx)!;
            policyBCls.GetMethod("addMix", mixCls)!.Invoke(pb, mix);
            var policy = policyBCls.GetMethod("build")!.Invoke(pb);

            // Register
            var registerMethod = Java.Lang.Class.FromType(typeof(AudioManager))
                .GetDeclaredMethod("registerAudioPolicyStatic", policyCls)!;
            registerMethod.Accessible = true;
            int reg = (int)registerMethod.Invoke(null, policy)!;
            if (reg != 0)
                throw new InvalidOperationException($"registerAudioPolicy returned {reg}");

            return (AudioRecord)policyCls
                .GetMethod("createAudioRecordSink", mixCls)!
                .Invoke(policy, mix)!;
        }
        catch (Exception ex)
        {
            Dg.Log("audio-stream", $"Loopback recorder build failed: {ex.Message}");
            // Graceful fallback: mic
            return new AudioRecord(
                AudioSource.Mic, sampleRate, channelMask, Encoding.Pcm16bit, bufferSize);
        }
    }

    // MediaCodec-encoded audio path.  Mirrors AudioEncoder.encode() in scrcpy.
    private static async Task EncodeAudio(
        AudioRecord recorder, string codec, int bitrate, int sampleRate,
        int channels, int bufferSize, System.IO.Stream output, CancellationToken ct)
    {
        var fmt = MediaFormat.CreateAudioFormat(codec, sampleRate, channels)!;
        fmt.SetInteger(MediaFormat.KeyBitRate,       bitrate);
        fmt.SetInteger(MediaFormat.KeyMaxInputSize,  bufferSize);
        fmt.SetInteger(MediaFormat.KeyAacProfile,    (int)MediaCodecProfileType.Aacobjectlc);

        var encoder = MediaCodec.CreateEncoderByType(codec)!;
        encoder.Configure(fmt, null, null, MediaCodecConfigFlags.Encode);
        encoder.Start();

        var pcm  = new byte[bufferSize];
        var info = new MediaCodec.BufferInfo();

        try
        {
            while (!ct.IsCancellationRequested)
            {
                // Feed input
                int inIdx = encoder.DequeueInputBuffer(timeoutUs: 5_000);
                if (inIdx >= 0)
                {
                    var inBuf = encoder.GetInputBuffer(inIdx);
                    if (inBuf != null)
                    {
                        int n = recorder.Read(pcm, 0, Math.Min(pcm.Length, inBuf.Capacity()));
                        if (n > 0)
                        {
                            inBuf.Clear();
                            inBuf.Put(pcm, 0, n);
                            encoder.QueueInputBuffer(inIdx, 0, n, 0, 0);
                        }
                    }
                }

                // Drain output
                int outIdx = encoder.DequeueOutputBuffer(info, timeoutUs: 0);
                if (outIdx >= 0)
                {
                    var outBuf = encoder.GetOutputBuffer(outIdx);
                    if (outBuf != null && info.Size > 0)
                    {
                        var data = new byte[info.Size];
                        outBuf.Position(info.Offset);
                        outBuf.Get(data);
                        await output.WriteAsync(data, ct);
                    }
                    encoder.ReleaseOutputBuffer(outIdx, render: false);
                }
                else if (outIdx == (int)Android.Media.MediaCodecInfoState.TryAgainLater)
                {
                    await Task.Delay(1, ct);
                }
            }
        }
        finally
        {
            encoder.Stop();
            encoder.Release();
        }
    }
}

/// <summary>
/// Stops a running audio stream session started by Start-AndroidAudioStream.
/// </summary>
[Cmdlet(VerbsLifecycle.Stop, "AndroidAudioStream")]
[OutputType(typeof(bool))]
public sealed class StopAndroidAudioStreamCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0)]
    public string SessionId { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try { Emit(AudioStreamRegistry.Stop(SessionId)); }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "StopAudioStreamFailed",
                ErrorCategory.InvalidOperation, SessionId));
        }
    }
}

/// <summary>Lists all active audio-stream sessions.</summary>
[Cmdlet(VerbsCommon.Get, "AndroidAudioStream")]
public sealed class GetAndroidAudioStreamCmdlet : WrapperCmdlet
{
    protected override void ProcessRecord() => Emit(AudioStreamRegistry.List());
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------
internal sealed class AudioStreamSession(TcpListener listener, CancellationTokenSource cts)
{
    public TcpListener              Listener { get; } = listener;
    public CancellationTokenSource  Cts      { get; } = cts;

    public PSObject ToInfo(string id)
    {
        var o = new PSObject();
        o.Properties.Add(new PSNoteProperty("SessionId", id));
        o.Properties.Add(new PSNoteProperty("Active",    !Cts.IsCancellationRequested));
        return o;
    }
}

internal static class AudioStreamRegistry
{
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, AudioStreamSession>
        _sessions = new();

    public static void Register(string id, AudioStreamSession s) => _sessions[id] = s;

    public static bool Stop(string id)
    {
        if (!_sessions.TryRemove(id, out var s)) return false;
        s.Cts.Cancel();
        s.Listener.Stop();
        return true;
    }

    public static System.Collections.Generic.IEnumerable<PSObject> List()
    {
        foreach (var (id, s) in _sessions)
            yield return s.ToInfo(id);
    }
}
