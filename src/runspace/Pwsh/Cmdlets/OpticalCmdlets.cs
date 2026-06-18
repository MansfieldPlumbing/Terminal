using System;
using System.Management.Automation;
using System.Threading;
using Subsystem.Device;

namespace Subsystem.Pwsh.Cmdlets;

// The optical link + voice surface — the grandma demo's cmdlet face. Send-Morse flashes text over the
// torch; Receive-Morse decodes the light sensor back to text; Out-Speech says it aloud. Two phones in
// airplane mode talk over light alone: Broker writes a line → Out-Speech → Send-Morse; the peer's
// Receive-Morse decodes → Broker replies → back over the lamp.

// The pure codec — text ↔ dotted Morse, no device. The idiomatic ConvertTo/ConvertFrom pair Broker
// composes (e.g. `ConvertTo-Morse 'sos' | Send-Morse`); Send/Receive-Morse drive the optical link.
[Cmdlet(VerbsData.ConvertTo, "Morse")]
public sealed class ConvertToMorseCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    public string Text { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try { Emit(Morse.Encode(Text)); }
        catch (Exception ex) { WriteError(new ErrorRecord(ex, "ConvertToMorseFailed", ErrorCategory.InvalidOperation, Text)); }
    }
}

[Cmdlet(VerbsData.ConvertFrom, "Morse")]
public sealed class ConvertFromMorseCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    public string Morse { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try { Emit(Subsystem.Device.Morse.Decode(Morse)); }
        catch (Exception ex) { WriteError(new ErrorRecord(ex, "ConvertFromMorseFailed", ErrorCategory.InvalidOperation, Morse)); }
    }
}

[Cmdlet(VerbsCommunications.Send, "Morse")]
public sealed class SendMorseCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    public string Text { get; set; } = string.Empty;

    // The base unit (ms). Longer = more reliable for the light sensor, slower to watch.
    [Parameter] public int UnitMs { get; set; } = Morse.DefaultUnitMs;

    // Emit the dotted Morse it sent (so a caller/UI can show the code alongside the flashes).
    [Parameter] public SwitchParameter PassThru { get; set; }

    // OL/1: acknowledged transfer — hail (CQ), wait for the invite (K), send, wait for the ack (R).
    [Parameter] public SwitchParameter Handshake { get; set; }

    // OL/1 hail retries and per-RX-window ack wait. Only meaningful with -Handshake.
    [Parameter] public int Retries { get; set; } = 3;
    [Parameter] public int AckTimeoutSeconds { get; set; } = 10;

    // Cancelled by StopProcessing (Ctrl+C, on the pipeline-stop thread) while ProcessRecord blocks —
    // the flash loop and every OL/1 wait observe it, and the torch is always left OFF.
    private readonly CancellationTokenSource _cts = new();

    protected override void StopProcessing() => _cts.Cancel();

    protected override void ProcessRecord()
    {
        try
        {
            if (Handshake.IsPresent)
            {
                // OL/1 needs the RX half too: the ack windows listen on the light sensor.
                if (!Light.Available)
                {
                    WriteError(new ErrorRecord(
                        new PlatformNotSupportedException("OL/1 needs an ambient-light sensor for the ack windows."),
                        "NoLightSensor", ErrorCategory.DeviceError, null));
                    return;
                }
                var r = OpticalLink.Send(Text, Retries, AckTimeoutSeconds * 1000, UnitMs, _cts.Token);
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Direction", "Send"));
                obj.Properties.Add(new PSNoteProperty("Text", Text));
                obj.Properties.Add(new PSNoteProperty("HandshakeOk", r.Ok));
                obj.Properties.Add(new PSNoteProperty("Attempts", r.Attempts));
                obj.Properties.Add(new PSNoteProperty("ElapsedMs", r.ElapsedMs));
                Emit(obj);
                return;
            }

            Morse.Transmit(Text, UnitMs, _cts.Token);
            if (PassThru.IsPresent) Emit(Morse.Encode(Text));
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "SendMorseFailed", ErrorCategory.InvalidOperation, Text));
        }
    }
}

