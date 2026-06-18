using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.OS;

namespace Subsystem;

[Service(ForegroundServiceType = ForegroundService.TypeDataSync | ForegroundService.TypeMediaProjection, Exported = false)]
public class SubsystemService : Service
{
    private const int NotificationId        = 1;
    private const int ConfirmNotificationId = 2;

    // Channel settings are IMMUTABLE once created on a device — any change here REQUIRES bumping the
    // id suffix (v2 -> v3 -> …) or installed devices keep the old behavior forever.
    // v3 (2026-06-11): the persistent engine card is SILENT — IMPORTANCE_LOW, no sound. Engine status
    // is ambient; only the Broker's message channel (Surfaces.cs, broker_v2) may chirp.
    private const string ChannelId        = "terminal_bg_v3";
    private const string ConfirmChannelId = "engine_confirm_v1"; // high-importance, shutdown confirmation ONLY

    // Chat-head verbs (the floating bubble). TOGGLE drives the notification action; SHOW/HIDE are the
    // explicit verbs the presenter/bubble themselves use (agent.obp collapse → SHOW; bubble tap → HIDE).
    public const string ActionToggleBubble = "TOGGLE_BUBBLE";
    public const string ActionShowBubble   = "SHOW_BUBBLE";
    public const string ActionHideBubble   = "HIDE_BUBBLE";
    // Notification hardening: A14+ lets users swipe even ongoing FGS notifications; the delete-intent
    // fires this action and we immediately re-post — an accidental swipe can't lose the engine card.
    public const string ActionRenotify     = "RENOTIFY";
    // Deliberate shutdown is TWO steps (the engine cannot die by accident, only on purpose):
    // SHUTDOWN_REQUEST posts a high-priority confirmation card; only SHUTDOWN_CONFIRM stops the
    // service (disarming RENOTIFY first); SHUTDOWN_KEEP dismisses the confirmation, changes nothing.
    public const string ActionShutdownRequest = "SHUTDOWN_REQUEST";
    public const string ActionShutdownConfirm = "SHUTDOWN_CONFIRM";
    public const string ActionShutdownKeep    = "SHUTDOWN_KEEP";

    private FloatingChatManager? _floatingChat;
    private AdbMdnsDiscoverer? _pairDiscoverer;
    private AdbMdnsDiscoverer? _connectDiscoverer;
    public static int LastDiscoveredAdbPort { get; private set; } = 0;
    public static AdbConnection? ElevatedAdb { get; private set; }
    private bool _isOverlayActive = false;
    // Set by SHUTDOWN_CONFIRM. Static on purpose: a stale RENOTIFY PendingIntent firing after StopSelf
    // re-creates the service — the flag survives within the process so that resurrection degrades to an
    // immediate stop instead of re-posting the engine card. A normal (deliberate) start clears it.
    private static bool _shuttingDown;

    public override IBinder? OnBind(Intent? intent) => null;

