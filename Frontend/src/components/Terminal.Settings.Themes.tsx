import React, { useState, useEffect } from 'react';
import { ChevronLeft, Plus } from 'lucide-react';
import { Tab, useAppStore } from '../System.Store';
import { cn } from '../System.Utils';

const STORAGE_KEY = 'terminal_themes';
const ACTIVE_THEME_KEY = 'terminal_active_theme';

const DEFAULT_THEMES = [
  {
      name: "Campbell (Default)",
      isDefault: true,
      colors: { background: "#0C0C0C", foreground: "#CCCCCC", cursorColor: "#FFFFFF", selectionBackground: "#FFFFFF40", black: "#0C0C0C", brightBlack: "#767676", red: "#C50F1F", brightRed: "#E74856", green: "#13A10E", brightGreen: "#16C60C", yellow: "#C19C00", brightYellow: "#F9F1A5", blue: "#0037DA", brightBlue: "#3B78FF", purple: "#881798", brightPurple: "#B4009E", cyan: "#3A96DD", brightCyan: "#61D6D6", white: "#CCCCCC", brightWhite: "#F2F2F2" }
  },
  {
      name: "Campbell PowerShell",
      isDefault: false,
      colors: { background: "#012456", foreground: "#CCCCCC", cursorColor: "#FFFFFF", selectionBackground: "#FFFFFF40", black: "#0C0C0C", brightBlack: "#767676", red: "#C50F1F", brightRed: "#E74856", green: "#13A10E", brightGreen: "#16C60C", yellow: "#C19C00", brightYellow: "#F9F1A5", blue: "#0037DA", brightBlue: "#3B78FF", purple: "#881798", brightPurple: "#B4009E", cyan: "#3A96DD", brightCyan: "#61D6D6", white: "#CCCCCC", brightWhite: "#F2F2F2" }
  },
  {
      name: "Dark+",
      isDefault: false,
      colors: { background: "#1E1E1E", foreground: "#CCCCCC", cursorColor: "#FFFFFF", selectionBackground: "#FFFFFF40", black: "#000000", brightBlack: "#666666", red: "#CD3131", brightRed: "#F14C4C", green: "#0DBC79", brightGreen: "#23D18B", yellow: "#E5E510", brightYellow: "#F5F543", blue: "#2472C8", brightBlue: "#3B8EEA", purple: "#BC3FBC", brightPurple: "#D670D6", cyan: "#11A8CD", brightCyan: "#29B8DB", white: "#E5E5E5", brightWhite: "#E5E5E5" }
  }
];

const colorMapLeft = ['black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white'];
const colorLabelsLeft = ['Black', 'Red', 'Green', 'Yellow', 'Blue', 'Purple', 'Cyan', 'White'];
const colorMapRight = ['foreground', 'background', 'cursorColor', 'selectionBackground'];
const colorLabelsRight = ['Foreground', 'Background', 'Cursor color', 'Selection background'];

export const WinToggle = ({ checked, onChange }: { checked: boolean, onChange: (v: boolean) => void }) => (
  <button 
    onClick={() => onChange(!checked)}
    className={cn(
      "w-[40px] h-[20px] rounded-full border relative transition-colors duration-200 shrink-0", 
      checked ? "bg-[#60cdff] border-[#60cdff]" : "bg-transparent border-[#878787] hover:bg-white/5")}
  >
     <div className={cn(
       "absolute top-1/2 -translate-y-1/2 w-[12px] h-[12px] rounded-full transition-all duration-200", 
       checked ? "bg-black left-[24px]" : "bg-[#878787] left-[3px]")} 
     />
  </button>
);

