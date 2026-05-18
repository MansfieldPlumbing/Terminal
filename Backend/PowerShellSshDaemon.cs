using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Microsoft.DevTunnels.Ssh;
using Microsoft.DevTunnels.Ssh.Algorithms;
using Microsoft.DevTunnels.Ssh.Events;
using Microsoft.DevTunnels.Ssh.Messages;

namespace TerminalApp;

public class PowerShellSshDaemon : IDisposable
{
    private readonly MainActivity _activity;
    private readonly int _port;
    private readonly CancellationTokenSource _cts = new();
    private TcpListener? _listener;

    public PowerShellSshDaemon(MainActivity activity, int port = 2222)
    {
        _activity = activity;
        _port = port;
    }

    public async Task StartAsync()
    {
        try
        {
            var config = new SshSessionConfiguration();
            config.AddHostKey(GenerateEphemeralKey());

            _listener = new TcpListener(IPAddress.Any, _port);
            _listener.Start();

            _activity.FeedTerminal(Encoding.UTF8.GetBytes(
                $"\x1b[36m[SSH] Listening on :{_port}\x1b[0m\r\n"));

            while (!_cts.Token.IsCancellationRequested)
            {
                var tcp = await _listener.AcceptTcpClientAsync(_cts.Token);
                _ = Task.Run(() => HandleClientAsync(tcp, config), _cts.Token);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _activity.FeedTerminal(Encoding.UTF8.GetBytes(
                $"\x1b[31m[SSH] Failed to start: {ex.Message}\x1b[0m\r\n"));
        }
    }

    private async Task HandleClientAsync(TcpClient tcp, SshSessionConfiguration config)
    {
        try
        {
            using var session = new SshServerSession(config);
            var stream = tcp.GetStream();

            // Simple password authentication — change credentials as needed
            session.Authenticating += (_, e) =>
            {
                if (e.AuthenticationType == SshAuthenticationType.ClientPassword &&
                    e.Password == "terminal")
                {
                    e.AuthenticationResult = SshAuthenticationResult.Authenticated;
                }
            };

            session.ChannelOpening += (_, e) =>
            {
                if (e.Channel is SshStream channel)
                {
                    _ = Task.Run(() => RunPowerShellSessionAsync(channel));
                }
            };

            _activity.FeedTerminal(Encoding.UTF8.GetBytes(
                $"\x1b[36m[SSH] Client connected from {((IPEndPoint?)tcp.Client.RemoteEndPoint)?.Address}\x1b[0m\r\n"));

            await session.ConnectAsync(stream, _cts.Token);
        }
        catch { }
        finally
        {
            tcp.Dispose();
        }
    }

    private async Task RunPowerShellSessionAsync(SshStream channel)
    {
        using var rs = RunspaceFactory.CreateRunspace();
        rs.Open();

        var reader = new StreamReader(channel);
        var writer = new StreamWriter(channel) { AutoFlush = true };

        await writer.WriteAsync("Windows PowerShell\r\nAndroid Terminal SSH\r\n\r\n");

        while (!channel.IsClosed)
        {
            await writer.WriteAsync("PS> ");
            var line = await reader.ReadLineAsync();
            if (line == null) break;

            line = line.Trim();
            if (string.IsNullOrEmpty(line)) continue;
            if (line.Equals("exit", StringComparison.OrdinalIgnoreCase)) break;

            try
            {
                using var ps = PowerShell.Create();
                ps.Runspace = rs;
                ps.AddScript(line).AddCommand("Out-String");

                var results = ps.Invoke<string>();
                foreach (var r in results)
                    await writer.WriteAsync(r.Replace("\n", "\r\n"));

                if (ps.HadErrors)
                    foreach (var err in ps.Streams.Error)
                        await writer.WriteAsync($"\x1b[31m{err}\x1b[0m\r\n");
            }
            catch (Exception ex)
            {
                await writer.WriteAsync($"\x1b[31mError: {ex.Message}\x1b[0m\r\n");
            }
        }

        channel.Close();
    }

    private static SshPrivateKey GenerateEphemeralKey()
    {
        return SshAlgorithms.PublicKey.RsaWithSha256.GenerateKeyPair();
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener?.Stop();
        _cts.Dispose();
    }
}
