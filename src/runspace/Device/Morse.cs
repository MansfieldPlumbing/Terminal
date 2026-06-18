using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace Subsystem.Device;

// \Device\Android\Morse — the optical link codec. Text ↔ International Morse, plus the timing model
// that drives the Torch actuator (TX) and decodes the Light sensor stream (RX). Pure logic + a thin
// actuator loop: the codec has no host; Transmit borrows the Torch driver, Decode is fed lux samples
// by the Light driver. One unit is the base interval; everything else is a multiple of it (dot = 1
// ON, dash = 3 ON, intra-character gap = 1 OFF, inter-character = 3 OFF, word = 7 OFF — the ITU model).
//
// Framing: a transmission is bracketed by a CALIBRATION PREAMBLE (one long steady ON) so the receiver
// can learn this room's bright/dark levels before any data arrives, and a matching tail of silence so
// the last character flushes. Without the preamble, RX would have to guess the threshold cold.
public static class Morse
{
    // Default base interval. 200ms is the reliability sweet spot for the ambient-light sensor: long
    // enough that a ~5–50Hz lux sample rate resolves a dot, short enough to stay watchable.
    public const int DefaultUnitMs = 200;

    // Steady-ON calibration lead-in / end-of-transmission tail: PreambleUnits of light. Long enough
    // that RX can never confuse it with a dash (3 units) — the marker threshold sits at PreambleUnits-1.
    public const int PreambleUnits = 6;

    // A run this many units or longer is a FRAME MARKER (preamble or EOT), not a dash. 5 units cleanly
    // separates the 6-unit markers from a 3-unit dash even with sampling jitter.
    private static int MarkerUnits => PreambleUnits - 1;

    private static readonly IReadOnlyDictionary<char, string> Table = new Dictionary<char, string>
    {
        ['A'] = ".-",    ['B'] = "-...",  ['C'] = "-.-.",  ['D'] = "-..",   ['E'] = ".",
        ['F'] = "..-.",  ['G'] = "--.",   ['H'] = "....",  ['I'] = "..",    ['J'] = ".---",
        ['K'] = "-.-",   ['L'] = ".-..",  ['M'] = "--",    ['N'] = "-.",    ['O'] = "---",
        ['P'] = ".--.",  ['Q'] = "--.-",  ['R'] = ".-.",   ['S'] = "...",   ['T'] = "-",
        ['U'] = "..-",   ['V'] = "...-",  ['W'] = ".--",   ['X'] = "-..-",  ['Y'] = "-.--",
        ['Z'] = "--..",
        ['0'] = "-----", ['1'] = ".----", ['2'] = "..---", ['3'] = "...--", ['4'] = "....-",
        ['5'] = ".....", ['6'] = "-....", ['7'] = "--...", ['8'] = "---..", ['9'] = "----.",
        ['.'] = ".-.-.-", [','] = "--..--", ['?'] = "..--..", ['\''] = ".----.", ['!'] = "-.-.--",
        ['/'] = "-..-.", ['('] = "-.--.",  [')'] = "-.--.-", ['&'] = ".-...",  [':'] = "---...",
        [';'] = "-.-.-.", ['='] = "-...-",  ['+'] = ".-.-.",  ['-'] = "-....-", ['_'] = "..--.-",
        ['"'] = ".-..-.", ['@'] = ".--.-.",
    };

    private static readonly IReadOnlyDictionary<string, char> Reverse = BuildReverse();

    private static IReadOnlyDictionary<string, char> BuildReverse()
    {
        var r = new Dictionary<string, char>();
        foreach (var kv in Table) r[kv.Value] = kv.Key;
        return r;
    }

    // ---- codec ----

    // Text → dotted Morse. Characters are space-separated; words are " / "-separated. Unknown
    // characters are dropped (logged once at the call site, not silently lost mid-stream).
    public static string Encode(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var words = text.Trim().ToUpperInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var sb = new StringBuilder();
        for (int w = 0; w < words.Length; w++)
        {
            if (w > 0) sb.Append(" / ");
            bool firstChar = true;
            foreach (var c in words[w])
            {
                if (!Table.TryGetValue(c, out var code)) continue;
                if (!firstChar) sb.Append(' ');
                sb.Append(code);
                firstChar = false;
            }
        }
        return sb.ToString();
    }