    public override StartCommandResult OnStartCommand(Intent? intent, StartCommandFlags flags, int startId)
    {
        EnsureChannel();

        if (intent?.Action == ActionRenotify)
        {
            // Confirmed shutdown in flight — RENOTIFY is disarmed; don't resurrect the card.
            if (_shuttingDown) { StopSelf(); return StartCommandResult.NotSticky; }
            // The engine card was swiped (accidentally or otherwise) — put it straight back.
            ((NotificationManager)GetSystemService(NotificationService)!).Notify(NotificationId, BuildNotification("Engine running..."));
            return StartCommandResult.Sticky;
        }

        if (intent?.Action == ActionShutdownRequest)
        {
            // Step 1 of 2: never stop on the first tap — an accidental press must be recoverable.
            PostShutdownConfirmation();
            return StartCommandResult.Sticky;
        }

        if (intent?.Action == ActionShutdownKeep)
        {
            ((NotificationManager)GetSystemService(NotificationService)!).Cancel(ConfirmNotificationId);
            return StartCommandResult.Sticky;
        }

        if (intent?.Action == ActionShutdownConfirm)
        {
            // Step 2 of 2: the deliberate stop. Disarm RENOTIFY first so removing the engine card
            // can't resurrect the service, then drop foreground state and both cards together.
            _shuttingDown = true;
            var nmgr = (NotificationManager)GetSystemService(NotificationService)!;
            nmgr.Cancel(ConfirmNotificationId);
            StopForeground(StopForegroundFlags.Remove);
            nmgr.Cancel(NotificationId);
            StopSelf();
            return StartCommandResult.NotSticky;
        }

        if (intent?.Action == ActionToggleBubble || intent?.Action == ActionShowBubble || intent?.Action == ActionHideBubble)
        {
            _isOverlayActive = intent.Action switch
            {
                ActionShowBubble => true,
                ActionHideBubble => false,
                _ => !_isOverlayActive,
            };
            if (_isOverlayActive)
            {
                if (_floatingChat == null) _floatingChat = new FloatingChatManager(this);
                _floatingChat.Show();
            }
            else
            {
                _floatingChat?.Hide();
                _floatingChat = null;
            }
            
            var notifManager = (NotificationManager)GetSystemService(NotificationService)!;
            notifManager.Notify(NotificationId, BuildNotification("Engine running..."));
            return StartCommandResult.Sticky;
        }

        // Boot the persistent FGS as dataSync ONLY. mediaProjection is asserted later, post-consent
        // (A14+ throws if a mediaProjection FGS starts without an active projection token).
        // A14+ also TIME-LIMITS a dataSync FGS: once the daily budget is exhausted, StartForeground throws
        // ForegroundServiceStartNotAllowedException. Degrade (keep running as a plain service) instead of
        // crashing the whole app — the engine/server don't need the foreground guarantee to function.
        _shuttingDown = false;   // a fresh deliberate start re-arms the durability guarantees
        try
        {
            StartForeground(NotificationId, BuildNotification("Engine running..."), ForegroundService.TypeDataSync);
        }
        catch (System.Exception ex)
        {
            Dg.Warn("svc", $"StartForeground denied (A14 dataSync FGS time limit?): {ex.GetType().Name}: {ex.Message}");
        }
        
#if DEV
        // ADB self-elevation — DEV builds ONLY. A release build (-p:SubsystemRelease=true) compiles this
        // entire block out, so the binary has no self-elevation path and starts no adb mDNS multicast — a
        // forwarded release APK is harmless. Default-deny even in DEV: the discoverers run only after the
        // owner grants \Capability\Consent\AdbElevation (flip it via adb -> Set-Capability). No elevation
        // by default, ever; this also stops the continuous-multicast idle drain until opted in.
        bool adbElevationGranted = Subsystem.Cm.Cm.Get("\\Capability\\Consent\\AdbElevation") is { Enabled: true };
        if (_pairDiscoverer == null && adbElevationGranted)
        {
            // PAIRING service (ephemeral): its port feeds the SPAKE2 flow via the "Enter Code"
            // notification action (PairAdbReceiver). It disappears the moment pairing succeeds.
            _pairDiscoverer = new AdbMdnsDiscoverer(this, AdbMdnsDiscoverer.PairingService);
            _pairDiscoverer.OnPortDiscovered = (port) =>
            {
                LastDiscoveredAdbPort = port;
                var nm = (NotificationManager)GetSystemService(NotificationService)!;
                nm.Notify(NotificationId, BuildNotification($"Pairing available (port {port}) — tap Enter Code", showPairing: true));
            };
            _pairDiscoverer.StartDiscovery();

            // CONNECT service (persistent): once paired (key on disk), connect to it to obtain the
            // elevated shell channel. This is the port that actually matters after pairing.
            _connectDiscoverer = new AdbMdnsDiscoverer(this, AdbMdnsDiscoverer.ConnectService);
            _connectDiscoverer.OnPortDiscovered = async (port) =>
            {
                LastDiscoveredAdbPort = port;
                string keyPath = SubsystemApi.AdbKeyPath;
                if (!System.IO.File.Exists(keyPath)) return; // not paired yet — ignore connect port
                if (ElevatedAdb != null) return;             // already elevated

                var nm = (NotificationManager)GetSystemService(NotificationService)!;
                nm.Notify(NotificationId, BuildNotification($"Elevating: ADB TLS connect on {port}..."));
                try
                {
                    var rsa = System.Security.Cryptography.RSA.Create(2048);
                    rsa.ImportRSAPrivateKey(System.IO.File.ReadAllBytes(keyPath), out _);
                    var conn = new AdbConnection(rsa, new ConscryptAdbTransport());
                    await conn.ConnectAsync("127.0.0.1", port);
                    ElevatedAdb = conn; // hold the connection — this is the elevated shell channel
                    // Prove it: run `id` over the channel — expect uid=2000(shell).
                    string idOut = (await conn.ExecuteShellAsync("id")).Trim();
                    Android.Util.Log.Info("SubsystemAdb", $"elevated shell `id` => {idOut}");
                    nm.Notify(NotificationId, BuildNotification($"Elevated shell: {idOut}"));
                }
                catch (Exception ex)
                {
                    nm.Notify(NotificationId, BuildNotification($"Connect failed: {ex.Message}"));
                }
            };
            _connectDiscoverer.StartDiscovery();
        }
#endif
        
        if (_floatingChat == null && _isOverlayActive)
        {
            // Delay instantiation slightly to ensure WindowManager is ready
            new Handler(Looper.MainLooper!).PostDelayed(() => {
                try {
                    _floatingChat = new FloatingChatManager(this);
                    if (_isOverlayActive) _floatingChat.Show();
                } catch { }
            }, 1000);
        }

        return StartCommandResult.Sticky;
    }

    public override void OnDestroy()
    {
        _floatingChat?.Hide();
        _pairDiscoverer?.StopDiscovery();
        _connectDiscoverer?.StopDiscovery();
        base.OnDestroy();
    }

