import React, { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { ChevronRight, ChevronLeft, Settings2 } from 'lucide-react';
import { useAppStore } from '../store';
import { cn } from '../lib/utils';

export default function HamburgerMenuContent() {
  const {
    tabs, activeTabId, addTab, removeTab,
    setHamburgerMenuOpen,
    autoHideTabs,
    commandPaletteVisible, setCommandPaletteVisible,
    thumbstickVisible, setThumbstickVisible
  } = useAppStore();

  const [activeSubmenu, setActiveSubmenu] = useState<'root' | 'file' | 'edit' | 'view' | 'settings'>('root');
  const activeTab = tabs.find(t => t.id === activeTabId);

  // Reset menu position when reopened or tab changes
  useEffect(() => {
    setActiveSubmenu('root');
  }, [activeTabId]);

  const emitAppletAction = (action: string) => {
    if (activeTabId) {
      window.dispatchEvent(new CustomEvent('app-menu-action', { detail: { action, tabId: activeTabId } }));
    }
  };

  const renderRoot = () => (
    <motion.div
      key="root"
      initial={{ x: -20, opacity: 0 }}
      animate={{ x: 0, opacity: 1 }}
      exit={{ x: -20, opacity: 0 }}
      className="flex flex-col"
    >
      <button onClick={() => setActiveSubmenu('file')} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center justify-between text-shadow-mica text-left font-medium">
        File <ChevronRight size={16} />
      </button>
      <button onClick={() => setActiveSubmenu('edit')} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center justify-between text-shadow-mica text-left font-medium">
        Edit <ChevronRight size={16} />
      </button>
      <button onClick={() => setActiveSubmenu('view')} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center justify-between text-shadow-mica text-left font-medium">
        View <ChevronRight size={16} />
      </button>
      <button onClick={() => setActiveSubmenu('settings')} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center justify-between text-shadow-mica text-left font-medium">
        Settings <ChevronRight size={16} />
      </button>
    </motion.div>
  );

  const renderFileMenu = () => {
    return (
      <motion.div
        key="file"
        initial={{ x: 20, opacity: 0 }}
        animate={{ x: 0, opacity: 1 }}
        exit={{ x: 20, opacity: 0 }}
        className="flex flex-col"
      >
        <button onClick={() => setActiveSubmenu('root')} className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-2 text-shadow-mica text-left font-semibold text-xs border-b border-white/10 pb-3 mb-1">
          <ChevronLeft size={16} /> Back
        </button>

        <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center text-shadow-mica text-left font-medium">
          Run
        </button>

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
          }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
            New File
          </button>
        )}

        {activeTab?.type === 'notepad' && (
          <>
            <button onClick={() => { emitAppletAction('open'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Open
            </button>
            <button onClick={() => { emitAppletAction('save'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Save
            </button>
          </>
        )}
        {activeTab?.type === 'explorer' && (
          <>
            <button onClick={() => { emitAppletAction('new-folder'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              New Folder
            </button>
            <button onClick={() => { emitAppletAction('new-file'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              New File
            </button>
          </>
        )}
        {activeTab?.type === 'terminal' && (
          <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center text-shadow-mica text-left font-medium">
             New Terminal
          </button>
        )}
        {activeTab && (
          <button onClick={() => { removeTab(activeTab.id); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-red-300 text-left font-medium">
            Close Tab
          </button>
        )}
      </motion.div>
    );
  };

  const renderEditMenu = () => {
    return (
      <motion.div
        key="edit"
        initial={{ x: 20, opacity: 0 }}
        animate={{ x: 0, opacity: 1 }}
        exit={{ x: 20, opacity: 0 }}
        className="flex flex-col"
      >
        <button onClick={() => setActiveSubmenu('root')} className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-2 text-shadow-mica text-left font-semibold text-xs border-b border-white/10 pb-3 mb-1">
          <ChevronLeft size={16} /> Back
        </button>
        {activeTab?.type === 'notepad' ? (
          <>
            <button onClick={() => { emitAppletAction('undo'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Undo
            </button>
            <button onClick={() => { emitAppletAction('redo'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Redo
            </button>
            <div className="h-px bg-white/10 my-1 mx-3" />
            <button onClick={() => { emitAppletAction('cut'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Cut
            </button>
            <button onClick={() => { emitAppletAction('copy'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Copy
            </button>
            <button onClick={() => { emitAppletAction('paste'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Paste
            </button>
            <div className="h-px bg-white/10 my-1 mx-3" />
            <button onClick={() => { emitAppletAction('select-all'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Select All
            </button>
          </>
        ) : activeTab?.type === 'terminal' ? (
          <>
            <button onClick={() => { emitAppletAction('copy'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Copy
            </button>
            <button onClick={() => { emitAppletAction('paste'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Paste
            </button>
          </>
        ) : activeTab?.type === 'explorer' ? (
          <>
             <button onClick={() => { emitAppletAction('copy-path'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Copy Path
            </button>
          </>
        ) : (
          <div className="px-5 py-3 text-sm text-gray-500 italic">No edit options</div>
        )}
      </motion.div>
    );
  };

  const renderViewMenu = () => {
    return (
      <motion.div
        key="view"
        initial={{ x: 20, opacity: 0 }}
        animate={{ x: 0, opacity: 1 }}
        exit={{ x: 20, opacity: 0 }}
        className="flex flex-col"
      >
        <button onClick={() => setActiveSubmenu('root')} className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-2 text-shadow-mica text-left font-semibold text-xs border-b border-white/10 pb-3 mb-1">
          <ChevronLeft size={16} /> Back
        </button>
        {activeTab?.type === 'notepad' && (
          <>
            <button onClick={() => { emitAppletAction('toggle-word-wrap'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Toggle Word Wrap
            </button>
            <button onClick={() => { emitAppletAction('toggle-minimap'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Toggle Minimap
            </button>
            <div className="h-px bg-white/10 my-1 mx-3" />
          </>
        )}
        {activeTab?.type === 'terminal' && (
          <>
            <button onClick={() => { emitAppletAction('clear-terminal'); setHamburgerMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex flex-col text-shadow-mica text-left font-medium">
              Clear Terminal
            </button>
            <div className="h-px bg-white/10 my-1 mx-3" />
          </>
        )}
        <div className="px-4 py-3 text-[11px] font-bold text-shadow-mica uppercase tracking-widest flex items-center justify-between pointer-events-none mt-1">
          Command Palette
          <div className={cn("w-8 h-4 rounded-full relative pointer-events-auto cursor-pointer", commandPaletteVisible ? "bg-blue-600" : "bg-white/20")} onClick={(e) => { e.stopPropagation(); setCommandPaletteVisible(!commandPaletteVisible); }}>
             <div className={cn("absolute top-0.5 bottom-0.5 w-3 bg-white rounded-full transition-all shadow-md", commandPaletteVisible ? "left-4" : "left-0.5")} />
          </div>
        </div>
        <div className="px-4 py-3 text-[11px] font-bold text-shadow-mica uppercase tracking-widest flex items-center justify-between pointer-events-none">
          Virtual Joystick
          <div className={cn("w-8 h-4 rounded-full relative pointer-events-auto cursor-pointer", thumbstickVisible ? "bg-blue-600" : "bg-white/20")} onClick={(e) => { e.stopPropagation(); setThumbstickVisible(!thumbstickVisible); }}>
             <div className={cn("absolute top-0.5 bottom-0.5 w-3 bg-white rounded-full transition-all shadow-md", thumbstickVisible ? "left-4" : "left-0.5")} />
          </div>
        </div>
      </motion.div>
    );
  };

  const renderSettingsMenu = () => {
    return (
      <motion.div
        key="settings"
        initial={{ x: 20, opacity: 0 }}
        animate={{ x: 0, opacity: 1 }}
        exit={{ x: 20, opacity: 0 }}
        className="flex flex-col"
      >
        <button onClick={() => setActiveSubmenu('root')} className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-2 text-shadow-mica text-left font-semibold text-xs border-b border-white/10 pb-3 mb-1">
          <ChevronLeft size={16} /> Back
        </button>
        <button 
          className="px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 cursor-pointer text-shadow-mica font-medium flex items-center gap-3 w-full text-left"
          onClick={() => {
            addTab({ id: 'settings-'+Date.now(), type: 'settings', title: 'Settings' });
            setHamburgerMenuOpen(false);
          }}
        >
          <Settings2 size={18} className="text-shadow-mica" /> Global Settings
        </button>
      </motion.div>
    );
  };

  return (
    <motion.div
       initial={{ opacity: 0, scale: 0.95, y: -5 }}
       animate={{ opacity: 1, scale: 1, y: 0 }}
       exit={{ opacity: 0, scale: 0.95, y: -5 }}
       transition={{ duration: 0.15 }}
       className={cn(
         "app-dropdown-menu absolute left-0 w-64 mica-panel mica-border shadow-2xl z-50 text-sm font-sans text-shadow-mica overflow-hidden",
         autoHideTabs ? "top-full mt-2 rounded-xl" : "top-[56px] rounded-b-xl rounded-tr-xl"
       )}
    >
      <div className="relative w-full py-2">
        <AnimatePresence mode="wait">
          {activeSubmenu === 'root' && renderRoot()}
          {activeSubmenu === 'file' && renderFileMenu()}
          {activeSubmenu === 'edit' && renderEditMenu()}
          {activeSubmenu === 'view' && renderViewMenu()}
          {activeSubmenu === 'settings' && renderSettingsMenu()}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}
