#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateSet('android-arm64', 'android-arm')]
    [string] $RuntimeIdentifier = 'android-arm',

    [string] $ApplicationId = 'dev.mansfieldplumbing.androidsma',

    [string] $JavaCompilerPath,

    [string] $D8Path,

    [string] $LlvmMcPath,

    [string] $LinkerPath,

    [string] $ZstdLibraryPath,

    [string] $AndroidSdkRoot,

    [string] $DotnetRoot
)

#region 00 — Strict Mode & Global Failure Policy
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

function Resolve-BuildExecutable {
    param(
        [string] $ExplicitPath,
        [Parameter(Mandatory)][string] $DisplayName,
        [Parameter(Mandatory)][string[]] $CommandName,
        [string[]] $CandidatePath = @()
    )

    if ($ExplicitPath) {
        $resolved = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "$DisplayName was not found at the explicit path '$resolved'."
        }
        return $resolved
    }

    foreach ($name in $CommandName) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) { return $command.Source }
    }

    foreach ($candidate in $CandidatePath) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw "$DisplayName was not found. Pass its explicit path or make it discoverable on PATH."
}

function Resolve-BuildDirectory {
    param(
        [string] $ExplicitPath,
        [Parameter(Mandatory)][string] $DisplayName,
        [string[]] $CandidatePath = @()
    )

    foreach ($candidate in @($ExplicitPath) + $CandidatePath) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw "$DisplayName was not found. Pass its explicit root path."
}

function Find-FirstFile {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Filter,
        [Parameter(Mandatory)][string] $Description
    )

    $match = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $match) { throw "$Description was not found beneath '$Root'." }
    $match.FullName
}

#region 01 — Authored Assembly Emission
# Emit the real AndroidSMA assembly from the authored PowerShell graph.
$androidSmaDll = Join-Path $PSScriptRoot 'build\generated\AndroidSMA.dll'
& (Join-Path $PSScriptRoot 'Scripts\Emit-AndroidSMA.ps1') -OutputPath $androidSmaDll
if (-not [IO.File]::Exists($androidSmaDll)) {
    throw "AndroidSMA.dll was not emitted: $androidSmaDll"
}
#endregion

#region 02 — Configuration & Path Topological Setup
if ([string]::IsNullOrWhiteSpace($ApplicationId)) {
    $ApplicationId = 'dev.mansfieldplumbing.androidsma'
}
$androidAbi = if ($RuntimeIdentifier -eq 'android-arm64') { 'arm64-v8a' } else { 'armeabi-v7a' }
$debuggable = $Configuration -eq 'Debug'
$smaPackageVersion = $PSVersionTable.PSVersion.ToString()

$dotnetCommand = Get-Command dotnet.exe, dotnet -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$dotnetCommandRoot = if ($dotnetCommand) { Split-Path $dotnetCommand.Source -Parent } else { $null }
$DotnetRoot = Resolve-BuildDirectory -ExplicitPath $DotnetRoot -DisplayName '.NET root' `
    -CandidatePath @($env:DOTNET_ROOT, $dotnetCommandRoot)
$AndroidSdkRoot = Resolve-BuildDirectory -ExplicitPath $AndroidSdkRoot -DisplayName 'Android SDK root' `
    -CandidatePath @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)

$apkOutput = Join-Path $PSScriptRoot "build\apk\$RuntimeIdentifier\$Configuration"
if (-not (Test-Path $apkOutput)) {
    New-Item -ItemType Directory -Path $apkOutput -Force | Out-Null
}

$tempDir = Join-Path $PSScriptRoot "build\temp\$RuntimeIdentifier\$Configuration"
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}
#endregion

#region 03 — Oracle Provenance Verification (Pinned Generation E85A25C3)
# The build borrows proven shell artifacts from an immutable, byte-pinned oracle generation:
# Oracle APK: E85A25C3A632FB0BB319769D1B19C3CBDAAA25A0B1406E752DC011F8883B3BF1
# Oracle XABA: 3EC2CEF338CD39D5A8B9410052A73EF3E8C924C537DCA4BC2BAF0B95BF2BE741
$oracleDir = Join-Path $PSScriptRoot "build\provenance\oracle-arm32-E85A25C3"
if ($RuntimeIdentifier -ne 'android-arm' -or -not (Test-Path $oracleDir)) {
    throw "Oracle provenance is currently pinned for android-arm at $oracleDir. Other architectures require pinned provenance."
}

$oracleXabaPath   = Join-Path $oracleDir "oracle-xaba.bin"
$oraclePayloadDir = Join-Path $oracleDir "payloads"
$oracleExtractDir = Join-Path $oracleDir "extracted"

$expectedXabaHash = "3EC2CEF338CD39D5A8B9410052A73EF3E8C924C537DCA4BC2BAF0B95BF2BE741"
$actualXabaHash   = (Get-FileHash $oracleXabaPath -Algorithm SHA256).Hash
if ($actualXabaHash -ne $expectedXabaHash) {
    throw "Oracle XABA hash mismatch!`n  Expected: $expectedXabaHash`n  Got:      $actualXabaHash"
}
#endregion

#region 04 — Encode Managed Assembly Payloads (XAZS Format)
# Input:
#   Emitted managed assembly (AndroidSMA.dll) + remaining 337 oracle payloads
# Output:
#   Payload directory populated with XAZS compressed binary blocks
# Physical Contract:
#   Offset 0x00..0x03 : 'XAZS' (0x58415A53)
#   Offset 0x04..0x07 : uint32 descriptorIndex (150 for AndroidSMA.dll)
#   Offset 0x08..0x0B : uint32 uncompressedLength (13,312 bytes)
#   Offset 0x0C..end  : Zstandard frame (Level 3 compression)
Write-Host "04 — Encoding managed assembly payloads..."

$payloadWorkDir = Join-Path $tempDir "payloads"
# Always rebuild from scratch — stale payload files from prior runs silently satisfy
# Region 05 lookups, making population changes invisible. Correctness requires a clean slate.
if (Test-Path $payloadWorkDir) { Remove-Item $payloadWorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $payloadWorkDir -Force | Out-Null

# 1. Populate upstream oracle payloads
# Excluded: AndroidSMA.dll (replaced by emitted build below)
# Excluded: AndroidSMA.PackagingHost.dll (unclassified — must defend right to exist; excluded pending runtime verification)
Get-ChildItem (Join-Path $oraclePayloadDir "*.bin") | Where-Object {
    $_.Name -notmatch 'AndroidSMA\.dll\.bin' -and
    $_.Name -notmatch 'AndroidSMA\.PackagingHost\.dll\.bin'
} | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $payloadWorkDir $_.Name) -Force
}

# 2. P/Invoke binding for Zstandard compression
if (-not ([System.Management.Automation.PSTypeName]'ZstdEngine').Type) {
    $zstdEnvironmentCandidate = $env:ZSTD_LIBRARY
    $ZstdLibraryPath = Resolve-BuildExecutable -ExplicitPath $ZstdLibraryPath `
        -DisplayName 'Zstandard native library' -CommandName @('libzstd.dll') `
        -CandidatePath @($zstdEnvironmentCandidate)
    $escapedZstdLibraryPath = $ZstdLibraryPath.Replace('"', '""')
    $csharp = @"
using System;
using System.Runtime.InteropServices;

public static class ZstdEngine
{
    private const string LibName = @"$escapedZstdLibraryPath";

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr ZSTD_compress(byte[] dst, UIntPtr dstCapacity, byte[] src, UIntPtr srcSize, int compressionLevel);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr ZSTD_compressBound(UIntPtr srcSize);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint ZSTD_isError(UIntPtr code);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ZSTD_getErrorName(UIntPtr code);
}
"@
    Add-Type -TypeDefinition $csharp
}

# 3. Compress newly emitted AndroidSMA.dll into payload_336_AndroidSMA.dll.bin
$rawAssemblyBytes = [System.IO.File]::ReadAllBytes($androidSmaDll)
$uncompressedSize = [uint32]$rawAssemblyBytes.Length

$bound = [ulong][ZstdEngine]::ZSTD_compressBound([UIntPtr]$uncompressedSize)
$compBuf = New-Object byte[] $bound
$compSize = [ZstdEngine]::ZSTD_compress($compBuf, [UIntPtr]$bound, $rawAssemblyBytes, [UIntPtr]$uncompressedSize, 3)

if ([ZstdEngine]::ZSTD_isError($compSize) -ne 0) {
    $errPtr = [ZstdEngine]::ZSTD_getErrorName($compSize)
    $errMsg = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($errPtr)
    throw "Zstandard compression failed: $errMsg"
}

$frameLen = [int][ulong]$compSize
$smaPayloadBytes = New-Object byte[] (12 + $frameLen)

