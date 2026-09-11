#Requires -Version 7.0
<#
.SYNOPSIS
    Materializes the .NET Android workload directly from NuGet into the active global dotnet tree.

.DESCRIPTION
    This script never invokes `dotnet workload`.

    It:
      - discovers the active global dotnet root;
      - downloads the Android workload manifest directly from NuGet;
      - recursively downloads dependent workload manifests;
      - resolves the packs required by the `android` workload, including inherited workloads;
      - places SDK/framework/tool/template/library packs in the locations the SDK resolver expects;
      - writes file-based workload installation records;
      - explicitly installs Microsoft.NETCore.App.Runtime.android-arm and android-arm64 so
        ARM32/ARM64 CoreCLR runtime payloads are present even when the workload policy graph
        would not select them.

    Defaults are the known-good .NET 11 Preview 7 AndroidSMA generation discussed on 2026-09-03.

.NOTES
    Run elevated when DotnetRoot is under Program Files.
    This is intentionally a materializer, not a workload lifecycle manager.
#>

[CmdletBinding()]
param(
    [string] $DotnetRoot,

    [string] $FeatureBand = '11.0.100-preview.7',

    [string] $AndroidManifestVersion = '37.0.0-preview.7.2131',

    [string] $CoreClrRuntimeVersion = '11.0.0-preview.7.26381.103',

    [string[]] $RuntimeIdentifiers = @(
        'android-arm',
        'android-arm64'
    ),

    [string] $CacheRoot = (Join-Path $env:ProgramData 'dotnet-direct-cache'),

    [string] $NuGetPackageRoot,

    [string[]] $Source = @(
        'https://api.nuget.org/v3/index.json',
        'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-workloads/nuget/v3/index.json'
    ),

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Install-AndroidWorkload.ps1 currently targets Windows global dotnet installations.'
}

function Get-DotnetRoot {
    param([string] $ExplicitRoot)

    if ($ExplicitRoot) {
        return [IO.Path]::GetFullPath($ExplicitRoot)
    }

    $Command = Get-Command dotnet.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($Command) {
        return [IO.Path]::GetFullPath((Split-Path -Parent $Command.Source))
    }

    if ($env:DOTNET_ROOT -and (Test-Path -LiteralPath $env:DOTNET_ROOT)) {
        return [IO.Path]::GetFullPath($env:DOTNET_ROOT)
    }

    $Default = Join-Path $env:ProgramFiles 'dotnet'

    if (Test-Path -LiteralPath $Default) {
        return [IO.Path]::GetFullPath($Default)
    }

    throw 'Could not locate a global dotnet root. Pass -DotnetRoot explicitly.'
}

function Get-NuGetPackageRoot {
    param([string] $ExplicitRoot)

    if ($ExplicitRoot) {
        return [IO.Path]::GetFullPath($ExplicitRoot)
    }

    if ($env:NUGET_PACKAGES) {
        return [IO.Path]::GetFullPath($env:NUGET_PACKAGES)
    }

    $Line = & dotnet nuget locals global-packages --list |
        Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $Line -match '^global-packages:\s*(.+)$') {
        return [IO.Path]::GetFullPath($Matches[1].Trim())
    }

    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.nuget\packages'))
}

function Assert-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)

    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Writing to '$DotnetRoot' requires an elevated PowerShell process."
    }
}

function Get-PackageBaseAddresses {
    param([string[]] $Sources)

    $Result = [Collections.Generic.List[string]]::new()

    foreach ($Uri in $Sources) {
        try {
            Write-Verbose "Reading NuGet service index: $Uri"

            $Index = Invoke-RestMethod -Uri $Uri

            $Base = $Index.resources |
                Where-Object {
                    $_.'@type' -eq 'PackageBaseAddress/3.0.0' -or
                    $_.'@type' -like 'PackageBaseAddress/*'
                } |
                Select-Object -First 1

            if ($Base -and $Base.'@id') {
                $Result.Add(([string]$Base.'@id').TrimEnd('/'))
            }
        }
        catch {
            Write-Warning "Could not read NuGet source '$Uri': $($_.Exception.Message)"
        }
    }

    if ($Result.Count -eq 0) {
        throw 'No usable NuGet PackageBaseAddress source could be resolved.'
    }

    return $Result.ToArray()
}

