import React from 'react';
import { Settings2, Keyboard, LayoutTemplate, ShieldAlert } from 'lucide-react';
import { useAppStore } from '../store';
import { cn } from '../lib/utils';
import { minimizeAppFromBridge } from '../lib/pwshBridge';

export default function SettingsTab() {
  const { 
    addTab,
    autoHideTabs, setAutoHideTabs,
    commandPaletteVisible, setCommandPaletteVisible,
    thumbstickVisible, setThumbstickVisible,
    micaOpacity, setMicaOpacity,
    micaBlur, setMicaBlur
  } = useAppStore();

  return (
    <div className="w-full h-full bg-[#1e1e1e] overflow-y-auto font-sans p-4 md:p-8 hide-scrollbar">
      <div className="max-w-2xl mx-auto space-y-6 text-gray-200">
        <div>
          <h1 className="text-2xl font-light text-white tracking-tight">Settings</h1>
          <p className="text-sm text-gray-400 mt-1">Manage application preferences and system settings.</p>
        </div>

        <section className="space-y-3">
          <h3 className="text-xs font-bold text-gray-500 uppercase tracking-widest pl-2">Interface</h3>
          <div className="bg-white/5 rounded-lg border border-white/10 overflow-hidden text-sm">
            <div className="px-4 py-3 flex flex-col gap-4 border-b border-white/10">
              <div className="flex items-center justify-between">
                <div>
                  <div className="font-semibold text-white">Global Mica Effect</div>
                  <div className="text-xs text-gray-400 mt-0.5">Adjust the transparency and blur of floating panels</div>
                </div>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="space-y-2 max-w-xs">
                  <div className="flex justify-between">
                    <label className="text-xs font-medium text-gray-300">Opacity</label>
                    <span className="text-xs text-gray-400">{Math.round(micaOpacity * 100)}%</span>
                  </div>
                  <input 
                    type="range" min="0" max="1" step="0.05" 
                    value={micaOpacity} 
                    onChange={(e) => setMicaOpacity(parseFloat(e.target.value))}
                    className="w-full accent-blue-500"
                  />
                </div>
                <div className="space-y-2 max-w-xs">
                  <div className="flex justify-between">
                    <label className="text-xs font-medium text-gray-300">Blur</label>
                    <span className="text-xs text-gray-400">{micaBlur}px</span>
                  </div>
                  <input 
                    type="range" min="0" max="64" step="1" 
                    value={micaBlur} 
                    onChange={(e) => setMicaBlur(parseInt(e.target.value, 10))}
                    className="w-full accent-blue-500"
                  />
                </div>
              </div>
            </div>

            <div className="px-4 py-3 flex items-center justify-between border-b border-white/10">
              <div>
                <div className="font-semibold text-white">Auto-Hide Top Bar</div>
                <div className="text-xs text-gray-400 mt-0.5">Hide tabs and system controls automatically</div>
              </div>
              <button 
                onClick={() => setAutoHideTabs(!autoHideTabs)}
                className={cn("w-10 h-5 rounded-full relative", autoHideTabs ? "bg-blue-600" : "bg-white/20")}
              >
                 <div className={cn("absolute top-0.5 bottom-0.5 w-4 bg-white rounded-full transition-all shadow-sm", autoHideTabs ? "left-5" : "left-1")} />
              </button>
            </div>
            
            <div className="px-4 py-3 flex items-center gap-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 cursor-pointer"
                 onClick={() => addTab({ id: 'colors-'+Date.now(), type: 'colors', title: 'Color Schemes', path: '/applets/terminal-color-schemes.html' })}>
              <div className="w-8 h-8 rounded-md bg-blue-500/20 flex items-center justify-center text-blue-400 shrink-0">
                <Settings2 size={16} />
              </div>
              <div>
                <div className="font-semibold text-white">Terminal Colors</div>
                <div className="text-xs text-gray-400 mt-0.5">Customize your terminal experience</div>
              </div>
            </div>
          </div>
        </section>

        <section className="space-y-3">
          <h3 className="text-xs font-bold text-gray-500 uppercase tracking-widest pl-2">Controls</h3>
          <div className="bg-white/5 rounded-lg border border-white/10 overflow-hidden text-sm">
            <div className="px-4 py-3 flex items-center justify-between border-b border-white/10">
              <div>
                <div className="font-semibold text-white">Command Palette</div>
                <div className="text-xs text-gray-400 mt-0.5">Show floating search button for quick actions</div>
              </div>
              <button 
                onClick={() => setCommandPaletteVisible(!commandPaletteVisible)}
                className={cn("w-10 h-5 rounded-full relative", commandPaletteVisible ? "bg-blue-600" : "bg-white/20")}
              >
                 <div className={cn("absolute top-0.5 bottom-0.5 w-4 bg-white rounded-full transition-all shadow-sm", commandPaletteVisible ? "left-5" : "left-1")} />
              </button>
            </div>
            
            <div className="px-4 py-3 flex items-center justify-between">
              <div>
                <div className="font-semibold text-white">Virtual Joystick</div>
                <div className="text-xs text-gray-400 mt-0.5">Enable on-screen analog controller</div>
              </div>
              <button 
                onClick={() => setThumbstickVisible(!thumbstickVisible)}
                className={cn("w-10 h-5 rounded-full relative", thumbstickVisible ? "bg-blue-600" : "bg-white/20")}
              >
                 <div className={cn("absolute top-0.5 bottom-0.5 w-4 bg-white rounded-full transition-all shadow-sm", thumbstickVisible ? "left-5" : "left-1")} />
              </button>
            </div>
          </div>
        </section>

        <section className="space-y-3">
          <h3 className="text-xs font-bold text-gray-500 uppercase tracking-widest pl-2">System</h3>
          <div className="bg-white/5 rounded-lg border border-white/10 overflow-hidden text-sm flex flex-col">
            <div 
              className="px-4 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 cursor-pointer text-white font-semibold border-b border-white/10"
              onClick={() => minimizeAppFromBridge()}
            >
              Minimize Android Task
            </div>
            <div 
              className="px-4 py-3 active:bg-[rgba(255,255,255,0.15)] active:scale-[0.98] transition-all duration-300 ease-out active:duration-0 cursor-pointer text-white flex items-center justify-between font-semibold"
              onClick={() => window.open('https://github.com/mansfieldplumbing/android-terminal', '_blank')}
            >
              <span>About / Source Code</span>
              <span className="text-xs font-normal text-gray-500">github.com/mansfieldplumbing/android-terminal</span>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}
