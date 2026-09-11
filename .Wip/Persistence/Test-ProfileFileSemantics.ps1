#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$proofRoot = Join-Path ([IO.Path]::GetTempPath()) ('AndroidSMA-ProfileFile-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($proofRoot) | Out-Null
$proofPath = Join-Path $proofRoot 'Profile.ps1'
$source = @'
using namespace System.Text

param([string] $Receipt = 'default')

[pscustomobject]@{
    Root    = $PSScriptRoot
    Receipt = $Receipt
    Type    = [StringBuilder].FullName
}
'@

try {
    [IO.File]::WriteAllText($proofPath, $source, [Text.UTF8Encoding]::new($false))
    $before = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($proofPath)))
    $shell = [Management.Automation.PowerShell]::Create()
    try {
        $null = $shell.AddCommand($proofPath)
        $null = $shell.AddParameter('Receipt', 'HOST_VALUE')
        $result = @($shell.Invoke())
        if ($shell.HadErrors) { throw ($shell.Streams.Error[0].ToString()) }
    }
    finally { $shell.Dispose() }
    $after = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($proofPath)))
    $item = $result[0]
    "SOURCE_UNCHANGED=$($before -eq $after)"
    "USING_NAMESPACE=$($item.Type -eq 'System.Text.StringBuilder')"
    "PARAMETER=$($item.Receipt)"
    "PSSCRIPTROOT=$($item.Root)"
    "PSSCRIPTROOT_MATCH=$($item.Root -eq $proofRoot)"

    $failurePath = Join-Path $proofRoot 'Profile.Failure.ps1'
    $failureSource = @'
using namespace System.Text

param([string] $Receipt = 'default')

[StringBuilder
'@
    [IO.File]::WriteAllText($failurePath, $failureSource, [Text.UTF8Encoding]::new($false))
    $failureShell = [Management.Automation.PowerShell]::Create()
    try {
        $null = $failureShell.AddCommand($failurePath)
        $caughtFailure = $null
        try { $null = $failureShell.Invoke() } catch { $caughtFailure = $_ }
        $failure = if ($failureShell.Streams.Error.Count) {
            $failureShell.Streams.Error[0]
        } else { $caughtFailure }
    }
    finally { $failureShell.Dispose() }
    $parseError = $caughtFailure.Exception.InnerException.Errors[0]
    "FAILURE_REPORTED=$($null -ne $failure)"
    "FAILURE_SCRIPT=$($parseError.Extent.File)"
    "FAILURE_LINE=$($parseError.Extent.StartLineNumber)"
    "FAILURE_POSITION=$($parseError.Extent.Text)"
    "FAILURE_LOCATION_MATCH=$($parseError.Extent.File -eq $failurePath -and $parseError.Extent.StartLineNumber -eq 5)"
}
finally {
    if ([IO.Directory]::Exists($proofRoot)) {
        [IO.Directory]::Delete($proofRoot, $true)
    }
}