# Header: 'XAZS' (0x58, 0x41, 0x5A, 0x53)
$smaPayloadBytes[0] = 0x58
$smaPayloadBytes[1] = 0x41
$smaPayloadBytes[2] = 0x5A
$smaPayloadBytes[3] = 0x53
[System.BitConverter]::GetBytes([uint32]150).CopyTo($smaPayloadBytes, 4)
[System.BitConverter]::GetBytes($uncompressedSize).CopyTo($smaPayloadBytes, 8)
[System.Buffer]::BlockCopy($compBuf, 0, $smaPayloadBytes, 12, $frameLen)

$smaPayloadFile = Join-Path $payloadWorkDir "payload_336_AndroidSMA.dll.bin"
[System.IO.File]::WriteAllBytes($smaPayloadFile, $smaPayloadBytes)
Write-Host "  Encoded AndroidSMA.dll -> payload_336 ($($smaPayloadBytes.Length) bytes, uncompressed=$uncompressedSize)"
#endregion

#region 05 — Construct XABA Assembly Store
# Materializes the .NET for Android CoreCLR assembly store (magic 'XABA', format 0x80010004).
# Header (28B) -> Index Table (9B * 2N) -> Descriptors (28B * N) -> Pascal Names -> Payloads
# Offsets and sizes are dynamically computed to support arbitrary payload lengths.
# The store is constructed entirely from the declared managed assembly population,
# with index hashes computed via IEEE 802.3 CRC32 in pure PowerShell.
Write-Host "05 — Constructing XABA assembly store from declared population..."
$generatedXabaPath = Join-Path $tempDir "assembly-store.generated.so"

# 1. CRC32 lookup hash function (IEEE 802.3 polynomial 0xEDB88320)
[uint32[]]$crcTable = New-Object uint32[] 256
for ($i = 0; $i -lt 256; $i++) {
    $c = [uint32]$i
    for ($j = 0; $j -lt 8; $j++) {
        if (($c -band 1) -ne 0) { $c = 0xedb88320u -bxor ($c -shr 1) }
        else                    { $c = ($c -shr 1) }
    }
    $crcTable[$i] = $c
}

