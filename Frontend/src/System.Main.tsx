import {StrictMode} from 'react';
import {createRoot} from 'react-dom/client';
import App from './App.tsx';
import './index.css';

// Notify C# that we are ready to receive the boot output and ArrayBuffers
if (typeof window !== 'undefined' && (window as any).AndroidBridge && (window as any).AndroidBridge.notifyReady) {
  setTimeout(() => (window as any).AndroidBridge.notifyReady(), 50);
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
