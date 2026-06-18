using System;

namespace Subsystem.Device;

// \Device\Android\* surface drivers — decomposed from VirtualObjectManager (VOM-SPEC §1). Verbatim except
// host-bound members resolve via MainActivity.Instance (the dropped Host mapping).

// \Device\Android\Clipboard
public static class Clipboard
{
    public static string GetClipboardText()
    {
        var host = Subsystem.MainActivity.Instance;
        if (host == null) return "";
        string text = "";
        host.RunOnUiThread(() => {
            try {
                using var cm = (Android.Content.ClipboardManager?)host.GetSystemService(Android.Content.Context.ClipboardService);
                if (cm != null && cm.HasPrimaryClip) {
                    using var clip = cm.PrimaryClip;
                    if (clip != null && clip.ItemCount > 0) {
                        using var item = clip.GetItemAt(0);
                        text = item?.Text ?? "";
                    }
                }
            } catch { }
        });
        System.Threading.Thread.Sleep(50);
        return text;
    }

    public static void SetClipboardText(string text)
    {
        var host = Subsystem.MainActivity.Instance;
        if (host == null || string.IsNullOrEmpty(text)) return;
        host.RunOnUiThread(() => {
            try {
                using var cm = (Android.Content.ClipboardManager?)host.GetSystemService(Android.Content.Context.ClipboardService);
                if (cm != null) {
                    using var clip = Android.Content.ClipData.NewPlainText("Subsystem", text);
                    cm.PrimaryClip = clip;
                }
            } catch { }
        });
    }
}

// \Device\Android\Display
public static class Display
{
    public static System.Collections.Generic.Dictionary<string, object> GetDisplayInfo()
    {
        var dict = new System.Collections.Generic.Dictionary<string, object>();
        try {
            var ctx = Android.App.Application.Context;
            using var res = ctx.Resources;
            using var dm = res?.DisplayMetrics;
            if (dm != null) {
                dict["WidthPixels"] = dm.WidthPixels;
                dict["HeightPixels"] = dm.HeightPixels;
                dict["DensityDpi"] = (int)dm.DensityDpi;
                dict["Density"] = dm.Density;
                dict["XDpi"] = dm.Xdpi;
                dict["YDpi"] = dm.Ydpi;
            }
            try {
                using var wm = Subsystem.MainActivity.Instance?.WindowManager;
                using var display = wm?.DefaultDisplay;
                var rr = display?.RefreshRate;
                if (rr.HasValue) dict["RefreshRate"] = System.Math.Round(rr.Value, 2);
            } catch { }
        } catch { }
        return dict;
    }

    public static string GetScreenshot()
    {
        var svc = TerminalAccessibilityService.Instance;
        if (svc == null) return "Error: Accessibility Service is not running.";
        var result = svc.CaptureScreenshotBase64();
        if (string.IsNullOrEmpty(result)) return "Error: Failed to capture screen.";
        return result;
    }
}

// \Device\Android\Notifications
public static class Notifications
{
    public static System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>> GetAndroidMessages()
    {
        var list = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>>();
        if (Subsystem.MainActivity.Instance == null) return list;

        foreach (var kvp in NotificationService.Notifications) {
            var sbn = kvp.Value;
            var dict = new System.Collections.Generic.Dictionary<string, object>();
            dict["Package"] = sbn.PackageName ?? "";
            dict["PostTime"] = sbn.PostTime;
            dict["IsClearable"] = sbn.IsClearable;

            using var notification = sbn.Notification;
            using var extras = notification?.Extras;
            if (extras != null) {
                dict["Title"] = extras.GetCharSequence(Android.App.Notification.ExtraTitle) ?? "";
                dict["Text"] = extras.GetCharSequence(Android.App.Notification.ExtraText) ?? "";
            }
            list.Add(dict);
        }
        return list;
    }

    // Monotonic notification id — replaces a per-call clock-seeded new Random().Next() whose collisions
    // made notifications clobber each other (SS006). Stable + unique per process. Starts at 1000:
    // ids 1..N belong to SubsystemService's FGS notification — the first increment from 0 collided
    // with it (same pkg+id replaces), swallowing the "Engine running" card and inheriting FGS flags.
    private static int _notificationId = 1000;

