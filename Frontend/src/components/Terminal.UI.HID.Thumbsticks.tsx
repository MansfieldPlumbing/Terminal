import React, { useRef, useState, useCallback, useEffect } from 'react';
import { cn } from '../System.Utils';
import { useAppStore } from '../System.Store';

export default function Thumbstick() {
  const { setFloatingCommandPaletteOpen, floatingCommandPaletteOpen } = useAppStore();
  const baseRef = useRef<HTMLDivElement>(null);
  const nubRef = useRef<HTMLDivElement>(null);
  
  const [pos, setPos] = useState({ x: 24, y: 0 });
  const modeRef = useRef<'idle' | 'move' | 'flick'>('idle');
  const startRef = useRef({ x: 0, y: 0 });
  const offsetRef = useRef({ x: 0, y: 0 });
  const lastDragPosRef = useRef({ x: 0, y: 0 });
  
  // Cooldown to prevent repeating arrows too quickly
  const lastArrowTime = useRef(0);

  const [fancyZone, setFancyZone] = useState<'left' | 'right' | null>(null);
  const [nestledState, setNestledState] = useState<'left' | 'right' | null>(null);
  const nestledRef = useRef<'left' | 'right' | null>(null);

  const sendArrowKey = useCallback((direction: 'Up' | 'Down' | 'Left' | 'Right') => {
    const now = performance.now();
    if (now - lastArrowTime.current < 150) return; // Basic rate limiting
    lastArrowTime.current = now;

    // Standard VT100 ESC sequences for arrow keys
    const escapeSequences = {
      Up: '\x1b[A',
      Down: '\x1b[B',
      Right: '\x1b[C',
      Left: '\x1b[D'
    };

    const seq = escapeSequences[direction];
    
    if (typeof window !== 'undefined' && (window as any).AndroidBridge) {
      (window as any).AndroidBridge.invokeCommand(seq);
    } else if (typeof window !== 'undefined' && (window as any).host?.call) {
      (window as any).host.call('tty.in', btoa(seq));
    } else if ((window as any).writeToTerminal) {
       // Debug local mock echo if no bridge is active (for dev view)
       // This is just to give UI feedback if tested on web without APK
      console.log('Sending arrow key:', direction);
    }
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
      setPos(p => ({
        x: wasNestled === 'left' ? 32 : window.innerWidth - 162,
        y: p.y
      }));
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
      
      if (dist > MAX) {
        nx = (nx / dist) * MAX;
        ny = (ny / dist) * MAX;
      }
      offsetRef.current = { x: nx, y: ny };
      
      // Determine direction of swipe/drag from center
      const absX = Math.abs(nx);
      const absY = Math.abs(ny);
      if (dist > 20) {
        if (absX > absY) {
            sendArrowKey(nx < 0 ? 'Left' : 'Right');
        } else {
            sendArrowKey(ny < 0 ? 'Up' : 'Down');
        }
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
    if (el.hasPointerCapture(e.pointerId)) {
      el.releasePointerCapture(e.pointerId);
    }
    
    el.style.background = 'rgba(26, 26, 26, 0.4)';
    el.style.transform = 'scale(1)';

    if (modeRef.current === 'move') {
      el.style.transitionProperty = 'all';
      setFancyZone(null);
      setPos(p => {
        const cx = p.x + 130 / 2;
        let targetY = p.y;
        if (targetY < 24) targetY = 24;
        if (targetY > window.innerHeight - 154) targetY = window.innerHeight - 154;

        if (cx < 24) {
          setTimeout(() => setNestled('left'), 0);
          return { x: -65, y: targetY };
        } else if (cx > window.innerWidth - 24) {
          setTimeout(() => setNestled('right'), 0);
          return { x: window.innerWidth - 65, y: targetY };
        }

        let targetX = p.x;
        if (targetX < 10) targetX = 10;
        if (targetX > window.innerWidth - 140) targetX = window.innerWidth - 140;

        return { x: targetX, y: targetY };
      });
    } else if (modeRef.current === 'flick' || modeRef.current === 'idle') {
      el.style.transitionProperty = 'all';
      
      const dist = Math.sqrt(Math.pow(offsetRef.current.x, 2) + Math.pow(offsetRef.current.y, 2));
      
      // If no significant movement, treat as tap to open command palette
      if (dist < 10) {
        setFloatingCommandPaletteOpen(!floatingCommandPaletteOpen);
      }
    }
    
    if (nubRef.current) {
      nubRef.current.style.transition = 'transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1)';
      nubRef.current.style.transform = `translate(0px, 0px)`;
      setTimeout(() => { if (nubRef.current) nubRef.current.style.transition = 'none'; }, 300);
    }
    
    modeRef.current = 'idle';
  }, [setFloatingCommandPaletteOpen, floatingCommandPaletteOpen, setNestled]);

  const isNestled = nestledState !== null;

  return (
    <>
      <div 
        className={cn("fixed top-0 bottom-0 left-0 w-8 bg-blue-500/20 transition-opacity pointer-events-none z-40 border-r border-blue-500/30", 
          fancyZone === 'left' ? "opacity-100" : "opacity-0")} 
      />
      <div 
        className={cn("fixed top-0 bottom-0 right-0 w-8 bg-blue-500/20 transition-opacity pointer-events-none z-40 border-l border-blue-500/30", 
          fancyZone === 'right' ? "opacity-100" : "opacity-0")} 
      />

      <div 
        ref={baseRef}
        className="fixed z-50 rounded-full flex touch-none transition-all duration-200 ease-out select-none"
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
          pointerEvents: isNestled ? 'none' : 'auto'
        }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        {/* Continuous hit area to ensure the rim registers pointers robustly */}
        <div className={cn("absolute inset-0 rounded-full", isNestled ? "pointer-events-none" : "pointer-events-auto")} />

        <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
          <div 
            ref={nubRef}
            className={cn("w-14 h-14 bg-[#121212] rounded-full flex items-center justify-center shadow-inner border border-white/10 pointer-events-auto active:cursor-grabbing",
              isNestled ? "cursor-pointer" : "cursor-grab")}
          >
            <div className="w-2.5 h-2.5 bg-indigo-500 rounded-full shadow-[0_0_8px_rgba(99,102,241,0.6)]" />
          </div>
        </div>
      </div>
    </>
  );
}
