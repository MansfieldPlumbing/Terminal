import React, { useMemo, useState } from 'react';
import { parseAlgebraicINI, ParsedINI } from './parser';
import { smokeTestConfig } from './config';
import { Palette, Gamepad2, Info, Activity, ChevronRight, ArrowLeft, Terminal } from 'lucide-react';
import { useAppStore } from '../System.Store';
import { motion, AnimatePresence } from 'motion/react';
import NativeColorSchemeEditor from '../components/Terminal.Settings.Themes';

const iconMap = {
  Palette,
  Gamepad2,
  Activity,
  Info,
  Terminal
};

export function SmokeTestApp({ inPanel = false }: { inPanel?: boolean }) {
  const store = useAppStore();
  
  if (inPanel) {
    return <SmokeTestRenderer store={store} inPanel={inPanel} />;
  }

  return (
    <div className={`w-full h-full flex items-center justify-center p-4`}>
       <div className={`w-full max-w-md h-[600px] relative`}>
          <SmokeTestRenderer store={store} inPanel={inPanel} />
       </div>
    </div>
  );
}

function SmokeTestRenderer({ store, inPanel }: { store: any, inPanel: boolean }) {
  const [history, setHistory] = useState<string[]>(['Settings.Root']);
  const activeView = history[history.length - 1];
  
  const parsed = useMemo(() => parseAlgebraicINI(smokeTestConfig), []);
  
  const sections = Object.entries(parsed).filter(([key]) => key !== 'Variables' && !key.startsWith('Profile.'));
  const currentViewConfig = parsed[activeView];
  
  const navigateBack = () => {
     if (history.length > 1) {
        setHistory(h => h.slice(0, -1));
     }
  };

  const navigateTo = (view: string) => {
     setHistory(h => [...h, view]);
  };

  if (!currentViewConfig) return <div className="text-white p-4">View not found: {activeView}</div>;

  const children = sections.filter(([key, value]) => {
     return value.parent === activeView;
  });

  const isRoot = activeView === 'Settings.Root';

  const innerContent = (
    <div className="flex w-full h-full bg-transparent text-white font-sans overflow-x-hidden overflow-y-auto hide-scrollbar relative">
      <div className="w-full max-w-4xl mx-auto px-4 md:px-8 py-6 md:py-10 pb-32">
        <AnimatePresence mode="wait">
          <motion.div 
            key={activeView}
            initial={{ x: isRoot ? -200 : 200, opacity: 0 }}
            animate={{ x: 0, opacity: 1 }}
            exit={{ x: isRoot ? -200 : 200, opacity: 0 }}
            transition={{ duration: 0.3, ease: [0.25, 1, 0.5, 1] }}
          >
            {isRoot ? (
              <div className="mb-8 flex items-center justify-between">
                <h1 className="text-3xl font-semibold tracking-tight">{currentViewConfig.title}</h1>
              </div>
            ) : (
              <div className="flex items-center gap-1 mb-6 md:mb-8 font-semibold text-2xl tracking-tight relative z-20">
                <button 
                  onClick={navigateBack}
                  className="text-gray-400 hover:text-white transition-colors cursor-pointer py-2 pr-2 -ml-2 pl-2 rounded-md hover:bg-white/5 active:scale-[0.98]"
                >
                  Settings
                </button>
                <ChevronRight size={20} className="text-gray-500 mt-1" />
                <span className="text-white pl-1">{currentViewConfig.title}</span>
              </div>
            )}
            
            <div className={isRoot ? "flex flex-col gap-2.5" : "space-y-6"}>
               {children.map(([key, config]) => (
                  <RendererNode key={key} id={key} config={config} parsed={parsed} store={store} onNavigate={navigateTo} />
               ))}
            </div>
          </motion.div>
        </AnimatePresence>
      </div>
    </div>
  );

  return (
    <div className={`absolute inset-0 flex flex-col pointer-events-auto h-full overflow-hidden ${inPanel ? 'bg-transparent' : 'bg-black/40 backdrop-blur-xl rounded-xl shadow-2xl border border-white/10'}`}>
      {innerContent}
    </div>
  );
}

