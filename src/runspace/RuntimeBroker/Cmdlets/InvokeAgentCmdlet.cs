using System;
using System.Management.Automation;
using System.Threading;

namespace Subsystem.RuntimeBroker.Cmdlets;

[Cmdlet(VerbsLifecycle.Invoke, "Agent")]
public class InvokeAgentCmdlet : PSCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    public string Prompt { get; set; } = string.Empty;

    // Return the full reply as ONE pipeline string instead of streaming it to the console host. This
    // is the programmatic path (the Morse chat loop, scripts, remote PSRP callers): Host.UI output
    // doesn't cross the PSRP seam, a WriteObject string does.
    [Parameter] public SwitchParameter AsText { get; set; }

    // Optional image to perceive with the prompt (multimodal turn). The file is read here and the bytes
    // are folded into the message as a content part by the runtime — Gemma 4 preprocesses it inline.
    [Parameter] public string? ImagePath { get; set; }

    protected override void ProcessRecord()
    {
        var ctx = Subsystem.MainActivity.Instance ?? Android.App.Application.Context;

        if (!AsText.IsPresent)
            Host.UI.WriteLine(ConsoleColor.DarkGray, Host.UI.RawUI.BackgroundColor, "[Agent Initializing...]");

        // Synchronously fetch the shared RuntimeBroker (Rb) instance
        var assistant = Subsystem.Rb.GetAsync(ctx).GetAwaiter().GetResult();

        if (!AsText.IsPresent)
            Host.UI.WriteLine(ConsoleColor.DarkGray, Host.UI.RawUI.BackgroundColor, "[Agent Thinking...]");

        byte[]? imageBytes = null;
        if (!string.IsNullOrEmpty(ImagePath))
        {
            try { imageBytes = System.IO.File.ReadAllBytes(ImagePath); }
            catch (Exception ex)
            {
                if (AsText.IsPresent) throw;
                Host.UI.WriteLine(ConsoleColor.Red, Host.UI.RawUI.BackgroundColor, $"[Image read failed: {ex.Message}]");
                return;
            }
        }

        var cts = new CancellationTokenSource();
        var stream = imageBytes != null
            ? assistant.SendMessageStreamAsync(Prompt, null, imageBytes, ct: cts.Token)
            : assistant.SendMessageStreamAsync(Prompt, ct: cts.Token);
        var enumerator = stream.GetAsyncEnumerator(cts.Token);
        var acc = AsText.IsPresent ? new System.Text.StringBuilder() : null;

        try
        {
            while (enumerator.MoveNextAsync().AsTask().GetAwaiter().GetResult())
            {
                var text = enumerator.Current;
                if (string.IsNullOrEmpty(text)) continue;
                if (acc != null) acc.Append(text);
                else Host.UI.Write(ConsoleColor.Cyan, Host.UI.RawUI.BackgroundColor, text);
            }
        }
        catch (Exception ex)
        {
            if (acc != null) throw;   // surface it as an error record to the programmatic caller
            Host.UI.WriteLine();
            Host.UI.WriteLine(ConsoleColor.Red, Host.UI.RawUI.BackgroundColor, $"[Error: {ex.Message}]");
        }
        finally
        {
            enumerator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }

        if (acc != null) WriteObject(acc.ToString().Trim());
        else Host.UI.WriteLine();
    }
}
