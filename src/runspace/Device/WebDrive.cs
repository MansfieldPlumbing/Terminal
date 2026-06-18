using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Android.Views;
using Android.Webkit;

namespace Subsystem.Device;

// WebDrive — the Android browse driver the Rd surface declared pending (InvokeRdConsultCmdlet's note).
// The on-device port of the Windows agent-webview2 surface: an agent-OWNED, network-capable WebView
// (distinct from the shell renderer, which is the air-gapped, loopback-only presenter) that the agent
// drives through bounded INTENTS and perceives through a text HUD. It is mounted as a VOM Surface under
// \Capability\WebDrive — a refcounted handle reclaimed by the same DropPrefix/Terminate cascade as any
// object — not a free-floating leaf. Off-device exposure, so its agent-tool projection is consent-gated.
//
// Intents (one per step):  goto <url> | click <N> | type <N> "text" | back
// The HUD tags every visible interactive node data-ag-id=N and projects SITREP / VIEWPORT / PAGE TEXT /
// ELEMENTS / INTENTS — the same shape the Windows surface emits, so one operator/agent reads both heads.
// Android has no CDP, so click/type are synthesized in the page (el.click(); value + input/change events)
// rather than through trusted input; deterministic on ordinary pages and the local web-fixtures.
public sealed class WebDrive
{
    private const string OwnerPath = "\\Capability\\WebDrive";
    private const string SurfaceName = "agent";

    private static readonly object _lock = new();
    private static WebDrive? _instance;

    private WebView _web = null!;

