import React, { useEffect } from 'react';
import { useAppStore } from './System.Store';
import { Menu, Plus } from 'lucide-react';
import TerminalCanvas from './components/Terminal.App.Console';
import TerminalXterm from './components/Terminal.App.Xterm';
import TerminalDebugView from './components/Terminal.Debug.CanvasHost';
import Thumbstick from './components/Terminal.UI.HID.Thumbsticks';
import Notifications from './components/Terminal.UI.Notifications';
import FloatingCommandPalette from './components/Terminal.UI.HID.CmdPalette';
import TerminalEditor from './components/Terminal.App.Editor';
import TerminalFiles from './components/Terminal.App.Files';
import NativeColorSchemeEditor from './components/Terminal.Settings.Themes';
import { SmokeTestApp } from './smoke_test/SmokeTest.Renderer';
import TabBar from './components/Terminal.UI.TabBar';
import WebGLWallpaper from './components/Terminal.UI.Wallpaper';
import { cn } from './System.Utils';

export default function App() {
  const { 
    tabs, activeTabId,
    thumbstickVisible,
    micaOpacity, bgOpacity, micaBlur, micaBaseColor, uiScale,
    fetchAppConfig
  } = useAppStore();

  useEffect(() => {
    fetchAppConfig();
    
    if (typeof window !== 'undefined' && (window as any).AndroidBridge && (window as any).AndroidBridge.notifyReady) {
      (window as any).AndroidBridge.notifyReady();
    }
  }, [fetchAppConfig]);

  useEffect(() => {
    document.documentElement.style.setProperty('--mica-opacity', micaOpacity.toString());
    document.documentElement.style.setProperty('--bg-opacity', bgOpacity.toString());
    document.documentElement.style.setProperty('--mica-blur', `${micaBlur}px`);
    document.documentElement.style.setProperty('--mica-bg-r', micaBaseColor.r.toString());
    document.documentElement.style.setProperty('--mica-bg-g', micaBaseColor.g.toString());
    document.documentElement.style.setProperty('--mica-bg-b', micaBaseColor.b.toString());
    document.documentElement.style.setProperty('--ui-scale', uiScale.toString());
    document.documentElement.style.fontSize = `${uiScale * 16}px`;
  }, [micaOpacity, bgOpacity, micaBlur, micaBaseColor, uiScale]);

  return (
    <div className="fixed inset-0 w-full h-full bg-[#000] overflow-hidden font-sans flex flex-col">
      {/* Sky Background Layer */}
      <WebGLWallpaper />

      {/* Main Container */}
      <div className="w-full h-full overflow-hidden relative shadow-md bg-transparent select-none flex flex-col z-10">
        
        {/* Main Terminal Container */}
        <div className="flex-1 w-full h-full overflow-hidden bg-transparent relative font-mono flex flex-col pointer-events-auto">

          <TabBar />

        {/* Main Terminal Container */}
          <div className="absolute w-full bottom-0 transition-all top-[56px]">
            {tabs.length === 0 && (
               <div className="absolute inset-0 flex items-center justify-center text-[#eeedf0]/50 font-sans text-sm bg-black/40 backdrop-blur-sm">
                 Tap <Menu size={16} className="inline mx-1.5" /> or <Plus size={16} className="inline mx-1.5" /> to start.
               </div>
            )}
            
            {tabs.map(tab => {
              const isActive = activeTabId === tab.id;
              return (
                <div key={tab.id} className={cn("absolute inset-0 w-full h-full shadow-[inset_0_4px_10px_rgba(0,0,0,0.3)] overflow-hidden", isActive ? "block" : "hidden pointer-events-none", tab.type === 'terminal' ? "bg-black/40 backdrop-blur-sm" : "mica-background")}>
                  {tab.type === 'terminal' && <TerminalCanvas tab={tab} />}
                  {tab.type === 'xterm' && <TerminalXterm tab={tab} />}
                  {tab.type === 'debug' && <TerminalDebugView tab={tab} />}
                  {tab.type === 'notepad' && <TerminalEditor tab={tab} />}
                  {tab.type === 'explorer' && <TerminalFiles tab={tab} />}
                  {tab.type === 'settings' && <SmokeTestApp inPanel={true} />}
                  {tab.type === 'colors' && <NativeColorSchemeEditor tab={tab} />}
                  {tab.type === 'applet' && (
                    <iframe 
                      src={tab.path.startsWith('/') ? `.${tab.path}` : tab.path}
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
    </div>
  );
}