function Compute-Crc([byte[]]$bytes) {
    $crc = [uint32]::MaxValue
    foreach ($b in $bytes) { $crc = $crcTable[($crc -bxor $b) -band 0xff] -bxor ($crc -shr 8) }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

# 2. Canonical assembly names from oracle, filtering unproven assemblies
$fsIn = [System.IO.File]::OpenRead($oracleXabaPath)
$brIn = [System.IO.BinaryReader]::new($fsIn)
$oracleMagic      = $brIn.ReadBytes(4)
$oracleVersion    = $brIn.ReadUInt32()
$oracleEntryCount = $brIn.ReadUInt32()
$oracleIndexEntryCount = $brIn.ReadUInt32()
$oracleIndexSize  = $brIn.ReadUInt32()
$oracleStoreId    = $brIn.ReadUInt64()
$brIn.ReadBytes($oracleIndexSize + (28 * $oracleEntryCount)) | Out-Null
$oracleNames = for ($i = 0; $i -lt $oracleEntryCount; $i++) {
    $len = $brIn.ReadUInt32()
    [System.Text.Encoding]::UTF8.GetString($brIn.ReadBytes($len))
}
$fsIn.Close()

# Active assemblies (even indices in oracle pairing), excluding AndroidSMA.PackagingHost.dll
$activeAssemblies = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $oracleEntryCount; $i += 2) {
    $name = $oracleNames[$i]
    if ($name -eq 'AndroidSMA.PackagingHost.dll') {
        Write-Host "  Excluding unproven assembly from XABA population: $name"
        continue
    }
    $safeName = $name.Replace('/', '_').Replace('\', '_')
    $matchedFile = Get-ChildItem $payloadWorkDir -Filter "*_${safeName}.bin" | Select-Object -First 1
    if (-not $matchedFile) { throw "Missing payload file for $name in $payloadWorkDir" }
    $activeAssemblies.Add([PSCustomObject]@{
        Name = $name
        File = $matchedFile.FullName
        Size = [uint32](Get-Item $matchedFile.FullName).Length
    })
}

$N = $activeAssemblies.Count
$descCount = 2 * $N
$idxCount = 4 * $N
$idxSize = $idxCount * 9

# 3. Build Descriptors and Names
$genNames = [string[]]::new($descCount)
$genDescriptors = [object[]]::new($descCount)

for ($i = 0; $i -lt $N; $i++) {
    $a = $activeAssemblies[$i]
    $fullName = $a.Name
    $bareName = $fullName -replace '\.dll$',''
    $niName = $bareName + '.ni.dll'

    $genNames[2*$i] = $fullName
    $genNames[2*$i + 1] = $niName

    $genDescriptors[2*$i] = [PSCustomObject]@{
        MappingIndex = [uint32]$i
        DataOffset   = [uint32]0 # computed below
        DataSize     = [uint32]$a.Size
        DebugOffset  = [uint32]0
        DebugSize    = [uint32]0
        ConfigOffset = [uint32]0
        ConfigSize   = [uint32]0
    }
    $genDescriptors[2*$i + 1] = [PSCustomObject]@{
        MappingIndex = [uint32]0
        DataOffset   = [uint32]0
        DataSize     = [uint32]0
        DebugOffset  = [uint32]0
        DebugSize    = [uint32]0
        ConfigOffset = [uint32]0
        ConfigSize   = [uint32]0
    }
}

# 4. Build Index Entries (2 per descriptor: full name + bare name)
$genIndexEntries = [System.Collections.Generic.List[object]]::new()
for ($d = 0; $d -lt $descCount; $d++) {
    $name = $genNames[$d]
    $isNi = $name.EndsWith('.ni.dll', [StringComparison]::OrdinalIgnoreCase)
    $flag = if ($isNi) { [byte]1 } else { [byte]0 }

    $fullBytes = [System.Text.Encoding]::UTF8.GetBytes($name)
    $genIndexEntries.Add([PSCustomObject]@{
        Hash            = Compute-Crc $fullBytes
        DescriptorIndex = [uint32]$d
        Flags           = $flag
    })

    $bare = $name -replace '\.dll$',''
    $bareBytes = [System.Text.Encoding]::UTF8.GetBytes($bare)
    $genIndexEntries.Add([PSCustomObject]@{
        Hash            = Compute-Crc $bareBytes
        DescriptorIndex = [uint32]$d
        Flags           = $flag
    })
}

$sortedIndex = $genIndexEntries | Sort-Object Hash, DescriptorIndex

# 5. Compute Contiguous Layout Offsets
$headerSize = 28
$indexTableSize = $idxSize
$descriptorsTableSize = $descCount * 28
$namesTableSize = 0
for ($d = 0; $d -lt $descCount; $d++) {
    $namesTableSize += 4 + [System.Text.Encoding]::UTF8.GetByteCount($genNames[$d])
}

$payloadStart = $headerSize + $indexTableSize + $descriptorsTableSize + $namesTableSize
$curOffset = $payloadStart

for ($i = 0; $i -lt $N; $i++) {
    $genDescriptors[2*$i].DataOffset = [uint32]$curOffset
    $curOffset += [uint32]$activeAssemblies[$i].Size
}

# 6. Serialize XABA Binary Store
$fsOut = [System.IO.File]::Create($generatedXabaPath)
$bwOut = [System.IO.BinaryWriter]::new($fsOut)

# Header
$bwOut.Write([byte[]]@(0x58, 0x41, 0x42, 0x41)) # 'XABA'
$bwOut.Write([uint32]$oracleVersion)
$bwOut.Write([uint32]$descCount)
$bwOut.Write([uint32]$idxCount)
$bwOut.Write([uint32]$idxSize)
$bwOut.Write([uint64]$oracleStoreId)

# Index Table
foreach ($e in $sortedIndex) {
    $bwOut.Write([uint32]$e.Hash)
    $bwOut.Write([uint32]$e.DescriptorIndex)
    $bwOut.Write([byte]$e.Flags)
}

# Descriptors Table
foreach ($d in $genDescriptors) {
    $bwOut.Write([uint32]$d.MappingIndex)
    $bwOut.Write([uint32]$d.DataOffset)
    $bwOut.Write([uint32]$d.DataSize)
    $bwOut.Write([uint32]$d.DebugOffset)
    $bwOut.Write([uint32]$d.DebugSize)
    $bwOut.Write([uint32]$d.ConfigOffset)
    $bwOut.Write([uint32]$d.ConfigSize)
}

# Names Table
foreach ($name in $genNames) {
    $nb = [System.Text.Encoding]::UTF8.GetBytes($name)
    $bwOut.Write([uint32]$nb.Length)
    $bwOut.Write($nb)
}

# Payloads
for ($i = 0; $i -lt $N; $i++) {
    if ($bwOut.BaseStream.Position -ne $genDescriptors[2*$i].DataOffset) {
        throw "Offset mismatch for $($activeAssemblies[$i].Name): pos=$($bwOut.BaseStream.Position), expected=$($genDescriptors[2*$i].DataOffset)"
    }
    $pBytes = [System.IO.File]::ReadAllBytes($activeAssemblies[$i].File)
    $bwOut.Write($pBytes)
}
$fsOut.Flush()
$fsOut.Close()

$generatedXabaHash = (Get-FileHash $generatedXabaPath -Algorithm SHA256).Hash
Write-Host "  XABA store constructed: $N active assemblies ($descCount descriptors, $idxCount index entries, $generatedXabaHash, $((Get-Item $generatedXabaPath).Length) bytes)"
#endregion

#region 06 — Materialize XABA as ELF (llvm-mc + ld)
# Wraps raw XABA binary blob into an allocatable ELF shared library exporting _assembly_store symbol.
# Section name MUST be exactly 'payload' (allocatable, 16KB aligned).
Write-Host "06 — Materializing XABA as ELF libassembly-store.so..."
$androidSdkPackRoot = Join-Path $DotnetRoot 'packs'
$llvmMcCandidate = Find-FirstFile -Root $androidSdkPackRoot -Filter 'llvm-mc.exe' `
    -Description 'Android workload llvm-mc executable'
$linkerCandidate = Find-FirstFile -Root $androidSdkPackRoot -Filter 'ld.exe' `
    -Description 'Android workload linker executable'
$llvmMc = Resolve-BuildExecutable -ExplicitPath $LlvmMcPath -DisplayName 'llvm-mc' `
    -CommandName @('llvm-mc.exe', 'llvm-mc') -CandidatePath @($llvmMcCandidate)
$ld = Resolve-BuildExecutable -ExplicitPath $LinkerPath -DisplayName 'Android linker' `
    -CommandName @('ld.exe', 'ld') -CandidatePath @($linkerCandidate)

$generatedElfPath = Join-Path $tempDir "libassembly-store.so"
$asmSource        = Join-Path $tempDir "assembly-store.S"
$asmObj           = Join-Path $tempDir "assembly-store.o"

# Forward slashes required for .incbin path
$xabaEscaped = (Resolve-Path $generatedXabaPath).Path -replace '\\', '/'

$asmLines = @(
    '.section payload, "a"',
    '.balign 16384',
    '.globl _assembly_store',
    '_assembly_store:',
    ('.incbin "' + $xabaEscaped + '"')
)
Set-Content -Path $asmSource -Value $asmLines -Encoding ASCII

if ($androidAbi -eq 'arm64-v8a') {
    & $llvmMc -triple=aarch64-linux-android -filetype=obj -o $asmObj $asmSource
    if ($LASTEXITCODE -ne 0) { throw "llvm-mc failed with exit code $LASTEXITCODE" }
    & $ld -m aarch64linux -shared -z noexecstack -z max-page-size=16384 --build-id=sha1 --export-dynamic-symbol=_assembly_store -o $generatedElfPath $asmObj
    if ($LASTEXITCODE -ne 0) { throw "ld failed with exit code $LASTEXITCODE" }
} else {
    & $llvmMc -triple=armv7-linux-androideabi -filetype=obj -o $asmObj $asmSource
    if ($LASTEXITCODE -ne 0) { throw "llvm-mc failed with exit code $LASTEXITCODE" }
    & $ld -m armelf_linux_eabi -shared -z noexecstack -z max-page-size=4096 --build-id=sha1 --export-dynamic-symbol=_assembly_store -o $generatedElfPath $asmObj
    if ($LASTEXITCODE -ne 0) { throw "ld failed with exit code $LASTEXITCODE" }
}

Remove-Item $asmSource, $asmObj -ErrorAction SilentlyContinue
if (-not (Test-Path $generatedElfPath)) {
    throw "Materialized ELF not found: $generatedElfPath"
}
$elfHash = (Get-FileHash $generatedElfPath -Algorithm SHA256).Hash
Write-Host "  ELF libassembly-store.so materialized: $elfHash ($((Get-Item $generatedElfPath).Length) bytes)"
#endregion

#region 07 — Assemble APK (ZIP with 4-byte Stored Alignment)
Write-Host "07 — Assembling APK archive..."

function Compress-Deflate([byte[]]$data) {
    $ms = [System.IO.MemoryStream]::new()
    $ds = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $ds.Write($data, 0, $data.Length); $ds.Dispose()
    [byte[]]$result = $ms.ToArray(); $ms.Dispose()
    return ,$result
}

function Write-ApkZip([string]$zipPath, [array]$entries) {
    $fs = [System.IO.File]::Create($zipPath)
    $bw = [System.IO.BinaryWriter]::new($fs)
    $cdList = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $entries) {
        [string]$name     = $item.Name
        [byte[]]$rawBytes = $item.Bytes
        [bool]$deflate    = $item.Deflate
        [int]$align       = if ($item.Align) { $item.Align } else { 0 }
        [uint32]$crc        = Compute-Crc $rawBytes
        [uint32]$uncompSize = [uint32]$rawBytes.Length
        [byte[]]$payload    = if ($deflate) { Compress-Deflate $rawBytes } else { $rawBytes }
        [uint32]$compSize   = [uint32]$payload.Length
        [uint16]$method     = if ($deflate) { [uint16]8 } else { [uint16]0 }
        [byte[]]$nameBytes  = [System.Text.Encoding]::UTF8.GetBytes($name)
        [uint16]$nameLen    = [uint16]$nameBytes.Length
        [uint32]$localOffset = [uint32]$fs.Position
        [byte[]]$extraBytes  = [byte[]]@()
        if ($align -gt 1) {
            [int]$unalignedPayloadOffset = $localOffset + 30 + $nameLen
            [int]$rem = $unalignedPayloadOffset % $align
            if ($rem -ne 0) {
                [int]$pad = $align - $rem
                if ($pad -lt 4) { $pad += $align }
                $extraMs = [System.IO.MemoryStream]::new()
                $extraBw = [System.IO.BinaryWriter]::new($extraMs)
                $extraBw.Write([uint16]0xd935)
                $extraBw.Write([uint16]($pad - 4))
                $extraBw.Write((New-Object byte[] ($pad - 4)))
                $extraBytes = $extraMs.ToArray()
                $extraBw.Dispose(); $extraMs.Dispose()
            }
        }
        [uint16]$extraLen = [uint16]$extraBytes.Length
        $bw.Write([uint32]0x04034b50); $bw.Write([uint16]20); $bw.Write([uint16]0)
        $bw.Write($method); $bw.Write([uint16]0x198a); $bw.Write([uint16]0x5d25)
        $bw.Write($crc); $bw.Write($compSize); $bw.Write($uncompSize)
        $bw.Write($nameLen); $bw.Write($extraLen); $bw.Write($nameBytes)
        if ($extraLen -gt 0) { $bw.Write($extraBytes) }
        [uint32]$actualPayloadOffset = [uint32]$fs.Position
        if ($align -gt 1 -and ($actualPayloadOffset % $align -ne 0)) {
            throw "Alignment failed for ${name}: offset $actualPayloadOffset not divisible by $align"
        }
        $bw.Write($payload)
        $cdList.Add([PSCustomObject]@{
            NameBytes   = $nameBytes; Method = $method; CRC = $crc
            CompSize    = $compSize; UncompSize = $uncompSize; LocalOffset = $localOffset
        })
    }
    [uint32]$cdOffset = [uint32]$fs.Position
    foreach ($cd in $cdList) {
        $bw.Write([uint32]0x02014b50); $bw.Write([uint16]20); $bw.Write([uint16]20)
        $bw.Write([uint16]0); $bw.Write($cd.Method)
        $bw.Write([uint16]0x198a); $bw.Write([uint16]0x5d25)
        $bw.Write($cd.CRC); $bw.Write($cd.CompSize); $bw.Write($cd.UncompSize)
        $bw.Write([uint16]$cd.NameBytes.Length); $bw.Write([uint16]0)
        $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]0)
        $bw.Write([uint32]0); $bw.Write($cd.LocalOffset); $bw.Write($cd.NameBytes)
    }
    [uint32]$cdSize = [uint32]($fs.Position - $cdOffset)
    $bw.Write([uint32]0x06054b50); $bw.Write([uint16]0); $bw.Write([uint16]0)
    $bw.Write([uint16]$cdList.Count); $bw.Write([uint16]$cdList.Count)
    $bw.Write($cdSize); $bw.Write($cdOffset); $bw.Write([uint16]0)
    $bw.Flush(); $fs.Close()
}

