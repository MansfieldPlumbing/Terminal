using Android.App;
using Android.Content;
using System.Threading.Tasks;

namespace Subsystem;

[BroadcastReceiver(Exported = false)]
[IntentFilter(new[] { "dev.mansfieldplumbing.subsystem.PAIR_ADB" })]
public class PairAdbReceiver : BroadcastReceiver
{
    public override async void OnReceive(Context? context, Intent? intent)
    {
        if (intent?.Action != "dev.mansfieldplumbing.subsystem.PAIR_ADB") return;

        var remoteInput = Android.App.RemoteInput.GetResultsFromIntent(intent);
        if (remoteInput != null)
        {
            string? codeStr = remoteInput.GetCharSequence("pairing_code")?.Replace(" ", "").Trim();
            if (!string.IsNullOrEmpty(codeStr))
            {
                int port = SubsystemService.LastDiscoveredAdbPort;
                
                if (port > 0)
                {
                    // Run on a background thread to prevent NetworkOnMainThreadException
                    _ = Task.Run(async () => {
                        string resultMessage = await SubsystemApi.PairAdbLoopback(port, codeStr);
                        
                        var notifManager = (NotificationManager)context!.GetSystemService(Context.NotificationService)!;
                        var reopen = PendingIntent.GetActivity(
                            context, 0,
                            new Intent(Intent.ActionView, Android.Net.Uri.Parse(Subsystem.ProjectionServer.LoopbackBase)),
                            PendingIntentFlags.Immutable)!;

                        var updatedNotif = new Notification.Builder(context, "terminal_bg_v2")
                            .SetContentTitle("Subsystem")
                            .SetContentText($"Pairing Result: {resultMessage}")
                            .SetSmallIcon(Resource.Mipmap.appicon)
                            .SetContentIntent(reopen)
                            .SetOngoing(true)
                            .Build();

                        notifManager.Notify(1, updatedNotif);
                    });
                }
                else
                {
                    // Handle invalid port instantly
                    var notifManager = (NotificationManager)context!.GetSystemService(Context.NotificationService)!;
                    var reopen = PendingIntent.GetActivity(
                        context, 0,
                        new Intent(Intent.ActionView, Android.Net.Uri.Parse(Subsystem.ProjectionServer.LoopbackBase)),
                        PendingIntentFlags.Immutable)!;

                    var updatedNotif = new Notification.Builder(context, "terminal_bg_v2")
                        .SetContentTitle("Subsystem")
                        .SetContentText("Error: Invalid port discovered.")
                        .SetSmallIcon(Resource.Mipmap.appicon)
                        .SetContentIntent(reopen)
                        .SetOngoing(true)
                        .Build();

                    notifManager.Notify(1, updatedNotif);
                }
            }
        }
    }
}
