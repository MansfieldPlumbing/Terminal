import React, { useEffect, useRef } from 'react';
import { makeStyles } from '@fluentui/react-components';
import { useAppStore, Tab } from '../System.Store';

// Full xterm 256-color palette
function buildPalette(): string[] {
  const p: string[] = [];
  // 0-15: standard ANSI colors
  const base = ['#0C0C0C','#C50F1F','#13A10E','#C19C00','#0037DA','#881798','#3A96DD','#CCCCCC',
                 '#767676','#E74856','#16C60C','#F9F1A5','#3B78FF','#B4009E','#61D6D6','#F2F2F2'];
  base.forEach(c => p.push(c));
  // 16-231: 6x6x6 RGB cube
  const ramp = [0, 95, 135, 175, 215, 255];
  for (let i = 0; i < 216; i++) {
    const r = ramp[Math.floor(i / 36)];
    const g = ramp[Math.floor((i % 36) / 6)];
    const b = ramp[i % 6];
    p.push(`rgb(${r},${g},${b})`);
  }
  // 232-255: grayscale
  for (let i = 0; i < 24; i++) {
    const v = 8 + i * 10;
    p.push(`rgb(${v},${v},${v})`);
  }
  return p;
}
const PALETTE = buildPalette();

const CELL_W = 9;
const CELL_H = 18;
const FONT_SIZE = 14;

const useStyles = makeStyles({
  root: {
    position: 'absolute',
    inset: 0,
    backgroundColor: '#000000',
    overflow: 'hidden',
    display: 'flex',
    flexDirection: 'column',
    fontFamily: 'monospace',
  },
  canvasContainer: {
    flex: 1,
    width: '100%',
    position: 'relative',
    outline: 'none',
    padding: '8px',
    display: 'flex',
    alignItems: 'flex-start',
    justifyContent: 'flex-start',
    overflow: 'hidden',
  },
  inputBar: {
    height: '48px',
    backgroundColor: '#121212',
    borderTop: '1px solid #333',
    display: 'flex',
    alignItems: 'center',
    paddingLeft: '16px',
    paddingRight: '16px',
    flexShrink: 0,
    zIndex: 40,
    position: 'relative',
  },
  prompt: {
    color: '#ec4899',
    fontWeight: 'bold',
    marginRight: '8px',
    fontSize: '14px',
    userSelect: 'none',
    flexShrink: 0,
  },
  input: {
    flex: 1,
    backgroundColor: 'transparent',
    border: 'none',
    outline: 'none',
    color: '#d1d5db',
    fontFamily: 'monospace',
    fontSize: '14px',
    height: '100%',
  },
});

export default function TerminalCanvas({ tab }: { tab: Tab }) {
  const styles = useStyles();
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const currentBounds = useRef({ cols: 120, rows: 40 });
  const [offline, setOffline] = React.useState(false);
  const addTab = useAppStore(state => state.addTab);
  const showInputBar = useAppStore(state => state.showInputBar);

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
      const cursorCol  = grid[2];
      const cursorRow  = grid[3];
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

      // Cells start at index 4 (header: cols, rows, cursorCol, cursorRow)
      for (let i = 0; i < activeCols * activeRows; i++) {
        if (i + 4 >= grid.length) break;
        const cell = grid[i + 4];
        if (cell === 0) continue;
        const charCode = cell & 0xFFFF;
        const fg = (cell >> 16) & 0xFF;
        const bg = (cell >> 24) & 0xFF;
        const x = (i % activeCols) * CELL_W;
        const y = Math.floor(i / activeCols) * CELL_H;
        if (bg !== 0) {
          ctx.fillStyle = PALETTE[bg] ?? PALETTE[bg % 16];
          ctx.fillRect(x, y, CELL_W + 0.5, CELL_H + 0.5);
        }
        if (charCode !== 32 && charCode !== 0) {
          ctx.fillStyle = PALETTE[fg] ?? PALETTE[fg % 16];
          ctx.fillText(String.fromCharCode(charCode), x, y + 1);
        }
      }

      // Cursor block
      if (cursorCol >= 0 && cursorRow >= 0 && cursorCol < activeCols && cursorRow < activeRows) {
        ctx.fillStyle = 'rgba(255,255,255,0.75)';
        ctx.fillRect(cursorCol * CELL_W, cursorRow * CELL_H, CELL_W, CELL_H);
        // Re-draw char under cursor in bg color for contrast
        const ci = cursorRow * activeCols + cursorCol;
        if (ci + 4 < grid.length) {
          const cell = grid[ci + 4];
          const charCode = cell & 0xFFFF;
          if (charCode !== 32 && charCode !== 0) {
            ctx.fillStyle = PALETTE[0];
            ctx.fillText(String.fromCharCode(charCode), cursorCol * CELL_W, cursorRow * CELL_H + 1);
          }
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
    <div className={styles.root}>
      <div ref={containerRef} className={styles.canvasContainer} tabIndex={0}>
        <canvas ref={canvasRef} onClick={handleTouch('tap')} />
      </div>

      {showInputBar && (
        <div className={styles.inputBar}>
          <span className={styles.prompt}>&gt;_</span>
          <input
            type="text"
            className={styles.input}
            placeholder="Send command to Canvas Host..."
            onKeyDown={handleKeyDown}
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
          />
        </div>
      )}
    </div>
  );
}
