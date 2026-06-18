[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Package
)

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$raw = Invoke-AdbShell 'cmd package query-activities -a android.intent.action.MAIN'
$tree = $raw | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($null -ne $tree) {
    foreach ($propName in $tree.psobject.Properties.Name) {
        if ($propName -notmatch '^Activity #') { continue }
        $act = $tree.$propName
        if ($null -eq $act -or $null -eq $act.ActivityInfo) { continue }
        
        $info = $act.ActivityInfo
        $pkg = $info.packageName
        $name = $info.name
        
        # Extract label
        $label = $null
        $labelString = $info.labelRes
        if ($null -ne $labelString -and $labelString -match 'nonLocalizedLabel=([^ ]+)') {
            $lblVal = $Matches[1]
            if ($lblVal -ne 'null') { $label = $lblVal }
        }
        if ($null -eq $label) {
            $label = $name
        }

        # Extract enabled and exported
        $enabled = $false
        $exported = $false
        $enabledString = $info.enabled
        
        if ($null -ne $enabledString) {
            if ($enabledString -match 'enabled=(true|false)') {
                $enabled = [System.Convert]::ToBoolean($Matches[1])
            } elseif ($enabledString -match '^true') {
                $enabled = $true
            }
            if ($enabledString -match 'exported=(true|false)') {
                $exported = [System.Convert]::ToBoolean($Matches[1])
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Package) -and $pkg -ne $Package) {
            continue
        }

        [void]$results.Add([pscustomobject]@{
            Package  = $pkg
            Activity = $name
            Label    = $label
            Exported = $exported
            Enabled  = $enabled
        })
    }
}

$results
