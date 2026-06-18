using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace Subsystem.Device;

// ============================================================================================
// STAGED DRAFT — authored outside the repo (S:\tmp\v21) so it can't touch the live gate while the
// other session holds S:\subsystem. Drop into src/runspace/Device/V21.cs when ready. The modem core
// is UNVERIFIED until round-tripped — run V21.SelfTest() once it compiles (no hardware needed).
// House-style + gate-aware: synchronous core (SS018), no ambient threads (SS009), no hardcoded paths
// (SS010/21), no banned words. Mirrors Morse/OpticalLink so the two share one shape.
// ============================================================================================

// \Device\Android\V21 — the acoustic link codec (ITU-T V.21 FSK), the audio analog of Morse. Text/bytes
// ↔ PCM tones, plus the bit-clock model that drives an audio actuator (TX) and decodes a captured
// waveform (RX). Pure DSP + a thin device loop: the codec has no host. One unit is the bit period; a
// byte is UART-framed (idle mark · start space · 8 data bits LSB-first · stop mark) — the same async
// framing every soft-modem since the 1960s uses, so a stop/start edge re-syncs the clock every byte.
//
// Framing parallels Morse exactly: a steady MARK carrier preamble (so RX locks its energy floor and bit
// clock before data — the calibration analog of Morse's steady-ON lead-in) and a mark tail so the last
// byte flushes. Without the carrier, RX would have to guess the threshold and phase cold.
public static class V21
{
    // ITU-T V.21 channel frequencies. Mark = binary 1, Space = binary 0. The two ends use DIFFERENT
    // channels, so neither hears itself even if both tones are in the air — the structural half-duplex
    // hinge, same idea as OpticalLink clearing its light ring before it lights the lamp.
    //   Channel 1 (originate): mark 980 Hz, space 1180 Hz
    //   Channel 2 (answer):    mark 1650 Hz, space 1850 Hz
    public readonly record struct Channel(int MarkHz, int SpaceHz);
    public static readonly Channel Originate = new(980, 1180);
    public static readonly Channel Answer    = new(1650, 1850);

    public const int BaudRate = 300;             // ITU-T V.21 line rate
    public const int DefaultSampleRate = 48000;  // device default; 8000 (telephone band) also valid
    public const int PreambleBits = 64;          // steady mark carrier: RX locks floor + bit phase here
    public const int TrailBits    = 8;           // mark tail so the final stop bit isn't clipped

    private const int CarrierDetectBits = 16;    // a mark run this long = "a transmission is starting"

    // ---- TX: bytes → PCM (continuous-phase FSK) ----

    // Encode text (UTF-8) as a V.21 waveform on `ch`. Continuous phase ACROSS bit boundaries — one
    // running phase accumulator, never a sine restarted per bit. Restarting would inject a discontinuity
    // at every transition (spectral splatter the demod then has to fight); a continuous phase keeps the
    // two tones clean, which is the whole reason FSK is robust on a cheap speaker + mic.
    public static float[] Encode(string text, Channel ch, int sampleRate = DefaultSampleRate)
        => EncodeBytes(Encoding.UTF8.GetBytes(text ?? ""), ch, sampleRate);

    public static float[] EncodeBytes(ReadOnlySpan<byte> data, Channel ch, int sampleRate = DefaultSampleRate)
    {
        int spb = sampleRate / BaudRate;                       // samples per bit (48000/300 = 160, exact)
        int totalBits = PreambleBits + TrailBits + data.Length * 10;   // 10 = start + 8 data + stop
        var outp = new float[totalBits * spb];

        double phase = 0;
        int w = 0;
        void EmitBit(bool mark)
        {
            double dp = 2.0 * Math.PI * (mark ? ch.MarkHz : ch.SpaceHz) / sampleRate;
            for (int i = 0; i < spb; i++)
            {
                outp[w++] = (float)Math.Sin(phase);
                phase += dp;
                if (phase >= 2.0 * Math.PI) phase -= 2.0 * Math.PI;   // keep it bounded, not drifting
            }
        }

        for (int i = 0; i < PreambleBits; i++) EmitBit(true);   // carrier
        foreach (var b in data)
        {
            EmitBit(false);                                     // start bit (space)
            for (int k = 0; k < 8; k++) EmitBit((b & (1 << k)) != 0);   // 8 data bits, LSB first
            EmitBit(true);                                      // stop bit (mark)
        }
        for (int i = 0; i < TrailBits; i++) EmitBit(true);      // tail
        return outp;
    }

    // ---- RX: PCM → bytes (non-coherent FSK demod, per-bit Goertzel) ----

