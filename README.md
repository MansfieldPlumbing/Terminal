# Terminal

**PowerShell 7 hosted in-process inside a native Android app — no Linux userland, no VM, no proot, no root.**

Terminal runs the `Microsoft.PowerShell.SDK` runspace directly inside a .NET 11 (`net11.0-android`) process on CoreCLR, on the device's ARM64 CPU. It is **not** a terminal emulator over SSH, a Termux/proot environment, or a Linux VM — the runspace lives in the app's own process and defines its cmdlets at runtime.

Terminal is the **focused, AI-free head of [Subsystem](https://github.com/MansfieldPlumbing/Subsystem)** — the same NT-shaped object substrate and registry-driven WebView shell, reshaped into a clean Android terminal: multiple PowerShell sessions, a taskbar/Start shell, a file browser, and a code editor.

## What's here

- **In-process CoreCLR + PowerShell runspace** on Android (`src/runspace`) — the VOM object kernel, the `Cm` registry, the REPL, and the Android device cmdlets.
- **A registry-driven WebView shell** (`src/shell`) — a taskbar, a cascading Start menu, charms, and presenters (terminal, files, editor, settings), all projected from the registry. The UI holds no truth.
- **A dependency-free code editor** (`src/shell/lib/codeedit.js`) — a vanilla, "monaco-like" editor (a native `<textarea>` over a syntax-highlight overlay, with a gutter), replacing Monaco's 12 MB TypeScript language service. Caret, IME, selection, and undo/redo are the OS's own — the things a custom editor gets wrong on touch.

## How it relates to Subsystem

Terminal is a **curated head**, not a hard fork. The shell + runspace core come from Subsystem via a reproducible strip — [`tools/strip-from-subsystem.ps1`](tools/strip-from-subsystem.ps1) — which removes the Windows head and the AI's reachable surface while keeping the core intact. Re-syncing Subsystem improvements is *re-running the strip* + reapplying the documented seam edits, not a manual merge.

What the strip removes for the focused product:

- **The Windows head** (Android-only product).
- **The AI as a usable feature** — the on-device LLM `RuntimeBroker` plumbing still compiles, but nothing in the UI reaches it (no agent app, no Broker charm, no model picker). It ships dormant; drop `libLiteRtLm.so` from `Subsystem.csproj` for the lean APK.
- **The shader-background live wallpaper** + the in-WebView WebGL backdrop — a continuous-GPU resource hog on a terminal.
- **Monaco** — replaced by the vanilla editor above.

## Building

A .NET 11 Android app: the .NET 11 preview SDK + **JDK 21**, targeting `net11.0-android`, built on physical ARM64 hardware. The native PowerShell shims (`libpsl-*.so`) are provided via `SS_LIBS` (they are build inputs, not committed):

```powershell
$env:SS_LIBS = '<dir containing arm64-v8a\libpsl-*.so>'
$env:SS_JDK  = '<path to JDK 21>'
dotnet build src/runspace/Subsystem.csproj -c Debug
```

## Lineage

Forked from [Subsystem](https://github.com/MansfieldPlumbing/Subsystem) (MIT). The architecture, doctrine, and hardware verification are the author's; AI pair-engineering (Claude) was the force multiplier.

## License

MIT — see [LICENSE](LICENSE).
