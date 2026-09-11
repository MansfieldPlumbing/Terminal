param(
    [Parameter(Mandatory=$true)]
    [string]$AssemblyPath,

    [Parameter(Mandatory=$true)]
    [string]$OutPayloadPath,

    [Parameter(Mandatory=$true)]
    [uint32]$DescriptorIndex,

    [int]$CompressionLevel = 3,

    [string]$ZstdDllPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $AssemblyPath)) {
    throw "Source assembly not found: $AssemblyPath"
}
if (-not $ZstdDllPath) {
    $ZstdDllPath = $env:ZSTD_LIBRARY
}
if (-not $ZstdDllPath) {
    $zstd = Get-Command libzstd.dll -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($zstd) { $ZstdDllPath = $zstd.Source }
}
if (-not $ZstdDllPath -or -not (Test-Path -LiteralPath $ZstdDllPath)) {
    throw 'libzstd.dll was not found. Pass -ZstdDllPath or set ZSTD_LIBRARY.'
}
$ZstdDllPath = (Resolve-Path -LiteralPath $ZstdDllPath).Path

# Ensure P/Invoke type is compiled
if (-not ([System.Management.Automation.PSTypeName]'XazsNative').Type) {
    $csharp = @"
using System;
using System.Runtime.InteropServices;

public static class XazsNative
{
    private const string LibName = @"$($ZstdDllPath.Replace('\', '\\'))";

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr ZSTD_compress(byte[] dst, UIntPtr dstCapacity, byte[] src, UIntPtr srcSize, int compressionLevel);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr ZSTD_compressBound(UIntPtr srcSize);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr ZSTD_decompress(byte[] dst, UIntPtr dstCapacity, byte[] src, UIntPtr srcSize);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint ZSTD_isError(UIntPtr code);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ZSTD_getErrorName(UIntPtr code);
}
"@
    Add-Type -TypeDefinition $csharp
}

$rawBytes = [System.IO.File]::ReadAllBytes($AssemblyPath)
$uncompressedSize = [uint32]$rawBytes.Length

$bound = [ulong][XazsNative]::ZSTD_compressBound([UIntPtr]$uncompressedSize)
$compBuf = New-Object byte[] $bound
$compSize = [XazsNative]::ZSTD_compress($compBuf, [UIntPtr]$bound, $rawBytes, [UIntPtr]$uncompressedSize, $CompressionLevel)

if ([XazsNative]::ZSTD_isError($compSize) -ne 0) {
    $errPtr = [XazsNative]::ZSTD_getErrorName($compSize)
    $errMsg = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($errPtr)
    throw "Zstandard compression failed: $errMsg"
}

$frameLen = [int][ulong]$compSize
$payload = New-Object byte[] (12 + $frameLen)

# XAZS header (12 bytes)
$payload[0] = 0x58 # X
$payload[1] = 0x41 # A
$payload[2] = 0x5A # Z
$payload[3] = 0x53 # S
[System.BitConverter]::GetBytes($DescriptorIndex).CopyTo($payload, 4)
[System.BitConverter]::GetBytes($uncompressedSize).CopyTo($payload, 8)
[System.Buffer]::BlockCopy($compBuf, 0, $payload, 12, $frameLen)

$outDir = [System.IO.Path]::GetDirectoryName($OutPayloadPath)
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

[System.IO.File]::WriteAllBytes($OutPayloadPath, $payload)
Write-Host "Compressed payload written: $OutPayloadPath ($($payload.Length) bytes, uncompressed=$uncompressedSize)"