    public static string Decode(float[] samples, Channel ch, int sampleRate = DefaultSampleRate)
        => Encoding.UTF8.GetString(DecodeBytes(samples, ch, sampleRate));

    // Recover the byte stream. Strategy mirrors Morse.DecodeSamples: measure the two tones' energy over
    // each bit window with a Goertzel (a single-bin DFT, O(N) per frequency — no FFT, cheap enough to run
    // per bit on a phone), learn the carrier energy from the peak, find the carrier, then for each byte
    // RE-FIND the start-bit falling edge and sample the 8 data bits at their centers. Re-syncing on every
    // start edge means clock error can't accumulate across a long message.
    public static byte[] DecodeBytes(float[] samples, Channel ch, int sampleRate = DefaultSampleRate)
    {
        if (samples == null || samples.Length < 20) return Array.Empty<byte>();
        int spb = sampleRate / BaudRate;
        int half = spb / 2;
        int len = samples.Length;

        // Energy of one tone over the bit window CENTERED on `center`.
        double Mark(int center)  => Goertzel(samples, center - half, spb, ch.MarkHz,  sampleRate);
        double Space(int center) => Goertzel(samples, center - half, spb, ch.SpaceHz, sampleRate);

        // Peak bit energy across the buffer → a relative carrier floor (absolute thresholds don't survive
        // a volume change between rooms/devices, the same reason Morse learns bright/dark from the preamble).
        double peak = 0;
        for (int c = half; c + half < len; c += spb)
        {
            double e = Math.Max(Mark(c), Space(c));
            if (e > peak) peak = e;
        }
        if (peak <= 0) return Array.Empty<byte>();
        double floor = peak * 0.15;

        bool IsMark(int c)    => Mark(c) >= Space(c);
        bool HasCarrier(int c) => Math.Max(Mark(c), Space(c)) >= floor;

        // 1. Lock the carrier: the first run of CarrierDetectBits consecutive mark windows.
        int i = half, run = 0, lockPos = -1;
        for (; i + half < len; i += spb)
        {
            if (HasCarrier(i) && IsMark(i)) { if (++run >= CarrierDetectBits) { lockPos = i; break; } }
            else run = 0;
        }
        if (lockPos < 0) return Array.Empty<byte>();

        // 2. Decode bytes. From inside the carrier, step forward to the first SPACE window (the start bit),
        //    take its center as the timing reference, read 8 data bit centers at +1..+8 bit periods, then
        //    advance past the stop bit and repeat. Carrier loss (a sustained sub-floor stretch) ends it.
        var outp = new List<byte>();
        i = lockPos;
        while (i + 10 * spb + half < len)
        {
            // advance while idle/mark/dead until a live SPACE window appears = the start-bit edge
            int guard = 0;
            while (i + half < len && (IsMark(i) || !HasCarrier(i)))
            {
                i += 1;
                if (++guard > 16 * spb) return outp.ToArray();   // long quiet → end of transmission
            }
            if (i + 10 * spb + half >= len) break;

            int startCenter = i;                                 // ~half into the start bit
            int b = 0;
            for (int k = 0; k < 8; k++)
                if (!IsMark(startCenter + (k + 1) * spb)) { } else b |= 1 << k;   // mark = 1, LSB first
            bool stopOk = IsMark(startCenter + 9 * spb);         // a real frame ends in a stop (mark)
            if (stopOk) outp.Add((byte)b);                       // framing error → drop the byte, resync
            i = startCenter + 9 * spb + half;                    // past the stop bit, hunt the next start
        }
        return outp.ToArray();
    }

    // Goertzel power of one frequency over [start, start+n). Two-term recurrence; returns squared
    // magnitude (energy), which is all the demod compares — phase is irrelevant for non-coherent FSK.
    private static double Goertzel(float[] s, int start, int n, double freq, int sampleRate)
    {
        if (start < 0) { n += start; start = 0; }
        if (start + n > s.Length) n = s.Length - start;
        if (n <= 0) return 0;
        double w = 2.0 * Math.PI * freq / sampleRate;
        double coeff = 2.0 * Math.Cos(w);
        double s1 = 0, s2 = 0;
        for (int i = 0; i < n; i++)
        {
            double s0 = s[start + i] + coeff * s1 - s2;
            s2 = s1; s1 = s0;
        }
        return s1 * s1 + s2 * s2 - coeff * s1 * s2;
    }

