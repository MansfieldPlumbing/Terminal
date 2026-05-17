using Android.App;
using Android.OS;
using Android.Views;
using Android.Webkit;
using Android.Window;
using Java.Interop;
using System;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Management.Automation.Host;
using System.Management.Automation.Provider;
using System.Runtime.InteropServices;
using System.Reflection;
using VtNetCore.VirtualTerminal;
using VtNetCore.XTermParser;

namespace TerminalApp;

public class ReactInputEvent {
    public string type { get; set; } = "";
    public int cols { get; set; }
    public int rows { get; set; }
    public string key { get; set; } = "";
    public string action { get; set; } = "";
    public int col { get; set; }
    public int row { get; set; }
}

public class LockedDownWebViewClient : WebViewClient
{
    public override void OnReceivedError(WebView? view, IWebResourceRequest? request, WebResourceError? error)
    {
        if (request?.IsForMainFrame == true) { view?.LoadDataWithBaseURL(null, "<html><body style='background:#000;color:#c42b1c;font-family:monospace;display:flex;align-items:center;justify-content:center;'>SYSTEM RESOURCE UNAVAILABLE</body></html>", "text/html", "utf-8", null); }
    }
}

public class QuietWebChromeClient : WebChromeClient
{
    public override bool OnConsoleMessage(ConsoleMessage? consoleMessage)
    {
        // Intercept all WebView console logs and swallow them. No more ADB spam.
        return true;
    }
}

[Activity(Label = "Terminal", MainLauncher = true, Theme = "@android:style/Theme.DeviceDefault.NoActionBar", WindowSoftInputMode = Android.Views.SoftInput.AdjustResize, ConfigurationChanges = Android.Content.PM.ConfigChanges.Orientation | Android.Content.PM.ConfigChanges.ScreenSize | Android.Content.PM.ConfigChanges.KeyboardHidden | Android.Content.PM.ConfigChanges.ScreenLayout)]
public class MainActivity : Activity
{
    private WebView _webView = null!;
    private PowerShell _ps = null!;
    private AndroidTerminalHost _host = null!;
    private bool _isReactReady = false;
    private Queue<byte[]> _outputQueue = new Queue<byte[]>();