$entryNames = @(
    'AndroidManifest.xml',
    'classes.dex',
    "lib/$androidAbi/libSystem.Globalization.Native.so",
    "lib/$androidAbi/libSystem.IO.Compression.Native.so",
    "lib/$androidAbi/libSystem.Native.so",
    "lib/$androidAbi/libSystem.Security.Cryptography.Native.Android.so",
    "lib/$androidAbi/libassembly-store.so",
    "lib/$androidAbi/libclrjit.so",
    "lib/$androidAbi/libcoreclr.so",
    "lib/$androidAbi/libmonodroid.so",
    "lib/$androidAbi/libpsl-native.so",
    "lib/$androidAbi/libxamarin-app.so",
    'res/drawable/androidsma_banner.xml',
    'res/xml/splits0.xml',
    'resources.arsc'
)

$apkEntries = @()
$patchedXamarinAppPath = Join-Path $tempDir "libxamarin-app.so"

# Synthesize application-specific typemap record for AndroidSMA.dll into libxamarin-app.so
# Extract active MVID directly from emitted AndroidSMA.dll metadata
$smaRaw = [System.IO.File]::ReadAllBytes($androidSmaDll)
$peOff = [System.BitConverter]::ToInt32($smaRaw, 0x3C)
$cliRva = [System.BitConverter]::ToInt32($smaRaw, $peOff + 24 + 208)
$numSec = [System.BitConverter]::ToInt16($smaRaw, $peOff + 6)
$optSec = [System.BitConverter]::ToInt16($smaRaw, $peOff + 20)
$secBase = $peOff + 24 + $optSec
$activeMvidBytes = $null

for ($i = 0; $i -lt $numSec; $i++) {
    $sec = $secBase + ($i * 40)
    $vRva = [System.BitConverter]::ToInt32($smaRaw, $sec + 12)
    $vSize = [System.BitConverter]::ToInt32($smaRaw, $sec + 8)
    $rawOff = [System.BitConverter]::ToInt32($smaRaw, $sec + 20)
    if ($cliRva -ge $vRva -and $cliRva -lt ($vRva + $vSize)) {
        $cliOff = $rawOff + ($cliRva - $vRva)
        $mdRva = [System.BitConverter]::ToInt32($smaRaw, $cliOff + 8)
        $mdOff = $rawOff + ($mdRva - $vRva)
        $vLen = [System.BitConverter]::ToInt32($smaRaw, $mdOff + 12)
        $sOff = $mdOff + 16 + $vLen
        $rem = $sOff % 4
        if ($rem -ne 0) { $sOff += (4 - $rem) }
        $sCnt = [System.BitConverter]::ToInt16($smaRaw, $sOff + 2)
        $cur = $sOff + 4
        for ($s = 0; $s -lt $sCnt; $s++) {
            $curOff = [System.BitConverter]::ToInt32($smaRaw, $cur)
            $cur += 8
            $sName = ''
            while ($smaRaw[$cur] -ne 0) { $sName += [char]$smaRaw[$cur]; $cur++ }
            $cur++
            $rem = $cur % 4
            if ($rem -ne 0) { $cur += (4 - $rem) }
            if ($sName -eq '#GUID') {
                $activeMvidBytes = New-Object byte[] 16
                [Array]::Copy($smaRaw, $mdOff + $curOff, $activeMvidBytes, 0, 16)
                break
            }
        }
        break
    }
}

if ($null -eq $activeMvidBytes -or $activeMvidBytes.Length -ne 16) {
    throw "Failed to extract MVID from $androidSmaDll"
}

# Base libxamarin-app.so from oracle provenance
$origXamarinAppPath = Join-Path $oracleExtractDir "lib\$androidAbi\libxamarin-app.so"
$xamarinAppBytes = [System.IO.File]::ReadAllBytes($origXamarinAppPath)

# ---------------------------------------------------------------------------
# Correct typemap module table sort order after MVID substitution.
#
# The Release CoreCLR runtime performs a binary search over managed_to_java_map
# using memcmp on the raw 16-byte module_uuid field (confirmed in dotnet/android
# issue #10779).  The array must remain sorted ascending by those bytes.
# Replacing AndroidSMA's uuid in-place may move it to a different sorted
# position, invalidating all binary-search results — including lookups for
# completely unrelated modules.
#
# Correct algorithm:
#   1. Read all three TypeMapModule records from the oracle binary.
#   2. Replace AndroidSMA's uuid with the freshly emitted MVID.
#   3. Sort all records ascending by raw uuid bytes (memcmp order).
#   4. Build an old-index → new-index remap table.
#   5. Walk every TypeMapJava entry and remap its module_index field.
#   6. Write the sorted modules and updated TypeMapJava table back.
#
# Structural constants (verified by binary inspection of oracle ELF):
#   managed_to_java_map  file offset 1039924  3 modules × 40 bytes each
#   TypeMapModule layout (40 bytes):
#       [0..15]  module_uuid       (16 bytes)
#       [16..19] entry_count       (uint32)
#       [20..23] duplicate_count   (uint32)
#       [24..27] assembly_name_index (uint32)
#       [28..31] assembly_name_length (uint32)
#       [32..35] map_index         (uint32)
#       [36..39] duplicate_map_index (uint32)
#
#   java_to_managed_map  file offset 177508   7279 entries × 24 bytes each
#   TypeMapJava layout (24 bytes):
#       [0..3]   module_index      (uint32)  ← must match sorted position
#       [4..7]   managed_type_name_index (uint32)
#       [8..11]  managed_type_name_length (uint32)
#       [12..15] managed_type_token_id   (uint32)
#       [16..19] java_name_index   (uint32)
#       [20..23] java_name_length  (uint32)
# ---------------------------------------------------------------------------

$moduleTableOffset  = 1039924   # file offset of managed_to_java_map[0]
$moduleCount        = 3
$moduleRecordSize   = 40

# Read all module records as raw byte arrays (preserves all fields)
$moduleRecords = @()
for ($m = 0; $m -lt $moduleCount; $m++) {
    $recOff = $moduleTableOffset + $m * $moduleRecordSize
    $rec = New-Object byte[] $moduleRecordSize
    [System.Buffer]::BlockCopy($xamarinAppBytes, $recOff, $rec, 0, $moduleRecordSize)
    $moduleRecords += ,$rec
}

# Identify which record is AndroidSMA by matching known oracle uuid
# Oracle AndroidSMA uuid (hex): 75 98 A9 08 00 BC 2D 40 94 2E D2 42 78 33 58 06
# (= GUID 08a99875-bc00-402d-942e-d24278335806 in little-endian storage)
# Replace that record's uuid with the freshly emitted MVID
$oracleAndroidSmaUuid = [byte[]](0x75,0x98,0xA9,0x08,0x00,0xBC,0x2D,0x40,0x94,0x2E,0xD2,0x42,0x78,0x33,0x58,0x06)
$smaModuleOldIndex = -1
for ($m = 0; $m -lt $moduleCount; $m++) {
    $match = $true
    for ($b = 0; $b -lt 16; $b++) {
        if ($moduleRecords[$m][$b] -ne $oracleAndroidSmaUuid[$b]) { $match = $false; break }
    }
    if ($match) { $smaModuleOldIndex = $m; break }
}
if ($smaModuleOldIndex -lt 0) {
    throw "Could not locate AndroidSMA TypeMapModule record by oracle uuid in libxamarin-app.so"
}
[System.Buffer]::BlockCopy($activeMvidBytes, 0, $moduleRecords[$smaModuleOldIndex], 0, 16)
Write-Host "  TypeMapModule[$smaModuleOldIndex] uuid replaced with fresh MVID"

# Sort module records ascending by raw uuid bytes (memcmp / lexicographic order)
$sortedRecords = $moduleRecords | Sort-Object -Property {
    $uuid = $_[0..15]
    # Return a key that sorts lexicographically: convert to hex string for stable comparison
    ($uuid | ForEach-Object { $_.ToString('X2') }) -join ''
}

# Build old-index → new-index remap
# For each old record, find its position in the sorted list by uuid identity
$oldToNew = @{}
for ($oldIdx = 0; $oldIdx -lt $moduleCount; $oldIdx++) {
    $oldUuid = $moduleRecords[$oldIdx][0..15]
    for ($newIdx = 0; $newIdx -lt $moduleCount; $newIdx++) {
        $newUuid = $sortedRecords[$newIdx][0..15]
        $match = $true
        for ($b = 0; $b -lt 16; $b++) {
            if ($oldUuid[$b] -ne $newUuid[$b]) { $match = $false; break }
        }
        if ($match) { $oldToNew[$oldIdx] = $newIdx; break }
    }
}
Write-Host "  Module index remap: $(($oldToNew.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)->$($_.Value)" }) -join ', ')"

