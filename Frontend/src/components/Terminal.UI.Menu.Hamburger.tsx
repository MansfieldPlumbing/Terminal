import React, { useState, useEffect } from 'react';
import { makeStyles } from '@fluentui/react-components';
import { motion, AnimatePresence } from 'motion/react';
import { ChevronRight, ChevronLeft, Settings2, LayoutTemplate, TerminalSquare, FileText, FolderTree, Activity } from 'lucide-react';
import { useAppStore } from '../System.Store';

const useStyles = makeStyles({
  menu: {
    display: 'flex',
    flexDirection: 'column',
  },
  btn: {
    width: '100%',
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '8px',
    paddingBottom: '8px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    textAlign: 'left',
    fontWeight: '500',
    border: 'none',
    backgroundColor: 'transparent',
    cursor: 'pointer',
    color: 'inherit',
    transition: 'all 300ms ease-out',
    ':active': {
      backgroundColor: 'rgba(255,255,255,0.15)',
      transform: 'scale(0.98)',
      transition: 'none',
    },
  },
  btnGap: {
    width: '100%',
    paddingLeft: '20px',
    paddingRight: '20px',
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
    ':active': {
      backgroundColor: 'rgba(255,255,255,0.15)',
      transform: 'scale(0.98)',
      transition: 'none',
    },
  },
  btnBack: {
    width: '100%',
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '8px',
    paddingBottom: '12px',
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    textAlign: 'left',
    fontWeight: '600',
    fontSize: '12px',
    borderBottom: '1px solid rgba(255,255,255,0.1)',
    marginBottom: '4px',
    border: 'none',
    backgroundColor: 'transparent',
    cursor: 'pointer',
    color: 'inherit',
    transition: 'all 300ms ease-out',
    ':active': {
      backgroundColor: 'rgba(255,255,255,0.15)',
      transform: 'scale(0.98)',
      transition: 'none',
    },
  },
  btnRed: {
    width: '100%',
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '8px',
    paddingBottom: '8px',
    textAlign: 'left',
    fontWeight: '500',
    border: 'none',
    backgroundColor: 'transparent',
    cursor: 'pointer',
    color: '#fca5a5',
    transition: 'all 300ms ease-out',
    ':active': {
      backgroundColor: 'rgba(255,255,255,0.15)',
      transform: 'scale(0.98)',
      transition: 'none',
    },
  },
  divider: {
    height: '1px',
    backgroundColor: 'rgba(255,255,255,0.1)',
    margin: '4px 12px',
  },
  sectionLabel: {
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '12px',
    paddingBottom: '4px',
    fontSize: '10px',
    textTransform: 'uppercase' as const,
    fontWeight: 'bold',
    color: 'rgba(255,255,255,0.4)',
    letterSpacing: '0.1em',
  },
  noItems: {
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '8px',
    paddingBottom: '8px',
    fontSize: '14px',
    color: 'rgba(107,114,128,1)',
    fontStyle: 'italic',
  },
  scrollable: {
    maxHeight: '300px',
    overflowY: 'auto',
  },
});