function Get-FileSha512Base64 {
    param([Parameter(Mandatory)][string] $Path)

    $Stream = [IO.File]::OpenRead($Path)

    try {
        $Hash = [Security.Cryptography.SHA512]::Create()

        try {
            return [Convert]::ToBase64String($Hash.ComputeHash($Stream))
        }
        finally {
            $Hash.Dispose()
        }
    }
    finally {
        $Stream.Dispose()
    }
}

function Get-NuGetPackageContentHash {
    param([Parameter(Mandatory)][string] $Path)

    $PackagingAssembly = Get-ChildItem (Join-Path $DotnetRoot 'sdk') `
        -Recurse -Filter 'NuGet.Packaging.dll' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $PackagingAssembly) {
        throw "NuGet.Packaging.dll was not found beneath '$DotnetRoot\sdk'."
    }

    $Assembly = [Reflection.Assembly]::LoadFrom($PackagingAssembly.FullName)
    $ReaderType = $Assembly.GetType('NuGet.Packaging.PackageArchiveReader', $true)
    $Stream = [IO.File]::OpenRead($Path)
    $Reader = [Activator]::CreateInstance($ReaderType, [object[]]@($Stream))
    try {
        $Fallback = [Func[string]] { Get-FileSha512Base64 -Path $Path }
        return $Reader.GetContentHash([Threading.CancellationToken]::None, $Fallback)
    }
    finally {
        $Reader.Dispose()
        $Stream.Dispose()
    }
}

function Get-NuGetPackage {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Version
    )

    $IdLower = $Id.ToLowerInvariant()
    $VersionLower = $Version.ToLowerInvariant()

    $PackageDirectory = Join-Path $CacheRoot $IdLower
    $PackageDirectory = Join-Path $PackageDirectory $VersionLower
    $PackagePath = Join-Path $PackageDirectory "$IdLower.$VersionLower.nupkg"
    $HashPath = "$PackagePath.sha512"

    New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null

    if ((Test-Path -LiteralPath $PackagePath) -and -not $Force) {
        if (Test-Path -LiteralPath $HashPath) {
            $Expected = (Get-Content -LiteralPath $HashPath -Raw).Trim()
            $Actual = Get-FileSha512Base64 -Path $PackagePath

            if ($Actual -eq $Expected) {
                Write-Host "[HAVE] $Id $Version"
                return $PackagePath
            }

            Write-Warning "Cached hash mismatch for $Id $Version; re-downloading."
        }
        else {
            Write-Host "[HAVE] $Id $Version"
            return $PackagePath
        }
    }

    $Errors = [Collections.Generic.List[string]]::new()

    foreach ($Base in $script:PackageBaseAddresses) {
        $Url = "$Base/$IdLower/$VersionLower/$IdLower.$VersionLower.nupkg"
        $ShaUrl = "$Url.sha512"
        $Partial = "$PackagePath.partial"

        try {
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue

            Write-Host "[GET ] $Id $Version"
            Write-Verbose $Url

            Invoke-WebRequest -Uri $Url -OutFile $Partial

            $Expected = $null

            try {
                $Expected = ([string](Invoke-RestMethod -Uri $ShaUrl)).Trim()
            }
            catch {
                Write-Verbose "No SHA512 sidecar available from $ShaUrl"
            }

            if ($Expected) {
                $Actual = Get-FileSha512Base64 -Path $Partial

                if ($Actual -ne $Expected) {
                    throw "SHA512 mismatch for $Id $Version"
                }

                Set-Content -LiteralPath $HashPath -Value $Expected -NoNewline
            }

            Move-Item -LiteralPath $Partial -Destination $PackagePath -Force
            return $PackagePath
        }
        catch {
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
            $Errors.Add("$Url :: $($_.Exception.Message)")
        }
    }

    throw "Could not download $Id $Version.`n$($Errors -join "`n")"
}

