import React, { useEffect } from 'react';
import { FluentProvider, webDarkTheme, makeStyles, mergeClasses } from '@fluentui/react-components';
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

const useStyles = makeStyles({
  shell: {
    position: 'fixed',
    inset: 0,
    width: '100%',
    height: '100%',
    backgroundColor: '#000',
    overflow: 'hidden',
    fontFamily: 'sans-serif',
    display: 'flex',
    flexDirection: 'column',
  },
  mainContainer: {
    width: '100%',
    height: '100%',
    overflow: 'hidden',
    position: 'relative',
    display: 'flex',
    flexDirection: 'column',
    zIndex: 10,
    userSelect: 'none',
  },
  terminalArea: {
    flex: 1,
    width: '100%',
    height: '100%',
    overflow: 'hidden',
    position: 'relative',
    fontFamily: 'monospace',
    display: 'flex',
    flexDirection: 'column',
    pointerEvents: 'auto',
  },
  tabContent: {
    position: 'absolute',
    width: '100%',
    bottom: 0,
    top: '56px',
    transition: 'all 200ms',
  },
  emptyState: {
    position: 'absolute',
    inset: 0,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    color: 'rgba(238,237,240,0.5)',
    fontFamily: 'sans-serif',
    fontSize: '14px',
    backgroundColor: 'rgba(0,0,0,0.4)',
    backdropFilter: 'blur(4px)',
    gap: '4px',
  },
  tab: {
    position: 'absolute',
    inset: 0,
    width: '100%',
    height: '100%',
    boxShadow: 'inset 0 4px 10px rgba(0,0,0,0.3)',
    overflow: 'hidden',
  },
  tabActive: {
    display: 'block',
  },
  tabHidden: {
    display: 'none',
    pointerEvents: 'none',
  },
  tabTerminal: {
    backgroundColor: 'rgba(0,0,0,0.4)',
    backdropFilter: 'blur(4px)',
  },
  iframe: {
    width: '100%',
    height: '100%',
    border: 'none',
    backgroundColor: '#000',
    isolation: 'isolate',
  },
});

export default function App() {
  const styles = useStyles();
  const {
    tabs, activeTabId,
    thumbstickVisible,
    micaOpacity, bgOpacity, micaBlur, micaBaseColor, uiScale,
    fetchAppConfig
  } = useAppStore();

  useEffect(() => {
    fetchAppConfig();
    if (typeof window !== 'undefined' && (window as any).AndroidBridge?.notifyReady) {
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
    <FluentProvider theme={webDarkTheme} style={{ colorScheme: 'dark', background: 'transparent', height: '100%' }}>
      <div className={styles.shell}>
        <WebGLWallpaper />

        <div className={styles.mainContainer}>
          <div className={styles.terminalArea}>
            <TabBar />

            <div className={styles.tabContent}>
              {tabs.length === 0 && (
                <div className={styles.emptyState}>
                  Tap <Menu size={16} style={{ display: 'inline', margin: '0 6px' }} /> or{' '}
                  <Plus size={16} style={{ display: 'inline', margin: '0 6px' }} /> to start.
                </div>
              )}

              {tabs.map(tab => {
                const isActive = activeTabId === tab.id;
                return (
                  <div
                    key={tab.id}
                    className={mergeClasses(
                      styles.tab,
                      isActive ? styles.tabActive : styles.tabHidden,
                      tab.type === 'terminal' ? styles.tabTerminal : 'mica-background'
                    )}
                  >
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
                        className={styles.iframe}
                        sandbox="allow-scripts allow-forms allow-same-origin allow-downloads allow-popups allow-modals"
                      />
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {thumbstickVisible && <Thumbstick />}
          <FloatingCommandPalette />
          <Notifications />
        </div>
      </div>
    </FluentProvider>
  );
}
