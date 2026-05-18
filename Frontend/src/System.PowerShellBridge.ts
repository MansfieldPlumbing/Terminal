// Batched raw input: accumulates keystrokes/VT100 sequences and flushes
// once per animation frame — single JNI crossing per frame regardless of
// how many characters arrived (paste, rapid typing, thumbstick sweeps).
let _inputBuffer = '';
let _flushPending: number | null = null;

export const sendRawInput = (data: string) => {
  _inputBuffer += data;
  if (_flushPending === null) {
    _flushPending = window.requestAnimationFrame(() => {
      const payload = _inputBuffer;
      _inputBuffer = '';
      _flushPending = null;
      if ((window as any).AndroidBridge) {
        (window as any).AndroidBridge.sendRawInput(payload);
      } else if ((window as any).host?.call) {
        (window as any).host.call('tty.in', btoa(payload));
      }
    });
  }
};

export const executeCommand = (command: string) => {
  if ((window as any).AndroidBridge) {
    (window as any).AndroidBridge.invokeCommand(command);
  } else if ((window as any).host?.call) {
    (window as any).host.call('tty.in', btoa(command + '\r'));
  }
};

export const minimizeAppFromBridge = () => {
  (window as any).AndroidBridge?.minimizeApp?.();
};
