using Android.Content;

namespace Subsystem;

// Persisted agent settings (Android SharedPreferences). Controls how much context she gets —
// the "settings page" toggles bind to these.
public static class AgentSettings
{
    private const string Prefs = "agent_settings";

    private static ISharedPreferences P(Context c) => c.GetSharedPreferences(Prefs, FileCreationMode.Private)!;

    // Use context from previous chats (persistent conversation memory).
    public static bool UseChatContext(Context c) => P(c).GetBoolean("use_chat_context", true);
    public static void SetUseChatContext(Context c, bool v) => P(c).Edit()!.PutBoolean("use_chat_context", v)!.Apply();

    // Tie into the underlying Android system (screen / app / device context).
    public static bool UseSystemContext(Context c) => P(c).GetBoolean("use_system_context", false);
    public static void SetUseSystemContext(Context c, bool v) => P(c).Edit()!.PutBoolean("use_system_context", v)!.Apply();

    // Let the model REASON in its thinking channel before answering. Default OFF (owner decree 2026-06-15:
    // E4B reasons unbounded on the slow CPU rung; start direct). When ON, the per-turn output budget bounds
    // it. The toggle strips the leading <|think|> from the resolved system prompt (RuntimeBroker).
    public static bool UseThinking(Context c) => P(c).GetBoolean("use_thinking", false);
    public static void SetUseThinking(Context c, bool v) => P(c).Edit()!.PutBoolean("use_thinking", v)!.Apply();
    
    // Auto-listen to microphone when assistant gesture triggers. Default OFF (owner decree
    // 2026-06-11: auto mic capture on assist is hostile) — opt in via the settings toggle.
    public static bool AutoListenAssist(Context c) => P(c).GetBoolean("auto_listen_assist", false);
    public static void SetAutoListenAssist(Context c, bool v) => P(c).Edit()!.PutBoolean("auto_listen_assist", v)!.Apply();

    // Let the assistant SEE the screen (assist view-tree text + screenshot) as context. Default OFF
    // (priority lane: nothing fires unprompted) — when off the dispatch sends empty screen context and
    // notes "(screen vision off)" instead of capturing/forwarding the screen. Opt in via the toggle.
    public static bool UseScreenVision(Context c) => P(c).GetBoolean("use_screen_vision", false);
    public static void SetUseScreenVision(Context c, bool v) => P(c).Edit()!.PutBoolean("use_screen_vision", v)!.Apply();

    // Speak the assistant's replies aloud (on-device TTS). Default OFF (priority lane: default silence)
    // — when off the reply is computed and surfaced silently, never spoken. Opt in via the toggle.
    public static bool SpeakReplies(Context c) => P(c).GetBoolean("speak_replies", false);
    public static void SetSpeakReplies(Context c, bool v) => P(c).Edit()!.PutBoolean("speak_replies", v)!.Apply();
}
