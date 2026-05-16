export const executeCommand = (command: string) => {
  if (typeof window !== 'undefined' && (window as any).AndroidBridge) {
    (window as any).AndroidBridge.invokeCommand(command);
  } else {
    // Web test environment fallback
    console.log('[Mock AndroidBridge] Executing:', command);
    if ((window as any).host?.call) {
        (window as any).host.call('tty.in', btoa(command + '\r'));
    }
  }
};

export const minimizeAppFromBridge = () => {
  if (typeof window !== 'undefined' && (window as any).AndroidBridge?.minimizeApp) {
    (window as any).AndroidBridge.minimizeApp();
  }
};
