import React, { useEffect, useRef } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { executeCommand } from '../lib/pwshBridge';
import { Tab } from '../store';

export default function TerminalEmulator({ tab }: { tab?: Tab }) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const termInstance = useRef<Terminal | null>(null);
  const currentLine = useRef('');

  useEffect(() => {
    if (!terminalRef.current) return;

    const term = new Terminal({
      cursorBlink: true,
      fontFamily: '"Cascadia Code", "Consolas", monospace',
      fontSize: 14,
      theme: { background: '#012456', foreground: '#eeedf0' },
    });
    
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(terminalRef.current);
    
    setTimeout(() => { try { fit.fit(); } catch {} }, 50);
    termInstance.current = term;

    term.writeln('PowerShell 7.6.1 Engine (Native Android Sandbox)');
    term.writeln('Type "help" to see available commands.');
    term.writeln('');
    term.write('PS > ');

    term.onData((data) => {
      const code = data.charCodeAt(0);
      if (code === 13) { // Enter
        term.write('\r\n');
        executeCommand(currentLine.current);
        currentLine.current = '';
      } else if (code === 127) { // Backspace
        if (currentLine.current.length > 0) {
          term.write('\b \b');
          currentLine.current = currentLine.current.slice(0, -1);
        }
      } else {
        currentLine.current += data;
        term.write(data);
      }
    });

    const resizeObserver = new ResizeObserver(() => requestAnimationFrame(() => fit.fit()));
    resizeObserver.observe(terminalRef.current);

    (window as any).receivePwshOutput = (output: string) => {
       term.write(output.replace(/\n/g, '\r\n'));
       term.write('PS > ');
    };

    return () => {
      resizeObserver.disconnect();
      term.dispose();
    };
  }, []);

  return (
    <div className="absolute inset-0 bg-[#012456] flex flex-col p-2">
      <div ref={terminalRef} className="flex-1 w-full h-full overflow-hidden" />
    </div>
  );
}
