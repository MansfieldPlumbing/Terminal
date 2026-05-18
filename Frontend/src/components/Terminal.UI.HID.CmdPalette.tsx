import React, { useRef, useState, useCallback, useEffect } from 'react';
import { makeStyles, mergeClasses } from '@fluentui/react-components';
import { motion, AnimatePresence } from 'motion/react';
import { useAppStore } from '../System.Store';
import { Search, TerminalSquare, FileText, FolderTree, Settings2, ShieldAlert, Github } from 'lucide-react';

const useStyles = makeStyles({
  fab: {
    position: 'fixed',
    touchAction: 'none',
    transition: 'transform 200ms ease-out',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    cursor: 'grab',
    zIndex: 300,
  },
  fabVisible: { opacity: 1, pointerEvents: 'auto', boxShadow: '0 25px 50px -12px rgba(0,0,0,0.5)' },
  fabHidden: { opacity: 0, pointerEvents: 'none' },
  fabInner: {
    width: '56px',
    height: '56px',
    borderRadius: '16px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    color: 'rgba(255,255,255,0.9)',
    boxShadow: '0 0 20px rgba(0,0,0,0.5)',
  },
  overlay: {
    position: 'fixed',
    inset: 0,
    zIndex: 300,
    pointerEvents: 'none',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    paddingLeft: '16px',
    paddingRight: '16px',
  },
  backdrop: {
    position: 'absolute',
    inset: 0,
    pointerEvents: 'auto',
  },
  palette: {
    width: '100%',
    maxWidth: '320px',
    borderRadius: '12px',
    overflow: 'hidden',
    pointerEvents: 'auto',
    display: 'flex',
    flexDirection: 'column',
    zIndex: 301,
    marginBottom: '128px',
    boxShadow: '0 25px 50px -12px rgba(0,0,0,0.5)',
  },
  searchRow: {
    display: 'flex',
    alignItems: 'center',
    paddingLeft: '12px',
    paddingRight: '12px',
    paddingTop: '8px',
    paddingBottom: '8px',
    borderBottom: '1px solid rgba(255,255,255,0.1)',
    fontFamily: 'sans-serif',
  },
  searchInput: {
    flex: 1,
    backgroundColor: 'transparent',
    outline: 'none',
    border: 'none',
    fontSize: '14px',
    color: '#ffffff',
    '::placeholder': { color: 'rgba(113,113,122,1)' },
  },
  resultsList: {
    maxHeight: '192px',
    overflowY: 'auto',
    paddingLeft: '4px',
    paddingRight: '4px',
    paddingTop: '4px',
    paddingBottom: '4px',
  },
  cmdBtn: {
    width: '100%',
    display: 'flex',
    alignItems: 'center',
    gap: '12px',
    paddingLeft: '8px',
    paddingRight: '8px',
    paddingTop: '8px',
    paddingBottom: '8px',
    borderRadius: '8px',
    textAlign: 'left',
    fontFamily: 'sans-serif',
    fontSize: '14px',
    border: 'none',
    cursor: 'pointer',
    transition: 'all 300ms ease-out',
    ':active': { transform: 'scale(0.98)', transition: 'none' },
  },
  cmdBtnSelected: { backgroundColor: 'rgba(255,255,255,0.1)', color: '#ffffff' },
  cmdBtnNormal: {
    backgroundColor: 'transparent',
    color: 'rgba(212,212,216,1)',
    ':active': { backgroundColor: 'rgba(255,255,255,0.15)' },
  },
  cmdIcon: { width: '16px', height: '16px' },
  cmdIconSelected: { color: '#ffffff' },
  cmdIconNormal: { color: 'rgba(113,113,122,1)' },
  empty: {
    paddingTop: '24px',
    paddingBottom: '24px',
    textAlign: 'center',
    color: 'rgba(113,113,122,1)',
    fontFamily: 'sans-serif',
    fontSize: '12px',
  },
});

