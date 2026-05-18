import React, { useRef, useState, useEffect } from 'react';
import { makeStyles, mergeClasses } from '@fluentui/react-components';
import { motion, AnimatePresence, Reorder } from 'motion/react';
import { useAppStore } from '../System.Store';
import { Plus, Menu, LayoutTemplate, FileText, FolderTree, Settings2, X, Clapperboard, TerminalSquare, Activity } from 'lucide-react';
import HamburgerMenuContent from './Terminal.UI.Menu.Hamburger';

const useStyles = makeStyles({
  bar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    height: '56px',
    display: 'flex',
    alignItems: 'center',
    flexShrink: 0,
    userSelect: 'none',
    zIndex: 400,
    transition: 'all 200ms',
  },
  barSolid: {
    backgroundColor: '#1C1C1C',
    borderBottom: '1px solid #000',
  },
  barMicaBg: {
    position: 'absolute',
    inset: 0,
    overflow: 'hidden',
    pointerEvents: 'none',
    zIndex: -10,
    borderBottom: '1px solid rgba(255,255,255,0.1)',
    boxShadow: '0 8px 32px rgba(0,0,0,0.2)',
  },
  barMicaSky: {
    position: 'absolute',
    inset: 0,
    pointerEvents: 'none',
    zIndex: 0,
  },
  barMicaPanel: {
    position: 'absolute',
    inset: 0,
    pointerEvents: 'none',
    zIndex: 10,
  },
  hamburgerArea: {
    position: 'relative',
    height: '100%',
    display: 'flex',
    alignItems: 'center',
    flexShrink: 0,
  },
  hamburgerBtn: {
    height: '100%',
    paddingLeft: '16px',
    paddingRight: '16px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    outline: 'none',
    border: 'none',
    backgroundColor: 'transparent',
    cursor: 'pointer',
    color: 'inherit',
    transition: 'all 300ms ease-out',
    ':active': { backgroundColor: 'rgba(255,255,255,0.15)', transform: 'scale(0.98)', transition: 'none' },
  },
  hamburgerBtnActive: { backgroundColor: 'rgba(255,255,255,0.1)' },
  hamburgerBtnSolidBorder: { borderRight: '1px solid rgba(0,0,0,0.31)' },
  tabGroup: {
    display: 'flex',
    height: '100%',
    overflowX: 'auto',
    scrollBehavior: 'smooth',
    touchAction: 'pan-x',
    flexShrink: 1,
    paddingLeft: '4px',
    paddingRight: '4px',
    scrollbarWidth: 'none',
    '::-webkit-scrollbar': { display: 'none' },
  },
  tabGroupMica: { alignItems: 'flex-end', paddingBottom: '2px' },
  tabItem: {
    display: 'flex',
    alignItems: 'center',
    gap: '12px',
    paddingLeft: '12px',
    paddingRight: '12px',
    minWidth: '56px',
    maxWidth: '120px',
    fontSize: '14px',
    fontFamily: 'sans-serif',
    cursor: 'pointer',
    flexShrink: 0,
    userSelect: 'none',
    position: 'relative',
    transition: 'all 300ms ease-out',
    ':active': { transform: 'scale(0.98)', transition: 'none' },
  },
  tabItemStd: {
    height: '100%',
    borderRight: '1px solid rgba(0,0,0,0.31)',
  },
  tabItemMica: {
    height: '42px',
    marginTop: 'auto',
    marginLeft: '-1px',
    marginRight: '-1px',
  },
  tabActiveStd: {
    backgroundColor: '#2D2D2D',
    color: '#eeedf0',
    borderTop: '3px solid #0078d4',
  },
  tabActiveMica: {
    backgroundColor: 'rgba(30,80,180,0.95)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    color: '#ffffff',
    borderLeft: '1px solid rgba(255,255,255,0.3)',
    borderRight: '1px solid rgba(255,255,255,0.3)',
    borderTop: '1px solid rgba(255,255,255,0.3)',
    boxShadow: '0 0 15px rgba(0,0,0,0.6)',
    zIndex: 20,
  },
  tabInactiveStd: {
    backgroundColor: '#1C1C1C',
    color: '#999',
    ':hover': { backgroundColor: '#2A2A2A' },
    ':active': { backgroundColor: '#333', transform: 'scale(0.98)', transition: 'none' },
  },
  tabInactiveMica: {
    backgroundColor: 'rgba(15,45,110,0.85)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    color: 'rgba(229,231,235,1)',
    borderLeft: '1px solid rgba(255,255,255,0.2)',
    borderRight: '1px solid rgba(255,255,255,0.2)',
    borderTop: '1px solid rgba(255,255,255,0.2)',
    zIndex: 10,
  },
  tabIcon: {
    width: '20px',
    display: 'flex',
    justifyContent: 'center',
    alignItems: 'center',
    flexShrink: 0,
    pointerEvents: 'none',
  },
  tabTitle: {
    fontWeight: '500',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
    flex: 1,
    fontSize: '13px',
    pointerEvents: 'none',
    display: 'none',
  },
  spacer: { flex: 1 },
  addArea: {
    position: 'relative',
    height: '100%',
    display: 'flex',
    alignItems: 'center',
    flexShrink: 0,
    borderLeft: '1px solid rgba(255,255,255,0.05)',
  },
  addBtn: {
    height: '100%',
    paddingLeft: '16px',
    paddingRight: '16px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
    border: 'none',
    cursor: 'pointer',
    transition: 'all 300ms ease-out',
    ':active': { backgroundColor: 'rgba(255,255,255,0.1)', transform: 'scale(0.98)', transition: 'none' },
  },
  addBtnMica: { backgroundColor: 'transparent', color: '#d1d5db' },
  addBtnSolid: { backgroundColor: '#1C1C1C', color: '#9ca3af' },
  dropdown: {
    position: 'absolute',
    width: '224px',
    boxShadow: '0 25px 50px -12px rgba(0,0,0,0.5)',
    paddingBottom: '8px',
    zIndex: 50,
    fontSize: '14px',
    fontFamily: 'sans-serif',
    overflow: 'hidden',
  },
  dropdownRight: { right: 0 },
  dropdownLeft: { left: 0 },
  dropdownTopFull: { top: '100%', marginTop: '8px', borderRadius: '12px' },
  dropdownTop56: { top: '56px', borderRadius: '0 0 12px 12px' },
  sectionHeader: {
    paddingLeft: '12px',
    paddingRight: '12px',
    paddingTop: '12px',
    paddingBottom: '4px',
    fontSize: '10px',
    textTransform: 'uppercase' as const,
    fontWeight: 'bold',
    color: 'rgba(255,255,255,0.4)',
    letterSpacing: '0.1em',
    borderBottom: '1px solid rgba(255,255,255,0.1)',
    marginBottom: '4px',
  },
  dropBtn: {
    width: '100%',
    paddingLeft: '16px',
    paddingRight: '16px',
    paddingTop: '10px',
    paddingBottom: '10px',
    display: 'flex',
    alignItems: 'center',
    gap: '12px',
    textAlign: 'left',
    fontWeight: '500',
    border: 'none',
    backgroundColor: 'transparent',
    cursor: 'pointer',
    color: 'inherit',
    transition: 'all 300ms ease-out',
    ':active': { backgroundColor: 'rgba(255,255,255,0.15)', transform: 'scale(0.98)', transition: 'none' },
  },
  closeArea: {
    height: '100%',
    display: 'flex',
    alignItems: 'center',
    flexShrink: 0,
    borderLeft: '1px solid rgba(255,255,255,0.05)',
    zIndex: 600,
    position: 'relative',
  },
  closeBtn: {
    height: '100%',
    paddingLeft: '20px',
    paddingRight: '20px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: 'none',
    backgroundColor: 'transparent',
    cursor: 'pointer',
    color: 'inherit',
    transition: 'background-color 200ms',
    ':hover': { backgroundColor: '#c42b1c' },
    ':active': { backgroundColor: '#a62417' },
  },
  closeBtnMicaHover: {
    ':hover': { backgroundColor: '#e81123' },
    ':active': { backgroundColor: '#f1707a' },
  },
});

