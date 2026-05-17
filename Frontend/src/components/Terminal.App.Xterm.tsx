import React, { useEffect, useRef } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { Tab } from '../System.Store';

export default function TerminalXterm({ tab }: { tab: Tab }) {
  const terminalRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!terminalRef.current) return;

    const term = new Terminal({
      cursorBlink: true,
      fontFamily: '"Cascadia Code", "Consolas", monospace',
      fontSize: 14,
      scrollback: 5000,
      theme: { background: '#00000000', foreground: '#eeedf0' },
    });
    
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(terminalRef.current);
    
    setTimeout(() => { try { fit.fit(); } catch {} }, 100);

    const buffer = (window as any).__pwshOutputBuffer || [];
    buffer.forEach((b: string) => term.write(b.replace(/\n/g, '\r\n')));

    const originalDispatch = (window as any).__dispatchPwshOutput;
    (window as any).__dispatchPwshOutput = (output: string) => {
        term.write(output.replace(/\n/g, '\r\n'));
        if (originalDispatch) originalDispatch(output);
    };

    term.onData((data) => {
        const bridge = (window as any).AndroidBridge;
        if (!bridge) return;
        
        if (data === '\r') bridge.sendInput(JSON.stringify({ type: 'input', key: 'Enter' }));
        else if (data === '\x7F' || data === '\b') bridge.sendInput(JSON.stringify({ type: 'input', key: 'Backspace' }));
        else {
            for (let i = 0; i < data.length; i++) {
                bridge.sendInput(JSON.stringify({ type: 'input', key: data[i] }));
            }
        }
    });

        let fitTimer: number | undefined;     const debouncedFit = () => {       clearTimeout(fitTimer);       fitTimer = window.setTimeout(() => {         try { if (terminalRef.current && terminalRef.current.offsetWidth > 0) fit.fit(); } catch {}       }, 120);     };     const resizeObserver = new ResizeObserver(debouncedFit);     resizeObserver.observe(terminalRef.current);
    resizeObserver.observe(terminalRef.current);

    return () => {
      clearTimeout(fitTimer);
      resizeObserver.disconnect();
      term.dispose();
      (window as any).__dispatchPwshOutput = originalDispatch;
    };
  }, []);

  return (
    <div className="absolute inset-0 bg-[#0A0A0A] flex flex-col p-2">
      <div ref={terminalRef} className="flex-1 w-full h-full overflow-hidden" />
    </div>
  );
}