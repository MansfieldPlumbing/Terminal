import React, { useEffect, useRef } from 'react';
import { makeStyles } from '@fluentui/react-components';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { Tab } from '../System.Store';
import { sendRawInput } from '../System.PowerShellBridge';

const PS_BLUE = '#012456';

const useStyles = makeStyles({
  root: {
    position: 'absolute',
    inset: 0,
    display: 'flex',
    flexDirection: 'column',
    padding: '8px',
    backgroundColor: PS_BLUE,
  },
  termDiv: {
    flex: 1,
    width: '100%',
    height: '100%',
    overflow: 'hidden',
  },
});

export default function TerminalXterm({ tab }: { tab: Tab }) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const styles = useStyles();

  useEffect(() => {
    if (!terminalRef.current) return;

    const term = new Terminal({
      cursorBlink: true,
      fontFamily: '"Cascadia Code", "Consolas", monospace',
      fontSize: 14,
      scrollback: 5000,
      theme: {
        background: PS_BLUE,
        foreground: '#ffffff',
        cursor: '#ffffff',
        cursorAccent: PS_BLUE,
        selectionBackground: 'rgba(255,255,255,0.25)',
      },
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

    term.onData((data) => sendRawInput(data));

    const blockWheel = (e: WheelEvent) => {
      e.preventDefault();
      e.stopPropagation();
    };
    terminalRef.current.addEventListener('wheel', blockWheel, { passive: false });

    const onTouchStart = () => term.focus();
    terminalRef.current.addEventListener('touchstart', onTouchStart, { passive: true });

    // Pinch-to-zoom: two-finger spread/pinch adjusts xterm fontSize
    const pinchPointers = new Map<number, { x: number; y: number }>();
    const onPointerDown = (e: PointerEvent) => {
      pinchPointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    };
    const onPointerUp = (e: PointerEvent) => {
      pinchPointers.delete(e.pointerId);
    };
    const onPointerMove = (e: PointerEvent) => {
      if (pinchPointers.size !== 2) { pinchPointers.set(e.pointerId, { x: e.clientX, y: e.clientY }); return; }
      const pts = [...pinchPointers.values()];
      const prevDist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      pinchPointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      const updated = [...pinchPointers.values()];
      const newDist = Math.hypot(updated[0].x - updated[1].x, updated[0].y - updated[1].y);
      const delta = newDist - prevDist;
      if (Math.abs(delta) > 2) {
        const current = term.options.fontSize ?? 14;
        term.options.fontSize = Math.max(8, Math.min(32, current + (delta > 0 ? 1 : -1)));
        try { fit.fit(); } catch {}
      }
    };
    terminalRef.current.addEventListener('pointerdown', onPointerDown);
    terminalRef.current.addEventListener('pointerup', onPointerUp);
    terminalRef.current.addEventListener('pointercancel', onPointerUp);
    terminalRef.current.addEventListener('pointermove', onPointerMove);

    let fitTimer: number | undefined;
    const debouncedFit = () => {
      clearTimeout(fitTimer);
      fitTimer = window.setTimeout(() => {
        try {
          if (terminalRef.current && terminalRef.current.offsetWidth > 0) fit.fit();
        } catch {}
      }, 120);
    };
    const ro = new ResizeObserver(debouncedFit);
    ro.observe(terminalRef.current);

    return () => {
      clearTimeout(fitTimer);
      ro.disconnect();
      if (terminalRef.current) {
        terminalRef.current.removeEventListener('wheel', blockWheel);
        terminalRef.current.removeEventListener('touchstart', onTouchStart);
        terminalRef.current.removeEventListener('pointerdown', onPointerDown);
        terminalRef.current.removeEventListener('pointerup', onPointerUp);
        terminalRef.current.removeEventListener('pointercancel', onPointerUp);
        terminalRef.current.removeEventListener('pointermove', onPointerMove);
      }
      term.dispose();
      (window as any).__dispatchPwshOutput = originalDispatch;
    };
  }, []);

  return (
    <div className={styles.root}>
      <div ref={terminalRef} className={styles.termDiv} />
    </div>
  );
}
