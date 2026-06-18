using System;
using System.Collections.Generic;
using Android.Hardware;

namespace Subsystem.Device;

// \Device\Android\Light — the ambient-light streaming driver, the RX half of the optical Morse link.
// Registers ONE listener on TYPE_LIGHT and accumulates (timestamp, lux) samples into a bounded ring.
// The Morse decoder (Subsystem.Device.Morse.DecodeSamples) consumes a captured window of these.
//
// A single shared listener: Start is idempotent (ref-free — the demo has one reader), Stop releases
// the sensor so it isn't left powered. Capture() drains a fresh window: Start, settle, drain.
public static class Light
{
    // Must hold a WHOLE frame at sensor rate: a continuously-reporting sensor over a long OL/1
    // payload window would otherwise evict the calibration preamble and blind the decoder's
    // threshold lock (DecodeSamples returns "" without the preamble marker).
    private const int RingCapacity = 16384;

    private static readonly object _gate = new();
    private static SensorManager? _sm;
    private static Sensor? _sensor;
    private static Listener? _listener;
    private static readonly Queue<Morse.LightSample> _ring = new(RingCapacity + 1);
    private static readonly System.Diagnostics.Stopwatch _clock = System.Diagnostics.Stopwatch.StartNew();

    public static bool Available
    {
        get
        {
            try
            {
                var ctx = Android.App.Application.Context;
                using var sm = (SensorManager?)ctx.GetSystemService(Android.Content.Context.SensorService);
                return sm?.GetDefaultSensor(SensorType.Light) != null;
            }
            catch { return false; }
        }
    }

    public static bool Start()
    {
        lock (_gate)
        {
            if (_listener != null) return true;
            try
            {
                var ctx = Android.App.Application.Context;
                _sm = (SensorManager?)ctx.GetSystemService(Android.Content.Context.SensorService);
                _sensor = _sm?.GetDefaultSensor(SensorType.Light);
                if (_sm == null || _sensor == null) { Subsystem.Dg.Warn("light", "no ambient-light sensor"); return false; }
                _listener = new Listener();
                // FASTEST: the demo needs the highest sample rate the sensor offers to resolve a 200ms dot.
                _sm.RegisterListener(_listener, _sensor, SensorDelay.Fastest);
                return true;
            }
            catch (Exception ex) { Subsystem.Dg.Warn("light", ex); return false; }
        }
    }

    public static void Stop()
    {
        lock (_gate)
        {
            try { if (_sm != null && _listener != null) _sm.UnregisterListener(_listener); }
            catch (Exception ex) { Subsystem.Dg.Warn("light", ex); }
            _listener?.Dispose();
            _listener = null;
            _sensor = null;
            _sm = null;
        }
    }

    // The current sample window (newest last). A COPY — the caller never holds the live ring.
    public static IReadOnlyList<Morse.LightSample> Samples()
    {
        lock (_gate) { return _ring.ToArray(); }
    }

    public static void Clear()
    {
        lock (_gate) { _ring.Clear(); }
    }

    internal static void Push(float lux)
    {
        lock (_gate)
        {
            _ring.Enqueue(new Morse.LightSample(_clock.ElapsedMilliseconds, lux));
            while (_ring.Count > RingCapacity) _ring.Dequeue();
        }
    }

    // Capture a fresh window: clear, listen for durationMs, return what landed. Used by Receive-Morse.
    public static IReadOnlyList<Morse.LightSample> Capture(int durationMs, System.Threading.CancellationToken ct = default)
    {
        if (!Start()) return Array.Empty<Morse.LightSample>();
        Clear();
        if (ct.CanBeCanceled) ct.WaitHandle.WaitOne(durationMs); else System.Threading.Thread.Sleep(durationMs);
        return Samples();
    }

    private sealed class Listener : Java.Lang.Object, ISensorEventListener
    {
        public void OnSensorChanged(SensorEvent? e)
        {
            if (e?.Values != null && e.Values.Count > 0) Push(e.Values[0]);
        }
        public void OnAccuracyChanged(Sensor? sensor, [Android.Runtime.GeneratedEnum] SensorStatus accuracy) { }
    }
}
