using Android.Content;
using Android.OS;
using Android.Speech.Tts;
using Android.Util;

namespace Subsystem;

// Text-to-speech output. Wraps the on-device TTS engine (Samsung SMT default, Google TTS
// fallback). Used for spoken confirmations ("Flashlight on") and, later, E2B's
// replies. Init once, reuse. Fully offline.
public class SpeechOutput : Java.Lang.Object, TextToSpeech.IOnInitListener
{
    private const string Tag = "SubsystemTts";
    private TextToSpeech? _tts;
    private TaskCompletionSource<bool>? _initTcs;
    private static int _uttCounter = 0;

    public bool Ready { get; private set; }

    public Task<bool> InitAsync(Context ctx)
    {
        _initTcs = new TaskCompletionSource<bool>();
        _tts = new TextToSpeech(ctx, this); // null engine => system default (Samsung SMT)
        return _initTcs.Task;
    }

    public void OnInit([Android.Runtime.GeneratedEnum] OperationResult status)
    {
        if (status == OperationResult.Success && _tts != null)
        {
            _tts.SetLanguage(Java.Util.Locale.Default);
            Ready = true;
            Log.Info(Tag, "TTS ready.");
            _initTcs?.TrySetResult(true);
        }
        else
        {
            Log.Warn(Tag, $"TTS init failed: {status}");
            _initTcs?.TrySetResult(false);
        }
    }

    public void Speak(string text, bool flush = true)
    {
        if (!Ready || _tts == null) return;
        string uttId = $"subsystem-{System.Threading.Interlocked.Increment(ref _uttCounter)}";
        _tts.Speak(text, flush ? QueueMode.Flush : QueueMode.Add, null, uttId);
    }

    public void Stop() { try { _tts?.Stop(); } catch { } }

    protected override void Dispose(bool disposing)
    {
        try { _tts?.Stop(); _tts?.Shutdown(); } catch { }
        _tts = null;
        base.Dispose(disposing);
    }
}
