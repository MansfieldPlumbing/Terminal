using Android.App;
using Android.Content;
using Android.OS;
using Android.Runtime;
using Android.Service.Voice;
using Android.Util;

namespace Subsystem;

// The VoiceInteractionService is the component the OS binds when Subsystem holds
// the ASSISTANT role. Its only job is lifecycle + pointing the system at our
// session service (via Resources/xml/interaction.xml). The actual assist work
// (screen read, screenshot, reasoning) happens in SubsystemVoiceInteractionSession.
//
// Name is pinned so it matches the component referenced from interaction.xml and
// so `cmd role add-role-holder ASSISTANT <pkg>` over the loopback shell can target it.
[Service(
    Name = "dev.mansfieldplumbing.subsystem.SubsystemVoiceInteractionService",
    Label = "Subsystem",
    Permission = "android.permission.BIND_VOICE_INTERACTION",
    Exported = true)]
[IntentFilter(new[] { "android.service.voice.VoiceInteractionService" })]
[MetaData("android.voice_interaction", Resource = "@xml/interaction")]
public class SubsystemVoiceInteractionService : VoiceInteractionService
{
    private const string Tag = "SubsystemVoice";

    public SubsystemVoiceInteractionService() { }
    protected SubsystemVoiceInteractionService(System.IntPtr handle, JniHandleOwnership transfer)
        : base(handle, transfer) { }

    public override void OnReady()
    {
        base.OnReady();
        Log.Info(Tag, "VoiceInteractionService ready — Subsystem is the active assistant.");
    }
}
