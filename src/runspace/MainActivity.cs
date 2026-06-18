using Android.App;
using Android.OS;
using Android.Views;
using Android.Webkit;
using Android.Window;
using Java.Interop;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using VtNetCore.VirtualTerminal;

using System.Management.Automation.Host;
using System.Management.Automation.Provider;
using VtNetCore.XTermParser;

namespace Subsystem;

public class ReactInputEvent {
    public string type { get; set; } = "";
    public int cols { get; set; }
    public int rows { get; set; }
    public string key { get; set; } = "";
    public string text { get; set; } = "";
    public long tabId { get; set; }
}

public class TerminalSession : IDisposable {
    public long TabId { get; }
    private readonly MainActivity _main;
    public PowerShell Ps { get; private set; } = null!;
    public AndroidSubsystemHost Host { get; private set; } = null!;
    public VirtualTerminalController VtController { get; private set; }
    public DataConsumer VtConsumer { get; private set; }
    public ReplEngine Repl { get; private set; } = null!;
    public Queue<byte[]> OutputQueue { get; } = new Queue<byte[]>();
    public readonly object VtLock = new object();

    public void Dispose() {
        try {
            Repl?.Stop();
            Ps?.Dispose();
        } catch { }
    }

    public TerminalSession(long tabId, MainActivity main) {
        TabId = tabId;
        _main = main;
        VtController = new VirtualTerminalController();
        VtController.ResizeView(120, 40);
        VtConsumer = new DataConsumer(VtController);
    }

