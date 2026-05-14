import { useState, useRef, useEffect, useCallback } from 'react';
import { 
  Terminal, Code2, Play, AppWindow,
  MonitorPlay, Cpu, Network, Video, Plus, Lock, Server, TerminalSquare,
  FileCode2, CheckSquare, Settings2, ChevronRight, Minus, Square, X, Menu
} from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

import { executeCommand, subscribeToOutput, minimizeAppFromBridge } from './lib/pwshBridge';

function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

function Thumbstick({ view, setView }: { view: string, setView: (v: any) => void }) {
  const baseRef = useRef<HTMLDivElement>(null);
  const nubRef = useRef<HTMLDivElement>(null);
  
  const [pos, setPos] = useState({ x: 24, y: 0 });
  const modeRef = useRef<'idle' | 'move' | 'flick'>('idle');
  const startRef = useRef({ x: 0, y: 0 });
  const offsetRef = useRef({ x: 0, y: 0 });
  const lastDragPosRef = useRef({ x: 0, y: 0 });

  const [fancyZone, setFancyZone] = useState<'left' | 'right' | null>(null);
  const [nestledState, setNestledState] = useState<'left' | 'right' | null>(null);
  const nestledRef = useRef<'left' | 'right' | null>(null);

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
  }, []);

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
      if (nubRef.current) {
        nubRef.current.style.transform = `translate(${nx}px, ${ny}px)`;
      }
    }
  }, []);

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
          // Schedule setNestled so it's not inside setPos updater
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
    } else if (modeRef.current === 'flick') {
      el.style.transitionProperty = 'all';
      const absX = Math.abs(offsetRef.current.x);
      const absY = Math.abs(offsetRef.current.y);
      
      if (absX > 20 || absY > 20) {
        if (absX > absY) {
          if (offsetRef.current.x < 0) setView(view === 'right' ? 'center' : 'left');
          else setView(view === 'left' ? 'center' : 'right');
        } else {
          if (offsetRef.current.y < 0) setView(view === 'bottom' ? 'center' : 'top');
          else setView(view === 'top' ? 'center' : 'bottom');
        }
      } else {
        setView('center');
      }
    } else if (modeRef.current === 'idle') {
       el.style.transitionProperty = 'all';
       setView('center');
    }
    
    if (nubRef.current) {
      nubRef.current.style.transition = 'transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1)';
      nubRef.current.style.transform = `translate(0px, 0px)`;
      setTimeout(() => { if (nubRef.current) nubRef.current.style.transition = 'none'; }, 300);
    }
    
    modeRef.current = 'idle';
  }, [view, setView, setNestled]);

  const isNestled = nestledState !== null;

  return (
    <>
      {/* Fancy Zones */}
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

function HamburgerStick({ view, setView, isMenuOpen, setIsMenuOpen }: { view: string, setView: (v: any) => void, isMenuOpen: boolean, setIsMenuOpen: (v: boolean) => void }) {
  const baseRef = useRef<HTMLDivElement>(null);
  const nubRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  
  const [pos, setPos] = useState({ x: 24, y: 0 });
  const modeRef = useRef<'idle' | 'move'>('idle');
  const startRef = useRef({ x: 0, y: 0 });
  const lastDragPosRef = useRef({ x: 0, y: 0 });

  const [fancyZone, setFancyZone] = useState<'left' | 'right' | null>(null);
  const [nestledState, setNestledState] = useState<'left' | 'right' | null>(null);
  const nestledRef = useRef<'left' | 'right' | null>(null);

  const setNestled = useCallback((val: 'left' | 'right' | null) => {
    nestledRef.current = val;
    setNestledState(val);
  }, []);

  useEffect(() => {
    setPos({ x: window.innerWidth - 150, y: window.innerHeight - 150 });
  }, []);

  useEffect(() => {
    if (!isMenuOpen) return;
    const handleClickOutside = (e: PointerEvent) => {
      if (
        menuRef.current && 
        !menuRef.current.contains(e.target as Node) &&
        baseRef.current &&
        !baseRef.current.contains(e.target as Node)
      ) {
        setIsMenuOpen(false);
      }
    };
    document.addEventListener('pointerdown', handleClickOutside);
    return () => document.removeEventListener('pointerdown', handleClickOutside);
  }, [isMenuOpen, setIsMenuOpen]);

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
    lastDragPosRef.current = { x: e.clientX, y: e.clientY };
    modeRef.current = 'idle';
    
    el.style.transitionProperty = 'background, transform, box-shadow';
    el.style.transform = 'scale(1.05)';
    el.style.background = 'rgba(40, 40, 40, 0.5)';
    if (navigator.vibrate) navigator.vibrate(50);
  }, [setNestled]);

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    if (nestledRef.current) return;

    const dx = e.clientX - lastDragPosRef.current.x;
    const dy = e.clientY - lastDragPosRef.current.y;
    const distFromStart = Math.sqrt(Math.pow(e.clientX - startRef.current.x, 2) + Math.pow(e.clientY - startRef.current.y, 2));

    if (distFromStart > 5 && modeRef.current === 'idle') {
      modeRef.current = 'move';
    }

    if (modeRef.current === 'move') {
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
    }
  }, []);

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
    } else if (modeRef.current === 'idle') {
       el.style.transitionProperty = 'all';
       setIsMenuOpen(!isMenuOpen);
    }
    
    modeRef.current = 'idle';
  }, [isMenuOpen, setIsMenuOpen, setNestled]);

  const isNestled = nestledState !== null;

  return (
    <div className="fixed inset-0 pointer-events-none z-50">
      {/* Fancy Zones */}
      <div 
        className={cn("fixed top-0 bottom-0 left-0 w-8 bg-blue-500/20 transition-opacity pointer-events-none z-40 border-r border-blue-500/30", 
          fancyZone === 'left' ? "opacity-100" : "opacity-0")} 
      />
      <div 
        className={cn("fixed top-0 bottom-0 right-0 w-8 bg-blue-500/20 transition-opacity pointer-events-none z-40 border-l border-blue-500/30", 
          fancyZone === 'right' ? "opacity-100" : "opacity-0")} 
      />

      {/* Menu popup */}
      <AnimatePresence>
        {isMenuOpen && (
          <motion.div
            ref={menuRef}
            initial={{ opacity: 0, scale: 0.9 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.9 }}
            transition={{ type: 'spring', stiffness: 300, damping: 25 }}
            className={cn(
              "fixed w-48 bg-black/40 backdrop-blur-xl border border-white/10 rounded-xl shadow-2xl overflow-hidden flex flex-col font-sans z-50 pointer-events-auto",
              pos.x > window.innerWidth / 2 ? (pos.y > window.innerHeight / 2 ? "origin-bottom-right" : "origin-top-right") : (pos.y > window.innerHeight / 2 ? "origin-bottom-left" : "origin-top-left")
            )}
            style={{ 
              top: pos.y > window.innerHeight / 2 ? pos.y - 250 : pos.y + 140, 
              left: pos.x <= window.innerWidth / 2 ? Math.max(10, pos.x) : 'auto',
              right: pos.x > window.innerWidth / 2 ? Math.max(10, window.innerWidth - pos.x - 130) : 'auto',
            }}
          >
            <button 
              onClick={() => { setView('center'); setIsMenuOpen(false); }}
              className={`px-4 py-3 text-left hover:bg-white/10 transition-colors ${view === 'center' ? 'text-blue-400 font-medium' : 'text-gray-200'}`}
            >Terminal</button>
            <div className="h-[1px] bg-white/10 mx-2" />
            <button 
              onClick={() => { setView('top'); setIsMenuOpen(false); }}
              className={`px-4 py-3 text-left hover:bg-white/10 transition-colors ${view === 'top' ? 'text-blue-400 font-medium' : 'text-gray-200'}`}
            >Profiles</button>
            <button 
              onClick={() => { setView('bottom'); setIsMenuOpen(false); }}
              className={`px-4 py-3 text-left hover:bg-white/10 transition-colors ${view === 'bottom' ? 'text-blue-400 font-medium' : 'text-gray-200'}`}
            >Settings</button>
            <button 
              onClick={() => { setView('left'); setIsMenuOpen(false); }}
              className={`px-4 py-3 text-left hover:bg-white/10 transition-colors ${view === 'left' ? 'text-blue-400 font-medium' : 'text-gray-200'}`}
            >Editor & Workspace</button>
            <button 
              onClick={() => { setView('right'); setIsMenuOpen(false); }}
              className={`px-4 py-3 text-left hover:bg-white/10 transition-colors ${view === 'right' ? 'text-blue-400 font-medium' : 'text-gray-200'}`}
            >Applets</button>
          </motion.div>
        )}
      </AnimatePresence>

      <div 
        ref={baseRef}
        className="fixed z-50 rounded-[2.5rem] flex touch-none transition-all duration-200 ease-out select-none"
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
        <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
          <div 
            ref={nubRef}
            className={cn("w-14 h-14 bg-black/40 rounded-2xl flex items-center justify-center shadow-inner border border-white/10 pointer-events-auto text-white/90 transition-colors",
              isNestled ? "cursor-pointer" : "cursor-grab", isMenuOpen && !isNestled ? "bg-white/10 text-white" : "")}
          >
            <Menu size={24} />
          </div>
        </div>
      </div>
    </div>
  );
}

