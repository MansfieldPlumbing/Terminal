using System;
using System.Text;
using System.Threading.Tasks;
using Android.App.Assist;
using Android.Content;
using Android.Graphics;
using Android.Media;
using Android.OS;
using Android.Service.Voice;
using Android.Util;
using Android.Views;
using Android.Webkit;

namespace Subsystem;

// The session is what the OS spins up on the assist gesture. It receives:
//   OnHandleAssist(AssistState)   -> the foreground app's view tree (text, bounds)
//   OnHandleScreenshot(Bitmap)    -> a pixel snapshot (vision input)
// Both arrive via the standard VoiceInteractionSession API on the user-invoked assist
// gesture — the same mechanism a system assistant uses; this path uses the assist
// permission, not the AccessibilityService toggle. Audio capture below is opt-in
// (AutoListenAssist) and announced with an audible cue. The result is handed to a
// swappable AssistDispatch (routes into the RuntimeBroker / Rb), then acted on.
public class SubsystemVoiceInteractionSession : VoiceInteractionSession
{
    private const string Tag = "SubsystemVoice";

    // Latest captured context — also surfaced to PowerShell via the VOM later.
    public static string LastAssistText { get; private set; } = "";
    public static Bitmap? LastScreenshot { get; private set; }

    public SubsystemVoiceInteractionSession(Context context) : base(context) { }

    public override void OnHandleAssist(VoiceInteractionSession.AssistState? state)
    {
        base.OnHandleAssist(state);
        try
        {
            // Screen-vision is OPT-IN (priority lane: nothing fires unprompted). When off we do NOT walk
            // the foreground app's view tree or retain its text — the captured context stays empty so the
            // screen is never read or forwarded. Opt in via AgentSettings.UseScreenVision.
            bool screenVision = AgentSettings.UseScreenVision(Context!);
            if (!screenVision)
            {
                LastAssistText = "";
                Log.Info(Tag, "Screen vision off — not capturing screen text.");
            }
            else
            {
                var structure = state?.AssistStructure;
                if (structure == null)
                {
                    Log.Warn(Tag, "AssistState had no structure (user may have disabled 'use text from screen').");
                }
                else
                {
                    var sb = new StringBuilder();
                    int windows = structure.WindowNodeCount;
                    for (int i = 0; i < windows; i++)
                    {
                        var win = structure.GetWindowNodeAt(i);
                        WalkNode(win?.RootViewNode, sb, 0);
                    }

                    LastAssistText = sb.ToString();
                    Log.Info(Tag, $"Captured screen text ({LastAssistText.Length} chars).");
                }
            }

            _ = Task.Run(async () =>
            {
                try
                {
                    if (AgentSettings.AutoListenAssist(Context!))
                    {
                        Subsystem.Device.Audio.PlayBeep(); // Audio feedback that we are listening
                        byte[] audio = await RecordAudioAsync(4); // record for 4 seconds
                        DispatchToHb(audio);

                        // Hide the overlay shortly after recording finishes
                        new Handler(Looper.MainLooper!).PostDelayed(() => {
                            Hide();
                        }, 500);
                    }
                    else
                    {
                        // No audio, just dispatch the text/screen context to initialize the session.
                        // We DO NOT Hide() automatically here, allowing the user to type in the UI.
                        DispatchToHb(Array.Empty<byte>());
                    }
                }
                catch (Exception ex)
                {
                    // Capture path faulted (mic contention, settings read, beep) — degrade to a
                    // text-only dispatch; the session stays up so the user can still type.
                    Dg.Error("voice", "assist capture failed, degrading to text-only: " + ex.Message);
                    DispatchToHb(Array.Empty<byte>());
                }
            });
        }
        catch (Exception ex)
        {
            // Degrade to text-only dispatch. Do NOT Hide() — the session must not vanish on error.
            Dg.Error("voice", "OnHandleAssist failed: " + ex.Message);
            DispatchToHb(Array.Empty<byte>());
        }
    }

