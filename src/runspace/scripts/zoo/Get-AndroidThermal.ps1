[CmdletBinding()]
param()
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-AdbShell 'dumpsys thermalservice' | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"
