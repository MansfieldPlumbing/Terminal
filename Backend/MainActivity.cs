using Android.App;
using Android.OS;
using Android.Views;
using Android.Webkit;
using Java.Interop;
using System;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Management.Automation.Host;
using System.Runtime.InteropServices;
using VtNetCore.VirtualTerminal;
using VtNetCore.XTermParser;

namespace TerminalApp;

public class ReactInputEvent {
    public string type { get; set; } = "";
    public int cols { get; set; }
    public int rows { get; set; }
    public string key { get; set; } = "";
}

public class LockedDownWebViewClient : WebViewClient
{
    public override void OnReceivedError(WebView? view, IWebResourceRequest? request, WebResourceError? error)
    {
        if (request?.IsForMainFrame == true) { view?.LoadDataWithBaseURL(null, "<html><body style='background:#000;color:#c42b1c;font-family:monospace;display:flex;align-items:center;justify-content:center;'>SYSTEM RESOURCE UNAVAILABLE</body></html>", "text/html", "utf-8", null); }
    }
}

[Activity(Label = "Terminal", MainLauncher = true, Theme = "@android:style/Theme.NoTitleBar.Fullscreen")]
public class MainActivity : Activity
{
    private WebView _webView = null!;
    private PowerShell _ps = null!;
    private AndroidTerminalHost _host = null!;
    private bool _isReactReady = false;

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
        _webView.SetWebChromeClient(new WebChromeClient());

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

        SetContentView(_webView);
        Task.Run(() => InitializePowerShell());
    }

    private void InitializePowerShell()
    {
        var iss = InitialSessionState.CreateDefault();
        iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Unrestricted;
        
        // FIX: Attach Host on Runspace birth
        _host = new AndroidTerminalHost(this);
        var rs = RunspaceFactory.CreateRunspace(_host, iss);
        rs.Open();

        _ps = PowerShell.Create();
        _ps.Runspace = rs;

        try {
            _ps.AddCommand("Import-Module").AddParameter("Name", "PSReadLine").Invoke();
            _ps.Commands.Clear();
        } catch {}

        FeedTerminal(Encoding.UTF8.GetBytes("\x1b[32mDirectPort Console Host Attached\x1b[0m\r\n\x1b[34mPS>\x1b[0m "));
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

    public void RouteInputEvent(string jsonPayload)
    {
        try {
            var ev = JsonSerializer.Deserialize<ReactInputEvent>(jsonPayload, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (ev?.type == "resize")
            {
                _vtController.ResizeView(ev.cols, ev.rows);
                PushTerminalFrame();
            }
            else if (ev?.type == "input" && !string.IsNullOrEmpty(ev.key))
            {
                char ch = ev.key.Length == 1 ? ev.key[0] : '\0';
                ConsoleKey consoleKey = MapReactKey(ev.key);
                
                // FIX: Valid KeyInfo Constructor
                var keyInfo = new KeyInfo((int)consoleKey, ch, (ControlKeyStates)0, true);
                
                // FIX: Retrieve RawUI safely from instantiated Host
                var rawUi = (AndroidTerminalRawUserInterface)_host.UI.RawUI;
                rawUi.InputQueue.Add(keyInfo);
            }
        } catch { }
    }

    public void FeedTerminal(byte[] rawAnsiBytes) 
    {
        _vtConsumer.Push(rawAnsiBytes); 
        
        if (_vtController.Changed && _isReactReady)
        {
            PushTerminalFrame();
            _vtController.ClearChanges();
        }
    }

        public void PushTerminalFrame()
    {
        if (!_isReactReady) return;

        int cols = _vtController.VisibleColumns;
        int rows = _vtController.VisibleRows;
        
        int[] frameBuffer = new int[(cols * rows) + 2];
        frameBuffer[0] = cols;
        frameBuffer[1] = rows;

        for (int y = 0; y < rows; y++)
        {
            var line = _vtController.ViewPort.GetVisibleLine(y);
            for (int x = 0; x < cols; x++)
            {
                int index = (y * cols + x) + 2; 
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
            string b64 = Convert.ToBase64String(bytes);
            _webView.EvaluateJavascript("var b=atob('" + b64 + "');var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);window.postMessage(a.buffer, '*');", null);
        });
    }
public void NotifyReactReady() { _isReactReady = true; PushTerminalFrame(); }
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



