[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Package
)
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmd = "dumpsys gfxinfo"
if (-not [string]::IsNullOrWhiteSpace($Package)) {
    $cmd += " $Package"
}
Invoke-AdbShell $cmd | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"