    private void EnsureChannel()
    {
        var nm = (NotificationManager)GetSystemService(NotificationService)!;
        // The persistent engine card: Low importance, explicitly no sound (see the ChannelId comment
        // for the immutability rule that forced the v3 bump).
        var channel = new NotificationChannel(ChannelId, "Subsystem", NotificationImportance.Low)
        {
            Description = "PWSH background execution"
        };
        channel.SetSound(null, null);
        nm.CreateNotificationChannel(channel);
        // Shutdown confirmation: heads-up importance so the two-step confirm is seen immediately.
        var confirm = new NotificationChannel(ConfirmChannelId, "Subsystem shutdown", NotificationImportance.High)
        {
            Description = "Engine shutdown confirmation"
        };
        nm.CreateNotificationChannel(confirm);
        // Retire the superseded channel so it doesn't linger in the system notification settings.
        try { nm.DeleteNotificationChannel("terminal_bg_v2"); }
        catch (Exception ex) { Dg.Warn("svc", "terminal_bg_v2 retire skipped: " + ex.Message); }
    }

    private Notification BuildNotification(string text, bool showPairing = false)
    {
        var reopen = PendingIntent.GetActivity(
            this, 0,
            new Intent(Intent.ActionView, Android.Net.Uri.Parse(Subsystem.ProjectionServer.LoopbackBase)),
            PendingIntentFlags.Immutable)!;

        // Toggle Bubble Action
        var toggleIntent = new Intent(this, typeof(SubsystemService));
        toggleIntent.SetAction(ActionToggleBubble);
        var togglePendingIntent = PendingIntent.GetService(
            this, 0, toggleIntent, 
            PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
            
        string toggleText = _isOverlayActive ? "Hide Bubble" : "Show Bubble";
        var toggleAction = new Notification.Action.Builder(
            Resource.Mipmap.appicon, toggleText, togglePendingIntent)
            .Build();

        // Hardening: ongoing + a delete-intent that re-posts (ActionRenotify). On A14+ ongoing alone
        // no longer prevents a swipe; this makes the card effectively undismissable-by-accident.
        var renotify = new Intent(this, typeof(SubsystemService));
        renotify.SetAction(ActionRenotify);
        var renotifyPi = PendingIntent.GetService(
            this, 1, renotify, PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);

        // The deliberate off-switch (step 1: posts the confirmation card, never stops directly).
        var shutdownReq = new Intent(this, typeof(SubsystemService));
        shutdownReq.SetAction(ActionShutdownRequest);
        var shutdownReqPi = PendingIntent.GetService(
            this, 2, shutdownReq, PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
        var shutdownAction = new Notification.Action.Builder(
            Resource.Mipmap.appicon, "Shut down", shutdownReqPi)
            .Build();

        var builder = new Notification.Builder(this, ChannelId)
            .SetContentTitle("Subsystem")
            .SetContentText(text)
            .SetSmallIcon(this.ApplicationInfo!.Icon)
            .SetContentIntent(reopen)
            .SetOngoing(true)
            .SetDeleteIntent(renotifyPi)
            .AddAction(toggleAction)
            .AddAction(shutdownAction);

        // "Enter Code" is scoped to an ACTIVE wireless-pairing attempt (a pairing port was
        // discovered via mDNS). It is never shown on the persistent "Engine running" notification.
        if (showPairing)
        {
            var remoteInput = new Android.App.RemoteInput.Builder("pairing_code")
                .SetLabel("Enter 6-digit code")
                .Build();

            var replyIntent = new Intent(this, typeof(PairAdbReceiver));
            replyIntent.SetAction("dev.mansfieldplumbing.subsystem.PAIR_ADB");
            
            var replyPendingIntent = PendingIntent.GetBroadcast(
                this, 0, replyIntent, 
                PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Mutable);

            var action = new Notification.Action.Builder(
                Resource.Mipmap.appicon, "Enter Code", replyPendingIntent)
                .AddRemoteInput(remoteInput)
                .Build();
                
            builder.AddAction(action);
        }

        return builder.Build()!;
    }

    // The confirmation card (step 2 surface). Separate id + high-importance channel so it heads-up
    // over the silent engine card. Times out to "keep running" — the safe default for no answer.
    private void PostShutdownConfirmation()
    {
        var confirm = new Intent(this, typeof(SubsystemService));
        confirm.SetAction(ActionShutdownConfirm);
        var confirmPi = PendingIntent.GetService(
            this, 3, confirm, PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);

        var keep = new Intent(this, typeof(SubsystemService));
        keep.SetAction(ActionShutdownKeep);
        var keepPi = PendingIntent.GetService(
            this, 4, keep, PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);

        var n = new Notification.Builder(this, ConfirmChannelId)
            .SetContentTitle("Shut down Subsystem?")
            .SetContentText("The engine, server, and runspace will stop.")
            .SetSmallIcon(this.ApplicationInfo!.Icon)
            .SetAutoCancel(true)
            .SetTimeoutAfter(30_000)
            .AddAction(new Notification.Action.Builder(Resource.Mipmap.appicon, "Confirm shutdown", confirmPi).Build())
            .AddAction(new Notification.Action.Builder(Resource.Mipmap.appicon, "Keep running", keepPi).Build())
            .Build()!;
        ((NotificationManager)GetSystemService(NotificationService)!).Notify(ConfirmNotificationId, n);
    }
}
