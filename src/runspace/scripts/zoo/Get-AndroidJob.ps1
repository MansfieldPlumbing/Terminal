[CmdletBinding()]
param()
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Invoke-AdbShell 'dumpsys jobscheduler' | & "$PSScriptRoot\ConvertFrom-DumpsysTree.ps1"