function RendererNode({ id, config, parsed, store, onNavigate }: { id: string, config: any, parsed: ParsedINI, store: any, onNavigate: (v:string)=>void }) {
   if (config.type === 'Surface') {
      const surfaceChildren = Object.entries(parsed).filter(([k, v]) => v.parent === id);
      return (
         <div className="bg-white/5 border border-white/10 rounded-lg overflow-hidden shadow-sm">
            {config.title && (
               <div className="px-5 py-4 border-b border-white/10 bg-white/5">
                  <h3 className="text-sm font-semibold text-gray-200">{config.title}</h3>
               </div>
            )}
            <div className="flex flex-col">
               {surfaceChildren.map(([k, c], i, arr) => (
                  <div key={k} className={i !== arr.length - 1 ? 'border-b border-white/5' : ''}>
                     <RendererNode key={k} id={k} config={c} parsed={parsed} store={store} onNavigate={onNavigate} />
                  </div>
               ))}
            </div>
         </div>
      );
   }

   if (config.type === 'ActionRow') {
      const Icon = iconMap[config.icon as keyof typeof iconMap] || ChevronRight;
      return (
         <button 
            onClick={() => config.target && onNavigate(config.target)}
            className="w-full flex items-center justify-between p-4 bg-white/5 hover:bg-white/10 border border-white/10 rounded-lg transition-colors active:scale-[0.99]"
         >
            <div className="flex items-center gap-4">
               <div className="text-gray-400">
                  <Icon size={22} />
               </div>
               <div className="text-left">
                  <div className="font-semibold text-[15px] text-white">{config.label}</div>
                  {config.caption && <div className="text-[13px] text-gray-400 mt-0.5">{config.caption}</div>}
               </div>
            </div>
            <ChevronRight size={18} className="text-gray-500" />
         </button>
      );
   }

   if (config.type === 'Slider') {
      const storeVal = config.storeKey ? store[config.storeKey] : undefined;
      const actualVal = typeof storeVal !== 'undefined' ? storeVal : Number(config.value);
      const min = Number(config.min);
      const max = Number(config.max);
      const multiplier = config.multiplier ? Number(config.multiplier) : 1;
      
      const percentValue = (actualVal - min) / (max - min) * 100;
      
      const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
         const num = Number(e.target.value);
         if (config.storeKey) {
            const setterName = 'set' + config.storeKey.charAt(0).toUpperCase() + config.storeKey.slice(1);
            if (store[setterName]) {
               store[setterName](num);
            }
         }
      };

      return (
         <div className="px-5 py-6 flex flex-col gap-2">
             <div className="flex items-center justify-between text-sm font-medium text-gray-300">
                 <span>{config.label}</span>
                 <span className="font-mono text-gray-400 w-12 text-right">{(actualVal * multiplier).toFixed(0)}{config.unit}</span>
             </div>
             
             <div className="relative w-full h-6 flex items-center group">
                 <input 
                    type="range"
                    min={min}
                    max={max}
                    step={ (max - min) / 100 }
                    value={actualVal}
                    onChange={handleChange}
                    className="absolute w-full h-full opacity-0 cursor-pointer z-10"
                 />
                 <div className="w-full h-1 bg-[#878787]/40 rounded-full overflow-hidden">
                    <div className="h-full bg-[#60cdff]" style={{ width: `${percentValue}%` }} />
                 </div>
                 <div 
                    className="absolute h-[18px] w-[18px] rounded-full shadow-md bg-[#454545] border-[4px] border-[#60cdff] transition-transform scale-100 group-hover:scale-110 pointer-events-none" 
                    style={{ left: `calc(${percentValue}% - 9px)` }}
                 />
             </div>
             {config.caption && <p className="text-[13px] text-gray-500 mt-1">{config.caption}</p>}
         </div>
      );
   }
   
   if (config.type === 'Toggle') {
      const storeVal = config.storeKey ? store[config.storeKey] : undefined;
      const isChecked = typeof storeVal !== 'undefined' ? storeVal : (config.value === 'true');
      
      const toggleCheck = () => {
         if (config.storeKey) {
            const setterName = 'set' + config.storeKey.charAt(0).toUpperCase() + config.storeKey.slice(1);
            if (store[setterName]) {
               store[setterName](!isChecked);
            }
         }
      };

      return (
         <div className="px-5 py-5 flex items-center justify-between">
            <div>
               <div className="font-semibold text-[15px] text-white">{config.label}</div>
               {config.caption && <div className="text-[13px] text-gray-400 mt-1">{config.caption}</div>}
            </div>
            <button 
               onClick={toggleCheck}
               className={`w-[40px] h-[20px] rounded-full border relative transition-colors duration-200 shrink-0 ${isChecked ? "bg-[#60cdff] border-[#60cdff]" : "bg-transparent border-[#878787] hover:bg-white/5"}`}
            >
               <div 
                  className={`absolute top-1/2 -translate-y-1/2 w-[12px] h-[12px] rounded-full transition-all duration-200 ${isChecked ? "bg-black left-[24px]" : "bg-[#878787] left-[3px]"}`}
               />
            </button>
         </div>
      );
   }

   if (config.type === 'Button') {
      const Icon = iconMap[config.icon as keyof typeof iconMap] || Terminal;
      
      const fireAction = () => {
         if (config.action === 'LaunchCanvasHost') {
            store.addTab({ id: 'debug-'+Date.now(), type: 'debug', title: 'Diagnostics' });
         } else if (config.action === 'OpenGitHub') {
            window.open('https://github.com/MansfieldPlumbing/android-terminal', '_blank');
         }
      };

      return (
         <div className="px-5 py-5 flex flex-col">
            {config.caption && <p className="text-sm text-gray-400 mb-5">{config.caption}</p>}
            <button 
               onClick={fireAction}
               className="flex items-center gap-2 px-5 py-2.5 bg-white/10 hover:bg-white/15 transition-colors rounded-md text-sm font-semibold active:scale-[0.98] w-fit"
            >
               {Icon && <Icon size={16} className="text-[#60cdff]" />}
               {config.label}
            </button>
         </div>
      );
   }

   if (config.type === 'Header') {
      return (
         <div className="px-5 py-6 flex flex-col items-center justify-center relative">
            <div className="w-16 h-16 bg-[#012456] rounded-2xl flex items-center justify-center mb-4 shadow-inner border border-white/20">
               <span className="font-extrabold text-pink-500 drop-shadow-sm text-4xl tracking-tighter leading-none mt-1 mr-1">&gt;_</span>
            </div>
            <h2 className="text-xl font-bold text-white tracking-tight">{config.title}</h2>
            {config.subtitle && <p className="text-sm text-gray-400 mt-1">{config.subtitle}</p>}
            {config.copyright && <p className="text-xs text-gray-500 mt-2">{config.copyright}</p>}
         </div>
      );
   }

   if (config.type === 'KeyValue') {
      return (
         <div className="px-5 py-3 flex items-center justify-between">
            <span className="text-sm text-gray-400">{config.label}</span>
            <span className="text-sm text-white font-mono truncate">{config.value}</span>
         </div>
      );
   }
   
   if (config.type === 'Custom') {
      if (config.component === 'NativeColorSchemeEditor') {
         return (
            <div className="bg-transparent rounded-lg overflow-hidden border-none shadow-none mt-2">
               <NativeColorSchemeEditor tab={{ id: 'dummy', type: 'settings', title: 'dummy' }} hideSystemAppearance={true} />
            </div>
         );
      }
   }

   return null;
}
