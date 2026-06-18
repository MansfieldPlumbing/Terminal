[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Package
)

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$raw = Invoke-AdbShell 'dumpsys app_function'
$tree = $raw | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$user0 = $tree.'AppFunction state for user 0'
if ($null -ne $user0) {
    foreach ($propName in $user0.psobject.Properties.Name) {
        if ($propName -match 'AppFunctionMetadata for:\s*(.*)') {
            $funcId = $Matches[1].Trim()
            $metadata = $user0.$propName
            
            $staticMeta = $metadata.'Static Metadata'
            $pkg = $null
            $desc = $null
            $schemaCategory = $null
            $schemaName = $null
            $enabled = $false
            
            if ($null -ne $staticMeta) {
                if ($staticMeta.packageName -is [array]) {
                    $pkg = $staticMeta.packageName[0]
                } elseif ($null -ne $staticMeta.packageName) {
                    $pkg = $staticMeta.packageName
                }
                
                if ($staticMeta.description -is [array]) {
                    $desc = $staticMeta.description[0]
                } elseif ($null -ne $staticMeta.description) {
                    $desc = $staticMeta.description
                }
                
                if ($staticMeta.schemaCategory -is [array]) {
                    $schemaCategory = $staticMeta.schemaCategory[0]
                } elseif ($null -ne $staticMeta.schemaCategory) {
                    $schemaCategory = $staticMeta.schemaCategory
                }
                
                if ($staticMeta.schemaName -is [array]) {
                    $schemaName = $staticMeta.schemaName[0]
                } elseif ($null -ne $staticMeta.schemaName) {
                    $schemaName = $staticMeta.schemaName
                }
                
                if ($staticMeta.enabledByDefault -is [array]) {
                    $enabled = [System.Convert]::ToBoolean($staticMeta.enabledByDefault[0])
                } elseif ($null -ne $staticMeta.enabledByDefault) {
                    $enabled = [System.Convert]::ToBoolean($staticMeta.enabledByDefault)
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($Package) -and $pkg -ne $Package) {
                continue
            }
            
            [void]$results.Add([pscustomobject]@{
                FunctionId     = $funcId
                Package        = $pkg
                Description    = $desc
                SchemaCategory = $schemaCategory
                SchemaName     = $schemaName
                Enabled        = $enabled
            })
        }
    }
}

$results