export default function HamburgerMenuContent() {
  const styles = useStyles();
  const {
    tabs, activeTabId, addTab, removeTab,
    setHamburgerMenuOpen, autoHideTabs,
    commandPaletteVisible, setCommandPaletteVisible,
    thumbstickVisible, setThumbstickVisible,
    appConfig
  } = useAppStore();

  const [activeSubmenu, setActiveSubmenu] = useState<'root' | 'file' | 'edit' | 'view' | 'applets' | 'apps'>('root');
  const activeTab = tabs.find(t => t.id === activeTabId);

  useEffect(() => { setActiveSubmenu('root'); }, [activeTabId]);

  const emitAppletAction = (action: string) => {
    if (activeTabId) window.dispatchEvent(new CustomEvent('app-menu-action', { detail: { action, tabId: activeTabId } }));
  };

  const renderRoot = () => (
    <motion.div key="root" initial={{ x: -20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: -20, opacity: 0 }} className={`${styles.menu} text-shadow-mica`}>
      <button onClick={() => setActiveSubmenu('file')} className={styles.btn}>File <ChevronRight size={16} /></button>
      <button onClick={() => setActiveSubmenu('edit')} className={styles.btn}>Edit <ChevronRight size={16} /></button>
      <button onClick={() => setActiveSubmenu('view')} className={styles.btn}>View <ChevronRight size={16} /></button>
      <button onClick={() => setActiveSubmenu('apps')} className={styles.btn}>Apps <ChevronRight size={16} /></button>
      <button onClick={() => setActiveSubmenu('applets')} className={styles.btn}>PWAs <ChevronRight size={16} /></button>
      <div className={styles.divider} />
      <div className={styles.sectionLabel}>System</div>
      <button onClick={() => { addTab({ id: 'settings-'+Date.now(), type: 'settings', title: 'Settings' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <Settings2 size={16} /> Settings
      </button>
    </motion.div>
  );

  const renderAppsMenu = () => (
    <motion.div key="apps" initial={{ x: 20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: 20, opacity: 0 }} className={`${styles.menu} text-shadow-mica`}>
      <button onClick={() => setActiveSubmenu('root')} className={styles.btnBack}><ChevronLeft size={16} /> Back</button>
      <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <span style={{ fontWeight: 900, color: '#ec4899', fontSize: '18px', width: '20px', textAlign: 'center' }}>&gt;_</span> Canvas Host
      </button>
      <button onClick={() => { addTab({ id: 'xterm-'+Date.now(), type: 'xterm', title: 'xterm.js' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <TerminalSquare size={16} style={{ color: '#a78bfa', width: '20px' }} /> xterm.js (Legacy)
      </button>
      <button onClick={() => { addTab({ id: 'explorer-'+Date.now(), type: 'explorer', title: 'Files' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <FolderTree size={16} style={{ color: '#fbbf24', width: '20px' }} /> File Explorer
      </button>
      <button onClick={() => { addTab({ id: 'editor-'+Date.now(), type: 'notepad', title: 'Editor' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <FileText size={16} style={{ color: '#60a5fa', width: '20px' }} /> Text Editor
      </button>
      <button onClick={() => { addTab({ id: 'debug-'+Date.now(), type: 'debug', title: 'Diagnostics' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <Activity size={16} style={{ color: '#60cdff', width: '20px' }} /> Diagnostics
      </button>
      <button onClick={() => { addTab({ id: 'colors-'+Date.now(), type: 'colors', title: 'Colors' }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
        <Settings2 size={16} style={{ color: '#f87171', width: '20px' }} /> Color Schemes
      </button>
    </motion.div>
  );

  const renderAppletsMenu = () => {
    const appletProfiles = appConfig?.profiles.list.filter(p => p.type === 'applet' && !p.hidden) || [];
    return (
      <motion.div key="applets" initial={{ x: 20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: 20, opacity: 0 }} className={`${styles.menu} text-shadow-mica`}>
        <button onClick={() => setActiveSubmenu('root')} className={styles.btnBack}><ChevronLeft size={16} /> Back</button>
        {appletProfiles.length === 0 ? (
          <div className={styles.noItems}>No PWAs found</div>
        ) : (
          <div className={styles.scrollable} style={{ scrollbarWidth: 'none' }}>
            {appletProfiles.map(profile => (
              <button key={profile.guid} onClick={() => { addTab({ id: `${profile.guid}-${Date.now()}`, type: profile.type as any, title: profile.name, path: profile.path }); setHamburgerMenuOpen(false); }} className={styles.btnGap}>
                <LayoutTemplate size={16} style={{ color: '#ff3366', flexShrink: 0 }} />
                {profile.name}
              </button>
            ))}
          </div>
        )}
      </motion.div>
    );
  };

  const renderFileMenu = () => (
    <motion.div key="file" initial={{ x: 20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: 20, opacity: 0 }} className={`${styles.menu} text-shadow-mica`}>
      <button onClick={() => setActiveSubmenu('root')} className={styles.btnBack}><ChevronLeft size={16} /> Back</button>
      <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Run</button>
      {(!activeTab || activeTab?.type === 'notepad') && (
        <button onClick={() => {
          const explorerTab = tabs.find(t => t.type === 'explorer');
          let targetId = '';
          if (explorerTab) {
            targetId = explorerTab.id;
            useAppStore.getState().setActiveTab(targetId);
            window.dispatchEvent(new CustomEvent('app-menu-action', { detail: { action: 'new-file', tabId: targetId } }));
          } else {
            targetId = 'explorer-'+Date.now();
            addTab({ id: targetId, type: 'explorer', title: 'Files' });
            setTimeout(() => window.dispatchEvent(new CustomEvent('app-menu-action', { detail: { action: 'new-file', tabId: targetId } })), 100);
          }
          setHamburgerMenuOpen(false);
        }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>New File</button>
      )}
      {activeTab?.type === 'notepad' && (
        <>
          <button onClick={() => { emitAppletAction('open'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Open</button>
          <button onClick={() => { emitAppletAction('save'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Save</button>
        </>
      )}
      {activeTab?.type === 'explorer' && (
        <>
          <button onClick={() => { emitAppletAction('new-folder'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>New Folder</button>
          <button onClick={() => { emitAppletAction('new-file'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>New File</button>
        </>
      )}
      {activeTab?.type === 'terminal' && (
        <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>New PWSH</button>
      )}
      {activeTab && <button onClick={() => { removeTab(activeTab.id); setHamburgerMenuOpen(false); }} className={styles.btnRed}>Close Tab</button>}
    </motion.div>
  );

  const renderEditMenu = () => (
    <motion.div key="edit" initial={{ x: 20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: 20, opacity: 0 }} className={`${styles.menu} text-shadow-mica`}>
      <button onClick={() => setActiveSubmenu('root')} className={styles.btnBack}><ChevronLeft size={16} /> Back</button>
      {activeTab?.type === 'notepad' ? (
        <>
          <button onClick={() => { emitAppletAction('undo'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Undo</button>
          <button onClick={() => { emitAppletAction('redo'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Redo</button>
          <div className={styles.divider} />
          <button onClick={() => { emitAppletAction('cut'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Cut</button>
          <button onClick={() => { emitAppletAction('copy'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Copy</button>
          <button onClick={() => { emitAppletAction('paste'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Paste</button>
          <div className={styles.divider} />
          <button onClick={() => { emitAppletAction('select-all'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Select All</button>
        </>
      ) : activeTab?.type === 'terminal' ? (
        <>
          <button onClick={() => { emitAppletAction('copy'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Copy</button>
          <button onClick={() => { emitAppletAction('paste'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Paste</button>
        </>
      ) : activeTab?.type === 'explorer' ? (
        <button onClick={() => { emitAppletAction('copy-path'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Copy Path</button>
      ) : (
        <div className={styles.noItems}>No edit options</div>
      )}
    </motion.div>
  );

  const renderViewMenu = () => (
    <motion.div key="view" initial={{ x: 20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: 20, opacity: 0 }} className={`${styles.menu} text-shadow-mica`}>
      <button onClick={() => setActiveSubmenu('root')} className={styles.btnBack}><ChevronLeft size={16} /> Back</button>
      {activeTab?.type === 'notepad' && (
        <>
          <button onClick={() => { emitAppletAction('toggle-word-wrap'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Toggle Word Wrap</button>
          <button onClick={() => { emitAppletAction('toggle-minimap'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Toggle Minimap</button>
          <div className={styles.divider} />
        </>
      )}
      {activeTab?.type === 'terminal' && (
        <>
          <button onClick={() => { useAppStore.getState().setShowInputBar(!useAppStore.getState().showInputBar); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Toggle Command Bar</button>
          <button onClick={() => { emitAppletAction('clear-terminal'); setHamburgerMenuOpen(false); }} className={styles.btn} style={{ justifyContent: 'flex-start' }}>Clear Output</button>
          <div className={styles.divider} />
        </>
      )}
    </motion.div>
  );

  return (
    <motion.div
      initial={{ opacity: 0, scale: 0.95, y: -5 }}
      animate={{ opacity: 1, scale: 1, y: 0 }}
      exit={{ opacity: 0, scale: 0.95, y: -5 }}
      transition={{ duration: 0.15 }}
      className="app-dropdown-menu mica-panel mica-border"
      style={{
        position: 'absolute',
        left: 0,
        width: '256px',
        boxShadow: '0 25px 50px -12px rgba(0,0,0,0.5)',
        zIndex: 50,
        fontSize: '14px',
        fontFamily: 'sans-serif',
        overflow: 'hidden',
        top: autoHideTabs ? '100%' : '56px',
        marginTop: autoHideTabs ? '8px' : 0,
        borderRadius: autoHideTabs ? '12px' : '0 12px 12px 12px',
      }}
    >
      <div style={{ position: 'relative', width: '100%', paddingTop: '8px', paddingBottom: '8px' }}>
        <AnimatePresence mode="wait">
          {activeSubmenu === 'root' && renderRoot()}
          {activeSubmenu === 'file' && renderFileMenu()}
          {activeSubmenu === 'edit' && renderEditMenu()}
          {activeSubmenu === 'view' && renderViewMenu()}
          {activeSubmenu === 'apps' && renderAppsMenu()}
          {activeSubmenu === 'applets' && renderAppletsMenu()}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}