[Cmdlet(VerbsCommunications.Receive, "Morse")]
public sealed class ReceiveMorseCmdlet : WrapperCmdlet
{
    // How long to listen on the light sensor before decoding. Unset with -Handshake it rises to
    // 120 s — a hail/payload/ack exchange is minutes-shaped, not a single frame.
    [Parameter(Position = 0)] public int TimeoutSec { get; set; } = 12;

    // Must match the transmitter's unit. Default pairs with Send-Morse's default.
    [Parameter] public int UnitMs { get; set; } = Morse.DefaultUnitMs;

    // Return the raw lux window + decoded code instead of just the text (tuning / diagnostics).
    [Parameter] public SwitchParameter Detailed { get; set; }

    // OL/1 listener: wait for the hail (CQ), invite (K), receive the payload to EOT, ack (R).
    [Parameter] public SwitchParameter Handshake { get; set; }

    // Cancelled by StopProcessing (Ctrl+C, on the pipeline-stop thread) — the poll loop and every
    // OL/1 wait observe it, and the light sensor is stopped in finally either way.
    private readonly CancellationTokenSource _cts = new();

    protected override void StopProcessing() => _cts.Cancel();

    protected override void ProcessRecord()
    {
        try
        {
            if (!Light.Available)
            {
                WriteError(new ErrorRecord(
                    new PlatformNotSupportedException("This device has no ambient-light sensor."),
                    "NoLightSensor", ErrorCategory.DeviceError, null));
                return;
            }

            if (Handshake.IsPresent)
            {
                int timeoutSec = MyInvocation.BoundParameters.ContainsKey(nameof(TimeoutSec)) ? TimeoutSec : 120;
                var r = OpticalLink.Receive(timeoutSec * 1000, UnitMs, _cts.Token);
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Direction", "Receive"));
                obj.Properties.Add(new PSNoteProperty("Text", r.Text));
                obj.Properties.Add(new PSNoteProperty("HandshakeOk", r.Ok));
                obj.Properties.Add(new PSNoteProperty("ElapsedMs", r.ElapsedMs));
                Emit(obj);
                return;
            }

            // Listen until the EOT marker arrives (a complete frame) OR the timeout — whichever first.
            // Poll the live light window every PollMs; the EOT lets a fast message return immediately
            // instead of always blocking the full TimeoutSec.
            const int PollMs = 300;
            var deadline = DateTime.UtcNow.AddSeconds(TimeoutSec);
            Light.Start();
            Light.Clear();
            System.Collections.Generic.IReadOnlyList<Morse.LightSample> samples;
            while (true)
            {
                _cts.Token.WaitHandle.WaitOne(PollMs);                    // interruptible — Ctrl+C lands mid-wait
                samples = Light.Samples();
                if (Morse.FrameComplete(samples, UnitMs)) break;          // EOT seen — done early
                if (DateTime.UtcNow >= deadline || _cts.IsCancellationRequested || Stopping) break;
            }
            var text = Morse.DecodeSamples(samples, UnitMs);

            if (Detailed.IsPresent)
            {
                var obj = new PSObject();
                obj.Properties.Add(new PSNoteProperty("Text", text));
                obj.Properties.Add(new PSNoteProperty("Samples", samples.Count));
                obj.Properties.Add(new PSNoteProperty("UnitMs", UnitMs));
                Emit(obj);
            }
            else Emit(text);
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "ReceiveMorseFailed", ErrorCategory.InvalidOperation, null));
        }
        finally { Light.Stop(); }
    }
}

[Cmdlet(VerbsData.Out, "Speech")]
public sealed class OutSpeechCmdlet : WrapperCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    public string Text { get; set; } = string.Empty;

    protected override void ProcessRecord()
    {
        try
        {
            var host = Subsystem.MainActivity.Instance
                ?? throw new InvalidOperationException("MainActivity.Instance is not initialized.");
            host.Speak(Text);   // built-in TTS, offline; fire-and-forget (the engine queues it)
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "OutSpeechFailed", ErrorCategory.InvalidOperation, Text));
        }
    }
}
