using System;
using System.Threading.Tasks;
using Android.Content;
using Android.Graphics;
using Android.Util;

namespace Subsystem;

// The assist gesture's route into the RuntimeBroker (Rb). Captures the screen + audio and
// dispatches them to the shared Rb, then speaks the reply via on-device TTS. First cold call loads
// the model (~10s; no re-download once in private storage). Fire-and-forget so the gesture never blocks.
// NOTE (VOM-SPEC §4b): the audio path here still uses a managed byte[] — flagged for migration to a
// fenced \Capture\Mic handle in Phase 2 (managed byte[] across JNI risks GC pauses + GREF exhaustion).
public static class AssistDispatch
{
    private const string Tag = "SubsystemVoice";
    private static SpeechOutput? _tts;

    public static void OnAssist(Context ctx, byte[] audioData, string screenText, Bitmap? screenshot)
    {
        // Callers hand us whatever the OS gave them — null inputs degrade to empty, never throw.
        audioData ??= Array.Empty<byte>();
        screenText ??= "";

        // Screen-vision is OPT-IN (priority lane: nothing fires unprompted). When off we never read or
        // forward the screen — the captured text/screenshot are dropped here and the model is told the
        // context is unavailable. Both the view-tree text and the screenshot (vision input) are gated.
        bool screenVision = AgentSettings.UseScreenVision(ctx);
        string screenContext = screenVision ? screenText : "(screen vision off)";

        _ = Task.Run(async () =>
        {
            try
            {
                string ctxText = screenContext.Length > 2000 ? screenContext.Substring(0, 2000) : screenContext;
                string prompt = "You are the phone's on-device voice assistant. Screen Context:\n\n" + ctxText;

                Log.Info(Tag, screenVision ? "Assist -> Rb (loading model if cold)…" : "Assist -> Rb (screen vision off)…");
                await SpeakStreaming(ctx, prompt, audioData);
            }
            catch (Exception ex) { Dg.Error("voice", "assist dispatch failed: " + ex.Message); }
        });
    }

    private static async Task SpeakStreaming(Context ctx, string prompt, byte[] audioData)
    {
        try
        {
            // Spoken output is OPT-IN (priority lane: default silence). When off we still run the turn —
            // the reply streams and is surfaced for non-audible consumers — but we never init or drive the
            // TTS engine. No SpeechOutput is constructed, so nothing speaks unprompted.
            bool speak = AgentSettings.SpeakReplies(ctx);
            if (speak && _tts == null) { _tts = new SpeechOutput(); await _tts.InitAsync(ctx); }

            var assistant = await Rb.GetAsync(ctx);
            var sentenceBuffer = new System.Text.StringBuilder();

            await foreach (var chunk in assistant.SendMessageStreamAsync(prompt, audioData))
            {
                sentenceBuffer.Append(chunk);
                string currentStr = sentenceBuffer.ToString();

                // naive sentence splitting
                int splitIdx = currentStr.LastIndexOfAny(new[] { '.', '!', '?', '\n' });
                if (splitIdx >= 0)
                {
                    string sentence = currentStr.Substring(0, splitIdx + 1).Trim();
                    string remainder = currentStr.Substring(splitIdx + 1);

                    if (!string.IsNullOrWhiteSpace(sentence))
                    {
                        Log.Info(Tag, speak ? "Speaking chunk: " + sentence : "Reply chunk (speak off): " + sentence);
                        if (speak) _tts!.Speak(sentence, flush: false);
                    }

                    sentenceBuffer.Clear();
                    sentenceBuffer.Append(remainder);
                }
            }

            // Speak whatever is left
            string finalSentence = sentenceBuffer.ToString().Trim();
            if (!string.IsNullOrWhiteSpace(finalSentence))
            {
                Log.Info(Tag, speak ? "Speaking final chunk: " + finalSentence : "Final reply chunk (speak off): " + finalSentence);
                if (speak) _tts!.Speak(finalSentence, flush: false);
            }
        }
        catch (Exception ex) { Dg.Error("voice", "tts streaming failed: " + ex.Message); }
    }
}
