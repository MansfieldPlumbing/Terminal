import React, { useState, useEffect, useMemo } from 'react';
import { useAppStore, Tab } from '../System.Store';
import { Menu, Monitor, HardDrive, Network, Download, Image as ImageIcon, Film, Music, Folder, File as FileIcon, Search, List as ListIcon, LayoutGrid, CheckSquare, Trash2, FolderPlus, ArrowUp, MoreHorizontal, X, Copy } from 'lucide-react';
import { cn } from '../System.Utils';
import { useRef } from 'react';
// @ts-ignore
import canvasHostRaw from '../canvas_host.cpp?raw';

const formatSize = (bytes: number) => {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
};

const SolidFolderIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">
    <path d="M224,72H141.3L118.6,49.3A15.9,15.9,0,0,0,107.3,44.6H32A16,16,0,0,0,16,60.6V208a16,16,0,0,0,16,16H224a16,16,0,0,0,16-16V88A16,16,0,0,0,224,72Z" fill="#FCE166" />
  </svg>
);

export default function TerminalFiles({ tab }: { tab: Tab }) {
  const { addTab } = useAppStore();
  const [viewMode, setViewMode] = useState<'grid'|'list'>('list');
  const [sortBy, setSortBy] = useState<'name'|'date'|'size'>('name');
  const [sortDirection, setSortDirection] = useState<'asc'|'desc'>('asc');
  const [currentPath, setCurrentPath] = useState<string>('root');
  const [sidebarExpanded, setSidebarExpanded] = useState(false);
  const [storageInfo, setStorageInfo] = useState({ usage: 0, quota: 0 });
  const [selectedNames, setSelectedNames] = useState<Set<string>>(new Set());
  const [pathInput, setPathInput] = useState(`/ Internal Storage / android-terminal`);
  const [nubY, setNubY] = useState(0);

  const [isCreatingFile, setIsCreatingFile] = useState(false);
  const [newFileName, setNewFileName] = useState('');
  const newFileInputRef = useRef<HTMLInputElement>(null);


  const isDraggingNub = useRef(false);
  const longPressTimer = useRef<any>(null);
  const wasLongPress = useRef(false);
  // Defer window.innerHeight read until after layout to get correct viewport size
  React.useLayoutEffect(() => {
    setNubY(window.innerHeight / 2);
  }, []);

  useEffect(() => {
    if (isCreatingFile && newFileInputRef.current) {
      newFileInputRef.current.focus();
    }
  }, [isCreatingFile]);

  useEffect(() => {
    setPathInput(`/ Internal Storage / android-terminal${currentPath !== 'root' ? '/' + currentPath.split('/').slice(1).join('/') : ''}`);
  }, [currentPath]);

  useEffect(() => {
    if (navigator.storage && navigator.storage.estimate) {
      navigator.storage.estimate().then(({ usage, quota }) => {
        setStorageInfo({ usage: usage ?? 0, quota: quota ?? 0 });
      });
    }
  }, []);
  
  // Dummy file system for demonstration
  const [items, setItems] = useState([
    { name: 'config.json', type: 'file', size: '2 KB', date: 'Today', path: 'root' },
    { name: 'system.log', type: 'file', size: '1.4 MB', date: 'Yesterday', path: 'root' },
    { name: 'projects', type: 'directory', size: '--', date: 'Last Week', path: 'root' },
    { name: 'backups', type: 'directory', size: '--', date: 'May 14', path: 'root' },
    { name: 'script.ps1', type: 'file', size: '4 KB', date: 'Today', path: 'root' },
    { name: 'userspace', type: 'directory', size: '--', date: 'Just now', path: 'root' },
    { name: 'applets', type: 'directory', size: '--', date: 'Today', path: 'root' },
    { name: 'canvas_host.cpp', type: 'file', size: '8 KB', date: 'Just now', path: 'root/userspace' },
    { name: 'nocap.html', type: 'file', size: '398 KB', date: 'Today', path: 'root/applets' },
    { name: 'notepad.html', type: 'file', size: '25 KB', date: 'Today', path: 'root/applets' },
    { name: 'terminal-color-schemes.html', type: 'file', size: '12 KB', date: 'Today', path: 'root/applets' },
    { name: 'terminal-files.html', type: 'file', size: '18 KB', date: 'Today', path: 'root/applets' },
  ]);

  const currentItems = useMemo(() => {
    let filtered = items.filter(i => i.path === currentPath);
    return filtered.sort((a, b) => {
      // Always put directories first, unless we specifically don't want to. 
      // Most file explorers always sort folders first.
      if (a.type === 'directory' && b.type !== 'directory') return -1;
      if (a.type !== 'directory' && b.type === 'directory') return 1;

      let compareResult = 0;
      if (sortBy === 'name') {
        compareResult = a.name.localeCompare(b.name);
      } else if (sortBy === 'date') {
        compareResult = a.date.localeCompare(b.date); // For real usage, parse actual dates
      } else if (sortBy === 'size') {
        // Simple string compare for demonstration since we store sizes as strings like "2 KB"
        // In reality, store bytes and compare bytes.
        compareResult = a.size.localeCompare(b.size);
      }
      return sortDirection === 'asc' ? compareResult : -compareResult;
    });
  }, [items, currentPath, sortBy, sortDirection]);

  const confirmNewFile = () => {
    if (newFileName.trim()) {
      setItems(prev => [...prev, { name: newFileName.trim(), type: 'file', size: '0 KB', date: 'Just now', path: currentPath }]);
    }
    setIsCreatingFile(false);
  };

  useEffect(() => {
    const handleAction = (e: CustomEvent) => {
      if (e.detail.tabId !== tab.id) return;
      switch (e.detail.action) {
        case 'new-folder':
          setItems(prev => [...prev, { name: 'New Folder', type: 'directory', size: '--', date: 'Just now', path: currentPath }]);
          break;
        case 'new-file':
          setIsCreatingFile(true);
          setNewFileName('');
          break;
      }
    };
    window.addEventListener('app-menu-action', handleAction as EventListener);
    return () => window.removeEventListener('app-menu-action', handleAction as EventListener);
  }, [tab.id, currentPath]);

  const handleOpen = (item: any) => {
    if (selectedNames.size > 0) {
       toggleSelection(item.name);
       return;
    }
    if (item.type === 'directory') {
      setCurrentPath(currentPath === 'root' ? `root/${item.name}` : `${currentPath}/${item.name}`);
    } else if (item.type === 'file') {
       if (item.name.endsWith('.ps1')) {
          addTab({ id: 'pwsh-'+Date.now(), type: 'terminal', title: 'pwsh' });
       } else if (item.name === 'canvas_host.cpp') {
          addTab({ id: 'notepad-'+Date.now(), type: 'notepad', title: item.name, content: canvasHostRaw, language: 'cpp' });
       } else if (item.name.endsWith('.html')) {
          addTab({ id: 'applet-'+Date.now(), type: 'applet', title: item.name, path: '/applets/' + item.name });
       } else {
          addTab({ id: 'notepad-'+Date.now(), type: 'notepad', title: item.name, content: '// Loaded ' + item.name });
       }
    }
  };

  const handleUp = () => {
    if (currentPath !== 'root') {
      const parts = currentPath.split('/');
      parts.pop();
      setCurrentPath(parts.join('/'));
    }
  };

  const toggleSelection = (name: string) => {
    setSelectedNames(prev => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  };

  const handlePointerDown = (e: React.PointerEvent, item: any) => {
     wasLongPress.current = false;
     if (e.button !== 0 && e.pointerType !== 'touch') return;
     
     longPressTimer.current = setTimeout(() => {
         wasLongPress.current = true;
         if (!selectedNames.has(item.name)) {
             setSelectedNames(new Set([item.name]));
         }
     }, 500);
  };

  const handlePointerUp = () => clearTimeout(longPressTimer.current);
  const handlePointerMove = () => clearTimeout(longPressTimer.current);

  const handleItemClick = (e: React.MouseEvent, item: any) => {
      if (wasLongPress.current) return;
      if (selectedNames.size > 0) {
        toggleSelection(item.name);
        return;
      }
      handleOpen(item);
  };

  const handleNubPointerDown = (e: React.PointerEvent) => {
    if (sidebarExpanded) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    isDraggingNub.current = true;
  };

  const handleNubPointerMove = (e: React.PointerEvent) => {
    if (isDraggingNub.current) {
       setNubY(Math.max(64, Math.min(window.innerHeight - 64, e.clientY)));
    }
  };

  const handleNubPointerUp = (e: React.PointerEvent) => {
    if (isDraggingNub.current) {
      isDraggingNub.current = false;
      e.currentTarget.releasePointerCapture(e.pointerId);
    }
  };

  const SidebarItem = ({ icon: Icon, label, onClick, isActive = false }: any) => (
    <div 
       className={`h-11 flex items-center px-[16px] cursor-pointer relative group overflow-hidden shrink-0 ${isActive ? 'bg-[#0078D7] active:bg-[#006cc1] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0' : 'active:bg-[#ffffff10] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0'}`}
       onClick={() => {
         onClick();
         setSidebarExpanded(false);
       }}
    >
      {isActive && <div className="absolute left-0 top-2 bottom-2 w-[3px] bg-blue-300 rounded-r-full" />}
      <Icon size={18} strokeWidth={1.5} className={`shrink-0 ${!isActive && 'text-neutral-400 active:text-neutral-200'}`} />
      <div className={`ml-4 text-[14px] truncate transition-opacity duration-200 ${sidebarExpanded ? 'opacity-100' : 'opacity-0'} ${!isActive ? 'text-neutral-300 active:text-white' : 'text-white'}`}>
        {label}
      </div>
    </div>
  );

  return (
    <div className="flex h-full w-full bg-black text-white font-sans overflow-hidden select-none relative">
      
      {/* Sidebar Overlay (Click to dismiss) */}
      {sidebarExpanded && (
        <div 
          className="absolute inset-0 z-10 transition-opacity duration-300 pointer-events-auto"
          onClick={() => setSidebarExpanded(false)}
        />
      )}

      {/* Slide-out Sidebar and Nub */}
      <div 
        className={cn(
          "absolute transition-transform duration-[300ms] ease-out z-20 flex flex-col pointer-events-auto overflow-hidden bg-[#1f1f1f] shadow-2xl border-r border-[#ffffff10] top-0 bottom-0 left-0 w-64", 
          sidebarExpanded ? "translate-x-0" : "-translate-x-full"
        )}
      >
        <div className="flex flex-col w-full h-full hide-scrollbar">
          <div className="h-14 flex items-center px-4 font-semibold shrink-0 border-b border-white/5">
            Files
          </div>
          <div className="flex-1 flex flex-col mt-2 overflow-y-auto hide-scrollbar">
            <div className="text-[10px] font-semibold text-neutral-500 uppercase tracking-wider px-4 mb-2">Storage</div>
            <SidebarItem icon={Monitor} label="Internal Storage" onClick={() => {}} isActive={true} />
            <SidebarItem icon={HardDrive} label="SD Card" onClick={() => {}} />
            <SidebarItem icon={Network} label="Network / Workgroup" onClick={() => {}} />

            <div className="text-[10px] font-semibold text-neutral-500 uppercase tracking-wider px-4 mt-6 mb-2">Categories</div>
            <SidebarItem icon={Download} label="Downloads" onClick={() => {}} />
            <SidebarItem icon={ImageIcon} label="Images" onClick={() => {}} />
            <SidebarItem icon={Film} label="Videos" onClick={() => {}} />
            <SidebarItem icon={Music} label="Audio" onClick={() => {}} />
            <SidebarItem icon={FileIcon} label="Documents" onClick={() => {}} />
          </div>

          {storageInfo.quota > 0 && (
             <div className="p-4 mt-auto border-t border-[#ffffff10]">
                <div className="flex justify-between text-[11px] text-neutral-400 mb-1.5">
                   <span>{formatSize(storageInfo.usage)}</span>
                   <span>{formatSize(storageInfo.quota)}</span>
                </div>
                <div className="w-full h-1.5 bg-[#ffffff10] rounded-full overflow-hidden">
                   <div 
                      className="h-full bg-[#0078D7]" 
                      style={{ width: `${Math.min(100, (storageInfo.usage / storageInfo.quota) * 100)}%` }} 
                   />
                </div>
                <div className="text-[11px] text-neutral-500 mt-1">Storage usage</div>
             </div>
          )}
        </div>
      </div>

      {/* Swipe Nub Indicator */}
      {!sidebarExpanded && (
         <div 
           className="absolute left-0 w-4 h-24 z-20 cursor-pointer pointer-events-auto flex items-center justify-center group"
           style={{ top: nubY, transform: 'translateY(-50%)' }}
           onPointerDown={handleNubPointerDown}
           onPointerMove={handleNubPointerMove}
           onPointerUp={handleNubPointerUp}
           onClick={() => !isDraggingNub.current && setSidebarExpanded(true)}
         >
            <div className="w-1.5 h-12 bg-white/20 group-hover:bg-indigo-400 group-hover:shadow-[0_0_8px_rgba(99,102,241,0.6)] rounded-full transition-all duration-200 group-active:w-2" />
         </div>
      )}

      {/* Main Content */}
      <div className="flex-1 flex flex-col min-w-0 bg-[#00000000]">
        
        {/* Top Header */}
        {selectedNames.size > 0 ? (
          <div className="flex justify-between items-center h-14 bg-[#0078D7] px-4 shrink-0 shadow-sm z-10 w-full overflow-hidden pointer-events-auto text-white">
            <div className="flex items-center gap-3 w-full">
              <button 
                onClick={() => setSelectedNames(new Set())}
                className="p-2 -ml-2 rounded-full active:bg-[rgba(255,255,255,0.2)] active:scale-[0.95] transition-all duration-300 ease-out active:duration-0 cursor-pointer"
                title="Clear Selection"
              >
                <X size={20} />
              </button>
              <span className="font-semibold text-[15px]">{selectedNames.size} selected</span>
              <div className="flex-1" />
              <button 
                 onClick={() => {
                   if (selectedNames.size === currentItems.length) setSelectedNames(new Set());
                   else setSelectedNames(new Set(currentItems.map(i => i.name)));
                 }}
                 className="p-2 rounded-full active:bg-[rgba(255,255,255,0.2)] active:scale-[0.95] transition-all duration-300 ease-out active:duration-0" 
                 title="Select All"
              >
                 <CheckSquare size={18} className={selectedNames.size === currentItems.length ? "fill-white/20" : ""} />
              </button>
              <button className="p-2 rounded-full active:bg-[rgba(255,255,255,0.2)] active:scale-[0.95] transition-all duration-300 ease-out active:duration-0" title="Copy"><Copy size={18} /></button>
              <button className="p-2 rounded-full active:bg-[rgba(255,255,255,0.2)] active:scale-[0.95] transition-all duration-300 ease-out active:duration-0" title="Delete"><Trash2 size={18} /></button>
              <button className="p-2 rounded-full active:bg-[rgba(255,255,255,0.2)] active:scale-[0.95] transition-all duration-300 ease-out active:duration-0" title="More"><MoreHorizontal size={18} /></button>
            </div>
          </div>
        ) : (
          <div className="flex justify-between items-center h-14 bg-[#1E1E1E]/80 backdrop-blur-md px-4 shrink-0 shadow-sm z-10 w-full overflow-hidden pointer-events-auto">
            <div className="flex items-center gap-2 w-full">
               <button 
                 onClick={handleUp} 
                 disabled={currentPath === 'root'}
                 className="p-2 -ml-2 rounded-md active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-white/50 disabled:opacity-30 disabled:hover:bg-transparent cursor-pointer disabled:cursor-default shrink-0"
               >
                 <ArrowUp size={18} />
               </button>
               <input 
                  type="text" 
                  value={pathInput} 
                  onChange={e => setPathInput(e.target.value)}
                  onKeyDown={e => {
                     if (e.key === 'Enter') e.currentTarget.blur();
                  }}
                  className="bg-transparent border border-transparent active:border-white/10 active:scale-[0.98] focus:border-[#0078D7] focus:bg-black/30 outline-none text-sm font-semibold truncate flex-1 tracking-wide w-full px-2 py-1.5 rounded transition-all"
               />
               <button onClick={() => navigator.clipboard.writeText(pathInput)} className="p-2 -mr-2 rounded-md active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 text-white/70 active:text-white shrink-0" title="Copy Path">
                 <Copy size={16} />
               </button>
            </div>
          </div>
        )}
      
      {/* Toolbar */}
      {viewMode === 'list' && (
      <div className="flex items-center px-4 h-10 gap-4 text-xs font-semibold text-neutral-400 shrink-0 border-b border-white/5 bg-[#1E1E1E]">
         <div 
           className={cn("flex-1 cursor-pointer flex items-center gap-1 active:text-white transition-colors", sortBy === 'name' && "text-white")}
           onClick={() => { setSortBy('name'); setSortDirection(prev => sortBy === 'name' && prev === 'asc' ? 'desc' : 'asc'); }}
         >
           Name {sortBy === 'name' ? (sortDirection === 'asc' ? '↑' : '↓') : ''}
         </div>
         <div 
           className={cn("w-24 shrink-0 hidden sm:flex cursor-pointer items-center gap-1 active:text-white transition-colors", sortBy === 'date' && "text-white")}
           onClick={() => { setSortBy('date'); setSortDirection(prev => sortBy === 'date' && prev === 'asc' ? 'desc' : 'asc'); }}
         >
           Modified {sortBy === 'date' ? (sortDirection === 'asc' ? '↑' : '↓') : ''}
         </div>
         <div 
           className={cn("w-16 shrink-0 flex cursor-pointer items-center gap-1 active:text-white transition-colors justify-end", sortBy === 'size' && "text-white")}
           onClick={() => { setSortBy('size'); setSortDirection(prev => sortBy === 'size' && prev === 'asc' ? 'desc' : 'asc'); }}
         >
           Size {sortBy === 'size' ? (sortDirection === 'asc' ? '↑' : '↓') : ''}
         </div>
      </div>
      )}

      {/* Item View */}
      <div className="flex-1 overflow-y-auto w-full hide-scrollbar">
         {viewMode === 'grid' ? (
           <div className="grid grid-cols-[repeat(auto-fill,minmax(100px,1fr))] gap-3 p-4">
             {isCreatingFile && (
               <div className="flex flex-col items-center p-3 rounded-lg border border-[#0078D7] bg-[#0078D7]/10">
                 <div className="w-14 h-14 flex items-center justify-center mb-2">
                   <FileIcon size={40} className="text-[#0078D7] stroke-1" />
                 </div>
                 <input 
                   ref={newFileInputRef}
                   value={newFileName} 
                   onChange={e => setNewFileName(e.target.value)}
                   onBlur={confirmNewFile}
                   onKeyDown={e => {
                     if (e.key === 'Enter') confirmNewFile();
                     if (e.key === 'Escape') setIsCreatingFile(false);
                   }}
                   className="w-full bg-black/50 border border-[#0078D7] outline-none text-xs text-center px-1 py-0.5 rounded text-white" 
                   placeholder="New File"
                 />
               </div>
             )}
             {currentItems.map(i => {
                const isSelected = selectedNames.has(i.name);
                return (
                <div 
                   key={i.name} 
                   onClick={(e) => handleItemClick(e, i)} 
                   onPointerDown={(e) => handlePointerDown(e, i)}
                   onPointerUp={handlePointerUp}
                   onPointerCancel={handlePointerUp}
                   onPointerMove={handlePointerMove}
                   className={cn("flex flex-col items-center p-3 rounded-lg cursor-pointer text-center group border", isSelected ? "bg-[#0078D7]/30 border-[#0078D7]" : "active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 border-transparent active:border-white/10 active:scale-[0.98]")}
                >
                  <div className="w-14 h-14 flex items-center justify-center mb-2">
                    {i.type === 'directory' ? <Folder size={46} className="text-[#FCE166] fill-[#FCE166]/20 stroke-1" /> : <FileIcon size={40} className="text-neutral-400 stroke-1" />}
                  </div>
                  <span className="text-xs truncate w-full break-all line-clamp-2 leading-tight px-1 font-medium">{i.name}</span>
                </div>
              )})}
           </div>
         ) : (
           <div className="flex flex-col w-full min-w-min">
             {isCreatingFile && (
               <div className="flex items-center gap-4 px-4 py-3 border-b border-[#0078D7] bg-[#0078D7]/10 text-sm">
                 <FileIcon size={20} className="text-[#0078D7] shrink-0" />
                 <input 
                   ref={newFileInputRef}
                   value={newFileName} 
                   onChange={e => setNewFileName(e.target.value)}
                   onBlur={confirmNewFile}
                   onKeyDown={e => {
                     if (e.key === 'Enter') confirmNewFile();
                     if (e.key === 'Escape') setIsCreatingFile(false);
                   }}
                   className="flex-1 bg-black/50 border border-[#0078D7] outline-none text-sm px-2 py-0.5 rounded text-white" 
                   placeholder="New File.ext"
                 />
                 <span className="text-xs text-neutral-500 w-24 shrink-0 hidden sm:block">Just now</span>
                 <span className="text-xs text-neutral-500 w-16 text-right shrink-0">0 KB</span>
               </div>
             )}
             {currentItems.map(i => {
                 const isSelected = selectedNames.has(i.name);
                 return (
                 <div 
                    key={i.name} 
                    onClick={(e) => handleItemClick(e, i)}
                    onPointerDown={(e) => handlePointerDown(e, i)}
                    onPointerUp={handlePointerUp}
                    onPointerCancel={handlePointerUp}
                    onPointerMove={handlePointerMove}
                     className={cn("flex items-center gap-4 px-4 py-3 border-b border-[#2d2d2d] cursor-pointer text-sm", isSelected ? "bg-[#0078D7]/30" : "active:bg-[rgba(255,255,255,0.1)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0")}
                 >
                    {i.type === 'directory' ? <Folder size={20} className="text-[#FCE166] shrink-0" /> : <FileIcon size={20} className="text-neutral-500 shrink-0" />}
                    <span className="flex-1 font-medium truncate">{i.name}</span>
                    <span className="text-xs text-neutral-500 w-24 shrink-0 hidden sm:block">{i.date}</span>
                    <span className="text-xs text-neutral-500 w-16 text-right shrink-0">{i.size}</span>
                 </div>
              )})}
           </div>
         )}
      </div>



      {/* Bottom Actions */}
      <div className="h-16 bg-[#1a1a1a]/80 backdrop-blur-md flex items-center justify-center px-4 gap-2 text-neutral-400 shrink-0 w-full overflow-hidden border-t border-[#2d2d2d] pointer-events-auto">
         <button onClick={() => setViewMode('list')} className={cn("w-10 h-10 flex items-center justify-center rounded-lg active:text-white active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0", viewMode === 'list' && "bg-white/10 text-white")}><ListIcon size={20} /></button>
         <button onClick={() => setViewMode('grid')} className={cn("w-10 h-10 flex items-center justify-center rounded-lg active:text-white active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0", viewMode === 'grid' && "bg-white/10 text-white")}><LayoutGrid size={20} /></button>
         <div className="w-[1px] h-6 bg-[#333] mx-2" />
         <button className="w-10 h-10 flex items-center justify-center rounded-lg active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 active:text-white" title="New Folder"><FolderPlus size={20} /></button>
         <button className="w-10 h-10 flex items-center justify-center rounded-lg active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 active:text-white"><Trash2 size={20} /></button>
         <button className="w-10 h-10 flex items-center justify-center rounded-lg active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 active:text-white"><CheckSquare size={20} /></button>
         <div className="flex-1" />
         <button className="w-10 h-10 flex items-center justify-center rounded-lg active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 active:text-white"><Search size={20} /></button>
      </div>
      </div>
    </div>
  );
}
