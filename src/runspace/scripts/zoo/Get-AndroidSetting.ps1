[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Key,

    [Parameter(Position = 1)]
    [ValidateSet('global', 'system', 'secure')]
    [string]$Scope = 'global'
)

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not [string]::IsNullOrWhiteSpace($Key)) {
    $val = Invoke-AdbShell "settings get $Scope $Key"
    if ($null -ne $val) {
        $val = $val.Trim()
        if ($val -eq 'null') { return $null }
        return $val
    }
    return $null
} else {
    Invoke-AdbShell "settings list $Scope" | & "$PSScriptRoot\ConvertFrom-Settings.ps1"
}
