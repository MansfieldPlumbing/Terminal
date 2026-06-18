using System;
using System.Collections.Generic;
using System.Text.Json;
using Android.AccessibilityServices;
using Android.App;
using Android.Content;
using Android.Graphics;
using Android.Views.Accessibility;

namespace Subsystem;

// One actionable element in a distilled screen frame: a numbered handle the Broker SELECTS by id
// (never authors). X/Y is the on-screen tap centre, so select-by-id -> DispatchTap is the act half.
public sealed record ScreenElement(int Id, string Role, string Text, bool Clickable, int X, int Y);

// The current screen, distilled from the accessibility tree: a compact, numbered, screen-reader-grade
// frame. Latest-only (replaced each capture), bounded in size — cheap to feed the on-device model.
public sealed record ScreenFrame(string App, string Title, IReadOnlyList<ScreenElement> Elements, long CapturedAtMs)
{
    public string ToJson() => JsonSerializer.Serialize(
        new { app = App, title = Title, capturedAtMs = CapturedAtMs, count = Elements.Count, elements = Elements },
        new JsonSerializerOptions { WriteIndented = true });
}

[Service(Name = "dev.mansfieldplumbing.subsystem.TerminalAccessibilityService", Label = "Subsystem", Permission = Android.Manifest.Permission.BindAccessibilityService, Exported = true)]
[IntentFilter(new[] { "android.accessibilityservice.AccessibilityService" })]
[MetaData("android.accessibilityservice", Resource = "@xml/accessibility_service_config")]
public class TerminalAccessibilityService : AccessibilityService
{
    public static TerminalAccessibilityService? Instance { get; private set; }

    protected override void OnServiceConnected()
    {
        base.OnServiceConnected();
        Instance = this;
    }

    // --- Perception (AGENT-SPEC §4): the a11y tree -> a distilled, numbered screen frame ---

    private static volatile ScreenFrame? _current;
    // The Broker's current perception: the latest distilled screen, or null until one is captured.
    public static ScreenFrame? CurrentScreen => _current;
    public static string CurrentScreenJson()
        => _current?.ToJson() ?? "{ \"app\": null, \"elements\": [], \"note\": \"no screen captured yet\" }";

    private const int MaxElements = 40;     // bound the frame: cheap to feed the on-device model
    private const int DebounceMs   = 400;   // snapshot AFTER the screen settles; coalesce event bursts

    private readonly Android.OS.Handler _ui = new(Android.OS.Looper.MainLooper!);
    private Java.Lang.IRunnable? _pending;

    public override void OnAccessibilityEvent(AccessibilityEvent? e)
    {
        if (e == null) return;
        // Only react to meaningful screen change — not every content tick (clock, animation, scroll).
        if (e.EventType != EventTypes.WindowStateChanged && e.EventType != EventTypes.WindowContentChanged) return;

        // Debounce: capture once the screen settles; a fresh event resets the timer.
        if (_pending != null) _ui.RemoveCallbacks(_pending);
        _pending = new Java.Lang.Runnable(CaptureScreen);
        _ui.PostDelayed(_pending, DebounceMs);
    }

    // Walk the active window's node tree into a compact, numbered frame. Replaces the current frame
    // (latest-only). Degrades + reports to Dg; never throws into the a11y callback.
    private void CaptureScreen()
    {
        try
        {
            var root = RootInActiveWindow;
            if (root == null) return;
            var elements = new List<ScreenElement>();
            Walk(root, elements, 0);
            var frame = new ScreenFrame(
                App: root.PackageName ?? "?",
                Title: FirstText(root) ?? (root.PackageName ?? "?"),
                Elements: elements,
                CapturedAtMs: Java.Lang.JavaSystem.CurrentTimeMillis());
            _current = frame;
            Dg.Debug("a11y", $"screen: {frame.App} '{frame.Title}' ({elements.Count} elements)");
        }
        catch (Exception ex) { Dg.Warn("a11y", ex); }
    }

