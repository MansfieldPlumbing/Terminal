using Android.App;
using Android.Content;
using Android.Runtime;
using Android.Speech;

namespace Subsystem;

// Stub RecognitionService. interaction.xml must reference a valid recognitionService
// for the voice-interaction-service to parse as valid. We don't transcribe here —
// the local multimodal model (Gemma E2B) consumes audio directly — so every call
// returns ERROR_CLIENT immediately. Present only to satisfy the platform contract.
[Service(
    Name = "dev.mansfieldplumbing.subsystem.SubsystemRecognitionService",
    Exported = true)]
[IntentFilter(new[] { "android.speech.RecognitionService" })]
[MetaData("android.speech", Resource = "@xml/recognition_service")]
public class SubsystemRecognitionService : RecognitionService
{
    public SubsystemRecognitionService() { }
    protected SubsystemRecognitionService(System.IntPtr handle, JniHandleOwnership transfer)
        : base(handle, transfer) { }

    protected override void OnStartListening(Intent? recognizerIntent, RecognitionService.Callback? listener)
    {
        try { listener?.Error(SpeechRecognizerError.Client); } catch { }
    }

    protected override void OnStopListening(RecognitionService.Callback? listener) { }

    protected override void OnCancel(RecognitionService.Callback? listener) { }
}
