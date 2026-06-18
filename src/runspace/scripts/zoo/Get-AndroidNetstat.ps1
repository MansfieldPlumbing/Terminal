[CmdletBinding()]
param()
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-AdbShell 'dumpsys netstats' | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"
