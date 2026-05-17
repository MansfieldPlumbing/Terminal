import React, { useRef, useState, useEffect } from 'react';
import { motion, AnimatePresence, Reorder } from 'motion/react';
import { useAppStore } from '../System.Store';
import { Plus, Menu, LayoutTemplate, FileText, FolderTree, Settings2, X, Clapperboard, TerminalSquare, Activity } from 'lucide-react';
import { cn } from '../System.Utils';
import HamburgerMenuContent from './Terminal.UI.Menu.Hamburger';

export default function TabBar() {
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
      <div 
        className={cn(
          "absolute top-0 left-0 right-0 h-[56px] flex items-center shrink-0 select-none z-[400] transition-all",
          !autoHideTabs && "bg-[#1C1C1C] border-b border-black"
        )}
      >
        {autoHideTabs && (
          <div className="absolute inset-0 overflow-hidden pointer-events-none -z-10 border-b border-white/10 shadow-xl">
            <div className="absolute inset-0 pointer-events-none sky-container z-0">
              <div className="cloud-layer" />
            </div>
            <div className="absolute inset-0 mica-panel pointer-events-none z-10" />
          </div>
        )}
        
        {/* Hamburger Menu */}
        <div className="relative h-full flex items-center shrink-0">
          <button 
            onClick={() => { setHamburgerMenuOpen(!hamburgerMenuOpen); setNewTabMenuOpen(false); }}
            className={cn(
              "app-menu-trigger h-full px-4 flex items-center justify-center outline-none focus:outline-none", 
              hamburgerMenuOpen && (autoHideTabs ? "bg-white/10" : "bg-black/10"),
              !hamburgerMenuOpen && (autoHideTabs ? "active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0" : "active:bg-white/10 active:scale-[0.98] transition-all duration-300 ease-out active:duration-0"),
              !autoHideTabs && "border-r border-[#00000050]"
            )}
          >
            <Menu size={22} className={autoHideTabs ? "text-gray-200" : "text-gray-300"} />
          </button>

          <AnimatePresence>
            {hamburgerMenuOpen && <HamburgerMenuContent key="hamburger" />}
          </AnimatePresence>
        </div>

        <Reorder.Group 
          axis="x" 
          values={tabs} 
          onReorder={setTabs} 
          className={cn("flex h-full overflow-x-auto hide-scrollbar scroll-smooth snap-x touch-pan-x shrink px-1", autoHideTabs ? "items-end pb-0.5" : "")}
          style={{ WebkitMaskImage: autoHideTabs ? "linear-gradient(to right, transparent, black 16px, black calc(100% - 16px), transparent)" : "none" }}
        >
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
                "flex items-center gap-3 px-3 md:px-4 min-w-[56px] md:min-w-[140px] max-w-[120px] md:max-w-[200px] text-sm font-sans shadow-sm cursor-pointer flex-shrink-0 group snap-start select-none relative",
                autoHideTabs ? "h-[42px] mt-auto rounded-none -mx-[1px]" : "h-full border-r border-[#00000050]",
                activeTabId === tab.id 
                  ? (autoHideTabs ? "bg-[rgba(30,80,180,0.95)] backdrop-blur-md text-white border-x border-t border-white/30 shadow-[0_0_15px_rgba(0,0,0,0.6)] z-20" : "bg-[#2D2D2D] text-[#eeedf0] border-t-[3px] border-t-[#0078d4]") 
                  : (autoHideTabs ? "bg-[rgba(15,45,110,0.85)] backdrop-blur-md hover:bg-[rgba(25,65,140,0.95)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-gray-200 border-x border-x-white/20 border-t border-t-white/20 z-10" : "bg-[#1C1C1C] hover:bg-[#2A2A2A] active:bg-[#333] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-[#999]")
              )}
            >
              <div className={cn("w-5 flex justify-center items-center shrink-0 pointer-events-none text-shadow-sm", activeTabId === tab.id ? "text-white" : (autoHideTabs ? "text-gray-300" : "text-[#666]"))}>
                {tab.type === 'xterm' && <TerminalSquare strokeWidth={3} size={16} className="text-purple-400" />}
                {tab.type === 'terminal' && <span className="font-extrabold text-pink-500 drop-shadow-sm text-base">&gt;_</span>}
                {tab.type === 'notepad' && <FileText strokeWidth={3} size={16} className={autoHideTabs ? "text-blue-300" : "text-[#0078D7]"} />}
                {tab.type === 'explorer' && <FolderTree strokeWidth={3} size={16} className={autoHideTabs ? "text-yellow-300" : "text-[#FCE166]"} />}
                {tab.type === 'colors' && <Settings2 strokeWidth={3} size={16} className={autoHideTabs ? "text-red-300" : "text-[#A31515]"} />}
                {tab.type === 'settings' && <Settings2 strokeWidth={3} size={16} className={autoHideTabs ? "text-gray-200" : "text-gray-600"} />}
                {tab.type === 'debug' && <Activity strokeWidth={3} size={16} className="text-[#60cdff]" />}
                {tab.type === 'applet' && tab.title === 'nocap' && <Clapperboard strokeWidth={3} size={16} className="text-white" />}
                {tab.type === 'applet' && tab.title !== 'nocap' && <LayoutTemplate strokeWidth={3} size={16} className="text-[#ff3366]" />}
              </div>
              <div className={cn("font-medium truncate flex-1 text-[13px] hidden md:block pointer-events-none text-shadow-sm", activeTabId === tab.id ? "text-white" : "text-white/80")}>{tab.title}</div>
            </Reorder.Item>
          ))}
        </Reorder.Group>

        {/* Add Tab Button */}
        <div className="relative h-full flex items-center shrink-0 border-l border-white/5">
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
            className={cn(
              "app-menu-trigger h-full px-4 flex items-center justify-center flex-shrink-0", 
              autoHideTabs ? "active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-gray-300" : "active:bg-white/10 active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 bg-[#1C1C1C] text-gray-400"
            )}
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
                  className={cn(
                    "app-dropdown-menu absolute w-56 mica-panel mica-border shadow-2xl pb-2 z-50 text-sm font-sans text-shadow-mica overflow-hidden",
                    plusMenuAnchor === 'right' ? 'right-0' : 'left-0',
                    autoHideTabs ? "top-full mt-2 rounded-xl" : "top-[56px] rounded-b-xl"
                  )}
                >
                  <div className="px-3 pt-3 pb-1 text-[10px] uppercase font-bold text-white/40 tracking-wider border-b border-white/10 mb-1">Terminals</div>
                  <button onClick={() => { addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' }); setNewTabMenuOpen(false); }} className="w-full px-4 py-2.5 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                    <span className="font-extrabold text-pink-500 text-base w-5 text-center drop-shadow-sm">&gt;_</span> Canvas Host
                  </button>
                  <button onClick={() => { addTab({ id: 'xterm-'+Date.now(), type: 'xterm', title: 'xterm.js' }); setNewTabMenuOpen(false); }} className="w-full px-4 py-2.5 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                    <TerminalSquare size={16} className="text-purple-400 w-5" /> xterm.js (Legacy)
                  </button>

                  <div className="px-3 pt-3 pb-1 text-[10px] uppercase font-bold text-white/40 tracking-wider border-b border-white/10 mb-1 mt-1">Apps</div>
                  <button onClick={() => { addTab({ id: 'explorer-'+Date.now(), type: 'explorer', title: 'Files' }); setNewTabMenuOpen(false); }} className="w-full px-4 py-2.5 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                    <FolderTree size={16} className="text-yellow-400 w-5" /> File Explorer
                  </button>
                  <button onClick={() => { addTab({ id: 'editor-'+Date.now(), type: 'notepad', title: 'Editor' }); setNewTabMenuOpen(false); }} className="w-full px-4 py-2.5 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                    <FileText size={16} className="text-blue-400 w-5" /> Text Editor
                  </button>

                  {(appConfig?.profiles.list.filter(p => p.type === 'applet' && !p.hidden) || []).length > 0 && (
                    <>
                      <div className="px-3 pt-3 pb-1 text-[10px] uppercase font-bold text-white/40 tracking-wider border-b border-white/10 mb-1 mt-1">PWAs</div>
                      {appConfig?.profiles.list.filter(p => p.type === 'applet' && !p.hidden).map(profile => (
                        <button key={profile.guid} onClick={() => { addTab({ id: `${profile.guid}-${Date.now()}`, type: profile.type as any, title: profile.name, path: profile.path }); setNewTabMenuOpen(false); }} className="w-full px-4 py-2.5 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 flex items-center gap-3 text-shadow-mica text-left font-medium">
                          {profile.name === 'nocap' ? <Clapperboard size={16} className="text-white w-5" /> : <LayoutTemplate size={16} className="text-[#ff3366] w-5" />} {profile.name}
                        </button>
                      ))}
                    </>
                  )}
                </motion.div>
            )}
          </AnimatePresence>
        </div>

        <div className="flex-1" />

        <div className="h-full flex items-center shrink-0 border-l border-white/5 z-[600] relative bg-transparent">
           <button 
             onClick={() => { if (activeTabId) removeTab(activeTabId); }}
             className={cn(
               "h-full px-5 flex items-center justify-center transition-colors group rounded-none bg-transparent relative z-10", 
               autoHideTabs ? "hover:bg-[#e81123] active:bg-[#f1707a]" : "hover:bg-[#c42b1c] active:bg-[#a62417]"
             )}
           >
              <X size={20} className={cn("transition-colors", autoHideTabs ? "text-gray-400 group-hover:text-white group-active:text-white" : "text-gray-500 active:text-white")} />
           </button>
        </div>
      </div>
    </>
  );
}