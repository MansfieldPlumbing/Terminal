import React, { useRef, useState, useCallback, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { useAppStore } from '../store';
import { Search, TerminalSquare, FileText, FolderTree, Settings2, ShieldAlert, Github, Video } from 'lucide-react';
import { cn } from '../lib/utils';

export default function FloatingCommandPalette() {
  const { commandPaletteVisible, floatingCommandPaletteOpen, setFloatingCommandPaletteOpen, addTab, addNotification } = useAppStore();
  const [pos, setPos] = useState({ x: 24, y: 0 });
  const [search, setSearch] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const baseRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  
  const isDragging = useRef(false);
  const startRef = useRef({ x: 0, y: 0 });
  const lastDragPosRef = useRef({ x: 0, y: 0 });

  useEffect(() => {
    setPos({ x: window.innerWidth - 80, y: window.innerHeight / 2 - 80 });
  }, []);

  useEffect(() => {
    if (floatingCommandPaletteOpen) {
      inputRef.current?.focus();
      setSearch('');
      setSelectedIndex(0);
    }
  }, [floatingCommandPaletteOpen]);

  const commands = [
    { id: '1', name: 'New Terminal', icon: TerminalSquare, action: () => addTab({ id: 'pwsh-' + Date.now(), type: 'terminal', title: 'pwsh' }) },
    { id: '2', name: 'Open Editor', icon: FileText, action: () => addTab({ id: 'notepad-' + Date.now(), type: 'notepad', title: 'untitled.txt', content: '' }) },
    { id: '3', name: 'Files', icon: FolderTree, action: () => addTab({ id: 'explorer-' + Date.now(), type: 'explorer', title: 'Files' }) },
    { id: '4', name: 'Color Schemes', icon: Settings2, action: () => addTab({ id: 'colors-' + Date.now(), type: 'colors', title: 'Schemes' }) },
    { id: '5', name: 'GitHub Repo', icon: Github, action: () => window.open('https://github.com/mansfieldplumbing/android-terminal', '_blank') },
    { id: '6', name: 'Trigger Telemetry', icon: ShieldAlert, action: () => addNotification('System telemetry generated.', 'warn') },
    { id: 'nc', name: 'No Cap Video Editor', icon: Video, action: () => addTab({ id: 'nocap', type: 'applet', title: 'No Cap', path: '/applets/no-cap.html' }) },
  ];

  const filteredCommands = commands.filter(c => c.name.toLowerCase().includes(search.toLowerCase()));

  const handlePointerDown = (e: React.PointerEvent) => {
    const el = baseRef.current;
    if (!el) return;
    el.setPointerCapture(e.pointerId);
    isDragging.current = false;
    startRef.current = { x: e.clientX, y: e.clientY };
    lastDragPosRef.current = { x: e.clientX, y: e.clientY };
  };

  const handlePointerMove = (e: React.PointerEvent) => {
    const el = baseRef.current;
    if (!el || !el.hasPointerCapture(e.pointerId)) return;
    
    const dx = e.clientX - lastDragPosRef.current.x;
    const dy = e.clientY - lastDragPosRef.current.y;
    const dist = Math.sqrt(Math.pow(e.clientX - startRef.current.x, 2) + Math.pow(e.clientY - startRef.current.y, 2));

    if (dist > 5) {
      isDragging.current = true;
    }

    if (isDragging.current) {
      lastDragPosRef.current = { x: e.clientX, y: e.clientY };
      setPos(p => {
        let nx = p.x + dx;
        let ny = p.y + dy;
        return { x: nx, y: ny };
      });
    }
  };

  const handlePointerUp = (e: React.PointerEvent) => {
    const el = baseRef.current;
    if (!el) return;
    if (el.hasPointerCapture(e.pointerId)) {
      el.releasePointerCapture(e.pointerId);
    }
    
    if (!isDragging.current) {
      setFloatingCommandPaletteOpen(!floatingCommandPaletteOpen);
    } else {
       // Snap to edges
       setPos(p => {
         let targetX = p.x;
         let targetY = Math.max(10, Math.min(window.innerHeight - 70, p.y));
         if (p.x < window.innerWidth / 2) targetX = 10;
         else targetX = window.innerWidth - 70;
         return { x: targetX, y: targetY };
       });
    }
    isDragging.current = false;
  };

  if (!commandPaletteVisible) return null;

  return (
    <>
      <div 
        ref={baseRef}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
        className={cn("fixed touch-none transition-transform duration-200 ease-out flex items-center justify-center cursor-grab active:cursor-grabbing z-[300]", 
          floatingCommandPaletteOpen ? "opacity-0 pointer-events-none" : "opacity-100 pointer-events-auto shadow-2xl"
        )}
        style={{ left: pos.x, top: pos.y, width: 56, height: 56 }}
      >
        <div className="w-14 h-14 mica-panel mica-border rounded-2xl flex items-center justify-center text-white/90 shadow-[0_0_20px_rgba(0,0,0,0.5)]">
           <Search size={22} className="opacity-80" />
        </div>
      </div>

      <AnimatePresence>
        {floatingCommandPaletteOpen && (
          <div className="fixed inset-0 z-[300] pointer-events-none flex items-center justify-center px-4">
            <motion.div
               initial={{ opacity: 0 }}
               animate={{ opacity: 1 }}
               exit={{ opacity: 0 }}
               className="absolute inset-0 pointer-events-auto"
               onClick={() => setFloatingCommandPaletteOpen(false)}
            />
            <motion.div
              layoutId="palette"
              initial={{ opacity: 0, scale: 0.95, y: 10 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 10 }}
              transition={{ type: 'spring', damping: 25, stiffness: 300 }}
              className="w-full max-w-xs mica-panel mica-border shadow-2xl rounded-xl overflow-hidden pointer-events-auto flex flex-col z-[301] text-shadow-mica mb-32"
            >
              <div className="flex items-center px-3 py-2 border-b border-white/10 font-sans">
                <Search className="w-4 h-4 text-zinc-400 mr-2" />
                <input
                  ref={inputRef}
                  value={search}
                  onChange={e => { setSearch(e.target.value); setSelectedIndex(0); }}
                  onKeyDown={e => {
                    if (e.key === 'ArrowDown') { e.preventDefault(); setSelectedIndex(p => Math.min(filteredCommands.length - 1, p + 1)); }
                    if (e.key === 'ArrowUp') { e.preventDefault(); setSelectedIndex(p => Math.max(0, p - 1)); }
                    if (e.key === 'Enter') { 
                      e.preventDefault(); 
                      filteredCommands[selectedIndex]?.action(); 
                      setFloatingCommandPaletteOpen(false); 
                    }
                    if (e.key === 'Escape') setFloatingCommandPaletteOpen(false);
                  }}
                  className="flex-1 bg-transparent outline-none border-none text-sm placeholder-zinc-500 text-white"
                  placeholder="Commands, tools, settings..."
                />
              </div>
              <div className="max-h-48 overflow-y-auto px-1 py-1 hide-scrollbar">
                {filteredCommands.length > 0 ? (
                  filteredCommands.map((c, i) => (
                    <button
                      key={c.id}
                      onMouseEnter={() => setSelectedIndex(i)}
                      onClick={() => { c.action(); setFloatingCommandPaletteOpen(false); }}
                      className={cn(
                        "w-full flex items-center gap-3 px-2 py-2 rounded-lg text-left font-sans text-sm",
                        selectedIndex === i ? "bg-white/10 text-white" : "text-zinc-300 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0"
                      )}
                    >
                      <c.icon className={cn("w-4 h-4", selectedIndex === i ? "text-white" : "text-zinc-500")} />
                      <span className="font-medium">{c.name}</span>
                    </button>
                  ))
                ) : (
                  <div className="py-6 text-center text-zinc-500 font-sans text-xs">No results</div>
                )}
              </div>
            </motion.div>
          </div>
        )}
      </AnimatePresence>
    </>
  );
}



