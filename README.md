# Terminal

Terminal is a PowerShell-native application environment for Android.

It runs CoreCLR and `System.Management.Automation` directly inside the Android
process. The process keeps a persistent PowerShell runspace and loads
`FilesDir/Profile.ps1`, which owns the application after Android admits it.

The Android host is emitted from PowerShell-authored CLR expression graphs.
`Profile.ps1` can own the application surface, launch other PowerShell
applications, create additional runspaces, and use Android APIs directly.

```text
Android process
    -> emitted Android host
    -> persistent SMA runspace
    -> FilesDir/Profile.ps1
         -> application shell
         -> Terminal.ps1
         -> other PowerShell applications
    -> Android presentation and platform APIs
```

The repository contains the emitted Android host and recovery path, the
PowerShell application shell, an interactive terminal/editor/settings surface,
Android presentation code, and ARM32 and ARM64 CoreCLR build work.

## Recovery contract

Terminal requires one user-managed file:

```text
FilesDir/
  Profile.ps1
  *                # optional files used by Profile.ps1
```

If `Profile.ps1` is absent or fails, the Activity shows the source, line,
column, source text, and message when available. The recovery screen imports any
selected document into `FilesDir` under its display name. Importing
`Profile.ps1` retries with a fresh runspace. Other files, including `config.ini`
or `cat.jpg`, are available to the start script under `$PSScriptRoot`.

The current Activity is available to the start script as `$Activity`. Android's
global application context remains available directly as
`[Android.App.Application]::Context`. The host publishes the fixed file
directory as `$PSScriptRoot` before invoking the start-script source.

## Reproduce the toolchain

Use a PowerShell host whose SMA and .NET versions match the Android runtime
artifacts being packaged. Resolve it explicitly before running the commands:

```powershell
$PowerShellPath = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
  Select-Object -First 1).Source
if (-not $PowerShellPath) {
  throw 'PowerShell was not found. Install it or set $PowerShellPath explicitly.'
}
```

The Android workload materializer downloads the workload manifests and every
declared pack directly from NuGet. It also explicitly installs and seeds the
NuGet global-package layout for `Microsoft.NETCore.App.Runtime.android-arm`,
including `libcoreclr.so` and `libclrjit.so`.

```powershell
& $PowerShellPath -NoProfile -ExecutionPolicy Bypass `
  -File .\Scripts\Install-AndroidWorkload.ps1
```

## Build

The current build machinery still carries several `AndroidSMA` identifiers from
the donor project. These are implementation names being mechanically renamed to
Terminal; they are not a second product.

The current authored build entry point is:

```powershell
& $PowerShellPath -NoProfile -ExecutionPolicy Bypass `
  -File .\Build-AndroidSMA.ps1
```

ARM32 CoreCLR:

```powershell
& $PowerShellPath -NoProfile -ExecutionPolicy Bypass `
  -File .\Build-AndroidSMA.ps1 -RuntimeIdentifier android-arm
```

Both targets accept `-Configuration Debug`.

`Build-AndroidSMA.ps1` accepts explicit `-JavaCompilerPath`, `-D8Path`,
`-LlvmMcPath`, `-LinkerPath`, `-ZstdLibraryPath`, `-AndroidSdkRoot`, and
`-DotnetRoot` values.
Without them, it discovers executables from `PATH`, `JAVA_HOME`,
`ANDROID_SDK_ROOT`/`ANDROID_HOME`, `DOTNET_ROOT`, and the active `dotnet`
installation. A missing tool or root stops the build with a direct error.

The current package identifier is
`dev.mansfieldplumbing.androidsma`; it will move with the remaining build
identity during the Terminal rename.

The APK packages the PowerShell native compatibility shim as
`libpsl-native.so`. Rebuild it with
`Native/PowerShellShim/Source/Build-libpsl-native.ps1` when required.

## Lifetime

The runspace is process-static. Activity recreation and normal background/
foreground transitions reuse it; process death starts a new runspace and runs
`Profile.ps1` again.

Terminal does not claim stronger lifetime semantics through a foreground
service.

## License

See [`LICENSE`](LICENSE).