    // Dotted Morse → text. Tolerant of extra whitespace; "/" (any surrounding spaces) is a word break.
    public static string Decode(string morse)
    {
        if (string.IsNullOrWhiteSpace(morse)) return "";
        var sb = new StringBuilder();
        foreach (var word in morse.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (sb.Length > 0) sb.Append(' ');
            foreach (var sym in word.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                if (Reverse.TryGetValue(sym, out var c)) sb.Append(c);
        }
        return sb.ToString();
    }

    // ---- TX: drive the Torch actuator on the unit clock ----

    // Flash `text` as Morse over the torch. Synchronous and cancellable — the caller (the Send-Morse
    // cmdlet, the chat loop) owns this as its foreground task, so Ctrl+C / a dropped token stops it
    // and the torch is always left OFF. The leading steady-ON preamble lets a receiver calibrate.
    public static void Transmit(string text, int unitMs = DefaultUnitMs, CancellationToken ct = default)
    {
        var code = Encode(text);
        if (code.Length == 0) return;

        // Lamp(...) is best-effort: the optical signal degrades gracefully if a single pulse glitches
        // (a Morse stream of hundreds of toggles shouldn't abort on one transient camera hiccup). The
        // FIRST toggle is NOT swallowed — a genuinely dead torch fails Send-Morse fast, up front.
        bool first = true;
        void Lamp(bool on, int units)
        {
            try { Torch.SetFlashlight(on ? "On" : "Off"); }
            catch (Exception ex) { if (first) throw; Subsystem.Dg.Warn("morse", ex); }
            first = false;
            Sleep(units * unitMs, ct);
        }
        void On(int units)  => Lamp(true, units);
        void Off(int units) => Lamp(false, units);

        try
        {
            // Calibration preamble: steady ON, then a 3-unit gap that marks "data starts now".
            On(PreambleUnits);
            Off(3);

            foreach (var ch in code)
            {
                if (ct.IsCancellationRequested) break;
                switch (ch)
                {
                    case '.': On(1); Off(1); break;   // dot + intra-character gap
                    case '-': On(3); Off(1); break;   // dash + intra-character gap
                    case ' ': Off(2); break;          // already 1 unit off from the prior symbol → 3 total (inter-character)
                    case '/': Off(4); break;          // → 7 total with the surrounding symbol gaps (word)
                }
            }

            // End-of-transmission marker: a clear gap then a steady long ON. The receiver locks onto
            // this to know the message is COMPLETE (so it stops listening immediately instead of
            // waiting out its whole timeout, and trailing ambient flicker can't corrupt the tail).
            if (!ct.IsCancellationRequested) { Off(2); On(PreambleUnits); }
        }
        finally
        {
            // Never leave the lamp on, even on cancel/throw. An Off failure is recorded, not rethrown:
            // a throw here would mask the original exception, and nothing above can turn the torch off.
            try { Torch.SetFlashlight("Off"); } catch (Exception ex) { Subsystem.Dg.Warn("morse", ex); }
        }
    }

    private static void Sleep(int ms, CancellationToken ct)
    {
        if (ct.CanBeCanceled) ct.WaitHandle.WaitOne(ms);
        else Thread.Sleep(ms);
    }

    // ---- RX: reconstruct text from a thresholded light stream ----

    // A light sample: when it was taken (ms since an arbitrary epoch) and the lux reading.
    public readonly record struct LightSample(long TimeMs, float Lux);

    // Decode a captured lux stream into text. Strategy: learn the bright level from the preamble
    // (the brightest sustained run), set the threshold at the midpoint to the dark floor, segment the
    // stream into ON/OFF runs, quantise each run's duration to units against the estimated unit length,
    // and map run-lengths back to dots/dashes/gaps. Returns "" if it can't lock onto a preamble.
    public static string DecodeSamples(IReadOnlyList<LightSample> samples, int unitMs = DefaultUnitMs)
    {
        if (samples == null || samples.Count < 4) return "";

        float min = float.MaxValue, max = float.MinValue;
        foreach (var s in samples) { if (s.Lux < min) min = s.Lux; if (s.Lux > max) max = s.Lux; }
        if (max - min < 1f) return "";                 // no modulation — nothing was transmitted
        float threshold = min + (max - min) * 0.5f;    // bright vs dark midpoint

        // Collapse the sample stream into (level, durationMs) runs.
        var runs = new List<(bool On, long Ms)>();
        bool curOn = samples[0].Lux >= threshold;
        long runStart = samples[0].TimeMs;
        for (int i = 1; i < samples.Count; i++)
        {
            bool on = samples[i].Lux >= threshold;
            if (on != curOn)
            {
                runs.Add((curOn, samples[i].TimeMs - runStart));
                curOn = on; runStart = samples[i].TimeMs;
            }
        }
        runs.Add((curOn, samples[^1].TimeMs - runStart));

        // Lock onto the calibration preamble: the first MARKER-length ON run (≥ MarkerUnits, well
        // above a dash). Everything before it is pre-transmission noise; data begins after it.
        int start = -1;
        for (int i = 0; i < runs.Count; i++)
            if (runs[i].On && Units(runs[i].Ms, unitMs) >= MarkerUnits) { start = i + 1; break; }
        if (start < 0) return "";

        var dots = new StringBuilder();
        for (int i = start; i < runs.Count; i++)
        {
            var (on, ms) = runs[i];
            int u = Units(ms, unitMs);
            if (on)
            {
                if (u >= MarkerUnits) break;           // the EOT marker — message ends here, stop cleanly
                dots.Append(u >= 2 ? '-' : '.');       // 1 unit = dot, ≥2 = dash (tolerance for jitter)
            }
            else
            {
                if (u <= 1) { /* intra-character gap — symbols stay joined */ }
                else if (u <= 5) dots.Append(' ');     // inter-character
                else dots.Append(" / ");               // word
            }
        }
        return Decode(dots.ToString());
    }

    private static int Units(long ms, int unitMs) => Math.Max(1, (int)Math.Round(ms / (double)unitMs));

    // True once a COMPLETE frame has landed: the preamble marker, the data, and the EOT marker's ON
    // run CLOSED — i.e. the first dark sample after the EOT pulse. Receive-Morse polls this so it
    // returns the instant a message is fully received instead of waiting out its whole timeout. The
    // frame MUST count as complete on that closing OFF edge: in steady darkness after EOT the OFF run
    // never closes (an on-change sensor reports nothing more), so any rule that requires the post-EOT
    // silence to end (light again) never fires and every listen runs to full timeout.
    public static bool FrameComplete(IReadOnlyList<LightSample> samples, int unitMs = DefaultUnitMs)
    {
        if (samples == null || samples.Count < 8) return false;

        float min = float.MaxValue, max = float.MinValue;
        foreach (var s in samples) { if (s.Lux < min) min = s.Lux; if (s.Lux > max) max = s.Lux; }
        if (max - min < 1f) return false;
        float threshold = min + (max - min) * 0.5f;

        int markers = 0;
        bool curOn = samples[0].Lux >= threshold;
        long runStart = samples[0].TimeMs;
        for (int i = 1; i < samples.Count; i++)
        {
            bool on = samples[i].Lux >= threshold;
            if (on == curOn) continue;
            // A marker-length ON run just closed; the 2nd is the EOT pulse ending — frame complete.
            if (curOn && Units(samples[i].TimeMs - runStart, unitMs) >= MarkerUnits && ++markers >= 2) return true;
            curOn = on; runStart = samples[i].TimeMs;
        }
        return false;
    }
}

// \Device\Android\OpticalLink — OL/1, the acknowledged-transfer protocol over the Morse optical layer
// (ham-shaped: CQ → K → payload → R). Half-duplex is structural, not negotiated: each side's TX and RX
// are strictly sequential — an RX window always closes before the lamp lights — so a side can never
// hear itself. Every RX window clears the light ring at open, which also discards the side's own
// just-transmitted flashes. Tokens are matched by CONTAINS: a 1–2 letter token in a noisy window
// decodes with junk letters padding it, so equality would reject good acks.
public static class OpticalLink
{
    public const string Hail   = "CQ";   // caller: anyone listening?
    public const string Invite = "K";    // listener: go ahead
    public const string Roger  = "R";    // listener: payload received

