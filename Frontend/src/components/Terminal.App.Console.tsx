import React, { useEffect, useRef } from 'react';
import { useAppStore, Tab } from '../System.Store';

const PALETTE = [
  '#0C0C0C', '#C50F1F', '#13A10E', '#C19C00', '#0037DA', '#881798', '#3A96DD', '#CCCCCC',
  '#767676', '#E74856', '#16C60C', '#F9F1A5', '#3B78FF', '#B4009E', '#61D6D6', '#F2F2F2'
];

export default function TerminalCanvas({ tab }: { tab: Tab }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const currentBounds = useRef({ cols: 120, rows: 40 });
  const [offline, setOffline] = React.useState(false);
  const addTab = useAppStore(state => state.addTab);
  const showInputBar = useAppStore(state => state.showInputBar);
  
  const CELL_W = 9;
  const CELL_H = 18;
  const FONT_SIZE = 14;

  useEffect(() => {
    const preventZoom = (e: WheelEvent) => { if (e.ctrlKey || e.metaKey) e.preventDefault(); };
    window.addEventListener('wheel', preventZoom, { passive: false });
    return () => window.removeEventListener('wheel', preventZoom);
  }, []);

  useEffect(() => {
    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container) return;
    const ctx = canvas.getContext('2d', { alpha: false });
    if (!ctx) return;

    container.focus();

    const resizeObserver = new ResizeObserver((entries) => {
      const { width, height } = entries[0].contentRect;
      const newCols = Math.max(1, Math.floor(width / CELL_W));
      const newRows = Math.max(1, Math.floor(height / CELL_H));

      if (currentBounds.current.cols !== newCols || currentBounds.current.rows !== newRows) {
        currentBounds.current = { cols: newCols, rows: newRows };
        if (typeof window !== 'undefined' && (window as any).AndroidBridge?.sendInput) {
            (window as any).AndroidBridge.sendInput(JSON.stringify({ type: 'resize', cols: newCols, rows: newRows }));
        }
      }
    });
    resizeObserver.observe(container);

    const onMessage = (e: MessageEvent) => {
      if (!(e.data instanceof ArrayBuffer)) return;
      const grid = new Uint32Array(e.data);
      if (grid.length < 2) return;
      
      const activeCols = grid[0];
      const activeRows = grid[1];
      const dpr = window.devicePixelRatio || 1;

      const exactWidth = activeCols * CELL_W;
      const exactHeight = activeRows * CELL_H;
      canvas.style.width = `${exactWidth}px`;
      canvas.style.height = `${exactHeight}px`;
      canvas.width = Math.floor(exactWidth * dpr);
      canvas.height = Math.floor(exactHeight * dpr);

      ctx.save();
      ctx.scale(dpr, dpr);
      ctx.fillStyle = PALETTE[0];
      ctx.fillRect(0, 0, exactWidth, exactHeight);
      ctx.font = `bold ${FONT_SIZE}px "Cascadia Code", Consolas, monospace`;
      ctx.textBaseline = 'top';

      for (let i = 0; i < activeCols * activeRows; i++) {
        if (i + 2 >= grid.length) break;
        const cell = grid[i + 2];
        if (cell === 0) continue;

        const charCode = cell & 0xFFFF;
        const fg = (cell >> 16) & 0xFF;
        const bg = (cell >> 24) & 0xFF;
        const x = (i % activeCols) * CELL_W;
        const y = Math.floor(i / activeCols) * CELL_H;

        if (bg !== 0) {
          ctx.fillStyle = PALETTE[bg % 16];
          ctx.fillRect(x, y, CELL_W + 0.5, CELL_H + 0.5);
        }
        if (charCode !== 32 && charCode !== 0) {
          ctx.fillStyle = PALETTE[fg % 16];
          ctx.fillText(String.fromCharCode(charCode), x, y + 1);
        }
      }
      ctx.restore();
    };

    const handleMessage = (e: MessageEvent) => { setOffline(false); onMessage(e); };
    window.addEventListener('message', handleMessage);
    return () => { window.removeEventListener('message', handleMessage); resizeObserver.disconnect(); };
  }, []);

  const handleTouch = (action: string) => (e: React.PointerEvent) => {
    const rect = canvasRef.current?.getBoundingClientRect();
    if (!rect) return;
    const col = Math.floor((e.clientX - rect.left) / CELL_W);
    const row = Math.floor((e.clientY - rect.top) / CELL_H);
    
    // BUG FIX: Only intercept actual taps. Ignore scrolling/dragging!
    if (action === 'tap' && typeof window !== 'undefined' && (window as any).AndroidBridge?.sendInput) {
      (window as any).AndroidBridge.sendInput(JSON.stringify({ type: 'touch', action: 'tap', col, row }));
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      const val = e.currentTarget.value;
      if (typeof window !== 'undefined' && (window as any).AndroidBridge?.invokeCommand) {
          (window as any).AndroidBridge.invokeCommand(val);
      }
      e.currentTarget.value = '';
    }
  };

  return (
    <div className="absolute inset-0 bg-[#000000] overflow-hidden flex flex-col font-mono">
      <div ref={containerRef} className="flex-1 w-full relative outline-none p-2 flex items-start justify-start overflow-hidden" tabIndex={0}>
        <canvas ref={canvasRef} onClick={handleTouch('tap')} />
      </div>
      
      {showInputBar && (
        <div className="h-12 bg-[#121212] border-t border-[#333] flex items-center px-4 shrink-0 z-40 relative">
           <span className="text-pink-500 font-bold mr-2 text-sm select-none">&gt;_</span>
           <input 
             type="text" 
             className="flex-1 bg-transparent border-none outline-none text-gray-200 font-mono text-sm h-full"
             placeholder="Send command to Canvas Host..."
             onKeyDown={handleKeyDown}
             autoComplete="off"
             autoCapitalize="off"
             spellCheck="false"
           />
        </div>
      )}
    </div>
  );
}