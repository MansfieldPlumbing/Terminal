using System;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Management.Automation.Host;

namespace TerminalApp;

public class ReplEngine
{
    private readonly MainActivity _mainActivity;
    private readonly AndroidTerminalHost _host;
    private readonly Runspace _runspace;
    private Thread _replThread = null!;
    private bool _shouldExit = false;

    public ReplEngine(MainActivity mainActivity, AndroidTerminalHost host, Runspace runspace)
    {
        _mainActivity = mainActivity;
        _host = host;
        _runspace = runspace;
    }

    public void Start()
    {
        _replThread = new Thread(RunLoop)
        {
            IsBackground = true,
            Name = "PowerShell-REPL-Thread"
        };
        _replThread.Start();
    }

    private void RunLoop()
    {
        using var ps = PowerShell.Create();
        ps.Runspace = _runspace;

        _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes("\x1b[2J\x1b[H"));

        while (!_shouldExit)
        {
            try
            {
                                // Safely get working directory without relying on prompt function
                string pText = "PS> ";
                try {
                    ps.Commands.Clear();
                    ps.Streams.ClearStreams();
                    ps.AddScript("$PWD.Path");
                    var pResult = ps.Invoke();
                    if (pResult != null && pResult.Count > 0 && pResult[0] != null) {
                        pText = $"PS {pResult[0]}> ";
                    }
                } catch {
                    pText = "PS> ";
                }
                pText = pText.Replace("\r", "").Replace("\n", "");
                _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[32;1m{pText}\x1b[0m"));
                string command = ReadLineFromRawUI();

                if (string.IsNullOrWhiteSpace(command)) continue;

                ps.Commands.Clear();
                ps.Streams.ClearStreams(); // CRITICAL FIX: Prevent infinite error loops
                ps.AddScript(command);
                ps.AddCommand("Out-Default"); 
                ps.Invoke();

                if (ps.HadErrors)
                {
                    foreach (var error in ps.Streams.Error)
                    {
                        _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[31m{error}\x1b[0m\r\n"));
                    }
                }
            }
            catch (Exception ex)
            {
                _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes($"\x1b[31mFatal Exec Error: {ex.Message}\x1b[0m\r\n"));
            }
        }
    }

    private string ReadLineFromRawUI()
    {
        var rawUi = (AndroidTerminalRawUserInterface)_host.UI.RawUI;
        var builder = new StringBuilder();

        while (true)
        {
            var keyInfo = rawUi.ReadKey(ReadKeyOptions.IncludeKeyDown);
            
                        if (keyInfo.VirtualKeyCode == (int)ConsoleKey.Enter || keyInfo.Character == '\r' || keyInfo.Character == '\n')
            {
                _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes("\r\n"));
                return builder.ToString();
            }
            else if (keyInfo.VirtualKeyCode == (int)ConsoleKey.Backspace || keyInfo.Character == '\b')
            {
                if (builder.Length > 0)
                {
                    builder.Length--;
                    _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes("\b \b"));
                }
            }
            else if (keyInfo.Character != '\0')
            {
                builder.Append(keyInfo.Character);
                _mainActivity.FeedTerminal(Encoding.UTF8.GetBytes(keyInfo.Character.ToString()));
            }
        }
    }
}