export const WinSlider = ({ min, max, step, value, onChange }: { min: number, max: number, step: number, value: number, onChange: (v: number) => void }) => {
  const percent = ((value - min) / (max - min)) * 100;
  return (
    <div className="relative w-full h-6 flex items-center group">
      <input 
        type="range"
        min={min} max={max} step={step}
        value={value} onChange={e => onChange(parseFloat(e.target.value))}
        className="absolute w-full h-full opacity-0 cursor-pointer z-10"
      />
      {/* Background track */}
      <div className="w-full h-1 bg-[#878787]/40 rounded-full overflow-hidden">
         {/* Filled track */}
         <div className="h-full bg-[#60cdff]" style={{ width: `${percent}%` }} />
      </div>
      {/* Thumb */}
      <div 
         className="absolute h-[18px] w-[18px] rounded-full shadow-md bg-[#454545] border-[4px] border-[#60cdff] transition-transform scale-100 group-hover:scale-110 pointer-events-none" 
         style={{ left: `calc(${percent}% - 9px)` }}
      />
    </div>
  );
};

const ColorSwatchBlock: React.FC<{ colors: Record<string, string>, isSelected?: boolean, onClick?: () => void, title?: React.ReactNode, subtitle?: React.ReactNode }> = ({ colors, isSelected, onClick, title, subtitle }) => (
  <div className="flex items-center gap-4 cursor-pointer group" onClick={onClick}>
    <div className={cn(
      "p-4 rounded-lg bg-[#252525] border shadow transition-colors w-fit flex flex-col gap-[2px]",
      isSelected ? "border-[#60cdff] shadow-black/40" : "border-transparent shadow-black/20 group-hover:border-white/10"
    )}>
      <div className="flex gap-[2px]">
        {colorMapLeft.map(c => (
          <div key={`n-${c}`} className="w-[14px] h-[14px] rounded-[2px]" style={{ backgroundColor: colors[c] ?? '#000' }} />
        ))}
      </div>
      <div className="flex gap-[2px]">
        {colorMapLeft.map(c => {
          const bc = 'bright' + c.charAt(0).toUpperCase() + c.slice(1);
          return <div key={`b-${c}`} className="w-[14px] h-[14px] rounded-[2px]" style={{ backgroundColor: colors[bc] ?? colors[c] ?? '#000' }} />;
        })}
      </div>
    </div>
    <div className="flex-1 text-[15px] font-medium text-gray-200 flex flex-col justify-center">
      <div className="flex items-center justify-between">
        <div>{title}</div>
        {subtitle}
      </div>
    </div>
  </div>
);