    // RX poll cadence. Coarse relative to the unit clock so FrameComplete sees whole runs land.
    private const int PollMs = 250;

    public readonly record struct LinkResult(bool Ok, string Text, int Attempts, long ElapsedMs);

    // Caller: TX the hail → RX window for the invite (K) → TX the payload → RX window for the ack (R).
    // The hail retries up to `retries` times (the listener may still be mid-window when we first call);
    // each RX window is `ackTimeoutMs`. Every wait honors `ct`; the light sensor stops on every exit.
    public static LinkResult Send(string text, int retries = 3, int ackTimeoutMs = 10_000,
                                  int unitMs = Morse.DefaultUnitMs, CancellationToken ct = default)
    {
        var clock = Stopwatch.StartNew();
        int attempts = 0;
        try
        {
            for (int attempt = 1; attempt <= retries && !ct.IsCancellationRequested; attempt++)
            {
                attempts = attempt;
                Morse.Transmit(Hail, unitMs, ct);
                if (!Heard(Listen(ackTimeoutMs, unitMs, ct), Invite)) continue;   // no K — re-hail
                Morse.Transmit(text, unitMs, ct);
                bool ok = Heard(Listen(ackTimeoutMs, unitMs, ct), Roger);
                return new LinkResult(ok, text, attempt, clock.ElapsedMilliseconds);
            }
            return new LinkResult(false, text, attempts, clock.ElapsedMilliseconds);
        }
        finally { Light.Stop(); }   // the RX windows share one sensor session — never leave it powered
    }