# Write sorted module records back into the byte array
for ($newIdx = 0; $newIdx -lt $moduleCount; $newIdx++) {
    $destOff = $moduleTableOffset + $newIdx * $moduleRecordSize
    [System.Buffer]::BlockCopy($sortedRecords[$newIdx], 0, $xamarinAppBytes, $destOff, $moduleRecordSize)
}

# Update every TypeMapJava.module_index to reflect new sorted positions
# java_to_managed_map starts at file offset 177508, 7279 entries × 24 bytes
$javaMapOffset    = 177508
$javaEntrySize    = 24
$javaEntryCount   = 7279
$remappedCount    = 0
for ($j = 0; $j -lt $javaEntryCount; $j++) {
    $entryOff = $javaMapOffset + $j * $javaEntrySize
    $oldModIdx = [System.BitConverter]::ToInt32($xamarinAppBytes, $entryOff)
    if ($oldToNew.ContainsKey($oldModIdx)) {
        $newModIdx = $oldToNew[$oldModIdx]
        if ($newModIdx -ne $oldModIdx) {
            $newModIdxBytes = [System.BitConverter]::GetBytes([int32]$newModIdx)
            [System.Buffer]::BlockCopy($newModIdxBytes, 0, $xamarinAppBytes, $entryOff, 4)
            $remappedCount++
        }
    }
}
Write-Host "  TypeMapJava module_index fields remapped: $remappedCount entries updated"

# Verify patch integrity: count total bytes changed vs oracle
$oracleOrigBytes = [System.IO.File]::ReadAllBytes($origXamarinAppPath)
$patchDiffs = 0
for ($bi = 0; $bi -lt $oracleOrigBytes.Length; $bi++) {
    if ($oracleOrigBytes[$bi] -ne $xamarinAppBytes[$bi]) { $patchDiffs++ }
}
$activeGuid = New-Object System.Guid (,$activeMvidBytes)
Write-Host "  Patched libxamarin-app.so with MVID: $activeGuid"
Write-Host "  Total bytes changed vs oracle: $patchDiffs"

#region 06.5 — Spike 1: Generic Peer / DEX Realization
Write-Host "06.5 — Generating classes.dex from semantic SMActivity peer..."
$spikeDexDir = Join-Path $tempDir "spike1_dex"
if (Test-Path $spikeDexDir) { Remove-Item $spikeDexDir -Recurse -Force }
$spikeSrcDir = Join-Path $spikeDexDir "src"
$spikeClassesDir = Join-Path $spikeDexDir "classes"
New-Item -ItemType Directory -Path (Join-Path $spikeSrcDir "dev\mansfieldplumbing\androidsma") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $spikeSrcDir "mono") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $spikeSrcDir "net\dot\android") -Force | Out-Null
New-Item -ItemType Directory -Path $spikeClassesDir -Force | Out-Null

# Semantic Peer Definition
$peerDeclaration = [PSCustomObject]@{
    PackageName     = 'dev.mansfieldplumbing.androidsma'
    ClassName       = 'SMActivity'
    ManagedType     = 'AndroidSMA.SMActivity, AndroidSMA'
    BaseClass       = 'android.app.Activity'
    Interfaces      = @('mono.android.IGCUserPeer')
    Overrides       = @(
        [PSCustomObject]@{
            Name          = 'onCreate'
            NativeName    = 'n_onCreate'
            JavaParamSig  = 'android.os.Bundle p0'
            JavaCallSig   = 'p0'
            MethodDesc    = '(Landroid/os/Bundle;)V'
            Handler       = 'GetOnCreate_Landroid_os_Bundle_Handler'
        },
        [PSCustomObject]@{
            Name          = 'onActivityResult'
            NativeName    = 'n_onActivityResult'
            JavaParamSig  = 'int p0, int p1, android.content.Intent p2'
            JavaCallSig   = 'p0, p1, p2'
            MethodDesc    = '(IILandroid/content/Intent;)V'
            Handler       = 'GetOnActivityResult_IILandroid_content_Intent_Handler'
        }
    )
}

# Synthesize md_methods string from semantic overrides
$mdMethodsLines = foreach ($ov in $peerDeclaration.Overrides) {
    "$($ov.NativeName):$($ov.MethodDesc):$($ov.Handler)\n"
}
$mdMethodsStr = ($mdMethodsLines -join "")

# Emit Java peer class source
$peerJavaCode = @"
package $($peerDeclaration.PackageName);