    private readonly object _vtLock = new object();
    private VirtualTerminalController _vtController = null!;
    private DataConsumer _vtConsumer = null!;

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);

        _webView = new WebView(this);
        
        _webView.Settings.JavaScriptEnabled = true;
        _webView.Settings.DomStorageEnabled = true;
        _webView.Settings.AllowFileAccess = true;
        _webView.Settings.AllowFileAccessFromFileURLs = true;
        _webView.Settings.AllowUniversalAccessFromFileURLs = true;
        _webView.Settings.BuiltInZoomControls = false;
        _webView.Settings.DisplayZoomControls = false;
        _webView.Settings.SetSupportZoom(false);
        _webView.OverScrollMode = OverScrollMode.Never;
        _webView.SetWebViewClient(new LockedDownWebViewClient()); 
        _webView.SetWebChromeClient(new QuietWebChromeClient());

        NativeLibrary.SetDllImportResolver(typeof(System.Management.Automation.PowerShell).Assembly, (libraryName, assembly, searchPath) =>
        {
            if (libraryName.Contains("libpsl-native"))
                return NativeLibrary.Load("libpsl-android.so", assembly, searchPath);
            return IntPtr.Zero;
        });

        _webView.AddJavascriptInterface(new PwshBridge(this), "AndroidBridge");
        _webView.LoadUrl("file:///android_asset/wwwroot/index.html");

        _vtController = new VirtualTerminalController();
        _vtController.ResizeView(120, 40); 
        _vtConsumer = new DataConsumer(_vtController);

                // Register Android 16 Predictive Back handler
        if (Build.VERSION.SdkInt >= BuildVersionCodes.Tiramisu)
        {
            this.OnBackInvokedDispatcher.RegisterOnBackInvokedCallback(
                0, 
                new TerminalBackCallback(this));
        }

        SetContentView(_webView);



        Task.Run(() => InitializePowerShell());
    }

    private void LoadFromAssembly(InitialSessionState iss, Assembly assembly)
    {
        try {
            foreach (var type in assembly.GetTypes())
            {
                var cmdletAttr = type.GetCustomAttribute<CmdletAttribute>();
                if (cmdletAttr != null)
                    iss.Commands.Add(new SessionStateCmdletEntry(
                        $"{cmdletAttr.VerbName}-{cmdletAttr.NounName}", type, ""));
                var providerAttr = type.GetCustomAttribute<CmdletProviderAttribute>();
                if (providerAttr != null)
                    iss.Providers.Add(new SessionStateProviderEntry(
                        providerAttr.ProviderName, type, ""));
            }
        } catch { }
    }

    public Coordinates GetCursorPosition() 
    {
        lock (_vtLock) { return _vtController == null ? new Coordinates(0,0) : new Coordinates(_vtController.CursorState.CurrentColumn, _vtController.CursorState.CurrentRow); }
    }
    
    public Size GetWindowSize() 
    {
        lock (_vtLock) { return _vtController == null ? new Size(120,40) : new Size(_vtController.VisibleColumns, _vtController.VisibleRows); }
    }

    private void InitializePowerShell()
    {
        var iss = InitialSessionState.Create();
        iss.LanguageMode = PSLanguageMode.FullLanguage;
        LoadFromAssembly(iss, typeof(PSObject).Assembly);
        LoadFromAssembly(iss, Assembly.Load("Microsoft.PowerShell.Commands.Utility"));
        LoadFromAssembly(iss, Assembly.Load("Microsoft.PowerShell.Commands.Management"));

        // --- RESTORE CORE ALIASES ---
        iss.Commands.Add(new SessionStateAliasEntry("cd", "Set-Location", ""));
        iss.Commands.Add(new SessionStateAliasEntry("ls", "Get-ChildItem", ""));
        iss.Commands.Add(new SessionStateAliasEntry("dir", "Get-ChildItem", ""));
        iss.Commands.Add(new SessionStateAliasEntry("cat", "Get-Content", ""));
        iss.Commands.Add(new SessionStateAliasEntry("echo", "Write-Output", ""));
        iss.Commands.Add(new SessionStateAliasEntry("clear", "Clear-Host", ""));
        iss.Commands.Add(new SessionStateAliasEntry("rm", "Remove-Item", ""));
        iss.Commands.Add(new SessionStateAliasEntry("pwd", "Get-Location", ""));
        iss.Commands.Add(new SessionStateAliasEntry("sl", "Set-Location", ""));
        // ----------------------------
        
        _host = new AndroidTerminalHost(this);
        var rs = RunspaceFactory.CreateRunspace(_host, iss);
        rs.Open();

        _ps = PowerShell.Create();
        _ps.Runspace = rs;

        // Map Android's sandboxed storage to the user's HOME directory
        string appBasePath = this.FilesDir!.AbsolutePath;
        System.Environment.SetEnvironmentVariable("HOME", appBasePath);
        
        _ps.AddScript($"$env:HOME = '{appBasePath}'; Set-Location -Path '{appBasePath}'");
        _ps.Invoke();
        _ps.Commands.Clear();

        var repl = new ReplEngine(this, _host, rs);
        repl.Start();
    }

    public void ExecuteCommand(string command) 
    {
        Task.Run(() => {
            try {
                FeedTerminal(Encoding.UTF8.GetBytes($"{command}\r\n"));
                _ps.Commands.Clear();
                _ps.AddScript(command);
                _ps.Invoke();
                if (_ps.HadErrors)
                {
                    foreach (var error in _ps.Streams.Error)
                    {
                        FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[31m{error}\x1b[0m\r\n"));
                    }
                }
                FeedTerminal(Encoding.UTF8.GetBytes("\x1b[34mPS>\x1b[0m "));
            } catch (Exception ex) {
                FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[31mFatal Exec Error: {ex.Message}\x1b[0m\r\n"));
            }
        });
    }

    private ConsoleKey MapReactKey(string key) {
        return key switch {
            "Enter" => ConsoleKey.Enter,
            "Backspace" => ConsoleKey.Backspace,
            "ArrowUp" => ConsoleKey.UpArrow,
            "ArrowDown" => ConsoleKey.DownArrow,
            "ArrowLeft" => ConsoleKey.LeftArrow,
            "ArrowRight" => ConsoleKey.RightArrow,
            "Escape" => ConsoleKey.Escape,
            "Tab" => ConsoleKey.Tab,
            _ => (ConsoleKey)0
        };
    }

        public void SendRawToReact(byte[] rawAnsiBytes)
    {
        if (!_isReactReady)
        {
            _outputQueue.Enqueue(rawAnsiBytes);
            return;
        }
        string text = Encoding.UTF8.GetString(rawAnsiBytes);
        RunOnUiThread(() => 
        {
            // NATIVE STRING IPC: Bypasses string evaluation limits
            _webView.PostWebMessage(new WebMessage(text), Android.Net.Uri.Parse("*")!);
        });
    }

    public void RouteInputEvent(string jsonPayload)
    {
        try {
            var ev = JsonSerializer.Deserialize<ReactInputEvent>(jsonPayload, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (ev?.type == "resize")
            {
                lock (_vtLock) 
                {
                    _vtController.ResizeView(ev.cols, ev.rows);
                    PushTerminalFrame();
                    _vtController.ClearChanges();
                }
            }
            else if (ev?.type == "input" && !string.IsNullOrEmpty(ev.key))
            {
                ConsoleKey consoleKey = MapReactKey(ev.key);
                char ch = ev.key.Length == 1 ? ev.key[0] : '\0';
                
                if (consoleKey == ConsoleKey.Enter) ch = '\r';
                if (consoleKey == ConsoleKey.Backspace) ch = '\b';
                if (consoleKey == ConsoleKey.Escape) ch = '\x1b';
                if (consoleKey == ConsoleKey.Tab) ch = '\t';
                
                var keyInfo = new KeyInfo((int)consoleKey, ch, (ControlKeyStates)0, true);
                
                var rawUi = (AndroidTerminalRawUserInterface)_host.UI.RawUI;
                rawUi.InputQueue.Add(keyInfo);
            }
            else if (ev?.type == "touch" && ev?.action == "tap")
            {
                var rawUi = (AndroidTerminalRawUserInterface)_host.UI.RawUI;
                string vtClick = $"\x1b[<0;{ev.col + 1};{ev.row + 1}M\x1b[<0;{ev.col + 1};{ev.row + 1}m";
                foreach (char c in vtClick) {
                    rawUi.InputQueue.Add(new KeyInfo((int)0, c, (ControlKeyStates)0, true));
                }
            }
        } catch { }
    }

    public void FeedTerminal(byte[] rawAnsiBytes) 
    {
        lock (_vtLock) 
        {
            _vtConsumer.Push(rawAnsiBytes); 
            if (_vtController.Changed) 
            {
                PushTerminalFrame();
                _vtController.ClearChanges();
            }
        }
        SendRawToReact(rawAnsiBytes);
    }

    public void PushTerminalFrame()
    {
        if (!_isReactReady) return;

        int cols = _vtController.VisibleColumns;
        int rows = _vtController.VisibleRows;
        
        int[] frameBuffer = new int[(cols * rows) + 4];
        frameBuffer[0] = cols;
        frameBuffer[1] = rows;
        frameBuffer[2] = _vtController.CursorState.CurrentColumn;
        frameBuffer[3] = _vtController.CursorState.CurrentRow;

        for (int y = 0; y < rows; y++)
        {
            var line = _vtController.ViewPort.GetVisibleLine(y);
            for (int x = 0; x < cols; x++)
            {
                int index = (y * cols + x) + 4; 
                if (line != null && x < line.Count)
                {
                    var cell = line[x];
                    byte fg = (byte)cell.Attributes.ForegroundColor;
                    byte bg = (byte)cell.Attributes.BackgroundColor;
                    if (cell.Attributes.Bright) fg += 8;
                    char c = cell.Char == '\0' ? ' ' : cell.Char;
                    frameBuffer[index] = (bg << 24) | (fg << 16) | (ushort)c;
                }
                else
                {
                    frameBuffer[index] = 0;
                }
            }
        }

        byte[] bytes = new byte[frameBuffer.Length * sizeof(int)];
        Buffer.BlockCopy(frameBuffer, 0, bytes, 0, bytes.Length);

        RunOnUiThread(() => {
            // ZERO-COPY IPC: Native Dalvik byte[] to V8 ArrayBuffer
            string b64 = Convert.ToBase64String(bytes);
            _webView.EvaluateJavascript("var b=atob('" + b64 + "');var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);window.postMessage(a.buffer, '*');", null);
        });
    }
            public void NotifyReactReady() { 
        _isReactReady = true; 
        lock (_vtLock) { PushTerminalFrame(); } 
        while (_outputQueue.Count > 0) { SendRawToReact(_outputQueue.Dequeue()); }
    }
}

public class PwshBridge : Java.Lang.Object
{
    private readonly MainActivity _activity;
    public PwshBridge(MainActivity activity) { _activity = activity; }

    [Export("invokeCommand")]
    [JavascriptInterface]
    public void InvokeCommand(string command) { _activity.ExecuteCommand(command); }

    [Export("sendInput")]
    [JavascriptInterface]
    public void SendInput(string json) { _activity.RouteInputEvent(json); }

    [Export("notifyReady")]
    [JavascriptInterface]
    public void NotifyReady() { _activity.NotifyReactReady(); }

    [Export("minimizeApp")]
    [JavascriptInterface]
    public void MinimizeApp() { _activity.MoveTaskToBack(true); }
}

public class TerminalBackCallback : Java.Lang.Object, IOnBackInvokedCallback
{
    private readonly MainActivity _activity;
    public TerminalBackCallback(MainActivity activity) { _activity = activity; }

    public void OnBackInvoked()
    {
        // Intercept Android Back Swipe: Send ESC instead of closing the app
        string json = "{ \"type\": \"input\", \"key\": \"Escape\" }";
        _activity.RouteInputEvent(json);
    }
}