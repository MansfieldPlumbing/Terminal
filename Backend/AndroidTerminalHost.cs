using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Concurrent;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Text;

namespace TerminalApp;

public class AndroidTerminalHost : PSHost
{
    private readonly MainActivity _main;
    private readonly AndroidTerminalUserInterface _ui;

    public AndroidTerminalHost(MainActivity main) {
        _main = main;
        _ui = new AndroidTerminalUserInterface(main);
    }

    public override PSHostUserInterface UI => _ui;
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "AndroidDirectPortHost";
    public override Version Version => new Version(1, 0, 0);
    public override CultureInfo CurrentCulture => CultureInfo.CurrentCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.CurrentUICulture;

    public override void EnterNestedPrompt() {}
    public override void ExitNestedPrompt() {}
    public override void NotifyBeginApplication() {}
    public override void NotifyEndApplication() {}
    public override void SetShouldExit(int exitCode) {}
}

public class AndroidTerminalUserInterface : PSHostUserInterface {
    private readonly MainActivity _main;
    private readonly AndroidTerminalRawUserInterface _rawUi;

    public AndroidTerminalUserInterface(MainActivity m) { 
        _main = m; 
        _rawUi = new AndroidTerminalRawUserInterface();
    }

    public override PSHostRawUserInterface RawUI => _rawUi;

    public override void Write(string value) {
        if (!string.IsNullOrEmpty(value)) {
            _main.FeedTerminal(Encoding.UTF8.GetBytes(value));
        }
    }

    // Newly required abstracts
    public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) => Write(value);

    public override void WriteLine(string value) => Write(value + "\r\n");
    
    public override void WriteErrorLine(string value) => WriteLine("\x1b[31m" + value + "\x1b[0m");
    public override void WriteDebugLine(string message) => WriteLine("\x1b[35mDEBUG: " + message + "\x1b[0m");
    public override void WriteProgress(long sourceId, ProgressRecord record) {}
    public override void WriteVerboseLine(string message) => WriteLine("\x1b[36mVERBOSE: " + message + "\x1b[0m");
    public override void WriteWarningLine(string message) => WriteLine("\x1b[33mWARNING: " + message + "\x1b[0m");

    public override string ReadLine() => "";
    public override System.Security.SecureString ReadLineAsSecureString() => new System.Security.SecureString();

    // Newly required prompt abstracts (No-ops for now, but C# requires them)
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => new Dictionary<string, PSObject>();
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) => defaultChoice;
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => null!;
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) => null!;
}

public class AndroidTerminalRawUserInterface : PSHostRawUserInterface {
    public BlockingCollection<KeyInfo> InputQueue { get; } = new BlockingCollection<KeyInfo>();

    public override ConsoleColor BackgroundColor { get => ConsoleColor.Black; set {} }
    public override ConsoleColor ForegroundColor { get => ConsoleColor.White; set {} }
    
    public override Coordinates CursorPosition { get => new Coordinates(0,0); set {} }
    public override Coordinates WindowPosition { get => new Coordinates(0,0); set {} }
    public override int CursorSize { get => 25; set {} }
    
    // PS 7+ enforce Size instead of Coordinates for Windows boundaries
    public override Size WindowSize { get => new Size(120, 40); set {} }
    public override Size MaxWindowSize => new Size(120, 40);
    public override Size MaxPhysicalWindowSize => new Size(120, 40);
    public override string WindowTitle { get => "Android Terminal"; set {} }
    
    public override bool KeyAvailable => InputQueue.Count > 0;
    public override Size BufferSize { get => new Size(120, 9000); set {} }

    public override KeyInfo ReadKey(ReadKeyOptions options) {
        return InputQueue.Take();
    }

    public override void FlushInputBuffer() {
        while (InputQueue.TryTake(out _)) {}
    }

    public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) {}
    public override void SetBufferContents(Rectangle rectangle, BufferCell fill) {}
    public override BufferCell[,] GetBufferContents(Rectangle rectangle) => new BufferCell[0,0];
    public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) {}
}