function Copy-ZipEntries {
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $Destination,
        [string] $Prefix
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $DestinationRoot = [IO.Path]::GetFullPath(
        $Destination.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
    )

    $Zip = [IO.Compression.ZipFile]::OpenRead($PackagePath)

    try {
        $Copied = 0

        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName

            if ($Prefix) {
                if (-not $Name.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $Name = $Name.Substring($Prefix.Length)
            }

            if ([string]::IsNullOrWhiteSpace($Name) -or $Name.EndsWith('/')) {
                continue
            }

            $Relative = $Name.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $Target = [IO.Path]::GetFullPath((Join-Path $Destination $Relative))

            if (-not $Target.StartsWith($DestinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe archive path '$($Entry.FullName)' in $PackagePath"
            }

            $Parent = Split-Path -Parent $Target

            if ($Parent) {
                New-Item -ItemType Directory -Path $Parent -Force | Out-Null
            }

            $Input = $Entry.Open()

            try {
                $Output = [IO.File]::Open(
                    $Target,
                    [IO.FileMode]::Create,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )

                try {
                    $Input.CopyTo($Output)
                }
                finally {
                    $Output.Dispose()
                }
            }
            finally {
                $Input.Dispose()
            }

            $Copied++
        }

        return $Copied
    }
    finally {
        $Zip.Dispose()
    }
}

function Install-Manifest {
    param(
        [Parameter(Mandatory)][string] $ManifestId,
        [Parameter(Mandatory)][string] $ManifestVersion
    )

    $Key = $ManifestId.ToLowerInvariant()

    if ($script:Manifests.ContainsKey($Key)) {
        return
    }

    $PackageId = "$ManifestId.manifest-$FeatureBand"
    $Package = Get-NuGetPackage -Id $PackageId -Version $ManifestVersion

    $Destination = Join-Path $DotnetRoot 'sdk-manifests'
    $Destination = Join-Path $Destination $FeatureBand
    $Destination = Join-Path $Destination $ManifestId
    $Destination = Join-Path $Destination $ManifestVersion

    $ManifestFile = Join-Path $Destination 'WorkloadManifest.json'

    if ($Force -or -not (Test-Path -LiteralPath $ManifestFile)) {
        Write-Host "[MAN ] $ManifestId $ManifestVersion"

        if ($Force -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null

        $Count = Copy-ZipEntries `
            -PackagePath $Package `
            -Destination $Destination `
            -Prefix 'data/'

        if ($Count -eq 0) {
            throw "Manifest package $PackageId $ManifestVersion contained no data/ payload."
        }
    }
    else {
        Write-Host "[MAN ] $ManifestId $ManifestVersion (present)"
    }

    if (-not (Test-Path -LiteralPath $ManifestFile)) {
        throw "WorkloadManifest.json was not materialized at '$ManifestFile'."
    }

    $Json = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json

    $script:Manifests[$Key] = [pscustomobject]@{
        Id      = $ManifestId
        Version = $ManifestVersion
        Path    = $ManifestFile
        Json    = $Json
    }

    $Dependencies = $Json.PSObject.Properties['depends-on']

    if ($Dependencies -and $Dependencies.Value) {
        foreach ($Dependency in $Dependencies.Value.PSObject.Properties) {
            Install-Manifest `
                -ManifestId $Dependency.Name `
                -ManifestVersion ([string]$Dependency.Value)
        }
    }
}

function Get-WorkloadDefinition {
    param([Parameter(Mandatory)][string] $WorkloadId)

    foreach ($Manifest in $script:Manifests.Values) {
        $WorkloadsProperty = $Manifest.Json.PSObject.Properties['workloads']

        if (-not $WorkloadsProperty -or -not $WorkloadsProperty.Value) {
            continue
        }

        $Definition = $WorkloadsProperty.Value.PSObject.Properties[$WorkloadId]

        if ($Definition) {
            $Value = $Definition.Value
            $Redirect = $Value.PSObject.Properties['replace-with']

            if ($Redirect -and $Redirect.Value) {
                return Get-WorkloadDefinition -WorkloadId ([string]$Redirect.Value)
            }

            return [pscustomobject]@{
                Manifest = $Manifest
                Id       = $WorkloadId
                Value    = $Value
            }
        }
    }

    throw "Workload '$WorkloadId' was not found in the composed manifest set."
}

function Get-PackDefinition {
    param([Parameter(Mandatory)][string] $PackId)

    foreach ($Manifest in $script:Manifests.Values) {
        $PacksProperty = $Manifest.Json.PSObject.Properties['packs']

        if (-not $PacksProperty -or -not $PacksProperty.Value) {
            continue
        }

        $Definition = $PacksProperty.Value.PSObject.Properties[$PackId]

        if ($Definition) {
            return [pscustomobject]@{
                Manifest = $Manifest
                Id       = $PackId
                Value    = $Definition.Value
            }
        }
    }

    throw "Pack '$PackId' was referenced by the Android workload but no definition was found."
}

function Get-HostRidCandidates {
    $Candidates = [Collections.Generic.List[string]]::new()

    $RuntimeRid = [Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier

    if ($RuntimeRid) {
        $Candidates.Add($RuntimeRid)
    }

    $Architecture = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64'   { 'x64' }
        'X86'   { 'x86' }
        'Arm64' { 'arm64' }
        'Arm'   { 'arm' }
        default { $null }
    }

    if ($Architecture) {
        $Candidates.Add("win-$Architecture")
    }

    $Candidates.Add('win')
    $Candidates.Add('any')

    return $Candidates | Select-Object -Unique
}

function Resolve-PackPackageId {
    param(
        [Parameter(Mandatory)][string] $PackId,
        [Parameter(Mandatory)] $PackDefinition
    )

    $AliasProperty = $PackDefinition.PSObject.Properties['alias-to']

    if (-not $AliasProperty -or -not $AliasProperty.Value) {
        return $PackId
    }

    foreach ($Rid in $script:HostRidCandidates) {
        $Match = $AliasProperty.Value.PSObject.Properties[$Rid]

        if ($Match -and $Match.Value) {
            return [string]$Match.Value
        }
    }

    return $null
}

function Add-WorkloadPackIds {
    param(
        [Parameter(Mandatory)][string] $WorkloadId,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]] $PackIds,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]] $Visited
    )

    if (-not $Visited.Add($WorkloadId)) {
        return
    }

    $Workload = Get-WorkloadDefinition -WorkloadId $WorkloadId
    $Value = $Workload.Value

    $PacksProperty = $Value.PSObject.Properties['packs']

    if ($PacksProperty -and $PacksProperty.Value) {
        foreach ($PackId in @($PacksProperty.Value)) {
            [void]$PackIds.Add([string]$PackId)
        }
    }

    $ExtendsProperty = $Value.PSObject.Properties['extends']

    if ($ExtendsProperty -and $ExtendsProperty.Value) {
        foreach ($BaseWorkload in @($ExtendsProperty.Value)) {
            Add-WorkloadPackIds `
                -WorkloadId ([string]$BaseWorkload) `
                -PackIds $PackIds `
                -Visited $Visited
        }
    }
}

function Write-PackInstallRecord {
    param(
        [Parameter(Mandatory)][string] $PackId,
        [Parameter(Mandatory)][string] $Version
    )

    $RecordDirectory = Join-Path $DotnetRoot 'metadata'
    $RecordDirectory = Join-Path $RecordDirectory 'workloads'
    $RecordDirectory = Join-Path $RecordDirectory 'installedpacks'
    $RecordDirectory = Join-Path $RecordDirectory 'v1'
    $RecordDirectory = Join-Path $RecordDirectory $PackId
    $RecordDirectory = Join-Path $RecordDirectory $Version

    New-Item -ItemType Directory -Path $RecordDirectory -Force | Out-Null

    $Record = Join-Path $RecordDirectory $FeatureBand

    if (-not (Test-Path -LiteralPath $Record)) {
        New-Item -ItemType File -Path $Record -Force | Out-Null
    }
}

function Install-WorkloadPack {
    param([Parameter(Mandatory)][string] $PackId)

    $Definition = Get-PackDefinition -PackId $PackId
    $Pack = $Definition.Value

    $VersionProperty = $Pack.PSObject.Properties['version']
    $KindProperty = $Pack.PSObject.Properties['kind']

    if (-not $VersionProperty -or -not $KindProperty) {
        throw "Pack '$PackId' has an incomplete manifest definition."
    }

    $Version = [string]$VersionProperty.Value
    $Kind = ([string]$KindProperty.Value).ToLowerInvariant()
    $PackageId = Resolve-PackPackageId -PackId $PackId -PackDefinition $Pack

    if (-not $PackageId) {
        Write-Host "[SKIP] $PackId has no alias for this Windows host."
        return
    }

    $Package = Get-NuGetPackage -Id $PackageId -Version $Version

    switch ($Kind) {
        { $_ -in @('framework', 'sdk') } {
            $Destination = Join-Path $DotnetRoot 'packs'
            $Destination = Join-Path $Destination $PackageId
            $Destination = Join-Path $Destination $Version

            $Marker = $Destination

            if ($Force -or -not (Test-Path -LiteralPath $Marker)) {
                Write-Host "[PACK] $PackId -> $PackageId $Version"

                if ($Force -and (Test-Path -LiteralPath $Destination)) {
                    Remove-Item -LiteralPath $Destination -Recurse -Force
                }

                New-Item -ItemType Directory -Path $Destination -Force | Out-Null

                $Count = Copy-ZipEntries `
                    -PackagePath $Package `
                    -Destination $Destination `
                    -Prefix 'data/'

                if ($Count -eq 0) {
                    throw "Workload pack $PackageId $Version contained no data/ payload."
                }
            }
            else {
                Write-Host "[PACK] $PackId -> $PackageId $Version (present)"
            }

            Write-PackInstallRecord -PackId $PackId -Version $Version

            if ($PackageId -ne $PackId) {
                Write-PackInstallRecord -PackId $PackageId -Version $Version
            }

            break
        }

        'tool' {
            $Destination = Join-Path $DotnetRoot 'tool-packs'
            $Destination = Join-Path $Destination $PackageId
            $Destination = Join-Path $Destination $Version

            if ($Force -or -not (Test-Path -LiteralPath $Destination)) {
                Write-Host "[TOOL] $PackId -> $PackageId $Version"

                if ($Force -and (Test-Path -LiteralPath $Destination)) {
                    Remove-Item -LiteralPath $Destination -Recurse -Force
                }

                New-Item -ItemType Directory -Path $Destination -Force | Out-Null

                $Count = Copy-ZipEntries `
                    -PackagePath $Package `
                    -Destination $Destination `
                    -Prefix 'data/'

                if ($Count -eq 0) {
                    throw "Tool pack $PackageId $Version contained no data/ payload."
                }
            }

            Write-PackInstallRecord -PackId $PackId -Version $Version

            if ($PackageId -ne $PackId) {
                Write-PackInstallRecord -PackId $PackageId -Version $Version
            }

            break
        }

        { $_ -in @('template', 'library') } {
            $DirectoryName = if ($Kind -eq 'template') {
                'template-packs'
            }
            else {
                'library-packs'
            }

            $DestinationDirectory = Join-Path $DotnetRoot $DirectoryName
            New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

            $CanonicalName = "$($PackageId.ToLowerInvariant()).$($Version.ToLowerInvariant()).nupkg"
            $Destination = Join-Path $DestinationDirectory $CanonicalName

            if ($Force -or -not (Test-Path -LiteralPath $Destination)) {
                Write-Host "[$($Kind.ToUpperInvariant())] $PackId -> $PackageId $Version"
                Copy-Item -LiteralPath $Package -Destination $Destination -Force
            }

            Write-PackInstallRecord -PackId $PackId -Version $Version

            if ($PackageId -ne $PackId) {
                Write-PackInstallRecord -PackId $PackageId -Version $Version
            }

            break
        }

        default {
            throw "Unknown workload pack kind '$Kind' for '$PackId'."
        }
    }
}

function Install-DirectRuntimePack {
    param(
        [Parameter(Mandatory)][string] $RuntimeIdentifier,
        [Parameter(Mandatory)][string] $Version
    )

    $PackageId = "Microsoft.NETCore.App.Runtime.$RuntimeIdentifier"
    $Package = Get-NuGetPackage -Id $PackageId -Version $Version

    # Framework resolution consumes this package from NuGet's global package
    # folder. Seed that exact layout so ARM32 does not work merely because a
    # previous restore happened to leave the unpublished runtime in a cache.
    $IdLower = $PackageId.ToLowerInvariant()
    $VersionLower = $Version.ToLowerInvariant()
    $GlobalDestination = Join-Path $NuGetPackageRoot $IdLower
    $GlobalDestination = Join-Path $GlobalDestination $VersionLower
    $GlobalCoreClr = Join-Path $GlobalDestination "runtimes\$RuntimeIdentifier\native\libcoreclr.so"
    $GlobalJit = Join-Path $GlobalDestination "runtimes\$RuntimeIdentifier\native\libclrjit.so"

    if ($Force -or -not (Test-Path -LiteralPath $GlobalCoreClr) -or -not (Test-Path -LiteralPath $GlobalJit)) {
        Write-Host "[NUGET] $PackageId $Version -> $GlobalDestination"
        if ($Force -and (Test-Path -LiteralPath $GlobalDestination)) {
            Remove-Item -LiteralPath $GlobalDestination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $GlobalDestination -Force | Out-Null
        $Count = Copy-ZipEntries -PackagePath $Package -Destination $GlobalDestination
        if ($Count -eq 0) { throw "Runtime package $PackageId $Version was empty." }

        $CanonicalPackage = Join-Path $GlobalDestination "$IdLower.$VersionLower.nupkg"
        $CanonicalHash = "$CanonicalPackage.sha512"
        Copy-Item -LiteralPath $Package -Destination $CanonicalPackage -Force
        $ArchiveHash = Get-FileSha512Base64 -Path $CanonicalPackage
        $ContentHash = Get-NuGetPackageContentHash -Path $CanonicalPackage
        Set-Content -LiteralPath $CanonicalHash -Value $ArchiveHash -NoNewline
        [IO.File]::WriteAllText(
            (Join-Path $GlobalDestination '.nupkg.metadata'),
            (@{ version = 2; contentHash = $ContentHash; source = $Source[0] } | ConvertTo-Json),
            [Text.UTF8Encoding]::new($false))
    }
    else {
        Write-Host "[NUGET] $PackageId $Version (present)"
    }

    $Destination = Join-Path $DotnetRoot 'packs'
    $Destination = Join-Path $Destination $PackageId
    $Destination = Join-Path $Destination $Version

    $CoreClr = Join-Path $Destination "runtimes\$RuntimeIdentifier\native\libcoreclr.so"
    $Jit = Join-Path $Destination "runtimes\$RuntimeIdentifier\native\libclrjit.so"

    if ($Force -or -not (Test-Path -LiteralPath $CoreClr) -or -not (Test-Path -LiteralPath $Jit)) {
        Write-Host "[CORE] $PackageId $Version"

        if ($Force -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null

        $Count = Copy-ZipEntries `
            -PackagePath $Package `
            -Destination $Destination

        if ($Count -eq 0) {
            throw "Runtime package $PackageId $Version was empty."
        }
    }
    else {
        Write-Host "[CORE] $PackageId $Version (present)"
    }

    Write-PackInstallRecord -PackId $PackageId -Version $Version

    if ($RuntimeIdentifier -eq 'android-arm') {
        if (-not (Test-Path -LiteralPath $CoreClr)) {
            throw "ARM32 libcoreclr.so is missing from '$Destination'."
        }

        if (-not (Test-Path -LiteralPath $Jit)) {
            throw "ARM32 libclrjit.so is missing from '$Destination'."
        }
    }
}

function Write-WorkloadInstallRecord {
    param([Parameter(Mandatory)][string] $WorkloadId)

    $Directory = Join-Path $DotnetRoot 'metadata'
    $Directory = Join-Path $Directory 'workloads'
    $Directory = Join-Path $Directory $FeatureBand
    $Directory = Join-Path $Directory 'installedworkloads'

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null

    $Record = Join-Path $Directory $WorkloadId

    if (-not (Test-Path -LiteralPath $Record)) {
        New-Item -ItemType File -Path $Record -Force | Out-Null
    }
}


# ---- Main --------------------------------------------------------------------

$DotnetRoot = Get-DotnetRoot -ExplicitRoot $DotnetRoot
$NuGetPackageRoot = Get-NuGetPackageRoot -ExplicitRoot $NuGetPackageRoot

if (-not (Test-Path -LiteralPath $DotnetRoot)) {
    throw "Dotnet root '$DotnetRoot' does not exist."
}

Assert-Administrator

New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null

$script:PackageBaseAddresses = Get-PackageBaseAddresses -Sources $Source
$script:Manifests = @{}
$script:HostRidCandidates = @(Get-HostRidCandidates)

Write-Host
Write-Host "Dotnet root      : $DotnetRoot"
Write-Host "Feature band     : $FeatureBand"
Write-Host "Android manifest : $AndroidManifestVersion"
Write-Host "CoreCLR runtime  : $CoreClrRuntimeVersion"
Write-Host "NuGet packages   : $NuGetPackageRoot"
Write-Host "Host RID aliases : $($script:HostRidCandidates -join ', ')"
Write-Host

# Materialize Android + every manifest it declares as a dependency.
Install-Manifest `
    -ManifestId 'microsoft.net.sdk.android' `
    -ManifestVersion $AndroidManifestVersion

# Resolve exactly what the composed manifest graph says `android` requires.
$PackIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)

$VisitedWorkloads = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)

Add-WorkloadPackIds `
    -WorkloadId 'android' `
    -PackIds $PackIds `
    -Visited $VisitedWorkloads

Write-Host
Write-Host "[INFO] Android workload requires $($PackIds.Count) manifest pack(s)."
Write-Host

foreach ($PackId in ($PackIds | Sort-Object)) {
    Install-WorkloadPack -PackId $PackId
}

# The Android workload policy graph does not reliably select the ARM32 CoreCLR
# runtime package. Materialize the runtime packs explicitly.
foreach ($Rid in $RuntimeIdentifiers) {
    Install-DirectRuntimePack `
        -RuntimeIdentifier $Rid `
        -Version $CoreClrRuntimeVersion
}

Write-WorkloadInstallRecord -WorkloadId 'android'

Write-Host
Write-Host '[DONE] Android workload materialized directly from NuGet.'
Write-Host
Write-Host "Manifest root : $(Join-Path $DotnetRoot "sdk-manifests\$FeatureBand")"
Write-Host "Pack root     : $(Join-Path $DotnetRoot 'packs')"
Write-Host "Cache         : $CacheRoot"

$Arm32Root = Join-Path $DotnetRoot "packs\Microsoft.NETCore.App.Runtime.android-arm\$CoreClrRuntimeVersion"
$Arm32CoreClr = Join-Path $Arm32Root 'runtimes\android-arm\native\libcoreclr.so'
$Arm32Jit = Join-Path $Arm32Root 'runtimes\android-arm\native\libclrjit.so'
$Arm32NuGetRoot = Join-Path $NuGetPackageRoot "microsoft.netcore.app.runtime.android-arm\$($CoreClrRuntimeVersion.ToLowerInvariant())"
$Arm32NuGetCoreClr = Join-Path $Arm32NuGetRoot 'runtimes\android-arm\native\libcoreclr.so'
$Arm32NuGetJit = Join-Path $Arm32NuGetRoot 'runtimes\android-arm\native\libclrjit.so'
$Arm32AndroidRoot = Join-Path $DotnetRoot "packs\Microsoft.Android.Runtime.CoreCLR.37.android-arm\$AndroidManifestVersion"
$Arm32AndroidHost = Join-Path $Arm32AndroidRoot 'runtimes\android-arm\native\libnet-android.release.so'

if ('android-arm' -in $RuntimeIdentifiers) {
    Write-Host
    Write-Host 'ARM32 CoreCLR receipts:'
    Get-Item -LiteralPath $Arm32CoreClr, $Arm32Jit, $Arm32NuGetCoreClr, $Arm32NuGetJit, $Arm32AndroidHost |
        Select-Object Name, Length, FullName |
        Format-Table -AutoSize

    Write-Host 'ARM32_CORECLR_RUNTIME=True'
    Write-Host 'ARM32_CLRJIT_RUNTIME=True'
    Write-Host 'ARM32_ANDROID_CORECLR_HOST=True'
}
