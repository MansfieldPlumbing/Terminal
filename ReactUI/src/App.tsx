import React, { useEffect, useState, useRef } from 'react';
import { motion, AnimatePresence, Reorder } from 'motion/react';
import { useAppStore } from './store';
import TerminalEmulator from './components/TerminalEmulator';
import Thumbstick from './components/Thumbstick';
import { Plus, Menu, LayoutTemplate, FileText, FolderTree, Settings2, X } from 'lucide-react';
import { minimizeAppFromBridge } from './lib/pwshBridge';
import Notifications from './components/Notifications';
import FloatingCommandPalette from './components/FloatingCommandPalette';
import NativeNotepad from './components/NativeNotepad';
import NativeExplorer from './components/NativeExplorer';
import SettingsTab from './components/SettingsTab';
import HamburgerMenuContent from './components/HamburgerMenuContent';
import { cn } from './lib/utils';

export default function App() {
  const { 
    tabs, activeTabId, setActiveTab, addTab, removeTab,
    commandPaletteVisible, setCommandPaletteVisible,
    floatingCommandPaletteOpen, setFloatingCommandPaletteOpen,
    hamburgerMenuOpen, setHamburgerMenuOpen,
    thumbstickVisible, setThumbstickVisible,
    autoHideTabs, setAutoHideTabs,
    micaOpacity, micaBlur
  } = useAppStore();

  const [tabsVisible, setTabsVisible] = useState(false);
  const [newTabMenuOpen, setNewTabMenuOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<{ id: string, x: number, y: number } | null>(null);

  const [plusMenuAnchor, setPlusMenuAnchor] = useState<'left' | 'right'>('left');
  const plusButtonRef = useRef<HTMLButtonElement>(null);

  const {
    closeTabsToRight,
    closeOtherTabs,
    setTabs
  } = useAppStore();

  useEffect(() => {
    document.documentElement.style.setProperty('--mica-opacity', micaOpacity.toString());
    document.documentElement.style.setProperty('--mica-blur', `${micaBlur}px`);
  }, [micaOpacity, micaBlur]);

  useEffect(() => {
    let timeout: ReturnType<typeof setTimeout>;
    if (autoHideTabs && tabsVisible) {
      timeout = setTimeout(() => setTabsVisible(false), 3000);
    }
    return () => clearTimeout(timeout);
  }, [autoHideTabs, tabsVisible]);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent | TouchEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest('.app-dropdown-menu') && !target.closest('.app-menu-trigger')) {
        setHamburgerMenuOpen(false);
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
    <div className="fixed inset-0 w-full h-full bg-[#000] overflow-hidden font-sans flex flex-col">
      {/* Main Container */}
      <div className="w-full h-full overflow-hidden relative shadow-md bg-[#09090b] select-none isolate flex flex-col">
        
        {/* Main Terminal Container */}
        <div className="flex-1 w-full h-full overflow-hidden bg-[#012456] relative font-mono flex flex-col pointer-events-auto">

          {/* Trigger area to show tabs when auto-hidden */}
          {autoHideTabs && (
             <div 
               className="absolute top-0 left-0 right-0 h-12 z-[400]"
               onMouseEnter={() => setTabsVisible(true)}
               onClick={() => setTabsVisible(true)}
             />
          )}

          {/* Windows Terminal Top Bar (Tabs) */}
          <motion.div 
             initial={false}
             animate={{
                y: (!autoHideTabs || tabsVisible) ? 0 : -60,
                opacity: (!autoHideTabs || tabsVisible) ? 1 : 0
             }}
             transition={{ duration: 0.2 }}
             className={cn(
               "absolute top-0 left-0 right-0 h-[56px] flex items-center shrink-0 select-none z-[400]",
               !autoHideTabs && "bg-[#1C1C1C] border-b border-black"
             )}
          >
            {autoHideTabs && (
              <div className="absolute inset-0 mica-panel border-b border-white/10 shadow-xl pointer-events-none -z-10" />
            )}
            
            {/* Hamburger Menu (Applets/Settings) */}
            <div className="relative h-full flex items-center shrink-0">
               <button 
                 onClick={() => { setHamburgerMenuOpen(!hamburgerMenuOpen); setNewTabMenuOpen(false); }}
                 className={cn(
                   "app-menu-trigger h-full px-4 flex items-center justify-center", 
                   hamburgerMenuOpen && (autoHideTabs ? "bg-white/10" : "bg-black/10"),
                   !hamburgerMenuOpen && (autoHideTabs ? "active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0" : "active:bg-white/10 active:scale-[0.98] transition-all duration-300 ease-out active:duration-0"),
                   !autoHideTabs && "border-r border-[#00000050]"
                 )}
               >
                  <Menu size={22} className={autoHideTabs ? "text-gray-200" : "text-gray-300"} />
               </button>

               <AnimatePresence>
                 {hamburgerMenuOpen && (
                   <>
                     <HamburgerMenuContent />
                   </>
                 )}
               </AnimatePresence>
            </div>

            <Reorder.Group 
              axis="x" 
              values={tabs} 
              onReorder={setTabs} 
              className="flex h-full overflow-x-auto hide-scrollbar scroll-smooth snap-x touch-pan-x shrink"
            >
              {/* Tabs */}
              {tabs.map(tab => (
                <Reorder.Item 
                  key={tab.id}
                  value={tab}
                  onClick={() => setActiveTab(tab.id)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    setContextMenu({ id: tab.id, x: e.clientX, y: e.clientY });
                  }}
                  dragListener={true}
                  className={cn(
                    "flex items-center gap-3 h-full px-3 md:px-4 min-w-[56px] md:min-w-[140px] max-w-[120px] md:max-w-[200px] text-sm font-sans shadow-sm cursor-pointer flex-shrink-0 group snap-start select-none",
                    activeTabId === tab.id 
                      ? (autoHideTabs ? "bg-white/10 text-white border-b-2 border-b-blue-500" : "bg-[#2D2D2D] text-[#eeedf0] border-t-[3px] border-t-[#0078d4]") 
                      : (autoHideTabs ? "active:bg-[rgba(255,255,255,0.1)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-gray-300" : "bg-[#1C1C1C] hover:bg-[#2A2A2A] active:bg-[#333] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-[#999] border-r border-[#00000050]")
                  )}
                >
                  <div className={cn("w-5 flex justify-center items-center shrink-0 pointer-events-none", activeTabId === tab.id ? "text-[#eeedf0]" : (autoHideTabs ? "text-gray-400" : "text-[#666]"))}>
                    {tab.type === 'terminal' && <span className="font-bold text-pink-500">&gt;_</span>}
                    {tab.type === 'notepad' && <FileText size={16} className={autoHideTabs ? "text-blue-400" : "text-[#0078D7]"} />}
                    {tab.type === 'explorer' && <FolderTree size={16} className={autoHideTabs ? "text-yellow-400" : "text-[#FCE166]"} />}
                    {tab.type === 'colors' && <Settings2 size={16} className={autoHideTabs ? "text-red-400" : "text-[#A31515]"} />}
                    {tab.type === 'settings' && <Settings2 size={16} className={autoHideTabs ? "text-gray-400" : "text-gray-600"} />}
                    {tab.type === 'applet' && <LayoutTemplate size={16} className="text-[#ff3366]" />}
                  </div>
                  
                  <div className="font-semibold truncate flex-1 text-[13px] hidden md:block pointer-events-none">{tab.title}</div>
                </Reorder.Item>
              ))}
            </Reorder.Group>

            {/* Add Tab Button inline with tabs */}
            <div className="relative h-full flex items-center shrink-0 border-l border-white/5">
              <button 
                ref={plusButtonRef}
                onClick={(e) => { 
                  // Calculate available space to the right
                  if (plusButtonRef.current) {
                     const rect = plusButtonRef.current.getBoundingClientRect();
                     // 224px is w-56
                     if (window.innerWidth - rect.right < 224 && rect.left > 224) {
                       setPlusMenuAnchor('right');
                     } else {
                       setPlusMenuAnchor('left');
                     }
                  }
                  setNewTabMenuOpen(!newTabMenuOpen); 
                  setHamburgerMenuOpen(false); 
                }}
                className={cn(
                  "app-menu-trigger h-full px-4 flex items-center justify-center flex-shrink-0", 
                  autoHideTabs ? "active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-gray-300" : "active:bg-white/10 active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 bg-[#1C1C1C] text-gray-400"
                )}
              >
                <Plus size={20} />
              </button>
              <AnimatePresence>
                {newTabMenuOpen && (
                  <>
                    <motion.div
                      initial={{ opacity: 0, scale: 0.95, y: -5 }}
                      animate={{ opacity: 1, scale: 1, y: 0 }}
                      exit={{ opacity: 0, scale: 0.95, y: -5 }}
                      transition={{ duration: 0.15 }}
                      className={cn(
                        "app-dropdown-menu absolute w-56 mica-panel mica-border shadow-2xl py-2 z-50 text-sm font-sans text-shadow-mica",
                        plusMenuAnchor === 'right' ? 'right-0' : 'left-0',
                        autoHideTabs ? "top-full mt-2 rounded-xl" : "top-[56px] rounded-b-xl"
                      )}
                    >
                      <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setNewTabMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                        <span className="font-bold text-pink-500 w-5 text-center">&gt;_</span> Terminal
                      </button>
                      <button onClick={() => { addTab({ id: 'notepad-'+Date.now(), type: 'notepad', title: 'untitled.txt', content: '' }); setNewTabMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                        <FileText size={18} className="text-blue-400" /> Editor
                      </button>
                      <button onClick={() => { addTab({ id: 'explorer-'+Date.now(), type: 'explorer', title: 'Files' }); setNewTabMenuOpen(false); }} className="w-full px-5 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                        <FolderTree size={18} className="text-yellow-400" /> Files
                      </button>
                    </motion.div>
                  </>
                )}
              </AnimatePresence>
            </div>

            {/* Spacer */}
            <div className="flex-1" />

            {/* Close Button placed within the animated top bar */}
            <div className="h-full flex items-center shrink-0 border-l border-white/5">
               <button 
                 onClick={() => {
                   if (activeTabId) removeTab(activeTabId);
                 }}
                 className={cn(
                   "h-full px-5 flex items-center justify-center", 
                   autoHideTabs ? "active:bg-red-500/20" : "active:bg-[#c42b1c] active:text-white "
                 )}
               >
                  <X size={20} className={cn(autoHideTabs ? "text-gray-400" : "text-gray-500", "active:text-red-400")} />
               </button>
            </div>
          </motion.div>

        {/* Main Terminal Container */}
          <div className={cn(
             "absolute w-full bottom-0 transition-all",
             !autoHideTabs ? "top-[56px]" : "top-0"
          )}>
            {tabs.length === 0 && (
               <div className="absolute inset-0 flex items-center justify-center text-[#eeedf0]/50 font-sans text-sm bg-[#012456]">
                 Tap 'hamburger menu' or + to start.
               </div>
            )}
            
            {tabs.map(tab => {
              const isActive = activeTabId === tab.id;
              return (
                <div key={tab.id} className={cn("absolute inset-0 w-full h-full shadow-[inset_0_4px_10px_rgba(0,0,0,0.3)] overflow-hidden", isActive ? "block" : "hidden pointer-events-none", tab.type === 'terminal' ? "bg-[#012456]" : "bg-[#191919]")}>
                  {tab.type === 'terminal' && <TerminalEmulator tab={tab} />}
                  {tab.type === 'notepad' && <NativeNotepad tab={tab} />}
                  {tab.type === 'explorer' && <NativeExplorer tab={tab} />}
                  {tab.type === 'settings' && <SettingsTab />}
                  {(tab.type === 'colors' || tab.type === 'applet') && (
                    <iframe 
                      src={tab.path}
                      className="w-full h-full border-none bg-black isolate"
                      sandbox="allow-scripts allow-forms allow-same-origin allow-downloads allow-popups allow-modals"
                    />
                  )}
                </div>
              );
            })}
          </div>
          
        </div>

        {/* Floating UI Elements */}
        {thumbstickVisible && <Thumbstick />}
        <FloatingCommandPalette />
        <Notifications />

      </div>

      <AnimatePresence>
        {contextMenu && (
          <>
            <div className="fixed inset-0 z-[200]" onContextMenu={(e) => { e.preventDefault(); setContextMenu(null); }} onClick={() => setContextMenu(null)} />
            <motion.div
              initial={{ opacity: 0, scale: 0.95 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.95 }}
              transition={{ duration: 0.1 }}
              style={{ top: Math.min(contextMenu.y, window.innerHeight - 150), left: Math.min(contextMenu.x, window.innerWidth - 200) }}
              className="fixed w-48 mica-panel mica-border shadow-2xl py-1 z-[210] rounded-xl text-sm font-sans text-shadow-mica overflow-hidden"
            >
              <button 
                onClick={() => { removeTab(contextMenu.id); setContextMenu(null); }} 
                className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-left font-medium flex items-center justify-between"
              >
                Close Tab
              </button>
              <button 
                onClick={() => { closeOtherTabs(contextMenu.id); setContextMenu(null); }} 
                className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-left font-medium flex items-center justify-between"
              >
                Close Other Tabs
              </button>
              <button 
                onClick={() => { closeTabsToRight(contextMenu.id); setContextMenu(null); }} 
                className="w-full px-4 py-2 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-left font-medium flex items-center justify-between"
              >
                Close Tabs to Right
              </button>
            </motion.div>
          </>
        )}
      </AnimatePresence>
    </div>
  );
}
