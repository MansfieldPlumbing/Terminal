import React, { useState } from 'react';
import { Settings2, Keyboard, LayoutTemplate, ShieldAlert, Activity, Monitor, Palette, Gamepad2, ChevronRight, ChevronLeft, Info, Terminal, FlaskConical } from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
import { useAppStore } from '../System.Store';
import { cn } from '../System.Utils';
import NativeColorSchemeEditor, { WinToggle, WinSlider } from './Terminal.Settings.Themes';
import { SmokeTestApp } from '../smoke_test/SmokeTest.Renderer';

export default function SettingsTab() {
  const { 
    addTab,
    commandPaletteVisible, setCommandPaletteVisible,
    thumbstickVisible, setThumbstickVisible,
    canvasDpi, setCanvasDpi,
    canvasBlockScale, setCanvasBlockScale
  } = useAppStore();

  const [activeTab, setActiveTab] = useState<'root'|'about'|'personalization'|'controls'|'canvas_host'>('root');
  const [useSmokeTest, setUseSmokeTest] = useState(false);

  const renderCategoryCard = (id: typeof activeTab, icon: React.ReactNode, title: string, description: string) => {
    return (
      <button 
        onClick={() => setActiveTab(id)}
        className="w-full flex items-center justify-between p-4 bg-white/5 hover:bg-white/10 border border-white/10 rounded-lg transition-colors active:scale-[0.99]"
      >
        <div className="flex items-center gap-4">
          <div className="text-gray-400">
            {icon}
          </div>
          <div className="text-left">
            <div className="font-semibold text-[15px] text-white">{title}</div>
            <div className="text-[13px] text-gray-400 mt-0.5">{description}</div>
          </div>
        </div>
        <ChevronRight size={18} className="text-gray-500" />
      </button>
    );
  };

  const renderTopBar = (active: string) => (
    <div className="flex items-center gap-1 mb-6 md:mb-8 font-semibold text-2xl tracking-tight relative z-20">
      <button 
        onClick={() => setActiveTab('root')}
        className="text-gray-400 hover:text-white transition-colors cursor-pointer py-2 pr-2 -ml-2 pl-2 rounded-md hover:bg-white/5 active:scale-[0.98]"
      >
        Settings
      </button>
      <ChevronRight size={20} className="text-gray-500 mt-1" />
      <span className="text-white pl-1">{active}</span>
    </div>
  );

  if (useSmokeTest) {
     return (
        <div className="flex flex-col w-full h-full bg-transparent text-white font-sans overflow-hidden">
           <div className="flex items-center justify-between p-4 border-b border-white/10 bg-white/5 mx-4 mt-4 rounded-xl shadow-sm">
              <div className="flex items-center gap-3">
                 <div className="bg-pink-500/20 p-2 rounded-lg text-pink-400">
                   <FlaskConical size={18} />
                 </div>
                 <div>
                    <div className="font-semibold text-sm">Algebraic INI Renderer Active</div>
                    <div className="text-xs text-white/50">Running purely on config-driven generic UI primitive rendering</div>
                 </div>
              </div>
              <button 
                 onClick={() => setUseSmokeTest(false)} 
                 className="px-4 py-2 bg-white/10 hover:bg-white/20 rounded-lg text-sm font-medium transition-colors"
              >
                 Revert to React native views
              </button>
           </div>
           
           <div className="flex-1 relative mt-4">
              <SmokeTestApp inPanel={true} />
           </div>
        </div>
     );
  }

  return (
    <div className="flex w-full h-full bg-transparent text-white font-sans overflow-x-hidden overflow-y-auto hide-scrollbar relative">
      <div className="w-full max-w-4xl mx-auto px-4 md:px-8 py-6 md:py-10 pb-32">
        <AnimatePresence mode="wait">
          {activeTab === 'root' && (
            <motion.div 
              key="root"
              initial={{ x: -200, opacity: 0 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: -200, opacity: 0 }}
              transition={{ duration: 0.3, ease: [0.25, 1, 0.5, 1] }}
            >
              <div className="mb-8 flex items-center justify-between">
                <h1 className="text-3xl font-semibold tracking-tight">Settings</h1>
                <button 
                   onClick={() => setUseSmokeTest(true)}
                   className="flex justify-between items-center bg-pink-500/10 hover:bg-pink-500/20 border border-pink-500/30 text-pink-300 px-4 py-2 rounded-lg text-sm font-semibold transition-all active:scale-95"
                >
                   <FlaskConical size={16} className="mr-2" />
                   Enable Algebraic INI Renderer
                </button>
              </div>
              <div className="flex flex-col gap-2.5">
                {renderCategoryCard('personalization', <Palette size={22} />, 'Personalization', 'Themes, UI scaling, transparency effects')}
                {renderCategoryCard('controls', <Gamepad2 size={22} />, 'Controls', 'Command palette, virtual joystick')}
                {renderCategoryCard('canvas_host', <Activity size={22} />, 'Canvas Host', 'Hardware-accelerated rendering and diagnostics')}
                {renderCategoryCard('about', <Info size={22} />, 'About', 'Device integration, source code and documentation')}
              </div>
            </motion.div>
          )}

          {activeTab === 'about' && (
            <motion.div 
              key="about"
              initial={{ x: 200, opacity: 0 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: 200, opacity: 0 }}
              transition={{ duration: 0.3, ease: [0.25, 1, 0.5, 1] }}
            >
              {renderTopBar('About')}
              <div className="space-y-6">
                <div className="bg-white/5 border border-white/10 rounded-lg overflow-hidden shadow-sm">
                  <div className="px-5 py-6 flex flex-col items-center justify-center border-b border-white/10 bg-white/5 relative">
                    <div className="w-16 h-16 bg-[#012456] rounded-2xl flex items-center justify-center mb-4 shadow-inner border border-white/20">
                      <span className="font-extrabold text-pink-500 drop-shadow-sm text-4xl tracking-tighter leading-none mt-1 mr-1">&gt;_</span>
                    </div>
                    <h2 className="text-xl font-bold text-white tracking-tight">Android Terminal</h2>
                    <p className="text-sm text-gray-400 mt-1">Version 0.2.0 • MIT License</p>
                    <p className="text-xs text-gray-500 mt-2">© 2026 MansfieldPlumbing. All rights reserved.</p>
                  </div>
                  <div className="flex flex-col bg-transparent">
                    <div className="px-5 py-3 border-b border-white/5 flex items-center justify-between">
                      <span className="text-sm text-gray-400">Environment</span>
                      <span className="text-sm text-white font-mono">pwsh (PowerShell)</span>
                    </div>
                    <div className="px-5 py-3 border-b border-white/5 flex items-center justify-between">
                      <span className="text-sm text-gray-400">PowerShell Version</span>
                      <span className="text-sm text-white font-mono">7.6.1</span>
                    </div>
                    <div className="px-5 py-3 border-b border-white/5 flex items-center justify-between">
                      <span className="text-sm text-gray-400">.NET Runtime</span>
                      <span className="text-sm text-white font-mono">11.0.100-preview.4.26230.115</span>
                    </div>
                    <div className="px-5 py-3 border-b border-white/5 flex items-center justify-between">
                      <span className="text-sm text-gray-400">Build Date</span>
                      <span className="text-sm text-white font-mono">2026-05-16</span>
                    </div>
                    <div 
                      className="px-5 py-4 active:bg-[rgba(255,255,255,0.05)] flex items-center justify-center transition-all hover:bg-white/5 cursor-pointer text-white text-sm"
                      onClick={() => window.open('https://github.com/MansfieldPlumbing/android-terminal', '_blank')}
                    >
                      <span className="text-sm font-mono text-blue-400 hover:underline">github.com/MansfieldPlumbing/android-terminal</span>
                    </div>
                  </div>
                </div>
              </div>
            </motion.div>
          )}

          {activeTab === 'canvas_host' && (
            <motion.div 
              key="canvas_host"
              initial={{ x: 200, opacity: 0 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: 200, opacity: 0 }}
              transition={{ duration: 0.3, ease: [0.25, 1, 0.5, 1] }}
            >
              {renderTopBar('Canvas Host')}
              <div className="space-y-6">
                <div className="bg-white/5 border border-white/10 rounded-lg overflow-hidden shadow-sm">
                  <div className="px-5 py-4 border-b border-white/10 bg-white/5">
                     <h3 className="text-sm font-semibold text-gray-200">Canvas Host Tunables</h3>
                  </div>
                  <div className="px-5 py-6 flex flex-col gap-6">
                    <div>
                      <div className="flex items-center justify-between text-sm font-medium text-gray-300 mb-2">
                        <span>DPI Scale</span>
                        <span className="font-mono text-gray-400 w-12 text-right">{canvasDpi}</span>
                      </div>
                      <WinSlider 
                        min={1} max={5} step={1} 
                        value={canvasDpi} onChange={setCanvasDpi} 
                      />
                    </div>
                    <div>
                      <div className="flex items-center justify-between text-sm font-medium text-gray-300 mb-2">
                        <span>Block Scale</span>
                        <span className="font-mono text-gray-400 w-12 text-right">{canvasBlockScale}x</span>
                      </div>
                      <WinSlider 
                        min={1} max={8} step={1} 
                        value={canvasBlockScale} onChange={setCanvasBlockScale} 
                      />
                    </div>
                  </div>
                </div>

                <div className="bg-white/5 border border-white/10 rounded-lg overflow-hidden shadow-sm">
                  <div className="px-5 py-4 border-b border-white/10 bg-white/5">
                     <h3 className="text-sm font-semibold text-gray-200">Canvas Host Diagnostics</h3>
                  </div>
                  <div className="px-5 py-6">
                     <p className="text-sm text-gray-400 mb-5">Hardware-accelerated in-app PowerShell SDK testing suite. Array buffers, flinger test, benchmarking.</p>
                     <button 
                       onClick={() => addTab({ id: 'debug-'+Date.now(), type: 'debug', title: 'Diagnostics' })}
                       className="flex items-center gap-2 px-5 py-2.5 bg-white/10 hover:bg-white/15 transition-colors rounded-md text-sm font-semibold active:scale-[0.98]"
                     >
                       <Activity size={16} className="text-[#60cdff]" />
                       Launch Canvas Host
                     </button>
                  </div>
                </div>
              </div>
            </motion.div>
          )}

          {activeTab === 'personalization' && (
            <motion.div 
              key="personalization"
              initial={{ x: 200, opacity: 0 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: 200, opacity: 0 }}
              transition={{ duration: 0.3, ease: [0.25, 1, 0.5, 1] }}
            >
              {renderTopBar('Personalization')}
              <div className="bg-transparent rounded-lg overflow-hidden border border-white/10 shadow-sm shadow-black/20">
                <NativeColorSchemeEditor tab={{ id: 'dummy', type: 'settings', title: 'dummy' }} />
              </div>
            </motion.div>
          )}

          {activeTab === 'controls' && (
            <motion.div 
              key="controls"
              initial={{ x: 200, opacity: 0 }}
              animate={{ x: 0, opacity: 1 }}
              exit={{ x: 200, opacity: 0 }}
              transition={{ duration: 0.3, ease: [0.25, 1, 0.5, 1] }}
            >
              {renderTopBar('Controls')}
              <div className="bg-white/5 border border-white/10 rounded-lg overflow-hidden shadow-sm">
                  <div className="px-5 py-5 flex items-center justify-between border-b border-white/10">
                    <div>
                      <div className="font-semibold text-[15px] text-white">Command Palette</div>
                      <div className="text-[13px] text-gray-400 mt-1">Show floating search button for quick actions across the app</div>
                    </div>
                    <WinToggle checked={commandPaletteVisible} onChange={setCommandPaletteVisible} />
                  </div>
                  
                  <div className="px-5 py-5 flex items-center justify-between">
                    <div>
                      <div className="font-semibold text-[15px] text-white">Virtual Joystick</div>
                      <div className="text-[13px] text-gray-400 mt-1">Enable on-screen analog controller for navigation</div>
                    </div>
                    <WinToggle checked={thumbstickVisible} onChange={setThumbstickVisible} />
                  </div>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}