    public override View OnCreateContentView()
    {
        // Best-effort window pinning: a stray outside touch must not dismiss the session
        // mid-capture. The Dialog/Window binding surface varies across API levels — record
        // and continue on failure, never throw from view creation.
        try
        {
            Window?.SetCanceledOnTouchOutside(false);
            Window?.Window?.AddFlags(Android.Views.WindowManagerFlags.NotTouchModal);
        }
        catch (Exception ex) { Dg.Log("voice", "session window pinning unavailable: " + ex.Message); }

        var webView = new WebView(Context!);
        webView.Settings.JavaScriptEnabled = true;
        webView.Settings.MediaPlaybackRequiresUserGesture = false;
        webView.SetBackgroundColor(Color.Transparent);
        webView.LoadUrl(Subsystem.ProjectionServer.LoopbackBase + "quickassist.html");
        return webView;
    }

    private Task<byte[]> RecordAudioAsync(int maxSeconds)
    {
        return Task.Run(() =>
        {
            try
            {
                int sampleRate = 16000;
                var channelConfig = ChannelIn.Mono;
                var audioFormat = Android.Media.Encoding.Pcm16bit;
                int minBuf = AudioRecord.GetMinBufferSize(sampleRate, channelConfig, audioFormat);
                
                using var audioRecord = new AudioRecord(AudioSource.Mic, sampleRate, channelConfig, audioFormat, minBuf * 10);
                if (audioRecord.State != State.Initialized)
                {
                    Log.Warn(Tag, "AudioRecord failed to initialize.");
                    return Array.Empty<byte>();
                }

                audioRecord.StartRecording();
                using var ms = new System.IO.MemoryStream();
                byte[] buffer = new byte[minBuf];
                
                DateTime start = DateTime.UtcNow;
                while ((DateTime.UtcNow - start).TotalSeconds < maxSeconds)
                {
                    int read = audioRecord.Read(buffer, 0, buffer.Length);
                    if (read > 0)
                        ms.Write(buffer, 0, read);
                }
                
                audioRecord.Stop();
                Log.Info(Tag, $"Captured {ms.Length} bytes of raw audio.");
                return ms.ToArray();
            }
            catch (Exception ex)
            {
                Log.Error(Tag, $"Audio recording failed: {ex.Message}");
                return Array.Empty<byte>();
            }
        });
    }

    public override void OnHandleScreenshot(Bitmap? screenshot)
    {
        base.OnHandleScreenshot(screenshot);
        // Screen-vision is OPT-IN (priority lane). When off we do NOT retain the pixel snapshot (vision
        // input) — drop it so it is never forwarded. Opt in via AgentSettings.UseScreenVision.
        if (!AgentSettings.UseScreenVision(Context!))
        {
            LastScreenshot = null;
            Log.Info(Tag, "Screen vision off — discarding screenshot.");
            return;
        }
        LastScreenshot = screenshot;
        Log.Info(Tag, screenshot != null
            ? $"Captured screenshot {screenshot.Width}x{screenshot.Height}."
            : "Screenshot was null (user may have disabled 'use screenshot').");
    }

    private static void WalkNode(AssistStructure.ViewNode? node, StringBuilder sb, int depth)
    {
        if (node == null) return;

        var text = node.Text;
        if (!string.IsNullOrWhiteSpace(text))
            sb.AppendLine(text);

        var cd = node.ContentDescription;
        if (!string.IsNullOrWhiteSpace(cd))
            sb.AppendLine($"[{cd}]");

        int children = node.ChildCount;
        for (int i = 0; i < children; i++)
            WalkNode(node.GetChildAt(i), sb, depth + 1);
    }

    private void DispatchToHb(byte[] audioData)
    {
        var ctx = Context;
        if (ctx != null) AssistDispatch.OnAssist(ctx, audioData, LastAssistText, LastScreenshot);
        else Log.Warn(Tag, "No context for assist dispatch.");
    }
}