export default function FloatingCommandPalette() {
  const styles = useStyles();
  const { commandPaletteVisible, floatingCommandPaletteOpen, setFloatingCommandPaletteOpen, addTab, addNotification, appConfig } = useAppStore();
  const [pos, setPos] = useState({ x: 24, y: 0 });
  const [search, setSearch] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const baseRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const isDragging = useRef(false);
  const startRef = useRef({ x: 0, y: 0 });
  const lastDragPosRef = useRef({ x: 0, y: 0 });

  useEffect(() => { setPos({ x: window.innerWidth - 80, y: window.innerHeight / 2 - 80 }); }, []);

  useEffect(() => {
    if (floatingCommandPaletteOpen) {
      inputRef.current?.focus();
      setSearch('');
      setSelectedIndex(0);
    }
  }, [floatingCommandPaletteOpen]);

  const defaultCommands = [
    { id: 'applet-github', name: 'GitHub Repo', icon: Github, action: () => window.open('https://github.com/mansfieldplumbing/android-terminal', '_blank') },
    { id: 'applet-telemetry', name: 'Trigger Telemetry', icon: ShieldAlert, action: () => addNotification('System telemetry generated.', 'warn') },
  ];

  const configCommands = (appConfig?.profiles.list || []).filter(p => !p.hidden).map(profile => {
    let Icon = TerminalSquare;
    if (profile.type === 'notepad') Icon = FileText;
    else if (profile.type === 'explorer') Icon = FolderTree;
    else if (profile.type === 'colors' || profile.type === 'applet') Icon = Settings2;
    return {
      id: profile.guid,
      name: profile.name,
      icon: Icon,
      action: () => addTab({ id: `${profile.guid}-${Date.now()}`, type: profile.type, title: profile.name, path: profile.path })
    };
  });

  const commands = [...configCommands, ...defaultCommands];
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
    const dist = Math.sqrt(Math.pow(e.clientX - startRef.current.x, 2) + Math.pow(e.clientY - startRef.current.y, 2));
    if (dist > 5) isDragging.current = true;
    if (isDragging.current) {
      const dx = e.clientX - lastDragPosRef.current.x;
      const dy = e.clientY - lastDragPosRef.current.y;
      lastDragPosRef.current = { x: e.clientX, y: e.clientY };
      setPos(p => ({ x: p.x + dx, y: p.y + dy }));
    }
  };

  const handlePointerUp = (e: React.PointerEvent) => {
    const el = baseRef.current;
    if (!el) return;
    if (el.hasPointerCapture(e.pointerId)) el.releasePointerCapture(e.pointerId);
    if (!isDragging.current) {
      setFloatingCommandPaletteOpen(!floatingCommandPaletteOpen);
    } else {
      setPos(p => ({
        x: p.x < window.innerWidth / 2 ? 10 : window.innerWidth - 70,
        y: Math.max(10, Math.min(window.innerHeight - 70, p.y)),
      }));
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
        className={mergeClasses(styles.fab, floatingCommandPaletteOpen ? styles.fabHidden : styles.fabVisible)}
        style={{ left: pos.x, top: pos.y, width: 56, height: 56 }}
      >
        <div className={`mica-panel mica-border ${styles.fabInner}`}>
          <Search size={22} style={{ opacity: 0.8 }} />
        </div>
      </div>

      <AnimatePresence>
        {floatingCommandPaletteOpen && (
          <div className={styles.overlay}>
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className={styles.backdrop}
              onClick={() => setFloatingCommandPaletteOpen(false)}
            />
            <motion.div
              layoutId="palette"
              initial={{ opacity: 0, scale: 0.95, y: 10 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 10 }}
              transition={{ type: 'spring', damping: 25, stiffness: 300 }}
              className={`mica-panel mica-border text-shadow-mica ${styles.palette}`}
            >
              <div className={styles.searchRow}>
                <Search style={{ width: 16, height: 16, color: 'rgba(161,161,170,1)', marginRight: '8px' }} />
                <input
                  ref={inputRef}
                  value={search}
                  onChange={e => { setSearch(e.target.value); setSelectedIndex(0); }}
                  onKeyDown={e => {
                    if (e.key === 'ArrowDown') { e.preventDefault(); setSelectedIndex(p => Math.min(filteredCommands.length - 1, p + 1)); }
                    if (e.key === 'ArrowUp') { e.preventDefault(); setSelectedIndex(p => Math.max(0, p - 1)); }
                    if (e.key === 'Enter') { e.preventDefault(); filteredCommands[selectedIndex]?.action(); setFloatingCommandPaletteOpen(false); }
                    if (e.key === 'Escape') setFloatingCommandPaletteOpen(false);
                  }}
                  className={styles.searchInput}
                  placeholder="Commands, tools, settings..."
                />
              </div>
              <div className={`hide-scrollbar ${styles.resultsList}`}>
                {filteredCommands.length > 0 ? (
                  filteredCommands.map((c, i) => (
                    <button
                      key={c.id}
                      onMouseEnter={() => setSelectedIndex(i)}
                      onClick={() => { c.action(); setFloatingCommandPaletteOpen(false); }}
                      className={mergeClasses(styles.cmdBtn, selectedIndex === i ? styles.cmdBtnSelected : styles.cmdBtnNormal)}
                    >
                      <c.icon className={mergeClasses(styles.cmdIcon, selectedIndex === i ? styles.cmdIconSelected : styles.cmdIconNormal)} />
                      <span style={{ fontWeight: '500' }}>{c.name}</span>
                    </button>
                  ))
                ) : (
                  <div className={styles.empty}>No results</div>
                )}
              </div>
            </motion.div>
          </div>
        )}
      </AnimatePresence>
    </>
  );
}