public class $($peerDeclaration.ClassName)
    extends $($peerDeclaration.BaseClass)
    implements $(($peerDeclaration.Interfaces) -join ', ')
{
    public static final String __md_methods;
    static {
        __md_methods =
$(($mdMethodsLines | ForEach-Object { "            `"$_`" +" }) -join "`n")
            "";
        mono.android.Runtime.register("$($peerDeclaration.ManagedType)", $($peerDeclaration.ClassName).class, __md_methods);
    }

    public $($peerDeclaration.ClassName)() {
        super();
        if (getClass() == $($peerDeclaration.ClassName).class) {
            mono.android.TypeManager.Activate("$($peerDeclaration.ManagedType)", "", this, new java.lang.Object[] {});
        }
    }
"@

foreach ($ov in $peerDeclaration.Overrides) {
    $peerJavaCode += @"

    public void $($ov.Name)($($ov.JavaParamSig)) {
        $($ov.NativeName)($($ov.JavaCallSig));
    }
    private native void $($ov.NativeName)($($ov.JavaParamSig));
"@
}

$peerJavaCode += @"

    private java.util.ArrayList refList;
    public void monodroidAddReference(java.lang.Object obj) {
        if (refList == null) refList = new java.util.ArrayList();
        refList.add(obj);
    }
    public void monodroidClearReferences() {
        if (refList != null) refList.clear();
    }
}
"@

$peerJavaFile = Join-Path $spikeSrcDir "$($peerDeclaration.PackageName.Replace('.', '\'))\$($peerDeclaration.ClassName).java"
Set-Content -Path $peerJavaFile -Value $peerJavaCode -Encoding UTF8

# Static framework registration sources
$rJavaCode = @"
package dev.mansfieldplumbing.androidsma;
public final class R {
    public static final class drawable {
        public static final int androidsma_banner = 0x7f010000;
    }
}
"@
Set-Content -Path (Join-Path $spikeSrcDir "dev\mansfieldplumbing\androidsma\R.java") -Value $rJavaCode -Encoding UTF8

$appRegCode = @"
package net.dot.android;
public class ApplicationRegistration {
    public static android.content.Context Context;
    public static void registerApplications() {}
}
"@
Set-Content -Path (Join-Path $spikeSrcDir "net\dot\android\ApplicationRegistration.java") -Value $appRegCode -Encoding UTF8

$monoResCode = @"
package mono;
public class MonoPackageManager_Resources {
    public static String[] Assemblies = new String[] { "AndroidSMA.PackagingHost.dll" };
}
"@
Set-Content -Path (Join-Path $spikeSrcDir "mono\MonoPackageManager_Resources.java") -Value $monoResCode -Encoding UTF8

$monoProvCode = @"
package mono;
public class MonoRuntimeProvider extends android.content.ContentProvider {
    public MonoRuntimeProvider() {}
    @Override public boolean onCreate() { return true; }
    @Override public void attachInfo(android.content.Context context, android.content.pm.ProviderInfo info) {
        mono.MonoPackageManager.LoadApplication(context);
        super.attachInfo(context, info);
    }
    @Override public android.database.Cursor query(android.net.Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) { throw new RuntimeException("Not supported"); }
    @Override public String getType(android.net.Uri uri) { throw new RuntimeException("Not supported"); }
    @Override public android.net.Uri insert(android.net.Uri uri, android.content.ContentValues values) { throw new RuntimeException("Not supported"); }
    @Override public int delete(android.net.Uri uri, String where, String[] whereArgs) { throw new RuntimeException("Not supported"); }
    @Override public int update(android.net.Uri uri, android.content.ContentValues values, String where, String[] whereArgs) { throw new RuntimeException("Not supported"); }
}
"@
Set-Content -Path (Join-Path $spikeSrcDir "mono\MonoRuntimeProvider.java") -Value $monoProvCode -Encoding UTF8

# Compile with javac
$javaHomeCandidate = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\javac.exe' } else { $null }
$javacExe = Resolve-BuildExecutable -ExplicitPath $JavaCompilerPath -DisplayName 'Java compiler (javac)' `
    -CommandName @('javac.exe', 'javac') -CandidatePath @($javaHomeCandidate)

$androidJarPath = Find-FirstFile -Root (Join-Path $AndroidSdkRoot 'platforms') `
    -Filter 'android.jar' -Description 'Android platform API jar'
$monoAndroidJar = Find-FirstFile -Root $androidSdkPackRoot -Filter 'mono.android.jar' `
    -Description 'Mono.Android reference jar'
$clrRuntimeJar = Find-FirstFile -Root $androidSdkPackRoot -Filter 'java_runtime_clr.jar' `
    -Description 'CoreCLR Java runtime jar'
$runtimePackName = if ($RuntimeIdentifier -eq 'android-arm64') {
    'Microsoft.NETCore.App.Runtime.Mono.android-arm64'
} else {
    'Microsoft.NETCore.App.Runtime.Mono.android-arm'
}
$cryptoJar = Find-FirstFile -Root (Join-Path $androidSdkPackRoot $runtimePackName) `
    -Filter 'libSystem.Security.Cryptography.Native.Android.jar' `
    -Description 'Android cryptography runtime jar'
$classpath      = "$androidJarPath;$monoAndroidJar;$clrRuntimeJar;$cryptoJar"

$allJavaFiles = (Get-ChildItem $spikeSrcDir -Recurse -Filter "*.java").FullName
& $javacExe -cp $classpath -d $spikeClassesDir $allJavaFiles
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

# D8 lowers .class files + runtime jars into classes.dex
$d8Candidate = Find-FirstFile -Root (Join-Path $AndroidSdkRoot 'build-tools') `
    -Filter 'd8.bat' -Description 'Android D8 executable'
$d8Bat = Resolve-BuildExecutable -ExplicitPath $D8Path -DisplayName 'Android D8' `
    -CommandName @('d8.bat', 'd8') -CandidatePath @($d8Candidate)
$env:JAVA_HOME = Split-Path (Split-Path $javacExe -Parent) -Parent
$allClassFiles = (Get-ChildItem $spikeClassesDir -Recurse -Filter "*.class").FullName
$generatedDexDir = Join-Path $spikeDexDir "dex_out"
New-Item -ItemType Directory -Path $generatedDexDir -Force | Out-Null

& $d8Bat --release --lib $androidJarPath --output $generatedDexDir $allClassFiles $monoAndroidJar $clrRuntimeJar $cryptoJar
if ($LASTEXITCODE -ne 0) { throw "d8 failed with exit code $LASTEXITCODE" }

$generatedClassesDex = Join-Path $generatedDexDir "classes.dex"
if (-not (Test-Path $generatedClassesDex)) { throw "classes.dex was not generated by D8!" }
$generatedDexHash = (Get-FileHash $generatedClassesDex).Hash
Write-Host "  Generated classes.dex: $generatedDexHash ($((Get-Item $generatedClassesDex).Length) bytes)"
#endregion

#region 06.6 — Spike 2: Semantic Activity -> Binary Android Admission (Binary AXML)
Write-Host "06.6 — Generating binary AndroidManifest.xml from semantic Activity declaration..."

function New-BinaryAxmlManifest {
    param(
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $ActivityClassName,
        [string] $ActivityLabel = "AndroidSMA",
        [int] $VersionCode = 1,
        [string] $VersionName = "1.0",
        [int] $MinSdkVersion = 26,
        [int] $TargetSdkVersion = 37,
        [int] $CompileSdkVersion = 37,
        [string] $CompileSdkVersionCodename = "17"
    )

    $attrNames = @(
        'theme',                       # ResID: 0x01010000
        'label',                       # ResID: 0x01010001
        'name',                        # ResID: 0x01010003
        'exported',                    # ResID: 0x01010010
        'authorities',                 # ResID: 0x01010018
        'initOrder',                   # ResID: 0x0101001A
        'launchMode',                  # ResID: 0x0101001D
        'value',                       # ResID: 0x01010024
        'resource',                    # ResID: 0x01010025
        'minSdkVersion',               # ResID: 0x0101020C
        'versionCode',                 # ResID: 0x0101021B
        'versionName',                 # ResID: 0x0101021C
        'targetSdkVersion',            # ResID: 0x01010270
        'allowBackup',                 # ResID: 0x01010280
        'required',                    # ResID: 0x0101028E
        'banner',                      # ResID: 0x010103F2
        'extractNativeLibs',           # ResID: 0x010104EA
        'compileSdkVersion',           # ResID: 0x01010572
        'compileSdkVersionCodename'    # ResID: 0x01010573
    )

    $resIds = @(
        0x01010000, 0x01010001, 0x01010003, 0x01010010, 0x01010018,
        0x0101001A, 0x0101001D, 0x01010024, 0x01010025, 0x0101020C,
        0x0101021B, 0x0101021C, 0x01010270, 0x01010280, 0x0101028E,
        0x010103F2, 0x010104EA, 0x01010572, 0x01010573
    )

    $activityFullName = "$PackageName.$ActivityClassName"
    $providerAuthority = "$PackageName.mono.MonoRuntimeProvider.__mono_init__"

    $otherStrings = @(
        $VersionName,
        $CompileSdkVersionCodename,
        $ActivityLabel,
        'action',
        'activity',
        'android',
        'android.app.Application',
        'android.hardware.touchscreen',
        'android.intent.action.MAIN',
        'android.intent.category.LAUNCHER',
        'android.intent.category.LEANBACK_LAUNCHER',
        'android.software.leanback',
        'application',
        'base',
        'category',
        'com.android.dynamic.apk.fused.modules',
        'com.android.vending.splits',
        $PackageName,
        $activityFullName,
        $providerAuthority,
        'http://schemas.android.com/apk/res/android',
        'intent-filter',
        'manifest',
        'meta-data',
        'mono.MonoRuntimeProvider',
        'package',
        'platformBuildVersionCode',
        'platformBuildVersionName',
        'provider',
        'uses-feature',
        'uses-sdk'
    )

    $allStrings = $attrNames + $otherStrings
    $strMap = @{}
    for ($i = 0; $i -lt $allStrings.Count; $i++) {
        $strMap[$allStrings[$i]] = $i
    }

    function S([string]$val) { return $strMap[$val] }

    # 2. Build StringPool Chunk
    $spDataMs = [System.IO.MemoryStream]::new()
    $spDataBw = [System.IO.BinaryWriter]::new($spDataMs)
    $strOffsets = [System.Collections.Generic.List[uint32]]::new()

    foreach ($s in $allStrings) {
        $strOffsets.Add([uint32]$spDataMs.Position)
        $chars = [System.Text.Encoding]::Unicode.GetBytes($s)
        $spDataBw.Write([uint16]($chars.Length / 2))
        $spDataBw.Write($chars)
        $spDataBw.Write([uint16]0)
    }
    $rawStrBytes = $spDataMs.ToArray()
    $spDataBw.Dispose(); $spDataMs.Dispose()

    $padLen = (4 - ($rawStrBytes.Length % 4)) % 4
    if ($padLen -gt 0) {
        $rawStrBytes = $rawStrBytes + (New-Object byte[] $padLen)
    }

    $strPoolHdrSize = 28
    $offsetTableSize = $allStrings.Count * 4
    $stringsStart = $strPoolHdrSize + $offsetTableSize
    $strPoolTotalSize = $stringsStart + $rawStrBytes.Length

    $spMs = [System.IO.MemoryStream]::new()
    $spBw = [System.IO.BinaryWriter]::new($spMs)
    $spBw.Write([uint16]0x0001)
    $spBw.Write([uint16]$strPoolHdrSize)
    $spBw.Write([uint32]$strPoolTotalSize)
    $spBw.Write([uint32]$allStrings.Count)
    $spBw.Write([uint32]0)
    $spBw.Write([uint32]0)
    $spBw.Write([uint32]$stringsStart)
    $spBw.Write([uint32]0)
    foreach ($off in $strOffsets) { $spBw.Write([uint32]$off) }
    $spBw.Write($rawStrBytes)
    $stringPoolChunk = $spMs.ToArray()
    $spBw.Dispose(); $spMs.Dispose()

    # 3. Build ResourceMap Chunk
    $rmMs = [System.IO.MemoryStream]::new()
    $rmBw = [System.IO.BinaryWriter]::new($rmMs)
    $rmTotalSize = 8 + ($resIds.Count * 4)
    $rmBw.Write([uint16]0x0180)
    $rmBw.Write([uint16]8)
    $rmBw.Write([uint32]$rmTotalSize)
    foreach ($rid in $resIds) { $rmBw.Write([uint32]$rid) }
    $resourceMapChunk = $rmMs.ToArray()
    $rmBw.Dispose(); $rmMs.Dispose()

    # 4. Build XML Tree Elements
    $xmlMs = [System.IO.MemoryStream]::new()
    $xmlBw = [System.IO.BinaryWriter]::new($xmlMs)

    function Write-StartNs([string]$prefix, [string]$uri, [int]$line) {
        $xmlBw.Write([uint16]0x0100)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]24)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32](S $prefix))
        $xmlBw.Write([int32](S $uri))
    }

    function Write-EndNs([string]$prefix, [string]$uri, [int]$line) {
        $xmlBw.Write([uint16]0x0101)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]24)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32](S $prefix))
        $xmlBw.Write([int32](S $uri))
    }

    function Write-StartElem([string]$name, [array]$attrs, [int]$line) {
        $attrSize = 20
        $attrCount = $attrs.Count
        $totalChunkSize = 36 + ($attrCount * $attrSize)
        $xmlBw.Write([uint16]0x0102)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]$totalChunkSize)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32]-1)
        $xmlBw.Write([int32](S $name))
        $xmlBw.Write([uint16]0x0014)
        $xmlBw.Write([uint16]0x0014)
        $xmlBw.Write([uint16]$attrCount)
        $xmlBw.Write([uint16]0)
        $xmlBw.Write([uint16]0)
        $xmlBw.Write([uint16]0)

        foreach ($at in $attrs) {
            $nsIdx = if ($at.HasNs) { S 'http://schemas.android.com/apk/res/android' } else { -1 }
            $nameIdx = S $at.Name
            $xmlBw.Write([int32]$nsIdx)
            $xmlBw.Write([int32]$nameIdx)
            $xmlBw.Write([int32]$at.RawVal)
            $xmlBw.Write([uint16]8)
            $xmlBw.Write([byte]0)
            $xmlBw.Write([byte]$at.DataType)
            $xmlBw.Write([uint32]$at.Data)
        }
    }

    function Write-EndElem([string]$name, [int]$line) {
        $xmlBw.Write([uint16]0x0103)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]24)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32]-1)
        $xmlBw.Write([int32](S $name))
    }

    function Attr-Ref([string]$name, [uint32]$resVal) {
        [PSCustomObject]@{ HasNs = $true; Name = $name; RawVal = -1; DataType = 0x01; Data = $resVal }
    }
    function Attr-String([string]$name, [string]$strVal, [bool]$hasNs = $true) {
        $sIdx = S $strVal
        [PSCustomObject]@{ HasNs = $hasNs; Name = $name; RawVal = $sIdx; DataType = 0x03; Data = [uint32]$sIdx }
    }
    function Attr-IntDec([string]$name, [int]$intVal, [bool]$hasNs = $true) {
        [PSCustomObject]@{ HasNs = $hasNs; Name = $name; RawVal = -1; DataType = 0x10; Data = [uint32]$intVal }
    }
    function Attr-Bool([string]$name, [bool]$boolVal) {
        $bData = if ($boolVal) { [uint32]4294967295 } else { [uint32]0 }
        [PSCustomObject]@{ HasNs = $true; Name = $name; RawVal = -1; DataType = 0x12; Data = $bData }
    }

    Write-StartNs 'android' 'http://schemas.android.com/apk/res/android' 8

    $manifestAttrs = @(
        (Attr-IntDec 'versionCode' $VersionCode),
        (Attr-String 'versionName' $VersionName),
        (Attr-IntDec 'compileSdkVersion' $CompileSdkVersion),
        (Attr-String 'compileSdkVersionCodename' $CompileSdkVersionCodename),
        (Attr-String 'package' $PackageName $false),
        (Attr-IntDec 'platformBuildVersionCode' $CompileSdkVersion $false),
        (Attr-String 'platformBuildVersionName' $CompileSdkVersionCodename $false)
    )
    Write-StartElem 'manifest' $manifestAttrs 8

    $usesSdkAttrs = @(
        (Attr-IntDec 'minSdkVersion' $MinSdkVersion),
        (Attr-IntDec 'targetSdkVersion' $TargetSdkVersion)
    )
    Write-StartElem 'uses-sdk' $usesSdkAttrs 9
    Write-EndElem   'uses-sdk' 9

    Write-StartElem 'uses-feature' @(
        (Attr-String 'name' 'android.software.leanback'),
        (Attr-Bool 'required' $false)
    ) 10
    Write-EndElem 'uses-feature' 10

    Write-StartElem 'uses-feature' @(
        (Attr-String 'name' 'android.hardware.touchscreen'),
        (Attr-Bool 'required' $false)
    ) 11
    Write-EndElem 'uses-feature' 11

    $appAttrs = @(
        (Attr-String 'label' $ActivityLabel),
        (Attr-String 'name' 'android.app.Application'),
        (Attr-Bool 'allowBackup' $true),
        (Attr-Ref 'banner' 0x7F010000),
        (Attr-Bool 'extractNativeLibs' $true)
    )
    Write-StartElem 'application' $appAttrs 12

    $activityAttrs = @(
        (Attr-Ref 'theme' 0x0103022E),
        (Attr-String 'label' $ActivityLabel),
        (Attr-String 'name' $activityFullName),
        (Attr-Bool 'exported' $true),
        (Attr-IntDec 'launchMode' 1),
        (Attr-Ref 'banner' 0x7F010000)
    )
    Write-StartElem 'activity' $activityAttrs 13

    Write-StartElem 'intent-filter' @() 14
    Write-StartElem 'action' @((Attr-String 'name' 'android.intent.action.MAIN')) 15
    Write-EndElem 'action' 15
    Write-StartElem 'category' @((Attr-String 'name' 'android.intent.category.LAUNCHER')) 16
    Write-EndElem 'category' 16
    Write-StartElem 'category' @((Attr-String 'name' 'android.intent.category.LEANBACK_LAUNCHER')) 17
    Write-EndElem 'category' 17
    Write-EndElem 'intent-filter' 14
    Write-EndElem 'activity' 13

    $providerAttrs = @(
        (Attr-String 'name' 'mono.MonoRuntimeProvider'),
        (Attr-Bool 'exported' $false),
        (Attr-String 'authorities' $providerAuthority),
        (Attr-IntDec 'initOrder' 1999999999)
    )
    Write-StartElem 'provider' $providerAttrs 20
    Write-EndElem 'provider' 20

    $meta1Attrs = @(
        (Attr-String 'name' 'com.android.dynamic.apk.fused.modules'),
        (Attr-String 'value' 'base')
    )
    Write-StartElem 'meta-data' $meta1Attrs 0
    Write-EndElem 'meta-data' 0

    $meta2Attrs = @(
        (Attr-String 'name' 'com.android.vending.splits'),
        (Attr-Ref 'resource' 0x7F020000)
    )
    Write-StartElem 'meta-data' $meta2Attrs 0
    Write-EndElem 'meta-data' 0

    Write-EndElem 'application' 12
    Write-EndElem 'manifest' 8
    Write-EndNs 'android' 'http://schemas.android.com/apk/res/android' 8

    $xmlTreeBytes = $xmlMs.ToArray()
    $xmlBw.Dispose(); $xmlMs.Dispose()

    $totalFileSize = 8 + $stringPoolChunk.Length + $resourceMapChunk.Length + $xmlTreeBytes.Length
    $docMs = [System.IO.MemoryStream]::new()
    $docBw = [System.IO.BinaryWriter]::new($docMs)
    $docBw.Write([uint16]0x0003)
    $docBw.Write([uint16]8)
    $docBw.Write([uint32]$totalFileSize)
    $docBw.Write($stringPoolChunk)
    $docBw.Write($resourceMapChunk)
    $docBw.Write($xmlTreeBytes)
    $docBytes = $docMs.ToArray()
    $docBw.Dispose(); $docMs.Dispose()

    return ,$docBytes
}

