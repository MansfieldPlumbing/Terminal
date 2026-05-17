import { create } from "zustand";

export interface SystemNotification {
  id: string;
  message: string;
  type: "info" | "success" | "warn" | "error";
  timestamp: number;
}

export type TabType = 'terminal' | 'xterm' | 'applet' | 'notepad' | 'explorer' | 'colors' | 'settings' | 'debug' | 'smoke_test';

export interface Tab {
  id: string;
  type: TabType;
  title: string;
  path?: string;
  content?: string;
  language?: string;
}

export interface AppletProfile {
  guid: string;
  name: string;
  type: TabType;
  path?: string;
  icon?: string;
  hidden?: boolean;
  commandline?: string;
}

export interface AppConfig {
  profiles: {
    defaults?: any;
    list: AppletProfile[];
  };
}

interface AppState {
  tabs: Tab[];
  activeTabId: string | null;
  addTab: (tab: Tab) => void;
  removeTab: (id: string) => void;
  reorderTabs: (startIndex: number, endIndex: number) => void;
  closeTabsToRight: (id: string) => void;
  closeOtherTabs: (id: string) => void;
  setActiveTab: (id: string) => void;
  updateTabContent: (id: string, content: string) => void;
  updateTabTitle: (id: string, title: string) => void;
  setTabs: (tabs: Tab[]) => void;

  appConfig: AppConfig | null;
  fetchAppConfig: () => Promise<void>;

  commandPaletteVisible: boolean;
  setCommandPaletteVisible: (visible: boolean) => void;

  floatingCommandPaletteOpen: boolean;
  setFloatingCommandPaletteOpen: (open: boolean) => void;

  hamburgerMenuOpen: boolean;
  setHamburgerMenuOpen: (open: boolean) => void;

  testsMenuOpen: boolean;
  setTestsMenuOpen: (open: boolean) => void;

  thumbstickVisible: boolean;
  setThumbstickVisible: (visible: boolean) => void;

  autoHideTabs: boolean;
  setAutoHideTabs: (autoHide: boolean) => void;

  showInputBar: boolean;
  setShowInputBar: (show: boolean) => void;

  bgOpacity: number;
  setBgOpacity: (opacity: number) => void;

  micaOpacity: number;
  setMicaOpacity: (opacity: number) => void;
  micaBlur: number;
  setMicaBlur: (blur: number) => void;
  micaBaseColor: { r: number; g: number; b: number };
  setMicaBaseColor: (color: { r: number; g: number; b: number }) => void;

  uiScale: number;
  setUiScale: (scale: number) => void;

  canvasDpi: number;
  setCanvasDpi: (dpi: number) => void;
  canvasBlockScale: number;
  setCanvasBlockScale: (scale: number) => void;

  notifications: SystemNotification[];
  addNotification: (message: string, type?: SystemNotification["type"]) => void;
  removeNotification: (id: string) => void;
}

