import React, { useRef, useState, useCallback, useEffect } from 'react';
import { makeStyles, mergeClasses } from '@fluentui/react-components';
import { useAppStore } from '../System.Store';
import { sendRawInput } from '../System.PowerShellBridge';

const useStyles = makeStyles({
  snapZoneLeft: {
    position: 'fixed',
    top: 0,
    bottom: 0,
    left: 0,
    width: '32px',
    backgroundColor: 'rgba(59,130,246,0.2)',
    transition: 'opacity 200ms',
    pointerEvents: 'none',
    zIndex: 40,
    borderRight: '1px solid rgba(59,130,246,0.3)',
  },
  snapZoneRight: {
    position: 'fixed',
    top: 0,
    bottom: 0,
    right: 0,
    width: '32px',
    backgroundColor: 'rgba(59,130,246,0.2)',
    transition: 'opacity 200ms',
    pointerEvents: 'none',
    zIndex: 40,
    borderLeft: '1px solid rgba(59,130,246,0.3)',
  },
  snapZoneVisible: { opacity: 1 },
  snapZoneHidden: { opacity: 0 },
  base: {
    position: 'fixed',
    zIndex: 50,
    borderRadius: '50%',
    display: 'flex',
    touchAction: 'none',
    transition: 'all 200ms ease-out',
    userSelect: 'none',
  },
  hitArea: {
    position: 'absolute',
    inset: 0,
    borderRadius: '50%',
  },
  hitAreaActive: { pointerEvents: 'auto' },
  hitAreaNestled: { pointerEvents: 'none' },
  center: {
    position: 'absolute',
    inset: 0,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    pointerEvents: 'none',
  },
  nub: {
    width: '56px',
    height: '56px',
    backgroundColor: '#121212',
    borderRadius: '50%',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    boxShadow: 'inset 0 2px 4px rgba(0,0,0,0.3)',
    border: '1px solid rgba(255,255,255,0.1)',
    pointerEvents: 'auto',
  },
  nubGrab: { cursor: 'grab' },
  nubPointer: { cursor: 'pointer' },
  dot: {
    width: '10px',
    height: '10px',
    backgroundColor: '#6366f1',
    borderRadius: '50%',
    boxShadow: '0 0 8px rgba(99,102,241,0.6)',
  },
});

