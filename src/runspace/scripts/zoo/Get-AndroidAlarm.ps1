[CmdletBinding()]
param()
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-AdbShell 'dumpsys alarm' | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"
