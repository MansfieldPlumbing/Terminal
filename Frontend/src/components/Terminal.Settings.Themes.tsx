import React, { useState, useEffect } from 'react';
import { makeStyles, mergeClasses, tokens } from '@fluentui/react-components';
import { ChevronLeft, Plus } from 'lucide-react';
import { Tab, useAppStore } from '../System.Store';

const STORAGE_KEY = 'terminal_themes';
const ACTIVE_THEME_KEY = 'terminal_active_theme';

const DEFAULT_THEMES = [
  {
    name: 'Campbell (Default)',
    isDefault: true,
    colors: { background: '#0C0C0C', foreground: '#CCCCCC', cursorColor: '#FFFFFF', selectionBackground: '#FFFFFF40', black: '#0C0C0C', brightBlack: '#767676', red: '#C50F1F', brightRed: '#E74856', green: '#13A10E', brightGreen: '#16C60C', yellow: '#C19C00', brightYellow: '#F9F1A5', blue: '#0037DA', brightBlue: '#3B78FF', purple: '#881798', brightPurple: '#B4009E', cyan: '#3A96DD', brightCyan: '#61D6D6', white: '#CCCCCC', brightWhite: '#F2F2F2' }
  },
  {
    name: 'Campbell PowerShell',
    isDefault: false,
    colors: { background: '#012456', foreground: '#CCCCCC', cursorColor: '#FFFFFF', selectionBackground: '#FFFFFF40', black: '#0C0C0C', brightBlack: '#767676', red: '#C50F1F', brightRed: '#E74856', green: '#13A10E', brightGreen: '#16C60C', yellow: '#C19C00', brightYellow: '#F9F1A5', blue: '#0037DA', brightBlue: '#3B78FF', purple: '#881798', brightPurple: '#B4009E', cyan: '#3A96DD', brightCyan: '#61D6D6', white: '#CCCCCC', brightWhite: '#F2F2F2' }
  },
  {
    name: 'Dark+',
    isDefault: false,
    colors: { background: '#1E1E1E', foreground: '#CCCCCC', cursorColor: '#FFFFFF', selectionBackground: '#FFFFFF40', black: '#000000', brightBlack: '#666666', red: '#CD3131', brightRed: '#F14C4C', green: '#0DBC79', brightGreen: '#23D18B', yellow: '#E5E510', brightYellow: '#F5F543', blue: '#2472C8', brightBlue: '#3B8EEA', purple: '#BC3FBC', brightPurple: '#D670D6', cyan: '#11A8CD', brightCyan: '#29B8DB', white: '#E5E5E5', brightWhite: '#E5E5E5' }
  }
];

const colorMapLeft = ['black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white'];
const colorLabelsLeft = ['Black', 'Red', 'Green', 'Yellow', 'Blue', 'Purple', 'Cyan', 'White'];
const colorMapRight = ['foreground', 'background', 'cursorColor', 'selectionBackground'];
const colorLabelsRight = ['Foreground', 'Background', 'Cursor color', 'Selection background'];

// ── Fluent 2 styles ──────────────────────────────────────────────────────────

