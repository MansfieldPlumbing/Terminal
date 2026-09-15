# Terminal ARM32 / CoreCLR

This directory records the proven 32-bit Terminal target.

It is intentionally treated as a distinct development line from the ARM64 phone/QNN work. The ARM32 target is expected to receive less development attention, but the working configuration is worth preserving as a first-class Terminal target.

## Proven target

The physical-device run used:

```text
Android:      Android 14 / API 34
RID:          android-arm
ABI:          armeabi-v7a
Runtime:      .NET 11 Preview 7 CoreCLR + JIT
PowerShell:   Microsoft.PowerShell.SDK 7.7.0-preview.2
Device class: Google TV / 32-bit Android userspace
```

The resulting APK contained ARM32 builds of `libcoreclr.so` and `libclrjit.so` and successfully executed `System.Management.Automation` in-process on the device.

The demonstrated path included:

```text
Android process
    ↓
CoreCLR
    ↓
System.Management.Automation
    ↓
persistent PowerShell service/runspace
    ↓
dedicated PowerShell UI runspace
    ↓
PowerShell-owned packed-cell Android Canvas
```

This is not the Qualcomm QNN target. The ARM32 Google TV work is a separate appliance/TV experiment.

## Known-good Preview 7 components

The successful investigation used these published packages/components:

```text
.NET SDK
11.0.100-preview.7.26381.103

Microsoft.NETCore.App.Runtime.android-arm
11.0.0-preview.7.26381.103

Microsoft.Android.Runtime.CoreCLR.37.android-arm
37.0.0-preview.7.2131

Microsoft.PowerShell.SDK
7.7.0-preview.2
```

The Android CoreCLR host pack is published by Microsoft as a platform package. This repository does not claim a broader support policy beyond the packages and behavior actually observed.

## The workload yak shave

The first `android-arm` CoreCLR restore failed with:

```text
NETSDK1181
Pack 'Microsoft.Android.Runtime.CoreCLR.37.android-arm' was not present in workload manifests.
```

The runtime and Android host packages themselves existed. The problem encountered on the development machine was workload registration/state: the machine-wide installation remained associated with the Preview 6 Android manifest even after Preview 7 workload activity.

A local, file-based Preview 7 SDK environment recognized the ARM32 CoreCLR pack and restored/built the project successfully.

From the ARM32 working-tree root, the known-good invocation was:

```powershell
$DotnetP7 = Join-Path $PWD '.dotnet-p7\dotnet.exe'

$env:DOTNET_ROOT = Split-Path $DotnetP7 -Parent
$env:DOTNET_MULTILEVEL_LOOKUP = '0'

& $DotnetP7 restore .\Terminal.Mvp.csproj
& $DotnetP7 build .\Terminal.Mvp.csproj -c Debug
```

The local SDK directory and downloaded/extracted runtime packages are build tooling, not source, and should not be committed.

## Native PowerShell compatibility shim

The ARM32 `libpsl-android.so` compatibility shim was built with the Android NDK ARMv7 compiler (`armv7a-linux-androideabi34-clang`).

The proven ARM32 shim result was:

```text
SHA-256
523B1455849710A279CCCCC3A02ABB8138050A9F09580C5E2A1E514ED78E85AD
```

The shim exists only to satisfy narrow native PowerShell compatibility edges; it is not the application runtime.

## Android 14 / API 34 canvas compatibility

The .NET Android bindings used by the project target newer Android APIs than the Google TV device provides.

The first dedicated-UI-runspace canvas launch reached the Android UI callback and failed because these properties map to API 35 methods:

```text
View.RequestedFrameRate
Window.FrameRateBoostOnTouchEnabled
```

On API 34, `View.setRequestedFrameRate(float)` is absent.

For first light, the ARM32 canvas script removed the API-35-only property access and allowed Android 14 to use the platform-default presentation rate. The patched script then rendered the packed-cell workload on the physical device.

The compatibility change used was equivalent to:

```powershell
# API 35+ only; API 34 uses the platform default.
# $surface.RequestedFrameRate = [single]120.0

[Android.Util.Log]::Info(
    'PowerShell',
    "Canvas window sdk=$([int][Android.OS.Build+VERSION]::SdkInt) requestedFrameRate=platform-default")
```

Future cleanup should prefer an explicit SDK-version guard if the same source is intended to run on both API 34 and API 35+.

## Status

Proven on physical hardware:

- `android-arm` restore/build under the local Preview 7 SDK environment
- ARM32 CoreCLR/JIT packaged into the APK
- APK installation and cold launch on 32-bit Android 14
- persistent SMA profile/service execution
- dedicated PowerShell UI runspace creation
- PowerShell canvas script execution
- packed-cell Canvas rendering after the API 34 compatibility correction

Still intentionally unfinished:

- polished Google TV / D-pad application surface
- final `autoexec.ps1` / writable-profile bootstrap architecture
- remote administration/control plane
- a completely automated ARM32 SDK/workload bootstrap

The target is preserved because it works, not because it is intended to track every ARM64 experiment.