    public void Start(string appBasePath) {
        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Init");
        var iss = InitialSessionState.Create();
        iss.LanguageMode = PSLanguageMode.FullLanguage;
        LoadFromAssembly(iss, typeof(PSObject).Assembly);
        LoadFromAssembly(iss, Assembly.Load("Microsoft.PowerShell.Commands.Utility"));
        LoadFromAssembly(iss, Assembly.Load("Microsoft.PowerShell.Commands.Management"));

        SubsystemAliases.Load(iss);

        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Creating Host");
        Host = new AndroidSubsystemHost(this);
        var rs = RunspaceFactory.CreateRunspace(Host, iss);
        rs.Open();

        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Init API");
        SubsystemApi.Initialize(iss, Host);
        SessionManager.Initialize(iss, Host); // named persistent PWSH sessions share this ISS/host

        Ps = PowerShell.Create();
        Ps.Runspace = rs;

        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Env Setup");
        string initScript = $@"
$env:HOME = '{appBasePath}'
$env:PHONE_HOME = '/storage/emulated/0'
$Global:VOM = [Subsystem.Vom.Vom]
$Global:ctx = [Subsystem.MainActivity]::Instance
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
Set-Location -Path '{appBasePath}'
$env:PATH += [System.IO.Path]::PathSeparator + '{appBasePath}'
function global:prompt {{ ""PS $($ExecutionContext.SessionState.Path.CurrentLocation)> "" }}
function global:dir {{ Get-ChildItem @args | Format-Table -Property @{{N='Date';E={{$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')}}}}, @{{N='Type';E={{if($_.PSIsContainer){{'<DIR>'}}else{{''}}}}}}, @{{N='Size';E={{if(!$_.PSIsContainer){{$_.Length}}}}}}, Name -AutoSize }}
Set-Alias ls dir -Force
";
        Ps.AddScript(initScript);
        Ps.Invoke();
        Ps.Commands.Clear();

        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Profile script");
        string profilePath = System.IO.Path.Combine(appBasePath, "profile.ps1");
        Ps.AddScript($"if (Test-Path '{profilePath}') {{ . '{profilePath}' }}");
        Ps.Invoke();
        Ps.Commands.Clear();

        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: ADB check");
        if (!SubsystemApi.IsAdbPaired())
        {
            FeedTerminal(Encoding.UTF8.GetBytes("\x1b[35m[System] Android 11+ Wireless Debugging is not paired yet.\x1b[0m\r\n"));
            FeedTerminal(Encoding.UTF8.GetBytes("\x1b[35m[System] Please go to Developer Options -> Wireless Debugging -> Pair device with pairing code.\x1b[0m\r\n"));
            FeedTerminal(Encoding.UTF8.GetBytes("\x1b[35m[System] Then tell me the port and code here (e.g. \"pair 41234 123456\").\x1b[0m\r\n"));
        }

        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Starting REPL");
        Repl = new ReplEngine(this, Host, rs);
        Repl.Start();
        Android.Util.Log.Debug("SubsystemDebug", "TerminalSession.Start: Done");
    }

    private void LoadFromAssembly(InitialSessionState iss, Assembly assembly) {
        try {
            foreach (var type in assembly.GetTypes()) {
                var cmdletAttr = type.GetCustomAttribute<CmdletAttribute>();
                if (cmdletAttr != null) iss.Commands.Add(new SessionStateCmdletEntry($"{cmdletAttr.VerbName}-{cmdletAttr.NounName}", type, ""));
                var providerAttr = type.GetCustomAttribute<CmdletProviderAttribute>();
                if (providerAttr != null) iss.Providers.Add(new SessionStateProviderEntry(providerAttr.ProviderName, type, ""));
            }
        } catch { }
    }

    public void FeedTerminal(byte[] rawAnsiBytes) {
        lock (VtLock) {
            VtConsumer.Push(rawAnsiBytes);
            if (VtController.Changed) VtController.ClearChanges();
        }
        _main.SendRawToReact(TabId, rawAnsiBytes);
        _main.BroadcastToProjection(TabId, rawAnsiBytes);
    }

    public void RouteRawInput(string payload) {
        if (string.IsNullOrEmpty(payload)) return;
        try {
            var rawUi = (AndroidSubsystemRawUserInterface)Host.UI.RawUI;
            for (int i = 0; i < payload.Length; i++) {
                char ch = payload[i]; ConsoleKey key = (ConsoleKey)0;
                if ((ch == '\x03' || ch == '\x1b') && Repl != null && Repl.IsRunning) {
                    Repl.StopActiveCommand();
                    continue;
                }
                if (ch == '\x1b' && i + 2 < payload.Length && payload[i + 1] == '[') {
                    switch (payload[i + 2]) {
                        case 'A': key = ConsoleKey.UpArrow;    break;
                        case 'B': key = ConsoleKey.DownArrow;  break;
                        case 'C': key = ConsoleKey.RightArrow; break;
                        case 'D': key = ConsoleKey.LeftArrow;  break;
                    }
                    if (key != (ConsoleKey)0) {
                        rawUi.InputQueue.Add(new KeyInfo((int)key, '\0', (ControlKeyStates)0, true));
                        i += 2; continue;
                    }
                }
                if      (ch == '\r' || ch == '\n') key = ConsoleKey.Enter;
                else if (ch == '\b' || ch == '\x7F') key = ConsoleKey.Backspace;
                else if (ch == '\t')  key = ConsoleKey.Tab;
                else if (ch == '\x1b') key = ConsoleKey.Escape;

                char keyChar = key switch { ConsoleKey.Enter => '\r', ConsoleKey.Backspace => '\b', ConsoleKey.Tab => '\t', ConsoleKey.Escape => '\x1b', _ => ch };
                rawUi.InputQueue.Add(new KeyInfo((int)key, keyChar, (ControlKeyStates)0, true));
            }
        } catch { }
    }

    public void ExecuteCommand(string command) {
        Task.Run(() => {
            try {
                FeedTerminal(Encoding.UTF8.GetBytes($"{command}\r\n"));
                Ps.Commands.Clear();
                Ps.AddScript(command);
                Ps.Invoke();
                if (Ps.HadErrors) foreach (var error in Ps.Streams.Error) FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[31m{error}\x1b[0m\r\n"));
                FeedTerminal(Encoding.UTF8.GetBytes("\x1b[34mPS>\x1b[0m "));
            } catch (Exception ex) { FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[31mFatal Exec Error: {ex.Message}\x1b[0m\r\n")); }
        });
    }

    public Coordinates GetCursorPosition() { lock (VtLock) { return new Coordinates(VtController.CursorState.CurrentColumn, VtController.CursorState.CurrentRow); } }
    public Size GetWindowSize() { lock (VtLock) { return new Size(VtController.VisibleColumns, VtController.VisibleRows); } }
}

// Name is pinned (not crc-mangled) so AndroidManifest activity-aliases — the FEDERATION's per-door
// launcher icons (Editor/Terminal/Settings/…) — can target this activity by a stable component name.
[Activity(Name = "dev.mansfieldplumbing.subsystem.MainActivity", Label = "@string/app_name", Icon = "@mipmap/appicon", RoundIcon = "@mipmap/appicon_round", MainLauncher = true, Theme = "@android:style/Theme.DeviceDefault.NoActionBar", WindowSoftInputMode = Android.Views.SoftInput.AdjustResize, ConfigurationChanges = Android.Content.PM.ConfigChanges.Orientation | Android.Content.PM.ConfigChanges.ScreenSize | Android.Content.PM.ConfigChanges.KeyboardHidden | Android.Content.PM.ConfigChanges.ScreenLayout)]
// SECURITY (history): the .ssr "open-to-import" ACTION_VIEW intent filters — and later the whole .ssr
// file-format module — were REMOVED. Open-to-import let ANY app or browsable link inject capabilities/verbs
// into Cm with no confirmation, reachable by the elevated uid=2000 adb channel. Verbs are Cm records,
// registered at runtime (Register-Capability / presenter menu-context); there is no file-import lane.
public class MainActivity : Activity
{
    private WebView _webView = null!;
    public bool IsReactReady { get; private set; } = false;
    private ProjectionServer? _projectionServer;
    public ConcurrentDictionary<long, TerminalSession> Sessions { get; } = new();
    public static MainActivity? Instance { get; private set; }

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        Instance = this;

        // SubsystemDom (Diagnostic Object Manager) — arm crash capture + persistent diag log
        // to /sdcard/SubsystemDom/ (survives reinstall) as early as possible.
        Dg.Initialize(this);

        // Move any pre-models/ flat model files (files/<name>) into files/models/ so a model
        // downloaded before this refactor is recognized as installed without re-downloading.
        try { ModelCatalog.MigrateLegacyLayout(this); } catch { }

        if (!Android.Provider.Settings.CanDrawOverlays(this)) {
            StartActivity(new Android.Content.Intent(Android.Provider.Settings.ActionManageOverlayPermission, Android.Net.Uri.Parse("package:" + PackageName)));
        }

        // ADD THIS 1 LINE: Force the PowerShell engine to boot headlessly 
        // as Tab 0 immediately on startup. This initializes the API pool.
        CreateSession(0);

        _webView = new WebView(this);
        _webView.Settings.JavaScriptEnabled = true;
        _webView.Settings.DomStorageEnabled = true;
        _webView.Settings.AllowFileAccess = true;
        _webView.Settings.AllowFileAccessFromFileURLs = true;
        _webView.Settings.AllowUniversalAccessFromFileURLs = true;
        _webView.Settings.SetSupportZoom(false);
        _webView.Settings.UseWideViewPort = true;
        _webView.Settings.LoadWithOverviewMode = true;
        _webView.OverScrollMode = OverScrollMode.Never;
        _webView.SetWebViewClient(new SubsystemWebViewClient());
        _webView.SetWebChromeClient(new CustomWebChromeClient());

        Java.Lang.JavaSystem.LoadLibrary("psl-android");
        // SetDllImportResolver can only be set ONCE per assembly per process. OnCreate can run
        // again (activity recreated while the assistant/VoiceInteraction process stays alive),
        // so guard the second call — otherwise it throws "resolver already set" and crashes launch.
        try {
            NativeLibrary.SetDllImportResolver(typeof(System.Management.Automation.PowerShell).Assembly, (libraryName, assembly, searchPath) => {
                if (libraryName.Contains("libpsl-native")) return NativeLibrary.Load("libpsl-android.so", assembly, null);
                return IntPtr.Zero;
            });
        } catch (System.InvalidOperationException) { /* resolver already set earlier this process */ }

        _webView.AddJavascriptInterface(new PwshBridge(this), "AndroidBridge");
        _webView.AddJavascriptInterface(new VomBridgeJSInterface(this), "VomBridge");
        // Pre-paint backdrop (visible only until the shell's first frame). BLACK read as a crash/hang on
        // launch; a neutral mid sky-blue (the classic desktop default) reads as "booting", not "dead".
        // This is a native surface OUTSIDE the WebView's CSS scope, so it can't reference var(--bg) — see
        // risks: ideally seeded from the active theme's --bg via Cm so the flash matches the shell.
        _webView.SetBackgroundColor(Android.Graphics.Color.Rgb(0x3A, 0x6E, 0xA5));
        EnsureWebServer();   // server must be up before the shell loads over http (idempotent; OnCreate re-call is a no-op)
        _webView.LoadUrl(ProjectionServer.LoopbackBase);   // "/" = the shell presenter (shell.obp, RAM-served)

        if (Build.VERSION.SdkInt >= BuildVersionCodes.Tiramisu) this.OnBackInvokedDispatcher.RegisterOnBackInvokedCallback(0, new TerminalBackCallback(this));

        SetContentView(_webView);

        // We OWN the system bars: edge-to-edge, status bar hidden while Subsystem is open, swipe-from-top
        // reveals it transiently (the pull-down). Left/right edges are freed for our own swipes. API 30+.
        Window?.SetDecorFitsSystemWindows(false);
        ApplyImmersive();

        if (Build.VERSION.SdkInt >= BuildVersionCodes.Tiramisu) RequestPermissions(new[] { Android.Manifest.Permission.PostNotifications }, 0);
        StartForegroundService(new Android.Content.Intent(this, typeof(SubsystemService)));

        // Edge ownership needs REAL decor dimensions, but the first OnWindowFocusChanged can beat
        // layout (observed on the Razr+ cover display: dv.Width==0 → the early-return left the edges
        // OS-owned, so a left swipe fired BACK instead of Charms). Re-assert on every decor layout —
        // cheap, idempotent. (Android still caps exclusion at ~200dp/edge, granted bottom-up: the
        // LOWER part of each edge is ours; mid/upper edge stays the OS back gesture.)
        try { if (Window?.DecorView is Android.Views.View _dv) _dv.LayoutChange += (s, e) => ApplyGestureExclusion(); } catch { }

        // Edge-to-edge (SetDecorFitsSystemWindows(false)) means the IME inset is NOT auto-applied, so on
        // API30+ the soft keyboard draws OVER the bottom of the WebView — on top of the always-visible
        // taskbar. Pad the WebView by the IME (keyboard) inset so content shrinks above it instead.
        if (Build.VERSION.SdkInt >= BuildVersionCodes.R)
            try { _webView.SetOnApplyWindowInsetsListener(new ImeInsetPad()); } catch { }

        // Bind the HTTP/WebSocket backend (8080) at launch. This MUST be unconditional —
        // it powers terminal/messenger/agent/files/settings. Previously it only started
        // inside StartProjection() (screen-cast), so a normal launch left 8080 unbound and
        // the whole frontend "couldn't connect". Decoupled now.
        EnsureWebServer();

        SeedAssets();
        System.Environment.SetEnvironmentVariable("POWERSHELL_TELEMETRY_OPTOUT", "1");
        System.Environment.SetEnvironmentVariable("DOTNET_EnableDiagnostics", "0");

        // Deep-link: an `open` extra names the presenter to land on (the chat head's tap carries
        // open=agent). Cold start — the shell isn't loaded yet, so it's flushed on page-finish.
        _pendingOpen = Intent?.GetStringExtra("open");

        // THE FEDERATION: launched through a door alias (…door.<Id>) → load THAT presenter
        // full-bleed, no shell chrome. The component name IS the door id (manifest is the truth).
        var door = DoorFromIntent(Intent);
        if (door != null) LoadDoor(door);
    }

    // Pads the WebView by the IME (soft-keyboard) inset under edge-to-edge, so the keyboard shrinks
    // the content above it instead of covering the always-visible taskbar (API30+).
    private sealed class ImeInsetPad : Java.Lang.Object, Android.Views.View.IOnApplyWindowInsetsListener
    {
        public WindowInsets OnApplyWindowInsets(Android.Views.View v, WindowInsets insets)
        {
            var ime = insets.GetInsets(WindowInsets.Type.Ime());
            v.SetPadding(v.PaddingLeft, v.PaddingTop, v.PaddingRight, ime.Bottom);
            return insets;
        }
    }

    // …door.Editor → "edit", …door.Broker → "agent", etc. Null = the main icon (the shell/hub).
    private static string? DoorFromIntent(Android.Content.Intent? intent)
    {
        var cls = intent?.Component?.ClassName ?? "";
        var i = cls.IndexOf(".door.", StringComparison.Ordinal);
        if (i < 0) return null;
        var id = cls.Substring(i + ".door.".Length).ToLowerInvariant();
        return id switch { "editor" => "edit", "broker" => "agent", _ => id };
    }

    // A door is the presenter ITSELF as the whole window — served flat from shell/presenters/.
    // (Presenters are standalone pages: they bring their own theme.css/themes.js.)
    private void LoadDoor(string presenterId)
    {
        RunOnUiThread(() => { try { _webView?.LoadUrl(ProjectionServer.LoopbackBase + "/presenters/" + presenterId + ".obp"); } catch { } });
    }

    // The presenter a launching intent asked us to open once the shell is up (flushed by
    // SubsystemWebViewClient.OnPageFinished; null = nothing pending).
    private string? _pendingOpen;

    // Warm path: the activity already exists (bubble tap with the app backgrounded) — the shell is
    // live, open the presenter immediately.
    protected override void OnNewIntent(Android.Content.Intent? intent)
    {
        base.OnNewIntent(intent);
        // Door alias tapped while we're alive (v1 = one task): become that door.
        var door = DoorFromIntent(intent);
        if (door != null) { LoadDoor(door); return; }
        var open = intent?.GetStringExtra("open");
        if (!string.IsNullOrEmpty(open)) OpenPresenter(open!);
    }

    public void FlushPendingOpen()
    {
        var open = _pendingOpen;
        _pendingOpen = null;
        if (!string.IsNullOrEmpty(open)) OpenPresenter(open!);
    }

    // Open a shell window by registry id — resolve-by-id through the Shell assembler, never a file
    // path (REGISTRY-SPEC §9). Retries briefly: page-finish can beat the Shell module's boot().
    public void OpenPresenter(string id)
    {
        var safe = System.Text.Json.JsonSerializer.Serialize(id);
        var js = "(function t(n){ if (window.Shell && window.Shell.open) window.Shell.open(" + safe +
                 "); else if (n > 0) setTimeout(function(){ t(n-1); }, 250); })(40)";
        EvaluateInWebView(js);
    }

    // Evaluate a JS expression in the shell WebView from native code (UI-thread marshalled, null-safe).
    // The single seam the renderer is driven through — callbacks to JS (permission results, deep links)
    // all funnel here so there is one place that talks to V8.
    public void EvaluateInWebView(string js) {
        RunOnUiThread(() => { try { _webView?.EvaluateJavascript(js, null); } catch { } });
    }

    // Runtime-permission request from the WebView (mic, etc.). getUserMedia in the WebView can only
    // succeed once the *app* holds the OS runtime grant, so the renderer asks the host to request it
    // at use-time. Synchronous return: true = already granted (caller proceeds now); false = a request
    // was dispatched and the result will arrive asynchronously at window.__onPermissionResult(name,bool)
    // (see OnRequestPermissionsResult). The renderer awaits that hook before calling getUserMedia.
    public const int PermissionRequestCode = 100;
    public bool RequestRuntimePermission(string permission) {
        try {
            if (CheckSelfPermission(permission) == Android.Content.PM.Permission.Granted) {
                NotifyPermissionResult(permission, true);   // already held — fire the hook for a uniform await path
                return true;
            }
            RunOnUiThread(() => { try { RequestPermissions(new[] { permission }, PermissionRequestCode); } catch (System.Exception ex) { Subsystem.Dg.Warn("perm", ex); } });
            return false;
        } catch (System.Exception ex) { Subsystem.Dg.Warn("perm", ex); return false; }
    }

    // The OS handed back a runtime-permission decision — relay each result to the WebView so an
    // awaiting getUserMedia (or any consumer) can proceed or degrade-and-record. Never silent.
    public override void OnRequestPermissionsResult(int requestCode, string[] permissions, Android.Content.PM.Permission[] grantResults) {
        base.OnRequestPermissionsResult(requestCode, permissions, grantResults);
        try {
            for (int i = 0; i < permissions.Length; i++) {
                bool granted = i < grantResults.Length && grantResults[i] == Android.Content.PM.Permission.Granted;
                NotifyPermissionResult(permissions[i], granted);
            }
        } catch (System.Exception ex) { Subsystem.Dg.Warn("perm", ex); }
    }

    // Post a single permission decision to the renderer's await hook. JSON-encoded args so a permission
    // string can never break out of the call (the renderer holds no authority; the host quotes for it).
    private void NotifyPermissionResult(string permission, bool granted) {
        var name = System.Text.Json.JsonSerializer.Serialize(permission);
        var js = "if (window.__onPermissionResult) try { window.__onPermissionResult(" + name + ", " + (granted ? "true" : "false") + "); } catch (e) {}";
        EvaluateInWebView(js);
    }

    // We own the system bars. Hide the status bar while Subsystem is open; a swipe from the top edge
    // brings it back transiently (the "pull-down"). Re-applied on focus regain (transient bars reset).
    // API 30+ (Razr+ is API 34); older OS = no-op.
    private void ApplyImmersive() {
        try {
            if (Build.VERSION.SdkInt < BuildVersionCodes.R) return;
            var c = Window?.InsetsController;
            if (c != null) {
                // Immersive at the TOP only: hide the STATUS bar (swipe-from-top reveals it transiently —
                // the pull-down). Do NOT hide the navigation/gesture bar: in sticky mode a hidden nav bar
                // consumes the bottom swipe-up to reveal itself, which STEALS the system Home gesture. We
                // keep the nav bar so the OS owns swipe-up (Home) / swipe-up-hold (Recents); the shell still
                // draws edge-to-edge beneath it (SetDecorFitsSystemWindows(false)).
                c.Hide(WindowInsets.Type.StatusBars());
                c.SystemBarsBehavior = (int)WindowInsetsControllerBehavior.ShowTransientBarsBySwipe;
            }
            // NOTE: ApplyGestureExclusion() (from OnWindowFocusChanged) excludes the LEFT/RIGHT edges from
            // the OS back-gesture so accidental edge swipes don't fire back — the taskbar + red-X are the
            // nav. (Android caps gesture exclusion at ~200dp/edge, so the lower part of each edge is what's
            // reliably covered; the back BUTTON / TerminalBackCallback still works for intentional back.)
        } catch { }
    }

    // System BACK (gesture or button) → navigate BACK inside the app (the shell's window history), not out.
    // The shell pushes a history entry per focused window, so GoBack() fires its popstate → focus the
    // previous window / close the active one. At the root: NOTHING — an edge swipe must never exit or
    // background the app (user directive: only the red-X leaves; the OS Home gesture still works).
    public void GoBackInApp() {
        RunOnUiThread(() => {
            try {
                if (_webView != null && _webView.CanGoBack()) _webView.GoBack();
            } catch { }
        });
    }

    // Own the LEFT/RIGHT edge swipes: exclude both vertical edges from Android's system back-gesture so
    // the WebView/Shell receives them instead of the OS treating them as "back". (API 29+.)
    private void ApplyGestureExclusion() {
        try {
            if (Build.VERSION.SdkInt < BuildVersionCodes.Q) return;
            var dv = Window?.DecorView;
            if (dv == null || dv.Width == 0 || dv.Height == 0) return;
            int edge = (int)(40 * Resources!.DisplayMetrics!.Density);
            dv.SystemGestureExclusionRects = new System.Collections.Generic.List<Android.Graphics.Rect> {
                new Android.Graphics.Rect(0, 0, edge, dv.Height),
                new Android.Graphics.Rect(dv.Width - edge, 0, dv.Width, dv.Height),
            };
        } catch { }
    }

    // Native window blur-behind for the assist popup / system mica (API 31+; S/Razr+ are 34). Best-effort:
    // the OS honors it only when window blurs are enabled in dev settings AND the device supports them, so
    // a non-zero radius degrades to no-op rather than failing. radiusPx <= 0 clears it. Guarded on SdkInt.
    public void SetWindowBlur(int radiusPx) {
        RunOnUiThread(() => {
            try {
                if (Build.VERSION.SdkInt < BuildVersionCodes.S) return;
                Window?.SetBackgroundBlurRadius(radiusPx < 0 ? 0 : radiusPx);
            } catch (System.Exception ex) { Subsystem.Dg.Warn("blur", ex); }
        });
    }

    // JS-driven status-bar control (PwshBridge.setStatusBarHidden): lets the Shell show the bar on the
    // start/launcher and hide it inside a presenter, if it wants finer control than the always-immersive default.
    public void SetStatusBarHidden(bool hidden) {
        RunOnUiThread(() => {
            try {
                if (Build.VERSION.SdkInt < BuildVersionCodes.R) return;
                var c = Window?.InsetsController; if (c == null) return;
                if (hidden) c.Hide(WindowInsets.Type.StatusBars());
                else c.Show(WindowInsets.Type.StatusBars());
            } catch { }
        });
    }

    public override void OnWindowFocusChanged(bool hasFocus) {
        base.OnWindowFocusChanged(hasFocus);
        if (hasFocus) { ApplyImmersive(); ApplyGestureExclusion(); }   // re-assert bar + edge-gesture ownership on focus regain
    }

    public bool IsAccessibilityEnabled() {
        int accessibilityEnabled = 0;
        try { accessibilityEnabled = Android.Provider.Settings.Secure.GetInt(ContentResolver, Android.Provider.Settings.Secure.AccessibilityEnabled); } catch { }
        if (accessibilityEnabled == 1) {
            string? settingValue = Android.Provider.Settings.Secure.GetString(ContentResolver, Android.Provider.Settings.Secure.EnabledAccessibilityServices);
            if (settingValue != null && settingValue.Contains(PackageName!)) return true;
        }
        return false;
    }

    public void CreateSession(long tabId) {
        if (Sessions.ContainsKey(tabId)) return;
        var session = new TerminalSession(tabId, this);
        Sessions[tabId] = session;
        Task.Run(() => session.Start(this.FilesDir!.AbsolutePath));
    }

    public void CloseSession(long tabId) {
        if (Sessions.TryRemove(tabId, out var session)) {
            session.Dispose();
        }
    }

    private void SeedAssets() {
        void SeedAsset(string assetName, string destPath) {
            if (!System.IO.File.Exists(destPath)) {
                // ObpHost: the shell tree is compiled into the assembly now (embedded -> asset fallback).
                try { using var s = ObpHost.OpenRead(assetName); if (s != null) { using var d = System.IO.File.Create(destPath); s.CopyTo(d); } } catch { }
            }
        }
        SeedAsset("shell/home/profile.ps1",  System.IO.Path.Combine(this.FilesDir!.AbsolutePath, "profile.ps1"));
        SeedAsset("shell/home/settings.ps1", System.IO.Path.Combine(this.FilesDir!.AbsolutePath, "settings.ps1"));
    }

    public void SendRawToReact(long tabId, byte[] rawAnsiBytes) {
        if (!IsReactReady) {
            if (Sessions.TryGetValue(tabId, out var s)) s.OutputQueue.Enqueue(rawAnsiBytes);
            return;
        }
        string text = Encoding.UTF8.GetString(rawAnsiBytes);
        RunOnUiThread(() => {
            _webView.PostWebMessage(new WebMessage($"{tabId}:{text}"), Android.Net.Uri.Parse("*")!);
        });
    }

    private Android.Media.Projection.MediaProjectionManager? _projectionManager;
    private Android.Media.Projection.MediaProjection? _mediaProjection;
    private Android.Hardware.Display.VirtualDisplay? _virtualDisplay;
    private Android.Media.ImageReader? _imageReader;

    [Export("startScreenCapture")] [JavascriptInterface]
    public void StartScreenCapture() {
        _projectionManager = (Android.Media.Projection.MediaProjectionManager)GetSystemService(MediaProjectionService)!;
        StartActivityForResult(_projectionManager.CreateScreenCaptureIntent(), 1000);
    }

    protected override void OnActivityResult(int requestCode, Result resultCode, Android.Content.Intent? data) {
        if (requestCode == 1000 && resultCode == Result.Ok && data != null) {
            // Android 14+ requires a foreground service of type mediaProjection to be running
            // before MediaProjection.start(); ours is dataSync, so this can throw RemoteException.
            // Guard it so a failed screen-cast logs instead of hard-crashing the whole app.
            try {
                _mediaProjection = _projectionManager!.GetMediaProjection((int)resultCode, data);
                SetupVirtualDisplay();
            } catch (System.Exception ex) {
                Android.Util.Log.Error("Subsystem", "Screen capture unavailable (needs mediaProjection FGS on A14+): " + ex.Message);
            }
        }
        base.OnActivityResult(requestCode, resultCode, data);
    }

    private void SetupVirtualDisplay() {
        var metrics = Resources!.DisplayMetrics!;
        int width = metrics.WidthPixels;
        int height = metrics.HeightPixels;
        int density = (int)metrics.DensityDpi;
        
        _imageReader = Android.Media.ImageReader.NewInstance(width, height, (Android.Graphics.ImageFormatType)1, 2); // 1 = PixelFormat.RGBA_8888
        _imageReader.SetOnImageAvailableListener(new ImageAvailableListener(_projectionServer), null);

        _virtualDisplay = _mediaProjection!.CreateVirtualDisplay("ScreenCapture",
            width, height, density,
            (Android.Views.DisplayFlags)16, // VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR
            _imageReader.Surface, null, null);
    }

    public void RouteInputEvent(string json) {
        try {
            var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("type", out var typeProp)) {
                string type = typeProp.GetString() ?? "";
                if (root.TryGetProperty("tabId", out var tabIdProp)) {
                    long tabId = tabIdProp.GetInt64();
                    if (type == "createSession") {
                        CreateSession(tabId);
                    }
                    else if (type == "input" || type == "resize" || type == "text") {
                        new PwshBridge(this).SendInput(tabId, json);
                    }
                }
            }
        } catch { }
    }

    public void BroadcastToProjection(long tabId, byte[] rawAnsiBytes) { _projectionServer?.Broadcast(tabId, rawAnsiBytes); }

    public void NotifyReactReady() {
        IsReactReady = true;
        foreach (var session in Sessions.Values) {
            while (session.OutputQueue.Count > 0) SendRawToReact(session.TabId, session.OutputQueue.Dequeue());
        }
    }

    // Reload the shell WebView — how a front-door swap (\Shell\FrontDoor) takes effect live.
    // Callable from JS (PwshBridge.reloadShell) and from the runspace (Invoke-ShellReload), so the
    // agent can switch doors herself: Register-Capability the new file, then reload.
    public void ReloadShell() {
        RunOnUiThread(() => { try { _webView?.Reload(); } catch { } });
    }

    // The shared TTS engine (built-in, offline — airplane-safe). Lazily initialized on first Speak so
    // a device with no TTS doesn't pay for it; Broker and Out-Speech share this one instance.
    private SpeechOutput? _speech;
    private readonly object _speechGate = new();
    public async void Speak(string text) {
        if (string.IsNullOrWhiteSpace(text)) return;
        SpeechOutput engine;
        lock (_speechGate) { _speech ??= new SpeechOutput(); engine = _speech; }
        try {
            if (!engine.Ready) await engine.InitAsync(this);
            engine.Speak(text);
        } catch (System.Exception ex) { Subsystem.Dg.Warn("tts", ex); }
    }

    // Web server is app-lifetime (started in OnCreate). Idempotent.
    public void EnsureWebServer() {
        if (_projectionServer == null) {
            _projectionServer = new ProjectionServer(this);
            _projectionServer.Start(8080);
        }
    }

    // Screen projection REUSES the already-running web server; it must not own its lifecycle.
    public void StartProjection() => EnsureWebServer();

    // Intentionally does NOT tear down the web server — the backend must survive a
    // screen-mirror stop. (Terminating it here is what made the frontend drop after toggling cast.)
    public void StopProjection() { }
}

public class PwshBridge : Java.Lang.Object {
    private readonly MainActivity _activity;
    public PwshBridge(MainActivity activity) { _activity = activity; }

    // The in-process loopback capability token. The WebView that owns this bridge is trusted; a foreign app
    // cannot reach AndroidBridge, so the token never leaves the process here. The shell sends it as the
    // X-Subsystem-Cap header / ?cap= query on the command routes (lib/api.js). Locks loopback against other apps.
    [Export("getCap")] [JavascriptInterface] public string GetCap() => ProjectionServer.CapToken;

    [Export("createSession")] [JavascriptInterface] public void CreateSession(long tabId) { _activity.CreateSession(tabId); }
    [Export("closeSession")]  [JavascriptInterface] public void CloseSession(long tabId)  { _activity.CloseSession(tabId); }
    [Export("invokeCommand")] [JavascriptInterface] public void InvokeCommand(long tabId, string cmd) { if (_activity.Sessions.TryGetValue(tabId, out var s)) s.ExecuteCommand(cmd); }
    [Export("sendRawInput")]  [JavascriptInterface] public void SendRawInput(long tabId, string payload) { if (_activity.Sessions.TryGetValue(tabId, out var s)) s.RouteRawInput(payload); }
    [Export("sendInput")]     [JavascriptInterface] public void SendInput(long tabId, string json) {
        try {
            var ev = JsonSerializer.Deserialize<ReactInputEvent>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (ev?.type == "resize" && _activity.Sessions.TryGetValue(tabId, out var sr)) { lock(sr.VtLock) { sr.VtController.ResizeView(ev.cols, ev.rows); sr.VtController.ClearChanges(); } }
            else if (ev?.type == "text" && !string.IsNullOrEmpty(ev.text) && _activity.Sessions.TryGetValue(tabId, out var st)) {
                st.RouteRawInput(ev.text);
            }
            else if (ev?.type == "input" && !string.IsNullOrEmpty(ev.key) && _activity.Sessions.TryGetValue(tabId, out var si)) {
                ConsoleKey consoleKey = ev.key switch { "Enter" => ConsoleKey.Enter, "Backspace" => ConsoleKey.Backspace, "Escape" => ConsoleKey.Escape, "Tab" => ConsoleKey.Tab, "ArrowUp" => ConsoleKey.UpArrow, "ArrowDown" => ConsoleKey.DownArrow, "ArrowLeft" => ConsoleKey.LeftArrow, "ArrowRight" => ConsoleKey.RightArrow, _ => (ConsoleKey)0 };
                char ch = ev.key.Length == 1 ? ev.key[0] : '\0';
                if (consoleKey == ConsoleKey.Enter) ch = '\r'; else if (consoleKey == ConsoleKey.Backspace) ch = '\b'; else if (consoleKey == ConsoleKey.Escape) ch = '\x1b'; else if (consoleKey == ConsoleKey.Tab) ch = '\t';
                ((AndroidSubsystemRawUserInterface)si.Host.UI.RawUI).InputQueue.Add(new KeyInfo((int)consoleKey, ch, (ControlKeyStates)0, true));
            }
        } catch { }
    }
    [Export("notifyReady")]     [JavascriptInterface] public void NotifyReady()     { _activity.NotifyReactReady(); }
    [Export("reloadShell")]     [JavascriptInterface] public void ReloadShell()     { _activity.ReloadShell(); }

    // Chat head: show/hide the system-overlay bubble (FloatingChatManager via SubsystemService).
    // agent.obp's collapse composes showChatHead() + minimizeApp() — Broker keeps floating over
    // every app; tapping the head reopens the app ONTO the agent presenter (open=agent extra).
    [Export("showChatHead")] [JavascriptInterface] public void ShowChatHead() {
        try {
            if (!Android.Provider.Settings.CanDrawOverlays(_activity)) {
                _activity.StartActivity(new Android.Content.Intent(
                    Android.Provider.Settings.ActionManageOverlayPermission,
                    Android.Net.Uri.Parse("package:" + _activity.PackageName)));
                return;
            }
            var i = new Android.Content.Intent(_activity, typeof(SubsystemService));
            i.SetAction(SubsystemService.ActionShowBubble);
            _activity.StartService(i);
        } catch (System.Exception ex) { Subsystem.Dg.Log("bridge", "showChatHead: " + ex.Message); }
    }
    [Export("hideChatHead")] [JavascriptInterface] public void HideChatHead() {
        try {
            var i = new Android.Content.Intent(_activity, typeof(SubsystemService));
            i.SetAction(SubsystemService.ActionHideBubble);
            _activity.StartService(i);
        } catch (System.Exception ex) { Subsystem.Dg.Log("bridge", "hideChatHead: " + ex.Message); }
    }
    [Export("minimizeApp")]     [JavascriptInterface] public void MinimizeApp()     { _activity.MoveTaskToBack(true); }
    [Export("setStatusBarHidden")] [JavascriptInterface] public void SetStatusBarHidden(bool hidden) { _activity.SetStatusBarHidden(hidden); }
    // Native background blur-behind for the assist popup / system mica (API 31+). radiusPx<=0 clears it.
    [Export("setWindowBlur")] [JavascriptInterface] public void SetWindowBlur(int radiusPx) { _activity.SetWindowBlur(radiusPx); }
    [Export("startProjection")] [JavascriptInterface] public void StartProjection() { _activity.StartProjection(); }
    [Export("startScreenCapture")] [JavascriptInterface] public void StartScreenCapture() { _activity.StartScreenCapture(); }
    [Export("exitApp")]         [JavascriptInterface] public void ExitApp()         { _activity.FinishAffinity(); Java.Lang.JavaSystem.Exit(0); }
    
    [Export("checkPermission")] [JavascriptInterface] public bool CheckPermission(string permission) {
        return _activity.CheckSelfPermission(permission) == Android.Content.PM.Permission.Granted;
    }

    // All-files access is an APPOP, not a runtime permission — CheckSelfPermission can NEVER report
    // it granted (the "always red" bug). The real check is Environment.IsExternalStorageManager and
    // the real request is the ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION settings screen.
    [Export("isAllFilesAccess")] [JavascriptInterface] public bool IsAllFilesAccess() {
        try { return Android.OS.Environment.IsExternalStorageManager; } catch { return false; }
    }

    [Export("requestAllFilesAccess")] [JavascriptInterface] public void RequestAllFilesAccess() {
        try {
            var uri = Android.Net.Uri.Parse("package:" + _activity.PackageName);
            var intent = new Android.Content.Intent(
                Android.Provider.Settings.ActionManageAppAllFilesAccessPermission, uri);
            _activity.StartActivity(intent);
        } catch (System.Exception ex) { Subsystem.Dg.Log("bridge", "requestAllFilesAccess: " + ex.Message); }
    }

    // Share OUT of the cage: hand text/JSON (Adaptive Cards, command output, file paths) to any
    // other provider via the system chooser. The renderer holds no authority — it asks, the host shares.
    [Export("shareText")] [JavascriptInterface] public void ShareText(string title, string text, string mime) {
        try {
            var send = new Android.Content.Intent(Android.Content.Intent.ActionSend);
            send.SetType(string.IsNullOrEmpty(mime) ? "text/plain" : mime);
            send.PutExtra(Android.Content.Intent.ExtraText, text ?? "");
            if (!string.IsNullOrEmpty(title)) send.PutExtra(Android.Content.Intent.ExtraTitle, title);
            var chooser = Android.Content.Intent.CreateChooser(send, title ?? "Share");
            chooser!.AddFlags(Android.Content.ActivityFlags.NewTask);
            _activity.StartActivity(chooser);
        } catch (System.Exception ex) { Subsystem.Dg.Log("bridge", "shareText: " + ex.Message); }
    }
    
    // Request an OS runtime permission at use-time (the WebView's getUserMedia needs the *app* to hold
    // RECORD_AUDIO first). Returns true if already granted (proceed now); false means a request was
    // dispatched and the decision arrives at window.__onPermissionResult(name, granted) — await that.
    [Export("requestPermission")] [JavascriptInterface] public bool RequestPermission(string permission) {
        return _activity.RequestRuntimePermission(permission);
    }
    
    [Export("openAccessibilitySettings")] [JavascriptInterface] public void OpenAccessibilitySettings() {
        _activity.StartActivity(new Android.Content.Intent(Android.Provider.Settings.ActionAccessibilitySettings));
    }
    
    [Export("isAccessibilityEnabled")] [JavascriptInterface] public bool IsAccessibilityEnabled() {
        return _activity.IsAccessibilityEnabled();
    }

    // Destroyable permissions — the owner's "take it back" with teeth. revokeSelfPermissionOnKill (API 33+;
    // the device is API 36) schedules the runtime permission to be dropped when the app's process next dies,
    // with no trip to system Settings. The Subsystem-side authority dies IMMEDIATELY anyway (the presenter
    // also flips \Capability\Consent\* off via Set-Capability, and the possession gate denies at once); this
    // releases the OS grant too. Returns true if the self-revoke was scheduled, false if the platform is too
    // old (caller then falls back to openAppSettings).
    [Export("revokePermission")] [JavascriptInterface] public bool RevokePermission(string permission) {
        try {
            if (Android.OS.Build.VERSION.SdkInt >= Android.OS.BuildVersionCodes.Tiramisu) {
                _activity.RevokeSelfPermissionOnKill(permission);
                return true;
            }
        } catch (System.Exception ex) { Subsystem.Dg.Log("bridge", "revokePermission: " + ex.Message); }
        return false;
    }

    // All-files access (an appop) and the Accessibility grant are not runtime permissions, so they cannot be
    // self-revoked — open the app's own system settings page where the owner turns them off by hand.
    [Export("openAppSettings")] [JavascriptInterface] public void OpenAppSettings() {
        try {
            var uri = Android.Net.Uri.Parse("package:" + _activity.PackageName);
            _activity.StartActivity(new Android.Content.Intent(
                Android.Provider.Settings.ActionApplicationDetailsSettings, uri));
        } catch (System.Exception ex) { Subsystem.Dg.Log("bridge", "openAppSettings: " + ex.Message); }
    }

    [Export("setWebcast")] [JavascriptInterface] public void SetWebcast(bool enable) {
        if (enable) _activity.StartProjection();
        else _activity.StopProjection();
    }

    [Export("getAutoListen")] [JavascriptInterface] public bool GetAutoListen() {
        return AgentSettings.AutoListenAssist(_activity);
    }

    [Export("setAutoListen")] [JavascriptInterface] public void SetAutoListen(bool enable) {
        AgentSettings.SetAutoListenAssist(_activity, enable);
    }

    [Export("getScripts")]      [JavascriptInterface] public string GetScripts() {
        try {
            // Embedded catalog (ObpHost), leaf names only — same contract the asset listing had.
            var files = ObpHost.Enumerate("shell/scripts")
                .Select(p => p.Substring(p.LastIndexOf('/') + 1)).ToArray();
            return JsonSerializer.Serialize(files);
        } catch { return "[]"; }
    }
}

public class TerminalBackCallback : Java.Lang.Object, IOnBackInvokedCallback {
    private readonly MainActivity _activity;
    public TerminalBackCallback(MainActivity activity) { _activity = activity; }
    public void OnBackInvoked() {
        // Back = in-app navigation (shell window history), not "send ESC to the terminal". The shell owns
        // what "back" means per the active surface; at the root it drops to home (see GoBackInApp).
        _activity.GoBackInApp();
    }
}

public class SubsystemWebViewClient : WebViewClient {
    // The shell document is up — flush any deep-link the launching intent carried (open=agent from
    // the chat head). The flush is a no-op when nothing is pending.
    public override void OnPageFinished(WebView? view, string? url) {
        base.OnPageFinished(view, url);
        try { MainActivity.Instance?.FlushPendingOpen(); } catch { }
    }

    public override WebResourceResponse? ShouldInterceptRequest(WebView? view, IWebResourceRequest? request) {
        if (request?.Url?.Scheme?.ToLower() == "vom") {
            var handleName = request.Url.Host;
            if (!string.IsNullOrEmpty(handleName)) {
                var bytes = VomInterop.GetTextureBytes(handleName);
                if (bytes != null && bytes.Length > 0) {
                    var ms = new System.IO.MemoryStream(bytes);
                    var response = new WebResourceResponse("application/octet-stream", "UTF-8", ms);
                    // Add CORS headers so local WebView can fetch it
                    response.ResponseHeaders = new System.Collections.Generic.Dictionary<string, string> {
                        { "Access-Control-Allow-Origin", "*" }
                    };
                    return response;
                }
            }
        }
        return base.ShouldInterceptRequest(view, request);
    }

    // HARD RULE: V8 can NEVER worm its way online. Allow only the local app origin + vom:// + benign
    // schemes; swallow everything else. This blocks CDN/phishing/exfiltration — the renderer has zero
    // authority AND zero reach (a leaf, offline-first).
    public override bool ShouldOverrideUrlLoading(WebView? view, IWebResourceRequest? request) {
        var url = request?.Url;
        if (url == null) return false;
        string scheme = (url.Scheme ?? "").ToLowerInvariant();
        string host   = (url.Host ?? "").ToLowerInvariant();
        bool localHttp = (scheme == "http" || scheme == "https") && (host == "127.0.0.1" || host == "localhost");
        bool allowed = localHttp || scheme == "vom" || scheme == "file" || scheme == "data" || scheme == "about" || scheme == "blob";
        if (allowed) return false;                              // let the WebView load it
        Subsystem.Dg.Log("v8", $"blocked off-origin navigation: {url}");
        return true;                                           // swallow — never go online
    }
}

public class VomBridgeJSInterface : Java.Lang.Object {
    private readonly MainActivity _activity;
    public VomBridgeJSInterface(MainActivity activity) { _activity = activity; }

    [Export("sendMessage")] [JavascriptInterface] 
    public void SendMessage(string payload) {
        Android.Util.Log.Debug("SubsystemVOM", "Received via JS Interface: " + payload);
    }

    [Export("apiCommand")] [JavascriptInterface] 
    public string ApiCommand(string command) {
        try {
            return SubsystemApi.ExecuteCommandAsJson(command).GetAwaiter().GetResult();
        } catch (System.Exception ex) {
            return $"{{\"error\": \"{ex.Message}\"}}";
        }
    }
}

public class ImageAvailableListener : Java.Lang.Object, Android.Media.ImageReader.IOnImageAvailableListener {
    private Subsystem.ProjectionServer? _server;
    public ImageAvailableListener(Subsystem.ProjectionServer? server) { _server = server; }
    public void OnImageAvailable(Android.Media.ImageReader? reader) {
        try {
            using var image = reader?.AcquireLatestImage();
            if (image == null) return;
            var plane = image.GetPlanes()![0];
            var buffer = plane.Buffer!;
            int pixelStride = plane.PixelStride;
            int rowStride = plane.RowStride;
            int rowPadding = rowStride - pixelStride * image.Width;
            
            using var bitmap = Android.Graphics.Bitmap.CreateBitmap(image.Width + rowPadding / pixelStride, image.Height, Android.Graphics.Bitmap.Config.Argb8888!);
            bitmap.CopyPixelsFromBuffer(buffer);
            
            using var ms = new System.IO.MemoryStream();
            using var cropped = Android.Graphics.Bitmap.CreateBitmap(bitmap, 0, 0, image.Width, image.Height);
            cropped.Compress(Android.Graphics.Bitmap.CompressFormat.Jpeg!, 30, ms);
            _server?.BroadcastRdpFrame(ms.ToArray());
        } catch { }
    }
}

public class CustomWebChromeClient : WebChromeClient {
    // Media-capture grant for the shell. The WebView only ever loads the loopback origin
    // (SubsystemWebViewClient blocks every off-origin navigation), so a capture request can only
    // come from our own presenters — granting the mic here lets the chat's voice-in (getUserMedia)
    // work. The app already holds RECORD_AUDIO (manifest + install -g).
    public override void OnPermissionRequest(Android.Webkit.PermissionRequest? request) {
        try { request?.Grant(request.GetResources()); }
        catch (System.Exception ex) { Subsystem.Dg.Warn("webview", ex); }
    }

    public override bool OnJsConfirm(WebView? view, string? url, string? message, JsResult? result) {
        new AlertDialog.Builder(view!.Context!)
            .SetTitle("Subsystem")
            .SetMessage(message)
            .SetPositiveButton(Android.Resource.String.Ok, (s, e) => result!.Confirm())
            .SetNegativeButton(Android.Resource.String.Cancel, (s, e) => result!.Cancel())
            .SetCancelable(false)
            .Show();
        return true;
    }

    public override bool OnJsAlert(WebView? view, string? url, string? message, JsResult? result) {
        new AlertDialog.Builder(view!.Context!)
            .SetTitle("Subsystem")
            .SetMessage(message)
            .SetPositiveButton(Android.Resource.String.Ok, (s, e) => result!.Confirm())
            .SetCancelable(false)
            .Show();
        return true;
    }
}