const useStyles = makeStyles({
  root: {
    display: 'flex',
    flexDirection: 'column',
    color: '#CCCCCC',
    fontFamily: 'sans-serif',
    width: '100%',
  },

  // Section header strip (like Windows Settings group label)
  sectionStrip: {
    backgroundColor: 'rgba(255,255,255,0.05)',
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '12px',
    paddingBottom: '12px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottom: '1px solid rgba(18,18,18,0.3)',
    boxShadow: '0 1px 3px rgba(0,0,0,0.1)',
    marginBottom: 0,
  },
  sectionStripLabel: { fontSize: '14px', fontWeight: '500', color: '#ffffff' },

  // Content card inside a section
  card: {
    padding: '24px',
    boxShadow: '0 1px 3px rgba(0,0,0,0.2)',
    border: '1px solid #2D2D2D',
    display: 'flex',
    flexDirection: 'column',
    gap: '24px',
  },

  // Row of controls with label + value
  controlRow: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
  },
  controlLabel: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    fontSize: '14px',
    fontWeight: '500',
    color: '#d1d5db',
  },
  controlValue: { fontFamily: 'monospace', color: '#9ca3af', width: '48px', textAlign: 'right' },
  controlHint: { fontSize: '12px', color: '#6b7280', marginTop: '4px' },

  divider: { height: '1px', backgroundColor: 'rgba(255,255,255,0.1)', margin: '8px 0' },

  // Toggle (Windows-style)
  toggleBtn: {
    width: '40px',
    height: '20px',
    borderRadius: '10px',
    border: 'none',
    position: 'relative',
    transition: 'background-color 200ms, border-color 200ms',
    cursor: 'pointer',
    flexShrink: 0,
    padding: 0,
  },
  toggleOn: { backgroundColor: '#60cdff', borderColor: '#60cdff' },
  toggleOff: { backgroundColor: 'transparent', border: '1px solid #878787' },
  toggleThumb: {
    position: 'absolute',
    top: '50%',
    transform: 'translateY(-50%)',
    width: '12px',
    height: '12px',
    borderRadius: '50%',
    transition: 'all 200ms',
  },
  toggleThumbOn: { backgroundColor: '#000000', left: '24px' },
  toggleThumbOff: { backgroundColor: '#878787', left: '3px' },

  // Slider
  sliderRoot: { position: 'relative', width: '100%', height: '24px', display: 'flex', alignItems: 'center' },
  sliderInput: { position: 'absolute', width: '100%', height: '100%', opacity: 0, cursor: 'pointer', zIndex: 10, margin: 0 },
  sliderTrack: { width: '100%', height: '4px', backgroundColor: 'rgba(135,135,135,0.4)', borderRadius: '2px', overflow: 'hidden' },
  sliderFill: { height: '100%', backgroundColor: '#60cdff' },
  sliderThumb: {
    position: 'absolute',
    height: '18px',
    width: '18px',
    borderRadius: '50%',
    boxShadow: '0 1px 4px rgba(0,0,0,0.5)',
    backgroundColor: '#454545',
    border: '4px solid #60cdff',
    pointerEvents: 'none',
    transition: 'transform 100ms',
    ':hover': { transform: 'translateY(-50%) scale(1.1)' },
    top: '50%',
    transform: 'translateY(-50%)',
  },

  // Color tint swatches
  swatchGrid: { display: 'flex', flexWrap: 'wrap', gap: '8px', maxWidth: '280px' },
  swatchBtn: {
    width: '26px',
    height: '26px',
    borderRadius: '4px',
    border: '2px solid rgba(255,255,255,0.1)',
    cursor: 'pointer',
    transition: 'all 100ms',
    position: 'relative',
    padding: 0,
    ':hover': { borderColor: 'rgba(255,255,255,0.3)', transform: 'scale(1.05)' },
  },
  swatchBtnActive: { borderColor: '#60cdff', transform: 'scale(1.1)', zIndex: 10 },
  swatchDot: {
    position: 'absolute',
    inset: 0,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    opacity: 0.8,
  },
  swatchDotInner: { width: '6px', height: '6px', backgroundColor: '#60cdff', borderRadius: '50%', boxShadow: '0 0 5px #60cdff' },

  // Toggle row (label + toggle inline)
  toggleRow: { display: 'flex', alignItems: 'center', justifyContent: 'space-between' },
  toggleRowLabel: { fontSize: '14px', fontWeight: '500', color: '#d1d5db' },
  toggleRowSub: { fontSize: '12px', color: '#6b7280', marginTop: '2px' },

  // Color scheme section
  addBtn: {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    paddingLeft: '16px',
    paddingRight: '16px',
    paddingTop: '8px',
    paddingBottom: '8px',
    borderRadius: '4px',
    marginBottom: '32px',
    transition: 'background-color 200ms',
    fontSize: '14px',
    fontWeight: '500',
    border: '1px solid rgba(255,255,255,0.1)',
    backgroundColor: 'rgba(255,255,255,0.05)',
    cursor: 'pointer',
    color: '#CCCCCC',
    ':hover': { backgroundColor: 'rgba(255,255,255,0.08)' },
    ':active': { backgroundColor: 'rgba(255,255,255,0.12)', transform: 'scale(0.98)', transition: 'none' },
  },

  // Color swatch block (theme preview)
  themeRow: { display: 'flex', alignItems: 'center', gap: '16px', cursor: 'pointer' },
  themeSwatchBox: {
    padding: '16px',
    borderRadius: '8px',
    backgroundColor: '#252525',
    border: '1px solid transparent',
    boxShadow: '0 1px 3px rgba(0,0,0,0.2)',
    transition: 'border-color 200ms',
    display: 'flex',
    flexDirection: 'column',
    gap: '2px',
    flexShrink: 0,
  },
  themeSwatchBoxSelected: { borderColor: '#60cdff', boxShadow: '0 1px 6px rgba(0,0,0,0.4)' },
  themeSwatchBoxHover: { ':hover': { borderColor: 'rgba(255,255,255,0.1)' } },
  themeSwatchRow: { display: 'flex', gap: '2px' },
  themeSwatch: { width: '14px', height: '14px', borderRadius: '2px' },
  themeName: { flex: 1, fontSize: '15px', fontWeight: '500', color: '#e5e7eb', display: 'flex', flexDirection: 'column', justifyContent: 'center' },
  themeNameRow: { display: 'flex', alignItems: 'center', justifyContent: 'space-between' },
  themeDefaultBadge: {
    paddingLeft: '8px',
    paddingRight: '8px',
    paddingTop: '2px',
    paddingBottom: '2px',
    borderRadius: '4px',
    fontSize: '11px',
    border: '1px solid #4b5563',
    color: '#9ca3af',
    marginLeft: '8px',
    fontWeight: '400',
  },
  themeEditBtn: {
    fontSize: '12px',
    paddingLeft: '12px',
    paddingRight: '12px',
    paddingTop: '4px',
    paddingBottom: '4px',
    backgroundColor: 'rgba(255,255,255,0.1)',
    borderRadius: '4px',
    opacity: 0,
    transition: 'all 200ms',
    border: 'none',
    cursor: 'pointer',
    color: '#CCCCCC',
    marginLeft: '16px',
    ':hover': { backgroundColor: 'rgba(255,255,255,0.2)' },
  },

  // Edit view
  editRoot: { paddingLeft: '24px', paddingRight: '24px', paddingBottom: '112px', paddingTop: '8px', maxWidth: '800px' },
  previewBlock: {
    borderRadius: '8px',
    padding: '20px',
    marginBottom: '32px',
    boxShadow: 'inset 0 1px 4px rgba(0,0,0,0.4)',
    border: '1px solid rgba(255,255,255,0.05)',
    position: 'relative',
  },
  previewTitle: { fontSize: '14px', fontWeight: '600', marginBottom: '16px', letterSpacing: '0.05em' },
  previewGrid: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px', fontSize: '15px', fontFamily: 'monospace', lineHeight: 1 },

  colorsHeader: {
    backgroundColor: 'rgba(255,255,255,0.05)',
    borderRadius: '8px 8px 0 0',
    paddingLeft: '20px',
    paddingRight: '20px',
    paddingTop: '12px',
    paddingBottom: '12px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottom: '1px solid rgba(18,18,18,0.3)',
    boxShadow: '0 1px 3px rgba(0,0,0,0.1)',
    marginTop: '24px',
  },
  colorsBody: {
    backgroundColor: 'rgba(255,255,255,0.05)',
    padding: '20px',
    paddingTop: '12px',
    borderRadius: '0 0 8px 8px',
    boxShadow: '0 1px 3px rgba(0,0,0,0.1)',
    border: '1px solid transparent',
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    columnGap: '48px',
    alignItems: 'flex-start',
  },
  colorPickerRow: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: '12px',
    paddingBottom: '12px',
  },
  colorPickerLabel: { fontSize: '13px', fontWeight: '500', color: '#d1d5db', width: '96px' },
  colorPickerSwatches: { display: 'flex', gap: '12px' },
  colorSwatch: {
    width: '32px',
    height: '32px',
    borderRadius: '4px',
    flexShrink: 0,
    border: '1px solid rgba(0,0,0,0.5)',
    cursor: 'pointer',
    overflow: 'hidden',
    position: 'relative',
    boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.3)',
  },
  colorInput: { position: 'absolute', top: '-16px', left: '-16px', width: '64px', height: '64px', opacity: 0, cursor: 'pointer', border: 'none' },

  // Save bar
  saveBar: {
    position: 'fixed',
    bottom: 0,
    left: 0,
    right: 0,
    padding: '16px',
    borderTop: '1px solid #151515',
    backgroundColor: 'rgba(255,255,255,0.05)',
    display: 'flex',
    justifyContent: 'flex-end',
    gap: '12px',
    zIndex: 20,
  },
  saveBtn: {
    paddingLeft: '32px',
    paddingRight: '32px',
    paddingTop: '8px',
    paddingBottom: '8px',
    borderRadius: '4px',
    backgroundColor: '#60A5FA',
    color: '#000',
    fontSize: '13px',
    fontWeight: '600',
    border: 'none',
    cursor: 'pointer',
    transition: 'background-color 200ms',
    ':hover': { backgroundColor: '#3B82F6' },
  },
  discardBtn: {
    paddingLeft: '24px',
    paddingRight: '24px',
    paddingTop: '8px',
    paddingBottom: '8px',
    borderRadius: '4px',
    backgroundColor: '#3D3D3D',
    color: '#CCCCCC',
    fontSize: '13px',
    fontWeight: '600',
    border: '1px solid rgba(26,26,26,0.3)',
    cursor: 'pointer',
    transition: 'background-color 200ms',
    ':hover': { backgroundColor: '#4D4D4D' },
  },
});

