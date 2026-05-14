// src/lib/pwshBridge.ts

declare global {
  interface Window {
    // This interface matches the name of the bridge you inject via the Android WebView
    AndroidBridge?: {
      // In C#, this will map to: 
      // [Export("invokeCommand")]
      // [JavascriptInterface]
      // public void InvokeCommand(string command) { ... }
      invokeCommand: (command: string) => void;
      minimizeApp?: () => void;
    };
    
    // Global callback for the Android layer to push text back into the React app
    receivePwshOutput?: (output: string) => void;
  }
}

// A simple event system so our React app can listen to incoming text streams
type OutputCallback = (text: string) => void;
const listeners: OutputCallback[] = [];

// Expose a global hook for Android to call
if (typeof window !== 'undefined') {
  window.receivePwshOutput = (output: string) => {
    listeners.forEach(listener => listener(output));
  };
}

export const subscribeToOutput = (callback: OutputCallback) => {
  listeners.push(callback);
  return () => {
    const idx = listeners.indexOf(callback);
    if (idx > -1) listeners.splice(idx, 1);
  };
};

export const minimizeAppFromBridge = () => {
  if (typeof window !== 'undefined' && window.AndroidBridge && window.AndroidBridge.minimizeApp) {
    window.AndroidBridge.minimizeApp();
  } else {
    console.log('[Mock AndroidBridge] Minimizing app...');
  }
};

export const executeCommand = (command: string) => {
  if (typeof window !== 'undefined' && window.AndroidBridge) {
    // Send to native .NET Android backend via the JavascriptInterface
    window.AndroidBridge.invokeCommand(command);
  } else {
    // Development Fallback: Simulate standard terminal response in browser
    console.log('[Mock AndroidBridge] Executing:', command);
    
    // Simulate slight command delay
    setTimeout(() => {
      // Simulate standard ping response or simple echo
      if (command.toLowerCase() === 'ping 8.8.8.8') {
        window.receivePwshOutput?.('Pinging 8.8.8.8 with 32 bytes of data:\nReply from 8.8.8.8: bytes=32 time=14ms TTL=117\n');
      } else if (command.toLowerCase() === 'clear' || command.toLowerCase() === 'cls') {
          // You could implement a special clearing command or handle it in the UI side
      } else {
        window.receivePwshOutput?.(`Demo mode (No Android Host): ${command}\n`);
      }
    }, 200);
  }
};
