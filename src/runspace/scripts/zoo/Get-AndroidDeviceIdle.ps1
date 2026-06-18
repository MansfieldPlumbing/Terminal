[CmdletBinding()]
param()
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-AdbShell 'dumpsys deviceidle' | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"