    // Collect clickable nodes and text-bearing nodes (visible only), numbered 1..N, with tap centres.
    private static void Walk(AccessibilityNodeInfo? node, List<ScreenElement> acc, int depth)
    {
        if (node == null || acc.Count >= MaxElements || depth > 40) return;

        var label = Text(node);
        if (node.Clickable || !string.IsNullOrWhiteSpace(label))
        {
            var r = new Rect();
            node.GetBoundsInScreen(r);
            if (r.Width() > 0 && r.Height() > 0)   // on-screen / non-degenerate
                acc.Add(new ScreenElement(
                    Id: acc.Count + 1,
                    Role: ShortRole(node.ClassName?.ToString()),
                    Text: label ?? "",
                    Clickable: node.Clickable,
                    X: r.CenterX(),
                    Y: r.CenterY()));
        }

        int n = node.ChildCount;
        for (int i = 0; i < n && acc.Count < MaxElements; i++)
            Walk(node.GetChild(i), acc, depth + 1);
    }

    private static string? Text(AccessibilityNodeInfo n)
    {
        var t = n.Text?.ToString();
        if (!string.IsNullOrWhiteSpace(t)) return t!.Trim();
        var d = n.ContentDescription?.ToString();
        return string.IsNullOrWhiteSpace(d) ? null : d!.Trim();
    }

    private static string? FirstText(AccessibilityNodeInfo root)
    {
        var t = Text(root);
        if (t != null) return t;
        for (int i = 0; i < root.ChildCount; i++)
        {
            var c = root.GetChild(i);
            if (c != null) { var r = FirstText(c); if (r != null) return r; }
        }
        return null;
    }

    // "android.widget.Button" -> "button"; the short role the model reasons over.
    private static string ShortRole(string? cls)
    {
        if (string.IsNullOrEmpty(cls)) return "view";
        int dot = cls!.LastIndexOf('.');
        var s = dot >= 0 ? cls.Substring(dot + 1) : cls;
        return s.Replace("AppCompat", "").Replace("Material", "").ToLowerInvariant();
    }

    public override void OnInterrupt() { }

    public override bool OnUnbind(Intent? intent)
    {
        Instance = null;
        return base.OnUnbind(intent);
    }

    public bool DispatchTap(float x, float y)
    {
        var path = new Android.Graphics.Path();
        path.MoveTo(x, y);
        var stroke = new GestureDescription.StrokeDescription(path, 0, 100);
        var gestureBuilder = new GestureDescription.Builder();
        gestureBuilder.AddStroke(stroke);
        return DispatchGesture(gestureBuilder.Build(), null, null);
    }

    public bool DispatchSwipe(float x1, float y1, float x2, float y2, long durationMs)
    {
        var path = new Android.Graphics.Path();
        path.MoveTo(x1, y1);
        path.LineTo(x2, y2);
        var stroke = new GestureDescription.StrokeDescription(path, 0, durationMs > 0 ? durationMs : 300);
        var gestureBuilder = new GestureDescription.Builder();
        gestureBuilder.AddStroke(stroke);
        return DispatchGesture(gestureBuilder.Build(), null, null);
    }

    // Capture the screen via the AccessibilityService (no MediaProjection consent prompt).
    // Returns a PNG data URI, or "" on failure. Blocks up to timeoutMs for the async callback.
    public string CaptureScreenshotBase64(int timeoutMs = 3000)
    {
        var tcs = new System.Threading.Tasks.TaskCompletionSource<string>();
        try
        {
            TakeScreenshot(0, MainExecutor!, new ScreenshotCallback(tcs));
        }
        catch
        {
            return "";
        }
        return tcs.Task.Wait(timeoutMs) ? tcs.Task.Result : "";
    }

    private class ScreenshotCallback : Java.Lang.Object, AccessibilityService.ITakeScreenshotCallback
    {
        private readonly System.Threading.Tasks.TaskCompletionSource<string> _tcs;
        public ScreenshotCallback(System.Threading.Tasks.TaskCompletionSource<string> tcs) { _tcs = tcs; }

        public void OnSuccess(AccessibilityService.ScreenshotResult result)
        {
            try
            {
                using var hb = result.HardwareBuffer;
                var bmp = Android.Graphics.Bitmap.WrapHardwareBuffer(hb!, result.ColorSpace);
                if (bmp == null) { _tcs.TrySetResult(""); return; }
                using var ms = new System.IO.MemoryStream();
                bmp.Compress(Android.Graphics.Bitmap.CompressFormat.Png!, 100, ms);
                bmp.Recycle();
                _tcs.TrySetResult("data:image/png;base64," + System.Convert.ToBase64String(ms.ToArray()));
            }
            catch { _tcs.TrySetResult(""); }
        }

        public void OnFailure(int errorCode)
        {
            _tcs.TrySetResult("");
        }
    }
}