    // Round-trip the modem with no hardware: text → samples → text. Run this FIRST when the file lands;
    // a green here means the DSP is sound and only the audio driver remains. Tries the device band and
    // the telephone band so a future PSTN/voip leg is covered too.
    public static bool SelfTest()
    {
        const string msg = "SUBSYSTEM V21 CQ DE NODE-A 73";
        foreach (var sr in new[] { DefaultSampleRate, 8000 })
            foreach (var ch in new[] { Originate, Answer })
            {
                var wave = Encode(msg, ch, sr);
                var back = Decode(wave, ch, sr);
                if (back != msg) { Subsystem.Dg.Log("v21", $"SELFTEST FAIL sr={sr} ch={ch.MarkHz} got='{back}'"); return false; }
            }
        Subsystem.Dg.Log("v21", "SELFTEST PASS (modem round-trips clean)");
        return true;
    }
}

// The acoustic device seam — the audio analog of Morse's Torch (TX) + Light (RX). The MODEM above is
// platform-agnostic sample math; the actual speaker/mic is a per-head leaf (a mount, not kernel code):
//   Android → the existing Audio actuator (AudioTrack) + AudioRecord
//   Windows → WASAPI / waveOut
// Keeping the device behind this interface is what lets the modem compile + SelfTest on both heads with
// no hardware in the loop.
public interface IAcousticDevice
{
    void Play(float[] samples, int sampleRate);          // blocks until the tone finishes (half-duplex)
    float[] Capture(int ms, int sampleRate, CancellationToken ct);   // one RX window of mono PCM
}

// The transport rung the ladder is built from: optical (OpticalLink), acoustic (AudioLink below), and
// PSRP all answer the SAME shape, so a caller can step up the ladder without changing its code. Reuses
// OpticalLink.LinkResult — one result type across every rung.
public interface ILink
{
    OpticalLink.LinkResult Send(string text, CancellationToken ct = default);
    OpticalLink.LinkResult Receive(CancellationToken ct = default);
}

// \Device\Android\AudioLink — the acknowledged half-duplex protocol over the V.21 acoustic layer. The
// SAME ham-shaped handshake as OpticalLink (CQ → K → payload → R); only the physical layer changed from
// light to sound. Half-duplex is structural: a capture window always closes before Play() opens, and the
// two ends sit on different channels, so a side never decodes its own tones.
public sealed class AudioLink : ILink
{
    private readonly IAcousticDevice _dev;
    private readonly V21.Channel _txChannel;   // this side transmits here
    private readonly V21.Channel _rxChannel;   // and listens here (the peer's TX channel)
    private readonly int _sampleRate;

    public const string Hail = "CQ", Invite = "K", Roger = "R";
    private const int WindowMs = 4000;     // one RX window

    // role = caller → TX on Originate, RX on Answer; role = listener → the reverse. The asymmetric
    // channel assignment is what makes the half-duplex collision-free.
    public AudioLink(IAcousticDevice dev, bool caller, int sampleRate = V21.DefaultSampleRate)
    {
        _dev = dev;
        _sampleRate = sampleRate;
        _txChannel = caller ? V21.Originate : V21.Answer;
        _rxChannel = caller ? V21.Answer    : V21.Originate;
    }

    public OpticalLink.LinkResult Send(string text, CancellationToken ct = default)
    {
        var clock = Stopwatch.StartNew();
        for (int attempt = 1; attempt <= 3 && !ct.IsCancellationRequested; attempt++)
        {
            Transmit(Hail, ct);
            if (!Heard(Listen(ct), Invite)) continue;        // no K → re-hail
            Transmit(text, ct);
            bool ok = Heard(Listen(ct), Roger);
            return new OpticalLink.LinkResult(ok, text, attempt, clock.ElapsedMilliseconds);
        }
        return new OpticalLink.LinkResult(false, text, 3, clock.ElapsedMilliseconds);
    }

    public OpticalLink.LinkResult Receive(CancellationToken ct = default)
    {
        var clock = Stopwatch.StartNew();
        while (!ct.IsCancellationRequested)
        {
            if (!Heard(Listen(ct), Hail)) continue;          // wait for a hail
            Transmit(Invite, ct);
            string payload = Listen(ct);
            if (payload.Length == 0) continue;               // caller went quiet → re-arm
            Transmit(Roger, ct);
            return new OpticalLink.LinkResult(true, payload, 1, clock.ElapsedMilliseconds);
        }
        return new OpticalLink.LinkResult(false, "", 1, clock.ElapsedMilliseconds);
    }

    private void Transmit(string text, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) return;
        _dev.Play(V21.Encode(text, _txChannel, _sampleRate), _sampleRate);
    }

    private string Listen(CancellationToken ct)
        => V21.Decode(_dev.Capture(WindowMs, _sampleRate, ct), _rxChannel, _sampleRate);

    private static bool Heard(string decoded, string token)
        => decoded.Length > 0 && decoded.Contains(token, StringComparison.OrdinalIgnoreCase);
}