$generatedAxmlBytes = New-BinaryAxmlManifest -PackageName $peerDeclaration.PackageName -ActivityClassName $peerDeclaration.ClassName
$generatedAxmlPath = Join-Path $tempDir "AndroidManifest.xml"
[System.IO.File]::WriteAllBytes($generatedAxmlPath, $generatedAxmlBytes)
$generatedAxmlHash = (Get-FileHash $generatedAxmlPath).Hash
Write-Host "  Generated binary AndroidManifest.xml: $generatedAxmlHash ($($generatedAxmlBytes.Length) bytes)"
#endregion

[System.IO.File]::WriteAllBytes($patchedXamarinAppPath, $xamarinAppBytes)

foreach ($relPath in $entryNames) {
    if ($relPath -eq "lib/$androidAbi/libassembly-store.so") {
        $rawBytes = [System.IO.File]::ReadAllBytes($generatedElfPath)
    } elseif ($relPath -eq "lib/$androidAbi/libxamarin-app.so") {
        $rawBytes = [System.IO.File]::ReadAllBytes($patchedXamarinAppPath)
    } elseif ($relPath -eq "classes.dex") {
        $rawBytes = [System.IO.File]::ReadAllBytes($generatedClassesDex)
    } elseif ($relPath -eq "AndroidManifest.xml") {
        $rawBytes = [System.IO.File]::ReadAllBytes($generatedAxmlPath)
    } else {
        $fullPath = Join-Path $oracleExtractDir ($relPath.Replace('/', '\'))
        if (-not (Test-Path $fullPath)) { throw "Oracle artifact missing: $fullPath" }
        $rawBytes = [System.IO.File]::ReadAllBytes($fullPath)
    }
    $isStored = ($relPath -eq 'resources.arsc')
    $apkEntries += [PSCustomObject]@{
        Name    = $relPath
        Bytes   = $rawBytes
        Deflate = (-not $isStored)
        Align   = if ($isStored) { 4 } else { 0 }
    }
}

$unsignedApk = Join-Path $apkOutput "$ApplicationId-Unsigned.apk"
Write-ApkZip $unsignedApk $apkEntries
Write-Host "  Unsigned APK written: $unsignedApk ($((Get-Item $unsignedApk).Length) bytes)"
#endregion

#region 08 — Sign APK (APK Signature Scheme v2)
Write-Host "08 — Signing APK with pure PowerShell APK Signature Scheme v2..."
function Write-LengthPrefixed([byte[]]$data) {
    $ms = [System.IO.MemoryStream]::new(); $bw = [System.IO.BinaryWriter]::new($ms)
    $bw.Write([uint32]$data.Length); $bw.Write($data)
    $res = $ms.ToArray(); $bw.Dispose(); $ms.Dispose()
    return ,$res
}

$ksPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Xamarin', 'Mono for Android', 'debug.keystore')
if (-not (Test-Path $ksPath)) {
    throw "Debug keystore not found: $ksPath"
}
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ksPath, 'android')
$rsa  = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)