const TERMINALS = [
  { id: 'pwsh-7.4', name: 'PowerShell 7.4 (Local)', type: 'pwsh', status: 'Active' },
  { id: 'pwsh-psrp', name: 'PSRP Node (Remote)', type: 'network', status: 'Idle' },
  { id: 'cmd', name: 'Command Prompt', type: 'cmd', status: 'Idle' },
  { id: 'wsl', name: 'Ubuntu (WSL)', type: 'linux', status: 'Stopped' },
  { id: 'azure', name: 'Azure Cloud Shell', type: 'cloud', status: 'Disconnected' }
];

const APPLETS = [
  { id: 'a1', name: 'SystemMonitor.ps1', type: 'ps1', category: 'monitoring' },
  { id: 'a2', name: 'NetworkScanner.ps1', type: 'ps1', category: 'network' },
  { id: 'a3', name: 'DockerManager.ps1', type: 'ps1', category: 'tools' },
  { id: 'a4', name: 'VideoNode.html', type: 'html', category: 'media' },
  { id: 'a5', name: 'HexViewer.html', type: 'html', category: 'tools' },
  { id: 'a6', name: 'GitHelper.ps1', type: 'ps1', category: 'tools' }
];

export default function App() {
  const [view, setView] = useState<'center'|'top'|'bottom'|'left'|'right'>('center');
  const [navMode, setNavMode] = useState<'joystick'|'hamburger'>('joystick');
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  
  // Editor State
  const [editorText, setEditorText] = useState(`function Get-NetworkStats {
    [CmdletBinding()]
    param (
        [string]$InterfaceAlias = '*'
    )

    Get-NetAdapterStatistics -Name $InterfaceAlias | 
    Select-Object Name, ReceivedBytes, SentBytes, ReceivedDiscardedPackets
}

# Monitor loop
while ($true) {
    Clear-Host
    Get-NetworkStats | Format-Table -AutoSize
    Start-Sleep -Seconds 2
}`);

  const [leftView, setLeftView] = useState<'explorer' | 'editor'>('explorer');
  const [selectedFile, setSelectedFile] = useState<string | null>(null);
  
  // Applet Viewer State for Center Panel
  const [activeApplet, setActiveApplet] = useState<string | null>(null);

  // Terminal UI State
  const [terminalHistory, setTerminalHistory] = useState<{type: 'input' | 'output', text: string}[]>([]);
  const [inputValue, setInputValue] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const terminalEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Keep terminal scrolled to bottom without scrolling outer containers
    const parent = terminalEndRef.current?.parentElement;
    if (parent) {
      parent.scrollTop = parent.scrollHeight;
    }
  }, [terminalHistory]);

  useEffect(() => {
    // Subscribe to async output from Android backend
    const unsubscribe = subscribeToOutput((text) => {
      setTerminalHistory(prev => [...prev, { type: 'output', text }]);
    });
    // React Handshake! Tell C# we are awake.
    if (typeof window !== 'undefined' && window.AndroidBridge && window.AndroidBridge.notifyReady) {
      window.AndroidBridge.notifyReady();
    }
    return () => unsubscribe();
  }, []);

  const handleTerminalInput = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      const cmd = inputValue.trim();
      if (!cmd) return;
      
      if (cmd.toLowerCase() === 'clear' || cmd.toLowerCase() === 'cls') {
         setTerminalHistory([]);
         setInputValue('');
         return;
      }
      
      setTerminalHistory(prev => [...prev, { type: 'input', text: cmd }]);
      executeCommand(cmd);
      setInputValue('');
    }
  };

  useEffect(() => {
    const handleMessage = (e: MessageEvent) => {
      if (e.data === 'close-applet') {
        setActiveApplet(null);
      }
    };
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, []);

  // File structure mock
  const WORKSPACE = {
    applets: [
      { name: 'dev-explorer.html', path: '/applets/dev-explorer.html' },
      { name: 'media-stitcher.html', path: '/applets/media-stitcher.html' },
      { name: 'text.html', path: '/applets/text.html' }
    ],
    scripts: [
      { name: 'txt.ps1', path: '/scripts/txt.ps1' }
    ],
    widgets: []
  };

  const openApplet = (path: string) => {
    setActiveApplet(path);
    setView('center');
  };

  const openScript = async (path: string) => {
    try {
      const res = await fetch(path);
      const text = await res.text();
      setEditorText(text);
      setSelectedFile(path);
      setLeftView('editor');
    } catch (e) {
      console.error(e);
    }
  };

  const lines = editorText.split('\n').length;
  const chars = editorText.length;

  return (
    <div className="fixed inset-0 w-full h-full bg-[#000] overflow-hidden touch-none select-none font-sans">
      <div className="absolute inset-0 opacity-5 pointer-events-none" 
           style={{ backgroundImage: 'radial-gradient(#fff 1px, transparent 1px)', backgroundSize: '20px 20px' }} />

      <motion.div
        className="absolute inset-0 z-10"
        initial={false}
        animate={view}
        variants={{
          center: { x: '0%', y: '0%' },
          left: { x: '100%', y: '0%' },
          right: { x: '-100%', y: '0%' },
          top: { x: '0%', y: '35%' },
          bottom: { x: '0%', y: '-40%' }
        }}
        transition={{ type: 'tween', ease: 'circOut', duration: navMode === 'hamburger' ? 0 : 0.3 }}
      >
        {/* Top Panel - Workspace Nav */}
        <div 
          className="absolute w-full h-full bg-[#f3f3f3] flex flex-col justify-end pb-8 px-4"
          style={{ top: '-100%', left: 0 }}
        >
          <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-widest mb-4">Terminal Profiles</h2>
          <div className="flex gap-4 overflow-x-auto custom-scrollbar items-center pb-2">
             <button className="flex flex-col items-center justify-center gap-2 w-24 h-24 shrink-0 bg-white hover:bg-gray-50 text-gray-800 rounded-xl font-medium transition-colors border border-gray-200 shadow-sm">
              <Plus className="w-6 h-6 text-blue-600" />
              <span className="text-[10px] uppercase font-semibold tracking-wider">New</span>
            </button>
            <button onClick={() => { setView('left'); setLeftView('explorer'); }} className="flex flex-col items-center justify-center gap-2 w-24 h-24 shrink-0 bg-white hover:bg-gray-50 text-gray-800 rounded-xl transition-colors border border-gray-200 shadow-sm group">
               <TerminalSquare className="w-8 h-8 text-blue-600 opacity-80 group-hover:opacity-100 group-hover:scale-110 transition-all" />
               <span className="text-[10px] uppercase font-semibold tracking-wider">Default</span>
            </button>
          </div>
        </div>

        {/* Bottom Panel - Settings */}
        <div 
          className="absolute w-full h-full bg-[#f3f3f3] flex flex-col pt-8 px-4"
          style={{ top: '100%', left: 0 }}
        >
          <div className="flex justify-between items-center mb-4">
            <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-widest">System Settings</h2>
          </div>
          <div className="flex flex-col gap-4 overflow-y-auto custom-scrollbar pr-2 pb-2 text-sm text-gray-800 font-sans">
             <div className="flex justify-between items-center bg-white p-3 rounded-lg border border-gray-200 shadow-sm">
                <span className="font-medium">Theme Preference</span>
                <div className="flex gap-2">
                   <button className="px-3 py-1 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded">Auto</button>
                   <button className="px-3 py-1 bg-white hover:bg-gray-50 text-gray-700 rounded border border-gray-200">Dark</button>
                   <button className="px-3 py-1 bg-blue-50 text-blue-600 border border-blue-200 rounded font-medium">Light</button>
                </div>
             </div>
             
             <div className="flex justify-between items-center bg-white p-3 rounded-lg border border-gray-200 shadow-sm">
                <span className="font-medium">Terminal Font Size</span>
                <div className="flex gap-2">
                   <button className="px-3 py-1 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded">12px</button>
                   <button className="px-3 py-1 bg-blue-50 text-blue-600 border border-blue-200 rounded font-medium">14px</button>
                   <button className="px-3 py-1 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded">16px</button>
                </div>
             </div>

             <div className="flex justify-between items-center bg-white p-3 rounded-lg border border-gray-200 shadow-sm">
                <span className="font-medium">Navigation Mode</span>
                <div className="flex gap-2">
                   <button 
                     onClick={() => setNavMode('joystick')}
                     className={`px-3 py-1 rounded border font-medium ${navMode === 'joystick' ? 'bg-blue-50 text-blue-600 border-blue-200' : 'bg-white hover:bg-gray-50 text-gray-700 border-gray-200'}`}
                   >
                     Joystick
                   </button>
                   <button 
                     onClick={() => setNavMode('hamburger')}
                     className={`px-3 py-1 rounded border font-medium ${navMode === 'hamburger' ? 'bg-blue-50 text-blue-600 border-blue-200' : 'bg-white hover:bg-gray-50 text-gray-700 border-gray-200'}`}
                   >
                     Hamburger
                   </button>
                </div>
             </div>
          </div>
        </div>

        {/* Left Panel - File Explorer and Editor */}
        <div 
          className="absolute w-full h-full bg-[#f3f3f3] flex flex-col pt-12 pb-6 px-4 overflow-hidden"
          style={{ top: 0, left: '-100%' }}
        >
          <div className="flex justify-between items-center mb-4 shrink-0">
            <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-widest">
               {leftView === 'explorer' ? 'Workspace' : 'Editor'}
            </h2>
            <div className="flex gap-2">
              {leftView === 'editor' && (
                <button 
                  onClick={() => setLeftView('explorer')}
                  className="p-2 hover:bg-gray-200 text-gray-500 hover:text-gray-800 rounded-lg transition-colors text-xs font-bold uppercase"
                >
                  Back
                </button>
              )}
              <button className="p-2 hover:bg-gray-200 text-gray-500 hover:text-gray-800 rounded-lg transition-colors">
                <Settings2 className="w-4 h-4" />
              </button>
            </div>
          </div>

          {leftView === 'explorer' ? (
            <div className="flex-1 overflow-y-auto custom-scrollbar pb-8 flex flex-col gap-6">
              <div className="flex flex-col gap-2">
                 <h3 className="text-[10px] text-gray-500 font-bold uppercase tracking-widest mb-1 px-1">applets/</h3>
                 {WORKSPACE.applets.map(file => (
                   <div key={file.path} onClick={() => openApplet(file.path)} className="flex items-center gap-3 bg-white hover:bg-gray-50 border border-gray-200 shadow-sm rounded-lg p-3 cursor-pointer">
                      <AppWindow className="w-4 h-4 text-blue-500" />
                      <span className="text-xs font-medium text-gray-800">{file.name}</span>
                   </div>
                 ))}
                 {WORKSPACE.applets.length === 0 && <div className="text-gray-400 text-xs px-2">Empty</div>}
              </div>

              <div className="flex flex-col gap-2">
                 <h3 className="text-[10px] text-gray-500 font-bold uppercase tracking-widest mb-1 px-1">scripts/</h3>
                 {WORKSPACE.scripts.map(file => (
                   <div key={file.path} onClick={() => openScript(file.path)} className="flex items-center gap-3 bg-white hover:bg-gray-50 border border-gray-200 shadow-sm rounded-lg p-3 cursor-pointer">
                      <TerminalSquare className="w-4 h-4 text-blue-500" />
                      <span className="text-xs font-medium text-gray-800">{file.name}</span>
                   </div>
                 ))}
                 {WORKSPACE.scripts.length === 0 && <div className="text-gray-400 text-xs px-2">Empty</div>}
              </div>

              <div className="flex flex-col gap-2">
                 <h3 className="text-[10px] text-gray-500 font-bold uppercase tracking-widest mb-1 px-1">widgets/</h3>
                 {WORKSPACE.widgets.map(file => (
                   <div key={file.path} className="flex items-center gap-3 bg-white hover:bg-gray-50 border border-gray-200 shadow-sm rounded-lg p-3 cursor-pointer">
                      <Cpu className="w-4 h-4 text-blue-500" />
                      <span className="text-xs font-medium text-gray-800">{(file as any).name}</span>
                   </div>
                 ))}
                 {WORKSPACE.widgets.length === 0 && <div className="text-gray-400 text-xs px-2">Empty</div>}
              </div>
            </div>
          ) : (
            <div className="flex-1 flex flex-col bg-white border border-gray-200 shadow-sm rounded-xl overflow-hidden font-mono text-sm relative">
              <div className="flex-1 flex h-full">
                <div className="w-12 bg-gray-50 border-r border-gray-200 flex flex-col items-end py-3 pr-3 text-gray-400 select-none overflow-hidden text-[11px] leading-6 tracking-tight">
                   {Array.from({length: Math.max(lines, 20)}).map((_, i) => <div key={i}>{i+1}</div>)}
                </div>
                <textarea 
                  value={editorText}
                  onChange={e => setEditorText(e.target.value)}
                  className="flex-1 bg-transparent p-3 outline-none text-gray-800 resize-none custom-scrollbar leading-6 pointer-events-auto" 
                  spellCheck={false}
                  autoCapitalize="off"
                  autoComplete="off"
                />
              </div>
            </div>
          )}
          
          {leftView === 'editor' && (
            <div className="flex items-center justify-between mt-4 px-1 text-[10px] uppercase font-bold tracking-widest text-gray-500 shrink-0">
              <div className="flex gap-4">
                <span className="flex items-center gap-1.5"><FileCode2 className="w-3 h-3"/> {lines} Lines</span>
                <span>{chars} Chars</span>
              </div>
              <span className="bg-gray-200 px-2 py-1 rounded">UTF-8</span>
            </div>
          )}

          {/* Mini Terminal PIP */}
          <div 
            onClick={() => setView('center')}
            className="absolute bottom-6 right-6 w-24 h-16 bg-[#012456] rounded-lg shadow-xl shadow-black/20 border border-gray-300 flex flex-col overflow-hidden cursor-pointer hover:scale-105 active:scale-95 transition-transform z-50"
          >
            <div className="h-4 bg-[#f3f3f3] flex items-center px-1 border-b border-gray-300">
              <div className="text-[#0078d4] font-bold tracking-tighter" style={{ fontSize: '8px' }}>&gt;_</div>
            </div>
            <div className="flex-1 p-1">
              <div className="text-white font-mono opacity-80" style={{ fontSize: '5px', lineHeight: '8px' }}>
                PS &gt; _
              </div>
            </div>
          </div>
        </div>

        {/* Right Panel - Applets Menu (Quick Launch) */}
        <div 
          className="absolute w-full h-full bg-[#f3f3f3] flex flex-col pt-12 pb-6 px-4 overflow-y-auto"
          style={{ top: 0, left: '100%' }}
        >
          <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-widest mb-6">Scripts</h2>

          <div className="flex flex-col gap-6">
            <div>
              <h3 className="text-[10px] text-gray-500 font-bold uppercase tracking-widest mb-3 px-1">Powershell Scripts</h3>
              <div className="flex flex-col gap-2">
                {APPLETS.filter(a => a.type === 'ps1').map(applet => (
                  <div key={applet.id} className="group flex items-center justify-between bg-white hover:bg-gray-50 border border-gray-200 shadow-sm rounded-xl p-3 cursor-pointer transition-all">
                    <div className="flex items-center gap-3 overflow-hidden">
                      <div className="bg-[#012456]/10 p-2 rounded-lg shrink-0">
                        <img src="/assets/ps1-icon.svg" alt="PS1 Icon" className="w-4 h-4 object-contain" />
                      </div>
                      <span className="text-gray-800 text-xs font-medium truncate" title={applet.name}>{applet.name}</span>
                    </div>
                    <button className="opacity-0 group-hover:opacity-100 p-2 rounded-lg bg-blue-600 text-white transition-all hover:scale-105 shadow-md shadow-blue-500/20">
                      <Play className="w-3 h-3 fill-current" />
                    </button>
                  </div>
                ))}
              </div>
            </div>

            <div>
              <h3 className="text-[10px] text-gray-500 font-bold uppercase tracking-widest mb-3 px-1">HTML Nodes</h3>
              <div className="flex flex-col gap-2">
                {APPLETS.filter(a => a.type === 'html').map(applet => (
                  <div key={applet.id} className="group flex items-center justify-between bg-white hover:bg-gray-50 border border-gray-200 shadow-sm rounded-xl p-3 cursor-pointer transition-all">
                    <div className="flex items-center gap-3 overflow-hidden">
                      <div className="bg-blue-50 p-2 rounded-lg shrink-0">
                        <Code2 className="w-4 h-4 text-blue-600"/>
                      </div>
                      <span className="text-gray-800 text-xs font-medium truncate" title={applet.name}>{applet.name}</span>
                    </div>
                    <button className="opacity-0 group-hover:opacity-100 p-2 rounded-lg bg-blue-600 text-white transition-all hover:scale-105 shadow-md shadow-blue-500/20">
                      <Play className="w-3 h-3 fill-current" />
                    </button>
                  </div>
                ))}
              </div>
            </div>
          </div>
          
          {/* Mini Terminal PIP */}
          <div 
            onClick={() => setView('center')}
            className="absolute bottom-6 left-6 w-24 h-16 bg-[#012456] rounded-lg shadow-xl shadow-black/20 border border-gray-300 flex flex-col overflow-hidden cursor-pointer hover:scale-105 active:scale-95 transition-transform z-50"
          >
            <div className="h-4 bg-[#f3f3f3] flex items-center px-1 border-b border-gray-300">
              <div className="text-[#0078d4] font-bold tracking-tighter" style={{ fontSize: '8px' }}>&gt;_</div>
            </div>
            <div className="flex-1 p-1">
              <div className="text-white font-mono opacity-80" style={{ fontSize: '5px', lineHeight: '8px' }}>
                PS &gt; _
              </div>
            </div>
          </div>
        </div>

        {/* Main Center Terminal Container */}
        <div className="absolute w-full h-full pointer-events-auto" style={{ top: 0, left: 0 }}>
          {/* Terminal Header & Frame (Only show for native terminal, not applets) */}
          {!activeApplet && <div className="absolute inset-0 pointer-events-none z-30" />}
          <div className="w-full h-full overflow-hidden bg-[#012456] relative font-mono flex flex-col">

            {/* Windows Terminal Top Bar */}
            {!activeApplet && (
              <div className="h-10 bg-[#f3f3f3] flex items-center shrink-0 transition-opacity select-none border-b border-gray-300">
                {/* Tab */}
                <div className="flex items-center gap-2 h-full px-4 min-w-[120px] md:min-w-[200px] bg-white border-t-2 border-t-[#0078d4] text-gray-800 text-xs font-sans shadow-sm z-10">
                  <div className="text-[#0078d4] font-bold text-sm w-4 flex justify-center">
                    &gt;_
                  </div>
                  <div>pwsh</div>
                </div>
                {/* New Tab Button */}
                <div className="flex h-full text-gray-600">
                   <div className="px-3 hover:bg-gray-200 cursor-pointer flex items-center justify-center transition-colors border-r border-[#00000018]">
                      <Plus size={14} />
                   </div>
                </div>
                <div className="flex-1 bg-[#f3f3f3] h-full"></div>
                {/* Windows Controls (Cosmetic + Minimize) */}
                <div className="flex h-full text-gray-600">
                   <div 
                     className="px-4 hover:bg-gray-200 cursor-pointer flex items-center justify-center transition-colors"
                     onClick={minimizeAppFromBridge}
                   >
                      <Minus size={14} />
                   </div>
                   <div className="px-4 hover:bg-gray-200 cursor-pointer flex items-center justify-center transition-colors">
                      <Square size={12} />
                   </div>
                   <div className="px-4 hover:bg-[#c42b1c] hover:text-white cursor-pointer flex items-center justify-center transition-colors">
                      <X size={14} />
                   </div>
                </div>
              </div>
            )}

            {/* Body */}
            {activeApplet ? (
              <iframe src={activeApplet} className="flex-1 w-full h-full border-none bg-white" />
            ) : (
              <div className={cn(
                "flex-1 p-4 overflow-y-auto text-sm leading-relaxed",
                "text-[#eeedf0]" // PowerShell standard text
              )}>
                <div className="mb-4 whitespace-pre-wrap shrink-0">
                  {`PowerShell 7.6.1
Copyright (c) Microsoft Corporation.

https://aka.ms/powershell
Type 'help' to get help.
`}
                </div>

                <div className="flex flex-col gap-1 w-full shrink-0">
                  {terminalHistory.map((line, idx) => (
                     <div key={idx} className={cn("whitespace-pre-wrap break-all", line.type === 'input' ? 'text-blue-300' : 'text-[#eeedf0]')}>
                       {line.type === 'input' ? `PS ~> ${line.text}` : line.text}
                     </div>
                  ))}
                </div>
                
                <div className="flex items-center mt-2 group shrink-0">
                  <span className="shrink-0">PS &gt; </span>
                  <input 
                    ref={inputRef}
                    type="text" 
                    value={inputValue}
                    onChange={e => setInputValue(e.target.value)}
                    onKeyDown={handleTerminalInput}
                    className="flex-1 bg-transparent border-none outline-none text-[#eeedf0] ml-2 font-mono w-full"
                    autoFocus
                    spellCheck={false}
                  />
                </div>
                {/* Invisible element to auto-scroll */}
                <div ref={terminalEndRef} className="h-4 shrink-0" />
                
              </div>
            )}
            
          </div>
        </div>

      </motion.div>

      {navMode === 'joystick' && <Thumbstick view={view} setView={setView} />}
      
      {navMode === 'hamburger' && (
        <HamburgerStick view={view} setView={setView} isMenuOpen={isMenuOpen} setIsMenuOpen={setIsMenuOpen} />
      )}
      
    </div>
  );
}