    // Open-or-resolve the single agent surface, mounting it in the VOM on first call. The WebView is
    // created on the UI thread; this blocks the caller (a runspace thread, never the UI thread) until it
    // is ready, so a cmdlet can drive it synchronously.
    public static WebDrive Open()
    {
        lock (_lock)
        {
            if (_instance != null) return _instance;
            var d = new WebDrive();
            d.OpenSurface();
            var owner = Subsystem.Vom.Vom.CreateOwner(OwnerPath);
            Subsystem.Vom.Vom.Register(owner, "Surface", d,
                onReclaim: () => { try { d.Close(); } catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); } },
                subdir: "Surfaces", name: SurfaceName);
            _instance = d;
            return d;
        }
    }

    // Tear the surface down: remove the overlay and forget the singleton. The VOM handle's onReclaim
    // routes here too, so a DropPrefix of \Capability\WebDrive closes it the same way.
    public void Close()
    {
        lock (_lock)
        {
            var web = _web;
            if (web != null)
            {
                RunUi(() =>
                {
                    try { MainActivity.Instance?.WindowManager?.RemoveView(web); } catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); }
                    try { web.Destroy(); } catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); }
                });
            }
            _web = null!;
            _instance = null;
        }
    }

    private void OpenSurface()
    {
        var act = MainActivity.Instance ?? throw new InvalidOperationException("MainActivity.Instance is not initialized.");
        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        act.RunOnUiThread(() =>
        {
            try
            {
                var web = new WebView(act);
                web.Settings.JavaScriptEnabled = true;
                web.Settings.DomStorageEnabled = true;
                web.Settings.AllowFileAccess = true;          // file:///android_asset/shell/web-fixtures/*
                web.Settings.LoadWithOverviewMode = true;
                web.Settings.UseWideViewPort = true;
                web.SetWebViewClient(new WebViewClient());     // keep navigation inside this surface
                web.SetBackgroundColor(Android.Graphics.Color.White);

                var dm = act.Resources!.DisplayMetrics!;
                int w = (int)(dm.WidthPixels * 0.82);
                int h = (int)(dm.HeightPixels * 0.62);
                var lp = new WindowManagerLayoutParams(
                    w, h,
                    WindowManagerTypes.ApplicationOverlay,
                    // Not focusable + not touchable: the agent acts through JS, never steals input; the
                    // operator can watch it drive without it interfering with the device.
                    WindowManagerFlags.NotFocusable | WindowManagerFlags.NotTouchable,
                    Android.Graphics.Format.Translucent)
                {
                    Gravity = GravityFlags.Top | GravityFlags.Left,
                    X = 24,
                    Y = 120,
                    Alpha = 0.96f,
                };
                act.WindowManager!.AddView(web, lp);
                _web = web;
                tcs.TrySetResult(true);
            }
            catch (Exception ex) { tcs.TrySetException(ex); }
        });
        if (!tcs.Task.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("WebDrive surface did not come up");
        tcs.Task.GetAwaiter().GetResult();
    }

    // Run a '|'-separated intent sequence on the live surface, projecting a HUD after each step.
    // Cancellation is the operator's (the loop owner's): checked between steps and honored mid-settle.
    public async Task<string> ApplyAsync(string script, CancellationToken ct = default)
    {
        var log = new StringBuilder();
        foreach (var raw in (script ?? "").Split('|'))
        {
            ct.ThrowIfCancellationRequested();
            var step = raw.Trim();
            if (step.Length == 0) continue;
            if (step[0] == '/') step = step.Substring(1).Trim();
            if (step.Length == 0) continue;

            int sp = step.IndexOf(' ');
            string verb = sp < 0 ? step.ToLowerInvariant() : step.Substring(0, sp).ToLowerInvariant();
            string arg = sp < 0 ? "" : step.Substring(sp + 1).Trim();

            switch (verb)
            {
                case "goto":
                case "nav":
                {
                    // A scheme-less argument is normalized by the platform URLUtil (no endpoint literal in
                    // source — SS010); a full URL or a file:// asset path passes through unchanged.
                    var u = arg.Contains("://") ? arg : Android.Webkit.URLUtil.GuessUrl(arg);
                    RunUi(() => { try { _web.LoadUrl(u); } catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); } });
                    break;
                }
                case "click":
                    await QueryScriptAsync("(function(){var el=document.querySelector(\"[data-ag-id='" + JsNum(arg) +
                        "']\");if(!el)return 'NO_ELEMENT';el.scrollIntoView();el.click();return 'OK';})()");
                    break;
                case "type":
                {
                    int q1 = arg.IndexOf('"');
                    string idPart = q1 >= 0 ? arg.Substring(0, q1).Trim() : arg.Trim();
                    string text = q1 >= 0 ? arg.Substring(q1).Trim().Trim('"') : "";
                    string js = "(function(){var el=document.querySelector(\"[data-ag-id='" + JsNum(idPart) +
                        "']\");if(!el)return 'NO_ELEMENT';el.focus();el.value=" + JsonSerializer.Serialize(text) +
                        ";el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return 'OK';})()";
                    await QueryScriptAsync(js);
                    break;
                }
                case "back":
                    RunUi(() => { try { if (_web.CanGoBack()) _web.GoBack(); } catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); } });
                    break;
                case "respond":
                    log.Append("\n[RESPOND] ").Append(arg).Append('\n');
                    continue;
                default:
                    log.Append("\n[SKIP unknown intent] ").Append(step).Append('\n');
                    continue;
            }

            await WaitSettleAsync(ct);
            log.Append(await ReadHudAsync(step));
        }
        return log.ToString();
    }

    // The HUD: tag every visible interactive node data-ag-id=N, then project the agent's situation report.
    public async Task<string> ReadHudAsync(string lastStep)
    {
        const string js = @"(function(){
  var url=document.location.href, title=document.title;
  var text=((document.body?document.body.innerText:'')||'').replace(/[ \t]+/g,' ').replace(/\n\s*\n/g,'\n').trim();
  if(text.length>4000) text=text.substring(0,4000)+'...';
  var els=[].slice.call(document.querySelectorAll('a,button,input,textarea,select,[role=button],[role=link],[role=textbox],[contenteditable=true],[onclick]'));
  var out=[],k=0;
  els.forEach(function(el){
    if(el.offsetParent===null||el.offsetWidth<=0||el.offsetHeight<=0) return;
    var label=((el.innerText||el.value||el.placeholder||el.getAttribute('aria-label')||el.title||el.name||el.alt||'')+'').replace(/\s+/g,' ').trim().substring(0,80);
    if(!label) return;
    el.setAttribute('data-ag-id',k);
    var type=el.tagName.toLowerCase(); if(el.type) type+='['+el.type+']';
    out.push(k+'|'+type+'|'+label); k++;
  });
  if(out.length>60) out=out.slice(0,60);
  return JSON.stringify({url:url,title:title,text:text,els:out});
})()";
        string json = ParseJsString(await QueryScriptAsync(js));
        string url = "", title = "", text = "";
        var els = new List<string>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            url = doc.RootElement.GetProperty("url").GetString() ?? "";
            title = doc.RootElement.GetProperty("title").GetString() ?? "";
            text = doc.RootElement.GetProperty("text").GetString() ?? "";
            foreach (var x in doc.RootElement.GetProperty("els").EnumerateArray()) els.Add(x.GetString() ?? "");
        }
        catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); }

        var sb = new StringBuilder();
        sb.Append("\n================================================================================\n");
        sb.Append("[SITREP] ").Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm")).Append(" | after: ").Append(lastStep).Append('\n');
        sb.Append("[VIEWPORT] ").Append(title).Append("\nURL: ").Append(url).Append("\n\n");
        sb.Append("[PAGE TEXT]\n").Append(text).Append("\n\n[ELEMENTS]\n");
        foreach (var el in els)
        {
            var parts = el.Split('|');
            if (parts.Length == 3) sb.Append('[').Append(parts[0]).Append("] ").Append(parts[1]).Append(' ').Append(parts[2]).Append('\n');
        }
        sb.Append("\n[INTENTS] /click <N> | /type <N> \"text\" | /goto <url> | /back | /respond <text>\n");
        return sb.ToString();
    }

    // The surface's navigation history (visited URLs, oldest->current). The loop uses it to prune intents
    // the agent has already seen instead of growing the prompt with an ALREADY-VISITED list — the browser
    // already remembers where it has been; the KV does not have to.
    public string[] QueryHistory()
    {
        var tcs = new TaskCompletionSource<string[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        RunUi(() =>
        {
            try
            {
                var list = _web.CopyBackForwardList();
                var urls = new List<string>();
                for (int i = 0; i < list.Size; i++) urls.Add(list.GetItemAtIndex(i)?.Url ?? "");
                tcs.TrySetResult(urls.ToArray());
            }
            catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); tcs.TrySetResult(Array.Empty<string>()); }
        });
        return tcs.Task.Wait(TimeSpan.FromSeconds(5)) ? tcs.Task.Result : Array.Empty<string>();
    }

    // Poll the page text length until it stops growing (the WebView analog of a network-settle), capped.
    private async Task WaitSettleAsync(CancellationToken ct)
    {
        string prev = ""; int stable = 0;
        for (int i = 0; i < 16 && stable < 3; i++)
        {
            await Task.Delay(450, ct);
            string len = await QueryScriptAsync("(document.body?document.body.innerText.length:0)");
            if (len == prev) stable++; else { stable = 0; prev = len; }
        }
    }

    // Evaluate JS in the surface and return the raw (JSON-encoded) result. Marshalled to the UI thread;
    // the result callback completes the task on a runspace thread, never deadlocking the caller.
    private Task<string> QueryScriptAsync(string js)
    {
        var cb = new JsResult();
        RunUi(() => { try { _web.EvaluateJavascript(js, cb); } catch (Exception ex) { Subsystem.Dg.Warn("webdrive", ex); cb.OnReceiveValue(null); } });
        return cb.Task;
    }

    private static void RunUi(Action a)
    {
        var act = MainActivity.Instance;
        if (act == null) return;
        act.RunOnUiThread(a);
    }

    // Digits-only — element ids are numeric; this also stops a malformed id from breaking the selector.
    private static string JsNum(string s)
    {
        var sb = new StringBuilder();
        foreach (var c in s) if (c >= '0' && c <= '9') sb.Append(c);
        return sb.Length == 0 ? "-1" : sb.ToString();
    }

    // EvaluateJavascript returns the value JSON-encoded (a string result arrives quoted/escaped). Unwrap
    // one layer to the inner payload; a non-string (number/null) round-trips unchanged.
    private static string ParseJsString(string raw)
    {
        if (string.IsNullOrEmpty(raw) || raw == "null") return "{}";
        try { return JsonSerializer.Deserialize<string>(raw) ?? raw; }
        catch { return raw; }
    }

    // IValueCallback bridge: completes a task with the JS result on the UI thread.
    private sealed class JsResult : Java.Lang.Object, IValueCallback
    {
        private readonly TaskCompletionSource<string> _tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<string> Task => _tcs.Task;
        public void OnReceiveValue(Java.Lang.Object? value) => _tcs.TrySetResult(value?.ToString() ?? "null");
    }
}
