using Android.App;
using Android.OS;
using Android.Util;
using Android.Webkit;
using Java.Interop;
using System;
using System.Text;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Management.Automation.Provider;
using System.Reflection;
using System.Runtime.InteropServices;

namespace TerminalApp;

[Activity(Label = "No Cap Terminal", MainLauncher = true, Theme = "@android:style/Theme.NoTitleBar.Fullscreen")]
public class MainActivity : Activity
{
    private WebView _webView;
    private PowerShell _ps;
    private bool _isReactReady = false;

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);

        _webView = new WebView(this);
        _webView.Settings.JavaScriptEnabled = true;
        _webView.Settings.DomStorageEnabled = true;
        _webView.Settings.AllowFileAccess = true;
        _webView.Settings.AllowFileAccessFromFileURLs = true;
        _webView.Settings.AllowUniversalAccessFromFileURLs = true;
        _webView.Settings.MediaPlaybackRequiresUserGesture = false;

        NativeLibrary.SetDllImportResolver(typeof(System.Management.Automation.PowerShell).Assembly, (libraryName, assembly, searchPath) =>
        {
            if (libraryName.Contains("libpsl-native"))
                return NativeLibrary.Load("libpsl-android.so", assembly, searchPath);
            return IntPtr.Zero;
        });

        _webView.AddJavascriptInterface(new PwshBridge(this), "AndroidBridge");
        _webView.SetWebViewClient(new WebViewClient()); 
        _webView.SetWebChromeClient(new WebChromeClient()); 
        _webView.LoadUrl("file:///android_asset/wwwroot/index.html");

        SetContentView(_webView);

        Task.Run(async () => 
        {
            await Task.Delay(2000);
            _isReactReady = true;
            InitializePowerShell();
        });
    }

    private void LoadFromAssembly(InitialSessionState iss, Assembly assembly)
    {
        try {
            foreach (var type in assembly.GetTypes())
            {
                // 1. Load the Cmdlets
                var cmdletAttr = type.GetCustomAttribute<CmdletAttribute>();
                if (cmdletAttr != null)
                {
                    iss.Commands.Add(new SessionStateCmdletEntry($"{cmdletAttr.VerbName}-{cmdletAttr.NounName}", type, ""));
                }
                
                // 2. Load the Providers (FileSystem, Environment, Alias, etc)
                var providerAttr = type.GetCustomAttribute<CmdletProviderAttribute>();
                if (providerAttr != null)
                {
                    iss.Providers.Add(new SessionStateProviderEntry(providerAttr.ProviderName, type, ""));
                }
            }
        } catch (Exception ex) {
            Log.Warn("PWSH-TEST", $"Could not load from {assembly.FullName}: {ex.Message}");
        }
    }

    private void InitializePowerShell()
    {
        try 
        {
            var iss = InitialSessionState.Create();
            iss.LanguageMode = PSLanguageMode.FullLanguage;

            LoadFromAssembly(iss, typeof(PSObject).Assembly);
            LoadFromAssembly(iss, Assembly.Load("Microsoft.PowerShell.Commands.Utility"));
            LoadFromAssembly(iss, Assembly.Load("Microsoft.PowerShell.Commands.Management"));

            _ps = PowerShell.Create(iss);
            
            _ps.AddCommand("Set-Location").AddParameter("Path", this.FilesDir.AbsolutePath).Invoke();
            _ps.Commands.Clear();
            
            SendToReact("PowerShell 7.6.1 Engine Initialized (Native Android Sandbox)\n");
        }
        catch (Exception ex)
        {
            Log.Error("PWSH-TEST", $"Engine Boot Error: {ex.ToString()}");
            SendToReact($"Engine Boot Error: {ex.Message}\n");
        }
    }

    public void ExecuteCommand(string command)
    {
        if (_ps == null) 
        {
            SendToReact("Error: PowerShell engine is still initializing...\n");
            return;
        }

        Task.Run(() => 
        {
            try 
            {
                _ps.Commands.Clear();
                _ps.Streams.ClearStreams();
                
                _ps.AddScript(command).AddCommand("Out-String");

                var results = _ps.Invoke<string>();
                
                StringBuilder sb = new StringBuilder();
                foreach (var result in results)
                {
                    sb.Append(result);
                }

                if (_ps.Streams.Error.Count > 0)
                {
                    foreach (var err in _ps.Streams.Error)
                    {
                        sb.AppendLine("ERROR: " + err.ToString());
                    }
                }

                string finalOutput = sb.ToString();
                if (string.IsNullOrWhiteSpace(finalOutput)) finalOutput = "\n";
                
                SendToReact(finalOutput);
            }
            catch (Exception ex)
            {
                SendToReact($"Execution Error: {ex.Message}\n");
            }
        });
    }

    public void SendToReact(string text)
    {
        if (!_isReactReady) return;
        string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
        RunOnUiThread(() => 
        {
            _webView.EvaluateJavascript($"if(window.receivePwshOutput) window.receivePwshOutput(decodeURIComponent(escape(window.atob('{b64}'))));", null);
        });
    }
}

public class PwshBridge : Java.Lang.Object
{
    private readonly MainActivity _activity;

    public PwshBridge(MainActivity activity)
    {
        _activity = activity;
    }

    [Export("invokeCommand")]
    [JavascriptInterface]
    public void InvokeCommand(string command)
    {
        _activity.ExecuteCommand(command);
    }

    [Export("minimizeApp")]
    [JavascriptInterface]
    public void MinimizeApp()
    {
        _activity.MoveTaskToBack(true);
    }
}


