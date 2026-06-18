[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$RawServiceList = $null
)

# 1. Get the list of all registered services via ADB shell or parameter
if ($null -ne $RawServiceList -and $RawServiceList.Length -gt 0) {
    $lines = $RawServiceList
} else {
    $rawServices = Invoke-AdbShell -Command 'service list'
    $lines = $rawServices -split "`r?`n"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# 2. Build index of loaded interface types once (O(N) initialization)
$interfaceByFullName = @{}
$interfaceByName = @{}

[System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
    $_.GetName().Name -eq "Mono.Android" -or $_.GetName().Name -eq "Subsystem"
} | ForEach-Object {
    try {
        $_.GetTypes()
    } catch [System.Reflection.ReflectionTypeLoadException] {
        $_.Exception.Types
    } catch {}
} | Where-Object { $_ -ne $null -and $_.IsInterface } | ForEach-Object {
    $interfaceByFullName[$_.FullName] = $_
    $interfaceByName[$_.Name] = $_
}

# Helper to map Java package name (e.g. android.os.IThermalService) to Xamarin naming conventions (O(1) lookup)
function Find-DotNetInterface {
    param([string]$AidlName)
    if ([string]::IsNullOrEmpty($AidlName)) { return $null }

    # Replace lowercase package parts with standard .NET casings (best-effort match)
    $parts = $AidlName.Split('.')
    $caser = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    
    for ($i = 0; $i -lt ($parts.Length - 1); $i++) {
        $parts[$i] = $caser.ToTitleCase($parts[$i])
    }
    
    $mappedName = [string]::Join('.', $parts)

    # O(1) FullName check
    if ($interfaceByFullName.ContainsKey($mappedName)) {
        return $interfaceByFullName[$mappedName]
    }

    # O(1) ShortName fallback (e.g. "IThermalService")
    $shortName = $parts[-1]
    if ($interfaceByName.ContainsKey($shortName)) {
        return $interfaceByName[$shortName]
    }

    return $null
}

# 3. Iterate and inspect each Binder service
foreach ($line in $lines) {
    $serviceName = $null
    $aidlName = $null
    
    if ($line -match '^\s*\d+\s+([^:]+?)\s*:\s*\[(.*)\]\s*$') {
        $serviceName = $Matches[1].Trim()
        $aidlName = $Matches[2].Trim()
    } elseif ($line -match '^\s*\d+\s+([^:]+?)\s*:\s*\[\s*\]\s*$') {
        $serviceName = $Matches[1].Trim()
        $aidlName = ""
    }

    if ([string]::IsNullOrEmpty($serviceName)) { continue }

    # Attempt to locate matching interface type
    $interfaceType = Find-DotNetInterface -AidlName $aidlName
    
    $methods = [System.Collections.Generic.List[string]]::new()
    if ($interfaceType) {
        # Reflect and extract all public method signatures (verbs)
        $interfaceType.GetMethods() | ForEach-Object {
            $params = $_.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }
            $paramStr = [string]::Join(", ", $params)
            [void]$methods.Add("$($_.ReturnType.Name) $($_.Name)($paramStr)")
        }
    }

    [void]$results.Add([pscustomobject]@{
        Service    = $serviceName
        Interface  = $aidlName
        DotNetType = if ($interfaceType) { $interfaceType.FullName } else { "Unknown" }
        Verbs      = $methods.ToArray()
    })
}

$results