export default function TabBar() {
  const styles = useStyles();
  const {
    tabs, activeTabId, setActiveTab, addTab, removeTab,
    hamburgerMenuOpen, setHamburgerMenuOpen, testsMenuOpen, setTestsMenuOpen,
    autoHideTabs, appConfig,
    closeTabsToRight, closeOtherTabs, setTabs
  } = useAppStore();

  const [newTabMenuOpen, setNewTabMenuOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<{ id: string, x: number, y: number } | null>(null);
  const [plusMenuAnchor, setPlusMenuAnchor] = useState<'left' | 'right'>('left');
  const plusButtonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent | TouchEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest('.app-dropdown-menu') && !target.closest('.app-menu-trigger')) {
        setHamburgerMenuOpen(false);
        setTestsMenuOpen(false);
        setNewTabMenuOpen(false);
        setContextMenu(null);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('touchstart', handleClickOutside);
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('touchstart', handleClickOutside);
    };
  }, [setHamburgerMenuOpen]);

  return (
    <>
      <div className={mergeClasses(styles.bar, !autoHideTabs && styles.barSolid)}>
        {autoHideTabs && (
          <div className={styles.barMicaBg}>
            <div className={`${styles.barMicaSky} sky-container`}>
              <div className="cloud-layer" />
            </div>
            <div className={`${styles.barMicaPanel} mica-panel`} />
          </div>
        )}

        {/* Hamburger */}
        <div className={styles.hamburgerArea}>
          <button
            onClick={() => { setHamburgerMenuOpen(!hamburgerMenuOpen); setNewTabMenuOpen(false); }}
            className={mergeClasses(
              'app-menu-trigger',
              styles.hamburgerBtn,
              hamburgerMenuOpen && styles.hamburgerBtnActive,
              !autoHideTabs && styles.hamburgerBtnSolidBorder
            )}
          >
            <Menu size={22} style={{ color: autoHideTabs ? '#e5e7eb' : '#d1d5db' }} />
          </button>
          <AnimatePresence>
            {hamburgerMenuOpen && <HamburgerMenuContent key="hamburger" />}
          </AnimatePresence>
        </div>

        {/* Tabs */}
        <Reorder.Group
          axis="x"
          values={tabs}
          onReorder={setTabs}
          className={mergeClasses(styles.tabGroup, autoHideTabs ? styles.tabGroupMica : undefined)}
          style={{ WebkitMaskImage: autoHideTabs ? 'linear-gradient(to right, transparent, black 16px, black calc(100% - 16px), transparent)' : 'none' }}
        >
          {tabs.map(tab => {
            const isActive = activeTabId === tab.id;
            return (
              <Reorder.Item
                key={tab.id}
                value={tab}
                onClick={() => setActiveTab(tab.id)}
                onContextMenu={(e) => { e.preventDefault(); setContextMenu({ id: tab.id, x: e.clientX, y: e.clientY }); }}
                dragListener={true}
                className={mergeClasses(
                  styles.tabItem,
                  autoHideTabs ? styles.tabItemMica : styles.tabItemStd,
                  isActive
                    ? (autoHideTabs ? styles.tabActiveMica : styles.tabActiveStd)
                    : (autoHideTabs ? styles.tabInactiveMica : styles.tabInactiveStd)
                )}
              >
                <div className={styles.tabIcon} style={{ color: isActive ? '#ffffff' : (autoHideTabs ? '#d1d5db' : '#666') }}>
                  {tab.type === 'xterm'     && <TerminalSquare strokeWidth={3} size={16} style={{ color: '#a78bfa' }} />}
                  {tab.type === 'terminal'  && <span style={{ fontWeight: 900, color: '#ec4899', fontSize: '18px' }}>&gt;_</span>}
                  {tab.type === 'notepad'   && <FileText strokeWidth={3} size={16} style={{ color: autoHideTabs ? '#93c5fd' : '#0078D7' }} />}
                  {tab.type === 'explorer'  && <FolderTree strokeWidth={3} size={16} style={{ color: autoHideTabs ? '#fde047' : '#FCE166' }} />}
                  {tab.type === 'colors'    && <Settings2 strokeWidth={3} size={16} style={{ color: autoHideTabs ? '#fca5a5' : '#A31515' }} />}
                  {tab.type === 'settings'  && <Settings2 strokeWidth={3} size={16} style={{ color: autoHideTabs ? '#e5e7eb' : '#4b5563' }} />}
                  {tab.type === 'debug'     && <Activity strokeWidth={3} size={16} style={{ color: '#60cdff' }} />}
                  {tab.type === 'applet' && tab.title === 'nocap' && <Clapperboard strokeWidth={3} size={16} style={{ color: '#ffffff' }} />}
                  {tab.type === 'applet' && tab.title !== 'nocap' && <LayoutTemplate strokeWidth={3} size={16} style={{ color: '#ff3366' }} />}
                </div>
                <div
                  className={`text-shadow-mica ${styles.tabTitle}`}
                  style={{ color: isActive ? '#ffffff' : 'rgba(255,255,255,0.8)', display: undefined }}
                >
                  {tab.title}
                </div>
              </Reorder.Item>
            );
          })}
        </Reorder.Group>

        <div className={styles.spacer} />

        {/* Add Tab */}
        <div className={styles.addArea}>
          <button
            ref={plusButtonRef}
            onClick={(e) => {
              if (plusButtonRef.current) {
                const rect = plusButtonRef.current.getBoundingClientRect();
                setPlusMenuAnchor((window.innerWidth - rect.right < 224 && rect.left > 224) ? 'right' : 'left');
              }
              setNewTabMenuOpen(!newTabMenuOpen);
              setHamburgerMenuOpen(false);
            }}
            className={mergeClasses('app-menu-trigger', styles.addBtn, autoHideTabs ? styles.addBtnMica : styles.addBtnSolid)}
          >
            <Plus size={20} />
          </button>

          <AnimatePresence>
            {newTabMenuOpen && (
              <motion.div
                key="new-tab-menu"
                initial={{ opacity: 0, scale: 0.95, y: -5 }}
                animate={{ opacity: 1, scale: 1, y: 0 }}
                exit={{ opacity: 0, scale: 0.95, y: -5 }}
                transition={{ duration: 0.15 }}
                className={mergeClasses(
                  'app-dropdown-menu mica-panel mica-border text-shadow-mica',
                  styles.dropdown,
                  plusMenuAnchor === 'right' ? styles.dropdownRight : styles.dropdownLeft,
                  autoHideTabs ? styles.dropdownTopFull : styles.dropdownTop56
                )}
              >
                <div className={styles.sectionHeader}>Terminals</div>
                <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setNewTabMenuOpen(false); }} className={styles.dropBtn}>
                  <span style={{ fontWeight: 900, color: '#ec4899', fontSize: '18px', width: '20px', textAlign: 'center' }}>&gt;_</span> Canvas Host
                </button>
                <button onClick={() => { addTab({ id: 'xterm-'+Date.now(), type: 'xterm', title: 'xterm.js' }); setNewTabMenuOpen(false); }} className={styles.dropBtn}>
                  <TerminalSquare size={16} style={{ color: '#a78bfa', width: '20px' }} /> xterm.js (Legacy)
                </button>

                <div className={styles.sectionHeader} style={{ marginTop: '4px' }}>Apps</div>
                <button onClick={() => { addTab({ id: 'explorer-'+Date.now(), type: 'explorer', title: 'Files' }); setNewTabMenuOpen(false); }} className={styles.dropBtn}>
                  <FolderTree size={16} style={{ color: '#fbbf24', width: '20px' }} /> File Explorer
                </button>
                <button onClick={() => { addTab({ id: 'editor-'+Date.now(), type: 'notepad', title: 'Editor' }); setNewTabMenuOpen(false); }} className={styles.dropBtn}>
                  <FileText size={16} style={{ color: '#60a5fa', width: '20px' }} /> Text Editor
                </button>

                {(appConfig?.profiles.list.filter(p => p.type === 'applet' && !p.hidden) || []).length > 0 && (
                  <>
                    <div className={styles.sectionHeader} style={{ marginTop: '4px' }}>PWAs</div>
                    {appConfig?.profiles.list.filter(p => p.type === 'applet' && !p.hidden).map(profile => (
                      <button key={profile.guid} onClick={() => { addTab({ id: `${profile.guid}-${Date.now()}`, type: profile.type as any, title: profile.name, path: profile.path }); setNewTabMenuOpen(false); }} className={styles.dropBtn}>
                        {profile.name === 'nocap' ? <Clapperboard size={16} style={{ color: '#ffffff', width: '20px' }} /> : <LayoutTemplate size={16} style={{ color: '#ff3366', width: '20px' }} />} {profile.name}
                      </button>
                    ))}
                  </>
                )}
              </motion.div>
            )}
          </AnimatePresence>
        </div>

        {/* Close Button */}
        <div className={styles.closeArea}>
          <button
            onClick={() => { if (activeTabId) removeTab(activeTabId); }}
            className={mergeClasses(styles.closeBtn, autoHideTabs ? styles.closeBtnMicaHover : undefined)}
          >
            <X size={20} style={{ color: autoHideTabs ? '#9ca3af' : '#6b7280', transition: 'color 200ms' }} />
          </button>
        </div>
      </div>
    </>
  );
}