    // Listener: RX until a hail (CQ) lands → TX the invite (K) → RX the payload to EOT → TX the ack (R).
    // Re-hail recovery: a caller that missed our K hails again instead of sending data — answer every
    // re-hail with a fresh K. An empty payload window means the caller went quiet; re-arm the hail watch.
    public static LinkResult Receive(int timeoutMs = 120_000, int unitMs = Morse.DefaultUnitMs,
                                     CancellationToken ct = default)
    {
        var clock = Stopwatch.StartNew();
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int remaining = timeoutMs - (int)clock.ElapsedMilliseconds;
                if (remaining <= 0) break;
                if (!Heard(Listen(remaining, unitMs, ct), Hail)) continue;   // not a hail — keep watching

                Morse.Transmit(Invite, unitMs, ct);
                while (!ct.IsCancellationRequested)
                {
                    remaining = timeoutMs - (int)clock.ElapsedMilliseconds;
                    if (remaining <= 0) break;
                    var payload = Listen(remaining, unitMs, ct);
                    if (payload.Length == 0) break;   // caller went quiet — back to the hail watch
                    if (IsRehail(payload)) { Morse.Transmit(Invite, unitMs, ct); continue; }
                    Morse.Transmit(Roger, unitMs, ct);
                    return new LinkResult(true, payload, 1, clock.ElapsedMilliseconds);
                }
            }
            return new LinkResult(false, "", 1, clock.ElapsedMilliseconds);
        }
        finally { Light.Stop(); }
    }

    // One RX window: clear the ring, poll the live light stream until a complete frame lands or the
    // window closes, decode what landed. Clearing at open is the half-duplex hinge — it discards our
    // own just-finished transmit so we never decode our own flashes.
    private static string Listen(int timeoutMs, int unitMs, CancellationToken ct)
    {
        if (!Light.Start()) return "";
        Light.Clear();
        var clock = Stopwatch.StartNew();
        IReadOnlyList<Morse.LightSample> samples = Array.Empty<Morse.LightSample>();
        while (clock.ElapsedMilliseconds < timeoutMs && !ct.IsCancellationRequested)
        {
            Wait(PollMs, ct);
            samples = Light.Samples();
            if (Morse.FrameComplete(samples, unitMs)) break;
        }
        return Morse.DecodeSamples(samples, unitMs);
    }

    private static bool Heard(string decoded, string token)
        => decoded.Length > 0 && decoded.Contains(token, StringComparison.OrdinalIgnoreCase);

    // A re-hail is a SHORT frame around CQ — the length guard keeps a real payload that merely
    // mentions CQ from being swallowed as a handshake artifact.
    private static bool IsRehail(string decoded)
        => Heard(decoded, Hail) && decoded.Trim().Length <= Hail.Length * 3;

    private static void Wait(int ms, CancellationToken ct)
    {
        if (ct.CanBeCanceled) ct.WaitHandle.WaitOne(ms);
        else Thread.Sleep(ms);
    }
}
