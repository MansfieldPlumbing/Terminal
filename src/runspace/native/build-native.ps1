$ErrorActionPreference = "Stop"

# Builds libpsl-android.so: the Bionic syslog null-stubs (libc.null.c) that let
# PowerShell's native layer boot on Android, plus pwshlog.cpp. No BoringSSL — adb
# pairing's SPAKE2 is now pure-managed (Spake25519Client), so this lib carries no
# crypto. Output replaces $(SsLibs)\arm64-v8a\libpsl-android.so consumed by the csproj.

# NDK location: $env:SS_NDK, else $env:ANDROID_NDK_HOME — no hardcoded machine paths.
$ndkDir = if ($env:SS_NDK) { $env:SS_NDK } elseif ($env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME } else { $null }

if (-not $ndkDir -or -not (Test-Path "$ndkDir\toolchains\llvm\prebuilt\windows-x86_64\bin\clang++.exe")) {
    Write-Host "Error: NDK clang++ not found. Set SS_NDK or ANDROID_NDK_HOME to your NDK root." -ForegroundColor Red
    exit 1
}

$clang = "$ndkDir\toolchains\llvm\prebuilt\windows-x86_64\bin\clang++.exe"
$sysroot = "$ndkDir\toolchains\llvm\prebuilt\windows-x86_64\sysroot"

if (-not (Test-Path "libs\arm64-v8a")) { New-Item -ItemType Directory "libs\arm64-v8a" | Out-Null }

Write-Host "Compiling libpsl-android.so (syslog stubs + pwshlog, no BoringSSL)..." -ForegroundColor Cyan
& $clang --target=aarch64-linux-android30 --sysroot="$sysroot" -shared -fPIC -O2 `
    libc.null.c pwshlog.cpp -llog -static-libstdc++ "-Wl,-z,max-page-size=16384" `
    -o libs\arm64-v8a\libpsl-android.so

if ($LASTEXITCODE -eq 0) {
    Write-Host "Compilation successful! Output: libs\arm64-v8a\libpsl-android.so" -ForegroundColor Green
} else {
    Write-Host "Compilation failed." -ForegroundColor Red
}