export default function NativeColorSchemeEditor({ tab, hideSystemAppearance = false }: { tab: Tab, hideSystemAppearance?: boolean }) {
  const {
    micaOpacity, setMicaOpacity,
    micaBlur, setMicaBlur,
    micaBaseColor, setMicaBaseColor,
    uiScale, setUiScale,
    autoHideTabs, setAutoHideTabs
  } = useAppStore();

  const [view, setView] = useState<'LIST' | 'EDIT'>('LIST');
  const [themes, setThemes] = useState<any[]>([]);
  const [editIndex, setEditIndex] = useState<number | null>(null);

  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) {
      try {
        setThemes(JSON.parse(saved));
      } catch (e) {
        setThemes(JSON.parse(JSON.stringify(DEFAULT_THEMES)));
      }
    } else {
      setThemes(JSON.parse(JSON.stringify(DEFAULT_THEMES)));
    }
  }, []);

  const saveThemes = () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(themes));
    if (editIndex !== null) {
      applyTheme(editIndex);
    }
    setView('LIST');
    setEditIndex(null);
  };

  const applyTheme = (index: number) => {
    const themeColors = themes[index].colors;
    localStorage.setItem(ACTIVE_THEME_KEY, JSON.stringify(themeColors));
    window.dispatchEvent(new CustomEvent('terminal-theme-changed', { detail: themeColors }));
  };

  const createNewTheme = () => {
    const newTheme = JSON.parse(JSON.stringify(DEFAULT_THEMES[0]));
    newTheme.name = "Custom Theme " + (themes.length + 1);
    newTheme.isDefault = false;
    const newThemes = [...themes, newTheme];
    setThemes(newThemes);
    setView('EDIT');
    setEditIndex(newThemes.length - 1);
  };

  const updateColor = (key: string, val: string) => {
    if (editIndex !== null) {
      const newThemes = [...themes];
      newThemes[editIndex].colors[key] = val.toUpperCase();
      setThemes(newThemes);
      window.dispatchEvent(new CustomEvent('terminal-theme-preview', { detail: newThemes[editIndex].colors }));
    }
  };

  return (
    <div className="flex flex-col text-[#CCCCCC] font-sans selection:bg-blue-500/30 w-full">
      <div className="flex-1 w-full">
        {view === 'LIST' && (
          <div className="flex flex-col gap-10 w-full">
            {!hideSystemAppearance && (
              <div>
                <div className="bg-white/5 px-5 py-3 flex items-center justify-between border-b border-[#121212]/30 shadow-sm mb-0">
                  <span className="text-sm font-medium text-white">System Appearance</span>
                </div>
                <div className="bg-transparent p-6 shadow-sm border border-[#2D2D2D] flex flex-col gap-6">
                  
                  {/* UI Scale / Density */}
                  <div className="flex flex-col gap-2">
                    <div className="flex items-center justify-between text-sm font-medium text-gray-300">
                      <span>UI Scale & Font Size</span>
                      <span className="font-mono text-gray-400 w-12 text-right">{(uiScale * 100).toFixed(0)}%</span>
                    </div>
                    <WinSlider 
                      min={0.5} max={1.5} step={0.05} 
                      value={uiScale} onChange={setUiScale} 
                    />
                    <p className="text-xs text-gray-500 mt-1">Adjusts the overall density, font sizes, and context menu sizing globally.</p>
                  </div>
  
                  <div className="h-px bg-white/10 my-2" />
  
                  {/* Mica Controls */}
                  <div className="flex flex-col gap-8">
                    <div className="flex flex-col md:flex-row gap-8">
                      <div className="flex flex-col gap-2 flex-1">
                        <div className="flex items-center justify-between text-sm font-medium text-gray-300">
                          <span>Panel Opacity</span>
                          <span className="font-mono text-gray-400 w-12 text-right">{(micaOpacity * 100).toFixed(0)}%</span>
                        </div>
                        <WinSlider 
                          min={0} max={1} step={0.05} 
                          value={micaOpacity} onChange={setMicaOpacity} 
                        />
                      </div>
                      
                      <div className="flex flex-col gap-2 flex-1">
                        <div className="flex items-center justify-between text-sm font-medium text-gray-300">
                          <span>Mica Blur Radius</span>
                          <span className="font-mono text-gray-400 w-12 text-right">{micaBlur}px</span>
                        </div>
                        <WinSlider 
                          min={0} max={32} step={1} 
                          value={micaBlur} onChange={setMicaBlur} 
                        />
                      </div>
                    </div>
  
                    {/* Panel Base Tint */}
                    <div className="flex flex-col gap-4">
                      <div>
                        <div className="text-sm font-medium text-gray-300">Panel Base Tint</div>
                        <p className="text-xs text-gray-500 mt-1">Controls the background tint of context menus, dialogs, and floating panels.</p>
                      </div>
                      <div className="flex flex-wrap gap-2 max-w-[280px]">
                        {[
                          { r: 24, g: 24, b: 24, name: 'Dark Gray' },
                          { r: 0, g: 0, b: 0, name: 'Black' },
                          { r: 20, g: 36, b: 75, name: 'Deep Blue' },
                          { r: 0, g: 45, b: 90, name: 'Navy' },
                          { r: 40, g: 20, b: 50, name: 'Plum Purple' },
                          { r: 60, g: 20, b: 80, name: 'Deep Purple' },
                          { r: 60, g: 15, b: 30, name: 'Crimson' },
                          { r: 80, g: 20, b: 20, name: 'Dark Red' },
                          { r: 20, g: 50, b: 30, name: 'Forest Green' },
                          { r: 15, g: 60, b: 45, name: 'Emerald' },
                          { r: 30, g: 40, b: 40, name: 'Slate Teal' },
                          { r: 10, g: 50, b: 60, name: 'Deep Teal' },
                          { r: 45, g: 35, b: 25, name: 'Brown' },
                          { r: 50, g: 40, b: 20, name: 'Bronze' },
                          { r: 45, g: 55, b: 65, name: 'Graphite' },
                          { r: 40, g: 50, b: 70, name: 'Slate Blue' }
                        ].map((color, i) => {
                          const isMatch = Math.abs(micaBaseColor.r - color.r) < 5 && Math.abs(micaBaseColor.g - color.g) < 5 && Math.abs(micaBaseColor.b - color.b) < 5;
                          return (
                            <button
                              key={i}
                              onClick={() => setMicaBaseColor({ r: color.r, g: color.g, b: color.b })}
                              className={cn(
                                "w-[26px] h-[26px] rounded-[4px] border-2 transition-all cursor-pointer shadow-sm relative",
                                isMatch ? "border-[#60cdff] scale-110 z-10" : "border-white/10 hover:border-white/30 hover:scale-105"
                              )}
                              style={{ backgroundColor: `rgb(${color.r}, ${color.g}, ${color.b})` }}
                              title={color.name}
                            >
                              {isMatch && <div className="absolute inset-0 flex items-center justify-center opacity-80"><div className="w-1.5 h-1.5 bg-[#60cdff] rounded-full shadow-[0_0_5px_#60cdff]"></div></div>}
                            </button>
                          );
                        })}
                      </div>
                    </div>
                  </div>
  
                  <div className="h-px bg-white/10 my-1" />
                  
                  {/* Mica Tab Bar */}
                  <div className="flex items-center justify-between">
                    <div>
                      <div className="text-sm font-medium text-gray-300">Mica Tab Bar</div>
                      <div className="text-xs text-gray-500 mt-0.5">Enable translucent tab bar with animated clouds</div>
                    </div>
                    <WinToggle checked={autoHideTabs} onChange={setAutoHideTabs} />
                  </div>
  
                </div>
              </div>
            )}

            <div>
              <div className="bg-white/5 px-5 py-3 flex items-center justify-between border-b md:border-t border-[#121212]/30 shadow-sm mb-0">
                <span className="text-sm font-medium text-white">Terminal Color Schemes</span>
              </div>
              <div className="bg-transparent p-6 shadow-sm border border-[#2D2D2D]">
                <p className="text-[13px] text-gray-400 mb-6">Schemes defined here can be applied to your profiles under the "Appearances" section of the profile settings pages.</p>
                
                <button 
                  onClick={createNewTheme} 
                  className="flex items-center gap-2 px-4 py-2 rounded mb-8 transition-colors text-sm font-medium border border-white/10 hover:bg-white/5 bg-white/5"
                >
                  <Plus size={16} /> Add new
                </button>

                <div className="flex flex-col gap-6">
                  {themes.map((theme, index) => (
                    <ColorSwatchBlock
                      key={index}
                      colors={theme.colors}
                      onClick={() => applyTheme(index)}
                      title={
                        <span>
                          {theme.name}
                          {theme.isDefault && <span className="px-2 py-0.5 rounded text-[11px] border border-gray-600 text-gray-400 ml-2 font-normal">default</span>}
                        </span>
                      }
                      subtitle={
                        <span 
                          onClick={(e) => { e.stopPropagation(); setView('EDIT'); setEditIndex(index); }} 
                          className="opacity-0 group-hover:opacity-100 text-[12px] px-3 py-1 bg-white/10 hover:bg-white/20 rounded transition-all ml-4"
                        >
                          Edit
                        </span>
                      }
                    />
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}

        {view === 'EDIT' && editIndex !== null && themes[editIndex] && (
          <div className="px-6 py-6 pb-28 pt-2 max-w-[800px] mx-auto">
            <div 
              className="rounded-md p-5 mb-8 shadow-inner shadow-black/40 border border-white/5 relative"
              style={{ backgroundColor: themes[editIndex].colors.background, color: themes[editIndex].colors.foreground }}
            >
              <div className="text-sm font-semibold mb-4 tracking-wide shadow-none bg-transparent">Foreground</div>
              <div className="grid grid-cols-2 gap-y-2 text-[15px] font-mono leading-none shadow-none bg-transparent">
                {colorMapLeft.map((c, i) => {
                  const bc = 'bright' + c.charAt(0).toUpperCase() + c.slice(1);
                  return (
                    <React.Fragment key={c}>
                      <div style={{ color: themes[editIndex].colors[c] }}>{colorLabelsLeft[i]}</div>
                      <div style={{ color: themes[editIndex].colors[bc] ?? themes[editIndex].colors[c] }}>Bright {c.toLowerCase()}</div>
                    </React.Fragment>
                  );
                })}
              </div>
            </div>

            <div className="bg-white/5 rounded-t-lg px-5 py-3 flex items-center justify-between border-b border-[#121212]/30 mb-0 shadow-sm mt-6">
              <span className="text-sm font-medium">Colors</span>
              <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="opacity-50"><polyline points="18 15 12 9 6 15"></polyline></svg>
            </div>
            
            <div className="bg-white/5 p-5 pt-3 rounded-b-lg shadow-sm border border-transparent grid grid-cols-1 md:grid-cols-2 gap-x-12 items-start">
              <div>
                {colorMapLeft.map((c, i) => {
                  const bc = 'bright' + c.charAt(0).toUpperCase() + c.slice(1);
                  return (
                    <div key={c} className="flex items-center justify-between py-3">
                      <span className="text-[13px] font-medium text-gray-300 w-24">{colorLabelsLeft[i]}</span>
                      <div className="flex gap-3">
                        <label className="w-8 h-8 rounded shrink-0 border border-black/50 cursor-pointer overflow-hidden relative shadow-inner" style={{ backgroundColor: themes[editIndex].colors[c] }}>
                          <input type="color" onChange={(e) => updateColor(c, e.target.value)} value={themes[editIndex].colors[c]} className="absolute -top-4 -left-4 w-16 h-16 opacity-0 cursor-pointer border-none" />
                        </label>
                        <label className="w-8 h-8 rounded shrink-0 border border-black/50 cursor-pointer overflow-hidden relative shadow-inner" style={{ backgroundColor: themes[editIndex].colors[bc] ?? themes[editIndex].colors[c] }}>
                          <input type="color" onChange={(e) => updateColor(bc, e.target.value)} value={themes[editIndex].colors[bc] ?? themes[editIndex].colors[c]} className="absolute -top-4 -left-4 w-16 h-16 opacity-0 cursor-pointer border-none" />
                        </label>
                      </div>
                    </div>
                  );
                })}
              </div>
              
              <div>
                {colorMapRight.map((c, i) => (
                  <div key={c} className="flex items-center justify-between py-3">
                    <span className="text-[13px] font-medium text-gray-300">{colorLabelsRight[i]}</span>
                    <label className="w-8 h-8 rounded shrink-0 border border-black/50 cursor-pointer overflow-hidden relative shadow-inner" style={{ backgroundColor: themes[editIndex].colors[c] }}>
                      <input type="color" onChange={(e) => updateColor(c, e.target.value)} value={themes[editIndex].colors[c] ?? '#000000'} className="absolute -top-4 -left-4 w-16 h-16 opacity-0 cursor-pointer border-none" />
                    </label>
                  </div>
                ))}
              </div>
            </div>

            <div className="fixed bottom-0 left-0 right-0 p-4 border-t border-[#151515] bg-white/5 flex justify-end gap-3 z-20">
              <button 
                onClick={saveThemes} 
                className="px-8 py-2 rounded bg-[#60A5FA] hover:bg-[#3B82F6] text-black text-[13px] font-semibold transition-colors"
              >
                Save
              </button>
              <button 
                onClick={() => { setView('LIST'); setEditIndex(null); }} 
                className="px-6 py-2 rounded bg-[#3D3D3D] hover:bg-[#4D4D4D] text-[#CCCCCC] text-[13px] font-semibold transition-colors border border-[#1A1A1A]/30"
              >
                Discard changes
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
