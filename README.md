# PSHost Mobile (Mansfield Plumbing Edition)
**A Micro-Frontend Operating Environment for Android, powered by .NET 11 and PowerShell 7.6.1.**

This repository demonstrates a completely novel architecture for hosting the raw `Microsoft.PowerShell.SDK` natively on an ARM64 Android device. It entirely bypasses standard Android XML/Compose UIs, opting instead for a React/Vite web-frontend hosted inside an embedded WebView, communicating bidirectionally with a background C# PowerShell daemon via a Base64 JSON bridge.

## The Black Magic (How this works)
Historically, hosting PowerShell on Android failed due to Bionic libc incompatibilities and IL Trimmer destruction. This project solves these via three major workarounds:

1. **The Telemetry Interceptor (`psl_dummy.c` & `NativeLibrary.SetDllImportResolver`)**
   PowerShell attempts to P/Invoke into a Linux-compiled `libpsl-native.so` for SysLog telemetry, which Android's Bionic C-library rejects, causing a fatal `TypeInitializationException`. We compile a dummy library aligned to Android 16's strict 16KB page sizes and intercept the engine's load request via C# reflection to serve our fake library.
2. **The Trimmer Bypass**
   PowerShell relies heavily on reflection and generic tuples. We disable the .NET 11 IL Trimmer and manually load the `Utility` and `Management` Cmdlets/Providers into an empty `InitialSessionState` to prevent `applicationBase` location crashes.
3. **The Micro-Frontend Sandbox**
   Instead of writing new Android code for tools, the frontend dynamically loads single-file `.html` applets inside `<iframe>` tags. The applets send `postMessage` payloads to the React shell, which proxies commands to the C# daemon and routes the output back.

## Build Instructions
1. Ensure the `.NET 11 SDK` and `Android workload` are installed.
2. Build the React frontend: `cd ReactUI && npm install && npm run build`
3. Copy `ReactUI/dist/*` to `Assets/wwwroot/`
4. Publish the APK: `dotnet publish -c Release -r android-arm64`