// ── Sub-components ───────────────────────────────────────────────────────────

export const WinToggle = ({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) => {
  const styles = useStyles();
  return (
    <button
      onClick={() => onChange(!checked)}
      className={mergeClasses(styles.toggleBtn, checked ? styles.toggleOn : styles.toggleOff)}
    >
      <div className={mergeClasses(styles.toggleThumb, checked ? styles.toggleThumbOn : styles.toggleThumbOff)} />
    </button>
  );
};

export const WinSlider = ({ min, max, step, value, onChange }: { min: number; max: number; step: number; value: number; onChange: (v: number) => void }) => {
  const styles = useStyles();
  const percent = ((value - min) / (max - min)) * 100;
  return (
    <div className={styles.sliderRoot}>
      <input
        type="range" min={min} max={max} step={step} value={value}
        onChange={e => onChange(parseFloat(e.target.value))}
        className={styles.sliderInput}
      />
      <div className={styles.sliderTrack}>
        <div className={styles.sliderFill} style={{ width: `${percent}%` }} />
      </div>
      <div className={styles.sliderThumb} style={{ left: `calc(${percent}% - 9px)` }} />
    </div>
  );
};

// ── Main component ───────────────────────────────────────────────────────────

export default function NativeColorSchemeEditor({ tab, hideSystemAppearance = false }: { tab: Tab; hideSystemAppearance?: boolean }) {
  const styles = useStyles();
  const {
    micaOpacity, setMicaOpacity,
    micaBlur, setMicaBlur,
    micaBaseColor, setMicaBaseColor,
    uiScale, setUiScale,
    autoHideTabs, setAutoHideTabs,
  } = useAppStore();

  const [view, setView] = useState<'LIST' | 'EDIT'>('LIST');
  const [themes, setThemes] = useState<any[]>([]);
  const [editIndex, setEditIndex] = useState<number | null>(null);

  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY);
    try { setThemes(saved ? JSON.parse(saved) : JSON.parse(JSON.stringify(DEFAULT_THEMES))); }
    catch { setThemes(JSON.parse(JSON.stringify(DEFAULT_THEMES))); }
  }, []);

  const saveThemes = () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(themes));
    if (editIndex !== null) applyTheme(editIndex);
    setView('LIST');
    setEditIndex(null);
  };

  const applyTheme = (index: number) => {
    const c = themes[index].colors;
    localStorage.setItem(ACTIVE_THEME_KEY, JSON.stringify(c));
    window.dispatchEvent(new CustomEvent('terminal-theme-changed', { detail: c }));
  };

  const createNewTheme = () => {
    const t = { ...JSON.parse(JSON.stringify(DEFAULT_THEMES[0])), name: `Custom Theme ${themes.length + 1}`, isDefault: false };
    const next = [...themes, t];
    setThemes(next);
    setView('EDIT');
    setEditIndex(next.length - 1);
  };

  const updateColor = (key: string, val: string) => {
    if (editIndex === null) return;
    const next = [...themes];
    next[editIndex].colors[key] = val.toUpperCase();
    setThemes(next);
    window.dispatchEvent(new CustomEvent('terminal-theme-preview', { detail: next[editIndex].colors }));
  };

  const tintPresets = [
    { r: 24, g: 24, b: 24, name: 'Dark Gray' },   { r: 0, g: 0, b: 0, name: 'Black' },
    { r: 20, g: 36, b: 75, name: 'Deep Blue' },    { r: 0, g: 45, b: 90, name: 'Navy' },
    { r: 40, g: 20, b: 50, name: 'Plum Purple' },  { r: 60, g: 20, b: 80, name: 'Deep Purple' },
    { r: 60, g: 15, b: 30, name: 'Crimson' },      { r: 80, g: 20, b: 20, name: 'Dark Red' },
    { r: 20, g: 50, b: 30, name: 'Forest Green' }, { r: 15, g: 60, b: 45, name: 'Emerald' },
    { r: 30, g: 40, b: 40, name: 'Slate Teal' },   { r: 10, g: 50, b: 60, name: 'Deep Teal' },
    { r: 45, g: 35, b: 25, name: 'Brown' },        { r: 50, g: 40, b: 20, name: 'Bronze' },
    { r: 45, g: 55, b: 65, name: 'Graphite' },     { r: 40, g: 50, b: 70, name: 'Slate Blue' },
  ];

  if (view === 'EDIT' && editIndex !== null && themes[editIndex]) {
    const theme = themes[editIndex];
    return (
      <div className={styles.root} style={{ overflowY: 'auto' }}>
        <div className={styles.editRoot}>
          {/* Live preview */}
          <div
            className={styles.previewBlock}
            style={{ backgroundColor: theme.colors.background, color: theme.colors.foreground }}
          >
            <div className={styles.previewTitle}>Foreground</div>
            <div className={styles.previewGrid}>
              {colorMapLeft.map((c, i) => {
                const bc = 'bright' + c.charAt(0).toUpperCase() + c.slice(1);
                return (
                  <React.Fragment key={c}>
                    <div style={{ color: theme.colors[c] }}>{colorLabelsLeft[i]}</div>
                    <div style={{ color: theme.colors[bc] ?? theme.colors[c] }}>Bright {c}</div>
                  </React.Fragment>
                );
              })}
            </div>
          </div>

          {/* Color pickers */}
          <div className={styles.colorsHeader}>
            <span style={{ fontSize: '14px', fontWeight: '500' }}>Colors</span>
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ opacity: 0.5 }}><polyline points="18 15 12 9 6 15" /></svg>
          </div>
          <div className={styles.colorsBody}>
            <div>
              {colorMapLeft.map((c, i) => {
                const bc = 'bright' + c.charAt(0).toUpperCase() + c.slice(1);
                return (
                  <div key={c} className={styles.colorPickerRow}>
                    <span className={styles.colorPickerLabel}>{colorLabelsLeft[i]}</span>
                    <div className={styles.colorPickerSwatches}>
                      <label className={styles.colorSwatch} style={{ backgroundColor: theme.colors[c] }}>
                        <input type="color" onChange={e => updateColor(c, e.target.value)} value={theme.colors[c]} className={styles.colorInput} />
                      </label>
                      <label className={styles.colorSwatch} style={{ backgroundColor: theme.colors[bc] ?? theme.colors[c] }}>
                        <input type="color" onChange={e => updateColor(bc, e.target.value)} value={theme.colors[bc] ?? theme.colors[c]} className={styles.colorInput} />
                      </label>
                    </div>
                  </div>
                );
              })}
            </div>
            <div>
              {colorMapRight.map((c, i) => (
                <div key={c} className={styles.colorPickerRow}>
                  <span className={styles.colorPickerLabel}>{colorLabelsRight[i]}</span>
                  <label className={styles.colorSwatch} style={{ backgroundColor: theme.colors[c] }}>
                    <input type="color" onChange={e => updateColor(c, e.target.value)} value={theme.colors[c] ?? '#000000'} className={styles.colorInput} />
                  </label>
                </div>
              ))}
            </div>
          </div>
        </div>

        <div className={styles.saveBar}>
          <button onClick={saveThemes} className={styles.saveBtn}>Save</button>
          <button onClick={() => { setView('LIST'); setEditIndex(null); }} className={styles.discardBtn}>Discard changes</button>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.root} style={{ overflowY: 'auto' }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: '40px', width: '100%' }}>

        {/* ── System Appearance ── */}
        {!hideSystemAppearance && (
          <div>
            <div className={styles.sectionStrip}>
              <span className={styles.sectionStripLabel}>System Appearance</span>
            </div>
            <div className={styles.card} style={{ backgroundColor: 'transparent' }}>

              {/* UI Scale */}
              <div className={styles.controlRow}>
                <div className={styles.controlLabel}>
                  <span>UI Scale &amp; Font Size</span>
                  <span className={styles.controlValue}>{(uiScale * 100).toFixed(0)}%</span>
                </div>
                <WinSlider min={0.5} max={1.5} step={0.05} value={uiScale} onChange={setUiScale} />
                <p className={styles.controlHint}>Adjusts the overall density, font sizes, and context menu sizing globally.</p>
              </div>

              <div className={styles.divider} />

              {/* Mica Opacity + Blur */}
              <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
                  <div style={{ display: 'flex', gap: '32px', flexWrap: 'wrap' }}>
                    <div className={styles.controlRow} style={{ flex: 1, minWidth: '140px' }}>
                      <div className={styles.controlLabel}>
                        <span>Panel Opacity</span>
                        <span className={styles.controlValue}>{(micaOpacity * 100).toFixed(0)}%</span>
                      </div>
                      <WinSlider min={0} max={1} step={0.05} value={micaOpacity} onChange={setMicaOpacity} />
                    </div>
                    <div className={styles.controlRow} style={{ flex: 1, minWidth: '140px' }}>
                      <div className={styles.controlLabel}>
                        <span>Mica Blur Radius</span>
                        <span className={styles.controlValue}>{micaBlur}px</span>
                      </div>
                      <WinSlider min={0} max={32} step={1} value={micaBlur} onChange={setMicaBlur} />
                    </div>
                  </div>

                  {/* Base tint swatches */}
                  <div className={styles.controlRow}>
                    <div className={styles.controlLabel}><span>Panel Base Tint</span></div>
                    <p className={styles.controlHint} style={{ marginTop: 0, marginBottom: '12px' }}>Controls the background tint of context menus, dialogs, and floating panels.</p>
                    <div className={styles.swatchGrid}>
                      {tintPresets.map((color, i) => {
                        const isMatch = Math.abs(micaBaseColor.r - color.r) < 5 && Math.abs(micaBaseColor.g - color.g) < 5 && Math.abs(micaBaseColor.b - color.b) < 5;
                        return (
                          <button
                            key={i}
                            onClick={() => setMicaBaseColor({ r: color.r, g: color.g, b: color.b })}
                            className={mergeClasses(styles.swatchBtn, isMatch ? styles.swatchBtnActive : undefined)}
                            style={{ backgroundColor: `rgb(${color.r},${color.g},${color.b})` }}
                            title={color.name}
                          >
                            {isMatch && <div className={styles.swatchDot}><div className={styles.swatchDotInner} /></div>}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                </div>

                <div className={styles.divider} />

                {/* Mica Tab Bar toggle */}
                <div className={styles.toggleRow}>
                  <div>
                    <div className={styles.toggleRowLabel}>Mica Tab Bar</div>
                    <div className={styles.toggleRowSub}>Enable translucent tab bar with animated clouds</div>
                  </div>
                  <WinToggle checked={autoHideTabs} onChange={setAutoHideTabs} />
                </div>
              </div>
            </div>
          </div>
        )}

        {/* ── Terminal Color Schemes ── */}
        <div>
          <div className={styles.sectionStrip}>
            <span className={styles.sectionStripLabel}>Terminal Color Schemes</span>
          </div>
          <div className={styles.card} style={{ backgroundColor: 'transparent' }}>
            <p style={{ fontSize: '13px', color: '#9ca3af', marginBottom: 0, marginTop: 0 }}>
              Schemes defined here can be applied to your profiles under the "Appearances" section of the profile settings pages.
            </p>

            <button onClick={createNewTheme} className={styles.addBtn}>
              <Plus size={16} /> Add new
            </button>

            <div style={{ display: 'flex', flexDirection: 'column', gap: '24px' }}>
              {themes.map((theme, index) => (
                <div
                  key={index}
                  className={styles.themeRow}
                  onClick={() => applyTheme(index)}
                >
                  <div className={mergeClasses(styles.themeSwatchBox, styles.themeSwatchBoxHover)}>
                    <div className={styles.themeSwatchRow}>
                      {colorMapLeft.map(c => (
                        <div key={`n-${c}`} className={styles.themeSwatch} style={{ backgroundColor: theme.colors[c] ?? '#000' }} />
                      ))}
                    </div>
                    <div className={styles.themeSwatchRow}>
                      {colorMapLeft.map(c => {
                        const bc = 'bright' + c.charAt(0).toUpperCase() + c.slice(1);
                        return <div key={`b-${c}`} className={styles.themeSwatch} style={{ backgroundColor: theme.colors[bc] ?? theme.colors[c] ?? '#000' }} />;
                      })}
                    </div>
                  </div>
                  <div className={styles.themeName}>
                    <div className={styles.themeNameRow}>
                      <div>
                        {theme.name}
                        {theme.isDefault && <span className={styles.themeDefaultBadge}>default</span>}
                      </div>
                      <button
                        onClick={e => { e.stopPropagation(); setView('EDIT'); setEditIndex(index); }}
                        className={styles.themeEditBtn}
                        style={{ opacity: 1 }}
                      >
                        Edit
                      </button>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>

      </div>
    </div>
  );
}
