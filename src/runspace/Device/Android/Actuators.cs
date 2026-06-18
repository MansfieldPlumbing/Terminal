using System;

namespace Subsystem.Device;

// \Device\Android\* actuator drivers — decomposed from VirtualObjectManager (VOM-SPEC §1). Bodies are
// verbatim except that the two host-bound drivers resolve the activity via MainActivity.Instance instead
// of the dropped VirtualObjectManager.Host mapping (the plan's "drivers use MainActivity.Instance").

// \Device\Android\Torch
public static class Torch
{
    private static bool _torchState = false;
    private static string? _flashCamId;   // the cached id of a camera that actually has a flash unit

    // On / Off / Toggle the torch. Throws a meaningful exception on failure so the cmdlet + the agent
    // tool report WHY (rather than the bare "status code 3" — CameraAccessException.CAMERA_ERROR).
    public static void SetFlashlight(string state = "Toggle")
    {
        var host = Subsystem.MainActivity.Instance
            ?? throw new InvalidOperationException("No activity context for the torch.");

        // The CameraManager is a system-service SINGLETON — NEVER dispose it. The old `using var cm`
        // disposed the managed wrapper after lighting the torch, which desynced the native torch
        // callback so the next SetTorchMode(false) threw CAMERA_ERROR (3). Resolve it fresh each call
        // (cheap — same singleton) and keep it alive.
        var cm = (Android.Hardware.Camera2.CameraManager?)host.GetSystemService(Android.Content.Context.CameraService)
            ?? throw new InvalidOperationException("CameraManager unavailable.");

        var camId = _flashCamId ??= FindFlashCamera(cm)
            ?? throw new InvalidOperationException("No camera on this device has a flash.");

        _torchState = state.Equals("On", StringComparison.OrdinalIgnoreCase) ? true
                    : state.Equals("Off", StringComparison.OrdinalIgnoreCase) ? false
                    : !_torchState;
        cm.SetTorchMode(camId, _torchState);
    }

    // Pick a camera whose FLASH_INFO_AVAILABLE is true — not blindly camera 0 (which on a foldable can
    // be a flashless lens). Cached after the first resolve.
    private static string? FindFlashCamera(Android.Hardware.Camera2.CameraManager cm)
    {
        try {
            foreach (var id in cm.GetCameraIdList()) {
                var chars = cm.GetCameraCharacteristics(id);
                var has = (Java.Lang.Boolean?)chars.Get(Android.Hardware.Camera2.CameraCharacteristics.FlashInfoAvailable!);
                if (has != null && has.BooleanValue()) return id;
            }
        } catch (System.Exception ex) { Subsystem.Dg.Warn("torch", ex); }
        return null;
    }
}

// \Device\Android\Haptics
public static class Haptics
{
    public static void Vibrate(int durationMs)
    {
        var host = Subsystem.MainActivity.Instance;
        if (host == null) return;
        try {
            using var vm = (Android.OS.VibratorManager?)host.GetSystemService(Android.Content.Context.VibratorManagerService);
            using var vib = vm?.DefaultVibrator;
            if (vib != null && vib.HasVibrator) {
                using var effect = Android.OS.VibrationEffect.CreateOneShot(durationMs, Android.OS.VibrationEffect.DefaultAmplitude);
                vib.Vibrate(effect);
            }
        } catch { }
    }
}

// \Device\Android\Audio
public static class Audio
{
    public static System.Collections.Generic.Dictionary<string, object> GetAudioVolume() {
        var d = new System.Collections.Generic.Dictionary<string, object>();
        try {
            var ctx = Android.App.Application.Context;
            var am = (Android.Media.AudioManager?)ctx.GetSystemService(Android.Content.Context.AudioService);
            if (am != null) {
                d["Media"] = am.GetStreamVolume(Android.Media.Stream.Music);
                d["MediaMax"] = am.GetStreamMaxVolume(Android.Media.Stream.Music);
                d["Ring"] = am.GetStreamVolume(Android.Media.Stream.Ring);
                d["RingMax"] = am.GetStreamMaxVolume(Android.Media.Stream.Ring);
                d["Alarm"] = am.GetStreamVolume(Android.Media.Stream.Alarm);
                d["AlarmMax"] = am.GetStreamMaxVolume(Android.Media.Stream.Alarm);
            }
        } catch { }
        return d;
    }

    public static void SetAudioVolume(string stream, int level) {
        try {
            var ctx = Android.App.Application.Context;
            var am = (Android.Media.AudioManager?)ctx.GetSystemService(Android.Content.Context.AudioService);
            if (am != null) {
                var s = Android.Media.Stream.Music;
                if (stream.Equals("Ring", StringComparison.OrdinalIgnoreCase)) s = Android.Media.Stream.Ring;
                if (stream.Equals("Alarm", StringComparison.OrdinalIgnoreCase)) s = Android.Media.Stream.Alarm;
                am.SetStreamVolume(s, level, Android.Media.VolumeNotificationFlags.ShowUi);
            }
        } catch { }
    }

    public static void PlayBeep() {
        try {
            var uri = Android.Media.RingtoneManager.GetDefaultUri(Android.Media.RingtoneType.Notification);
            var r = Android.Media.RingtoneManager.GetRingtone(Android.App.Application.Context, uri);
            r?.Play();
        } catch { }
    }
}

// \Device\Android\Input — injection through the AccessibilityService front door (no adb / shell required).
public static class Input
{
    public static string InvokeTap(float x, float y)
    {
        var svc = TerminalAccessibilityService.Instance;
        if (svc == null) return "Error: Accessibility Service is not running.";
        return svc.DispatchTap(x, y) ? $"Tapped ({x}, {y})" : "Error: Tap dispatch failed.";
    }

    public static string InvokeSwipe(float x1, float y1, float x2, float y2, long durationMs)
    {
        var svc = TerminalAccessibilityService.Instance;
        if (svc == null) return "Error: Accessibility Service is not running.";
        return svc.DispatchSwipe(x1, y1, x2, y2, durationMs)
            ? $"Swiped ({x1}, {y1}) -> ({x2}, {y2}) over {(durationMs > 0 ? durationMs : 300)}ms"
            : "Error: Swipe dispatch failed.";
    }
}