$signedApkPath = Join-Path $apkOutput "$ApplicationId-Signed.apk"
Copy-Item $unsignedApk $signedApkPath -Force

$fs = [System.IO.File]::Open($signedApkPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
$br = [System.IO.BinaryReader]::new($fs)
$fileLen = $fs.Length
$fs.Position = $fileLen - 22
while ($fs.Position -gt 0 -and $br.ReadUInt32() -ne 0x06054b50) { $fs.Position = $fs.Position - 5 }
$eocdOffset = [uint32]($fs.Position - 4)
$fs.Position = $eocdOffset + 12
$cdSize   = $br.ReadUInt32()
$cdOffset = $br.ReadUInt32()
$fs.Position = 0;            $sec1Bytes = $br.ReadBytes([int]$cdOffset)
$fs.Position = $cdOffset;    $sec2Bytes = $br.ReadBytes([int]$cdSize)
$fs.Position = $eocdOffset;  $sec3Bytes = $br.ReadBytes([int]($fileLen - $eocdOffset))
[System.BitConverter]::GetBytes([uint32]$cdOffset).CopyTo($sec3Bytes, 16)

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$chunkSize = 1048576
$allChunkDigests = [System.Collections.Generic.List[byte]]::new()
$totalChunks = 0
foreach ($sectionBytes in @($sec1Bytes, $sec2Bytes, $sec3Bytes)) {
    $offset = 0
    while ($offset -lt $sectionBytes.Length) {
        $len = [Math]::Min($chunkSize, $sectionBytes.Length - $offset)
        $chunkHeader = New-Object byte[] 5; $chunkHeader[0] = 0xa5
        [System.BitConverter]::GetBytes([uint32]$len).CopyTo($chunkHeader, 1)
        $chunkData = New-Object byte[] (5 + $len)
        [System.Buffer]::BlockCopy($chunkHeader, 0, $chunkData, 0, 5)
        [System.Buffer]::BlockCopy($sectionBytes, $offset, $chunkData, 5, $len)
        $allChunkDigests.AddRange($sha256.ComputeHash($chunkData))
        $totalChunks++; $offset += $len
    }
}
$topHeader = New-Object byte[] 5; $topHeader[0] = 0x5a
[System.BitConverter]::GetBytes([uint32]$totalChunks).CopyTo($topHeader, 1)
$topData = New-Object byte[] (5 + $allChunkDigests.Count)
[System.Buffer]::BlockCopy($topHeader, 0, $topData, 0, 5)
$allChunkDigests.CopyTo($topData, 5)
[byte[]]$apkContentDigest = $sha256.ComputeHash($topData)

$algoId = [uint32]0x0103 # SHA256withRSA
$digestEntryMs = [System.IO.MemoryStream]::new(); $digestEntryBw = [System.IO.BinaryWriter]::new($digestEntryMs)
$digestEntryBw.Write($algoId); $digestEntryBw.Write([uint32]$apkContentDigest.Length); $digestEntryBw.Write($apkContentDigest)
$digestsBlock = Write-LengthPrefixed (Write-LengthPrefixed $digestEntryMs.ToArray())
$certsBlock   = Write-LengthPrefixed (Write-LengthPrefixed $cert.RawData)
$attrsBlock   = Write-LengthPrefixed (New-Object byte[] 0)

$signedDataMs = [System.IO.MemoryStream]::new(); $signedDataBw = [System.IO.BinaryWriter]::new($signedDataMs)
$signedDataBw.Write($digestsBlock); $signedDataBw.Write($certsBlock); $signedDataBw.Write($attrsBlock)
[byte[]]$signedDataPayload = $signedDataMs.ToArray()
[byte[]]$signedData  = Write-LengthPrefixed $signedDataPayload
[byte[]]$sigBytes    = $rsa.SignData($signedDataPayload, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

$sigEntryMs = [System.IO.MemoryStream]::new(); $sigEntryBw = [System.IO.BinaryWriter]::new($sigEntryMs)
$sigEntryBw.Write($algoId); $sigEntryBw.Write([uint32]$sigBytes.Length); $sigEntryBw.Write($sigBytes)
$signaturesBlock = Write-LengthPrefixed (Write-LengthPrefixed $sigEntryMs.ToArray())
$pubKeyBlock     = Write-LengthPrefixed $cert.PublicKey.ExportSubjectPublicKeyInfo()

$signerMs = [System.IO.MemoryStream]::new(); $signerBw = [System.IO.BinaryWriter]::new($signerMs)
$signerBw.Write($signedData); $signerBw.Write($signaturesBlock); $signerBw.Write($pubKeyBlock)
$signersBlock = Write-LengthPrefixed (Write-LengthPrefixed $signerMs.ToArray())

$pairSize = [uint64](4 + $signersBlock.Length)
$pairMs = [System.IO.MemoryStream]::new(); $pairBw = [System.IO.BinaryWriter]::new($pairMs)
$pairBw.Write($pairSize); $pairBw.Write([uint32]0x7109871a); $pairBw.Write($signersBlock)
$v2PairBytes = $pairMs.ToArray()

$blockSize = [uint64]($v2PairBytes.Length + 24)
$blockMs = [System.IO.MemoryStream]::new(); $blockBw = [System.IO.BinaryWriter]::new($blockMs)
$blockBw.Write($blockSize); $blockBw.Write($v2PairBytes)
$blockBw.Write($blockSize); $blockBw.Write([System.Text.Encoding]::ASCII.GetBytes('APK Sig Block 42'))
$signingBlockBytes = $blockMs.ToArray()

$fs.SetLength(0); $bw = [System.IO.BinaryWriter]::new($fs)
$bw.Write($sec1Bytes); $bw.Write($signingBlockBytes); $bw.Write($sec2Bytes)
$newCdOffset = [uint32]($cdOffset + $signingBlockBytes.Length)
[System.BitConverter]::GetBytes($newCdOffset).CopyTo($sec3Bytes, 16)
$bw.Write($sec3Bytes)
$bw.Flush(); $fs.Close()

$signedApk = Get-Item $signedApkPath
Write-Host "  Signed APK produced: $($signedApk.FullName) ($($signedApk.Length) bytes)"
#endregion

#region 09 — Contract Output
"SMA_PACKAGE_VERSION=$smaPackageVersion"
"CONFIGURATION=$Configuration"
"DEBUGGABLE=$debuggable"
"RUNTIME_IDENTIFIER=$RuntimeIdentifier"
"ANDROID_ABI=$androidAbi"
"APPLICATION_ID=$ApplicationId"
'PACKAGING_PROJECT=Disposable'
"APK_EXISTS=$([IO.File]::Exists($signedApk.FullName))"
"APK=$($signedApk.FullName)"
#endregion