export const useAppStore = create<AppState>((set) => ({
  tabs: [],
  activeTabId: null,
  addTab: (tab) => set((state) => {
    if (tab.type === 'settings') {
      const existingSettingsTab = state.tabs.find(t => t.type === 'settings');
      if (existingSettingsTab) {
        return { activeTabId: existingSettingsTab.id };
      }
    }
    return {
      tabs: [...state.tabs, tab], 
      activeTabId: tab.id 
    };
  }),
  appConfig: null,
  fetchAppConfig: async () => {
    try {
      const res = await fetch('./config.json');
      if (res.ok) {
        const data = await res.json();
        set({ appConfig: data });
      }
    } catch (e) {
      console.error("Failed to load app config:", e);
    }
  },
  removeTab: (id) => set((state) => {
    const closedIndex = state.tabs.findIndex(t => t.id === id);
    if (closedIndex === -1) return state;
    const newTabs = state.tabs.filter(t => t.id !== id);
    let nextActiveId = state.activeTabId;
    if (state.activeTabId === id) {
      if (newTabs.length > 0) {
        const nextIndex = Math.min(closedIndex, newTabs.length - 1);
        nextActiveId = newTabs[nextIndex].id;
      } else {
        nextActiveId = null;
      }
    }
    return {
      tabs: newTabs,
      activeTabId: nextActiveId
    };
  }),
  reorderTabs: (startIndex, endIndex) => set((state) => {
    const result = Array.from(state.tabs);
    const [removed] = result.splice(startIndex, 1);
    result.splice(endIndex, 0, removed);
    return { tabs: result };
  }),
  closeTabsToRight: (id) => set((state) => {
    const index = state.tabs.findIndex(t => t.id === id);
    if (index === -1) return state;
    const newTabs = state.tabs.slice(0, index + 1);
    let nextActiveId = state.activeTabId;
    if (!newTabs.find(t => t.id === nextActiveId)) {
      nextActiveId = id;
    }
    return {
      tabs: newTabs,
      activeTabId: nextActiveId
    };
  }),
  closeOtherTabs: (id) => set((state) => {
    const tabToKeep = state.tabs.find(t => t.id === id);
    if (!tabToKeep) return state;
    return {
      tabs: [tabToKeep],
      activeTabId: id
    };
  }),
  setActiveTab: (id) => set({ activeTabId: id }),
  updateTabContent: (id, content) => set((state) => ({
    tabs: state.tabs.map(t => t.id === id ? { ...t, content } : t)
  })),
  updateTabTitle: (id, title) => set((state) => ({
    tabs: state.tabs.map(t => t.id === id ? { ...t, title } : t)
  })),
  setTabs: (tabs) => set({ tabs }),

  commandPaletteVisible: false,
  setCommandPaletteVisible: (visible) => set({ commandPaletteVisible: visible }),

  floatingCommandPaletteOpen: false,
  setFloatingCommandPaletteOpen: (open) => set({ floatingCommandPaletteOpen: open }),

  hamburgerMenuOpen: false,
  setHamburgerMenuOpen: (open) => set({ hamburgerMenuOpen: open, testsMenuOpen: false }),

  testsMenuOpen: false,
  setTestsMenuOpen: (open) => set({ testsMenuOpen: open, hamburgerMenuOpen: false }),

  thumbstickVisible: false,
  setThumbstickVisible: (visible) => set({ thumbstickVisible: visible }),

  autoHideTabs: true,
  setAutoHideTabs: (autoHide) => set({ autoHideTabs: autoHide }),
  showInputBar: true,
  setShowInputBar: (show) => set({ showInputBar: show }),

  bgOpacity: 0.5,
  setBgOpacity: (opacity) => set({ bgOpacity: opacity }),

  micaOpacity: 0.5,
  setMicaOpacity: (opacity) => set({ micaOpacity: opacity }),
  micaBlur: 6,
  setMicaBlur: (blur) => set({ micaBlur: blur }),
  micaBaseColor: { r: 20, g: 36, b: 75 },
  setMicaBaseColor: (color) => set({ micaBaseColor: color }),

  uiScale: 1.0,
  setUiScale: (scale) => set({ uiScale: scale }),

  canvasDpi: 1,
  setCanvasDpi: (dpi) => set({ canvasDpi: dpi }),
  canvasBlockScale: 1,
  setCanvasBlockScale: (scale) => set({ canvasBlockScale: scale }),

  notifications: [],
  addNotification: (message, type = "info") => {
    const id = Math.random().toString(36).substring(7);
    set((state) => ({
      notifications: [
        { id, message, type, timestamp: Date.now() },
        ...state.notifications,
      ],
    }));
    setTimeout(() => {
      set((state) => ({
        notifications: state.notifications.filter((n) => n.id !== id),
      }));
    }, 5000);
  },
  removeNotification: (id) =>
    set((state) => ({
      notifications: state.notifications.filter((n) => n.id !== id),
    })),
}));
