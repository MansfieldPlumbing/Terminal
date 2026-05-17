import {StrictMode} from 'react';
import {createRoot} from 'react-dom/client';
import App from './App.tsx';
import './index.css';

// Initialize output buffers to catch boot traffic before terminal mounts
(window as any).__pwshOutputBuffer = [];
(window as any).__writeToTerminalBuffer = [];

(window as any).receivePwshOutput = (output: string) => {
  const dispatch = (window as any).__dispatchPwshOutput;
  if (dispatch) {
    dispatch(output);
  } else {
    (window as any).__pwshOutputBuffer.push(output);
  }
};

(window as any).writeToTerminal = (b64Payload: string) => {
  const dispatch = (window as any).__dispatchWriteToTerminal;
  if (dispatch) {
    dispatch(b64Payload);
  } else {
    (window as any).__writeToTerminalBuffer.push(b64Payload);
  }
};

// Notify C# that we are ready to receive the boot output is now handled by the App component on mount.


createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

// Listen for Native Android WebMessages (ArrayBuffers for Canvas, Strings for Xterm)
window.addEventListener('message', (e) => {
    if (typeof e.data === 'string') {
        const dispatch = (window as any).__dispatchPwshOutput;
        if (dispatch) {
            dispatch(e.data);
        } else {
            (window as any).__pwshOutputBuffer.push(e.data);
        }
    }
});