    // Broker's message channel, with the chirp (Resources/raw/chirp01.mp3) as its sound. Separate from
    // the silent FGS channel on purpose — a message from her may chirp; engine status never does.
    // Channel settings are IMMUTABLE once created on a device — any change here REQUIRES bumping the
    // id suffix (v1 -> v2 -> …) or installed devices keep the old behavior forever.
    // v2 (2026-06-11, quieter delivery): Importance stays Default; the chirp rides AudioAttributes
    // usage=Notification (respects the system notification volume / DND, never the media stream),
    // and posts carry OnlyAlertOnce so an update to an already-visible id never re-chirps.
    // (BUG FIX, v1: this used to post to "terminal_bg", a channel that was never created — on O+ the
    // OS silently dropped every notification, so the agent's `notify` tool did nothing visible.)
    private const string BrokerChannelId = "broker_v2";
    private static bool _channelReady;
    private static void EnsureBrokerChannel(Android.Content.Context ctx, Android.App.NotificationManager nm) {
        if (_channelReady) return;
        var ch = new Android.App.NotificationChannel(BrokerChannelId, "Broker", Android.App.NotificationImportance.Default);
        try {
            var sound = Android.Net.Uri.Parse("android.resource://" + ctx.PackageName + "/raw/chirp01");
            var attrs = new Android.Media.AudioAttributes.Builder()
                .SetUsage(Android.Media.AudioUsageKind.Notification)!
                .SetContentType(Android.Media.AudioContentType.Sonification)!
                .Build();
            ch.SetSound(sound, attrs);
        } catch { /* no chirp resource — the channel still works with the default sound */ }
        nm.CreateNotificationChannel(ch);
        // Retire the superseded channel so it doesn't linger in the system notification settings.
        try { nm.DeleteNotificationChannel("broker_v1"); }
        catch (Exception ex) { Subsystem.Dg.Log("notify", "broker_v1 retire skipped: " + ex.Message); }
        _channelReady = true;
    }

    public static void SendNotification(string title, string text) {
        try {
            var ctx = Android.App.Application.Context;
            var nm = (Android.App.NotificationManager?)ctx.GetSystemService(Android.Content.Context.NotificationService);
            if (nm != null) {
                EnsureBrokerChannel(ctx, nm);
                var builder = new Android.App.Notification.Builder(ctx, BrokerChannelId)
                    .SetContentTitle(title)
                    .SetContentText(text)
                    .SetSmallIcon(Resource.Mipmap.appicon)
                    .SetOnlyAlertOnce(true)   // quieter delivery: updates to a visible id don't re-chirp
                    .SetAutoCancel(true);
                nm.Notify(System.Threading.Interlocked.Increment(ref _notificationId), builder.Build());
            }
        } catch { }
    }
}

// \Device\Android\Apps
public static class Apps
{
    public static System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>> GetInstalledApps(bool includeSystem = false)
    {
        var list = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>>();
        try {
            var ctx = Android.App.Application.Context;
            using var pm = ctx.PackageManager;
            if (pm == null) return list;
            var apps = pm.GetInstalledApplications(Android.Content.PM.PackageManager.ApplicationInfoFlags.Of(0));
            if (apps != null) {
                foreach (var app in apps) {
                    bool isSystem = ((int)app.Flags & (int)Android.Content.PM.ApplicationInfoFlags.System) != 0;
                    if (!includeSystem && isSystem) {
                        app.Dispose();
                        continue;
                    }
                    var d = new System.Collections.Generic.Dictionary<string, object>();
                    d["Package"] = app.PackageName ?? "";

                    var labelCharSeq = app.LoadLabel(pm);
                    d["Label"] = labelCharSeq?.ToString() ?? app.PackageName ?? "";

                    d["Enabled"] = app.Enabled;
                    d["IsSystem"] = isSystem;
                    list.Add(d);

                    app.Dispose(); // Dispose the individual AppInfo wrappers
                }
            }
        } catch { }
        return list;
    }
}

// \Device\Android\Shell
public static class Shell
{
    public static void ShowToast(string message, bool isLong)
    {
        var host = Subsystem.MainActivity.Instance;
        if (host == null || host.IsFinishing || host.IsDestroyed) return;
        if (string.IsNullOrEmpty(message)) return;

        host.RunOnUiThread(() => {
            try {
                if (host.IsFinishing || host.IsDestroyed) return;
                var length = isLong ? Android.Widget.ToastLength.Long : Android.Widget.ToastLength.Short;
                using var toast = Android.Widget.Toast.MakeText(host, message, length);
                toast?.Show();
            } catch { }
        });
    }

    public static void StartIntent(string uriString) {
        try {
            var ctx = Android.App.Application.Context;
            var intent = new Android.Content.Intent(Android.Content.Intent.ActionView, Android.Net.Uri.Parse(uriString));
            intent.AddFlags(Android.Content.ActivityFlags.NewTask);
            ctx.StartActivity(intent);
        } catch { }
    }
}
