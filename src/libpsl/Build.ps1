param(
    [ValidateSet('Arm64', 'Arm32')]
    [string] $Architecture = 'Arm64',
    [string] $NdkRoot
)

$ErrorActionPreference = 'Stop'

if (-not $NdkRoot) {
    $NdkRoot = if ($env:ANDROID_NDK_ROOT) {
        $env:ANDROID_NDK_ROOT
    } elseif ($env:ANDROID_NDK_HOME) {
        $env:ANDROID_NDK_HOME
    } else {
        $androidSdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
        if ($androidSdkRoot) {
            Get-ChildItem (Join-Path $androidSdkRoot 'ndk') -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -ExpandProperty FullName -First 1
        }
    }
}
if (-not $NdkRoot -or -not (Test-Path -LiteralPath $NdkRoot -PathType Container)) {
    throw 'Android NDK root was not found. Pass -NdkRoot or configure ANDROID_NDK_ROOT.'
}

$target = if ($Architecture -eq 'Arm32') {
    @{
        Abi = 'armeabi-v7a'
        Compiler = 'armv7a-linux-androideabi34-clang.cmd'
        ExpectedSha256 = '523B1455849710A279CCCCC3A02ABB8138050A9F09580C5E2A1E514ED78E85AD'
    }
} else {
    @{
        Abi = 'arm64-v8a'
        Compiler = 'aarch64-linux-android34-clang.cmd'
        ExpectedSha256 = '4605293D2EAD6D06CF39C45534C5928B8F40DB3AB2A80B415F7FE36C56961A32'
    }
}

$ExpectedSha256 = $target.ExpectedSha256
$Clang = Join-Path $NdkRoot (
    'toolchains\llvm\prebuilt\windows-x86_64\bin\' + $target.Compiler)

$Source = Join-Path $PSScriptRoot 'libc.null.c'
$NativeRoot = Split-Path $PSScriptRoot -Parent
$OutputDir = Join-Path $NativeRoot $target.Abi
$Output = Join-Path $OutputDir 'libpsl-native.so'
$Candidate = Join-Path $env:TEMP ('libpsl-native.' + $target.Abi + '.rebuild.so')

if (-not (Test-Path $Clang)) {
    throw "Android clang not found: $Clang"
}

New-Item -ItemType Directory -Force $OutputDir | Out-Null
Remove-Item $Candidate -Force -ErrorAction SilentlyContinue

& $Clang `
    -O0 `
    -fPIC `
    -shared `
    $Source `
    '-Wl,-z,max-page-size=16384' `
    -o $Candidate

if ($LASTEXITCODE -ne 0) {
    throw "clang failed with exit code $LASTEXITCODE"
}

$Actual = (Get-FileHash $Candidate -Algorithm SHA256).Hash

if ($Actual -ne $ExpectedSha256) {
    throw @"
libpsl-native.so reproducibility failure.

Expected: $ExpectedSha256
Actual:   $Actual

The generated binary was NOT promoted.
"@
}

Copy-Item $Candidate $Output -Force

$Item = Get-Item $Output

[pscustomobject]@{
    Status = 'PASS'
    Architecture = $Architecture
    Abi = $target.Abi
    Length = $Item.Length
    SHA256 = $Actual
    Output = $Output
}
