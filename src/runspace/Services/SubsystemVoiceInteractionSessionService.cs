using Android.App;
using Android.OS;
using Android.Runtime;
using Android.Service.Voice;

namespace Subsystem;

// Factory the OS binds to mint a session each time the assist gesture fires.
[Service(
    Name = "dev.mansfieldplumbing.subsystem.SubsystemVoiceInteractionSessionService",
    Permission = "android.permission.BIND_VOICE_INTERACTION",
    Exported = true)]
public class SubsystemVoiceInteractionSessionService : VoiceInteractionSessionService
{
    public SubsystemVoiceInteractionSessionService() { }
    protected SubsystemVoiceInteractionSessionService(System.IntPtr handle, JniHandleOwnership transfer)
        : base(handle, transfer) { }

    public override VoiceInteractionSession OnNewSession(Bundle? args)
        => new SubsystemVoiceInteractionSession(this);
}