export default function Thumbstick() {
  const styles = useStyles();
  const { setFloatingCommandPaletteOpen, floatingCommandPaletteOpen } = useAppStore();
  const baseRef = useRef<HTMLDivElement>(null);
  const nubRef = useRef<HTMLDivElement>(null);

  const [pos, setPos] = useState({ x: 24, y: 0 });
  const modeRef = useRef<'idle' | 'move' | 'flick'>('idle');
  const startRef = useRef({ x: 0, y: 0 });
  const offsetRef = useRef({ x: 0, y: 0 });
  const lastDragPosRef = useRef({ x: 0, y: 0 });

  const lastArrowTime = useRef(0);
  const [fancyZone, setFancyZone] = useState<'left' | 'right' | null>(null);
  const [nestledState, setNestledState] = useState<'left' | 'right' | null>(null);
  const nestledRef = useRef<'left' | 'right' | null>(null);

  const sendArrowKey = useCallback((direction: 'Up' | 'Down' | 'Left' | 'Right') => {
    const now = performance.now();
    if (now - lastArrowTime.current < 80) return;
    lastArrowTime.current = now;
    const escapeSequences = { Up: '\x1b[A', Down: '\x1b[B', Right: '\x1b[C', Left: '\x1b[D' };
    sendRawInput(escapeSequences[direction]);
  }, []);

  const setNestled = useCallback((val: 'left' | 'right' | null) => {
    nestledRef.current = val;
    setNestledState(val);
  }, []);

  useEffect(() => {
    setPos({ x: window.innerWidth - 110, y: window.innerHeight - 154 });
  }, []);

  const onPointerDown = useCallback((e: React.PointerEvent) => {
    const el = baseRef.current;
    if (!el) return;
    if (nestledRef.current) {
      const wasNestled = nestledRef.current;
      setPos(p => ({ x: wasNestled === 'left' ? 32 : window.innerWidth - 162, y: p.y }));
      setNestled(null);
    }
    el.setPointerCapture(e.pointerId);
    startRef.current = { x: e.clientX, y: e.clientY };
    offsetRef.current = { x: 0, y: 0 };
    lastDragPosRef.current = { x: e.clientX, y: e.clientY };

    if (nubRef.current && nubRef.current.contains(e.target as Node)) {
      modeRef.current = 'flick';
      el.style.transitionProperty = 'background, box-shadow';
    } else {
      modeRef.current = 'move';
      el.style.transitionProperty = 'background, transform, box-shadow';
      el.style.transform = 'scale(1.05)';
      el.style.background = 'rgba(40, 40, 40, 0.5)';
      if (navigator.vibrate) navigator.vibrate(50);
    }
  }, [setNestled]);

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    if (nestledRef.current) return;
    if (modeRef.current === 'move') {
      const dx = e.clientX - lastDragPosRef.current.x;
      const dy = e.clientY - lastDragPosRef.current.y;
      lastDragPosRef.current = { x: e.clientX, y: e.clientY };
      setPos(p => {
        const nx = p.x + dx;
        const ny = p.y + dy;
        const cx = nx + 130 / 2;
        if (cx < 24) setFancyZone('left');
        else if (cx > window.innerWidth - 24) setFancyZone('right');
        else setFancyZone(null);
        return { x: nx, y: ny };
      });
    } else if (modeRef.current === 'flick') {
      const MAX = 40;
      let nx = e.clientX - startRef.current.x;
      let ny = e.clientY - startRef.current.y;
      const dist = Math.sqrt(nx*nx + ny*ny);
      if (dist > MAX) { nx = (nx / dist) * MAX; ny = (ny / dist) * MAX; }
      offsetRef.current = { x: nx, y: ny };
      const absX = Math.abs(nx);
      const absY = Math.abs(ny);
      if (dist > 20) {
        if (absX > absY) sendArrowKey(nx < 0 ? 'Left' : 'Right');
        else sendArrowKey(ny < 0 ? 'Up' : 'Down');
      }
      if (nubRef.current) {
        nubRef.current.style.transform = `translate(${nx}px, ${ny}px)`;
      }
    }
  }, [sendArrowKey]);

  const onPointerUp = useCallback((e: React.PointerEvent) => {
    setFancyZone(null);
    if (nestledRef.current) return;
    const el = baseRef.current;
    if (!el) return;
    if (el.hasPointerCapture(e.pointerId)) el.releasePointerCapture(e.pointerId);

    el.style.background = 'rgba(26, 26, 26, 0.4)';
    el.style.transform = 'scale(1)';

    if (modeRef.current === 'move') {
      el.style.transitionProperty = 'all';
      setFancyZone(null);
      setPos(p => {
        const cx = p.x + 130 / 2;
        let targetY = Math.max(24, Math.min(window.innerHeight - 154, p.y));
        if (cx < 24) { setTimeout(() => setNestled('left'), 0); return { x: -65, y: targetY }; }
        if (cx > window.innerWidth - 24) { setTimeout(() => setNestled('right'), 0); return { x: window.innerWidth - 65, y: targetY }; }
        return { x: Math.max(10, Math.min(window.innerWidth - 140, p.x)), y: targetY };
      });
    } else if (modeRef.current === 'flick' || modeRef.current === 'idle') {
      el.style.transitionProperty = 'all';
      const dist = Math.sqrt(Math.pow(offsetRef.current.x, 2) + Math.pow(offsetRef.current.y, 2));
      if (dist < 10) setFloatingCommandPaletteOpen(!floatingCommandPaletteOpen);
    }

    if (nubRef.current) {
      nubRef.current.style.transition = 'transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1)';
      nubRef.current.style.transform = 'translate(0px, 0px)';
      setTimeout(() => { if (nubRef.current) nubRef.current.style.transition = 'none'; }, 300);
    }
    modeRef.current = 'idle';
  }, [setFloatingCommandPaletteOpen, floatingCommandPaletteOpen, setNestled]);

  const isNestled = nestledState !== null;

  return (
    <>
      <div className={mergeClasses(styles.snapZoneLeft, fancyZone === 'left' ? styles.snapZoneVisible : styles.snapZoneHidden)} />
      <div className={mergeClasses(styles.snapZoneRight, fancyZone === 'right' ? styles.snapZoneVisible : styles.snapZoneHidden)} />

      <div
        ref={baseRef}
        className={styles.base}
        style={{
          width: 130,
          height: 130,
          left: pos.x,
          top: pos.y,
          background: isNestled ? 'transparent' : 'rgba(26, 26, 26, 0.4)',
          backdropFilter: isNestled ? 'none' : 'blur(16px)',
          WebkitBackdropFilter: isNestled ? 'none' : 'blur(16px)',
          border: isNestled ? '1px solid transparent' : '1px solid rgba(255, 255, 255, 0.1)',
          boxShadow: isNestled ? 'none' : '0 8px 32px rgba(0, 0, 0, 0.3)',
          cursor: isNestled ? 'default' : 'grab',
          pointerEvents: isNestled ? 'none' : 'auto',
        }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <div className={mergeClasses(styles.hitArea, isNestled ? styles.hitAreaNestled : styles.hitAreaActive)} />

        <div className={styles.center}>
          <div
            ref={nubRef}
            className={mergeClasses(styles.nub, isNestled ? styles.nubPointer : styles.nubGrab)}
          >
            <div className={styles.dot} />
          </div>
        </div>
      </div>
    </>
  );
}
