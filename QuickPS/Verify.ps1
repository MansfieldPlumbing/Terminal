[CmdletBinding()]
param(
    [string] $Path = $PSScriptRoot
)

if ($MyInvocation.InvocationName -eq '.') {
    throw 'Verify.ps1 must be invoked with &, not dot-sourced.'
}

$ErrorActionPreference = 'Stop'
$allowedSystemDlls = [Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'advapi32.dll', 'avrt.dll', 'd2d1.dll', 'd3d11.dll', 'd3d12.dll',
        'd3dcompiler_47.dll', 'dcomp.dll', 'dwmapi.dll', 'dxgi.dll',
        'kernel32.dll', 'mf.dll', 'mfplat.dll', 'mfreadwrite.dll',
        'mmdevapi.dll', 'ole32.dll', 'propsys.dll', 'shcore.dll',
        'user32.dll', 'windowscodecs.dll'
    ),
    [StringComparer]::OrdinalIgnoreCase)

$failures = [Collections.Generic.List[string]]::new()
$receipts = [Collections.Generic.List[object]]::new()
$binderFiles = Get-ChildItem -LiteralPath $Path -File -Filter '*.ps1' |
    Where-Object Name -NotIn @('QuickPS.ps1', 'Verify.ps1') |
    Sort-Object Name

foreach ($file in $binderFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
    $fileFailures = [Collections.Generic.List[string]]::new()

    foreach ($errorRecord in $parseErrors) {
        $fileFailures.Add("parse line $($errorRecord.Extent.StartLineNumber): $($errorRecord.Message)")
    }

    $source = [IO.File]::ReadAllText($file.FullName)
    if ($source -notmatch [regex]::Escape("`$MyInvocation.InvocationName -eq '.'")) {
        $fileFailures.Add('missing explicit dot-source rejection')
    }

    foreach ($forbidden in @(
        'DirectPort.PowerShell', 'GpuConsole', 'DirectPort.Console.Native',
        'ijwhost', 'Add-Type', 'Reflection.Assembly]::LoadFrom',
        'Assembly]::LoadFrom', 'DllImport', 'New-Capability',
        'GrantDomain', 'RootCapability', 'CapabilityScope'
    )) {
        if ($source.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $fileFailures.Add("forbidden reference: $forbidden")
        }
    }

    $globalFunctions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name.StartsWith('global:', [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    foreach ($function in $globalFunctions) {
        $fileFailures.Add("global function line $($function.Extent.StartLineNumber): $($function.Name)")
    }

    $globalVariables = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.VariablePath.IsGlobal
    }, $true))
    foreach ($variable in $globalVariables) {
        $fileFailures.Add("global variable line $($variable.Extent.StartLineNumber): $($variable.Extent.Text)")
    }

    $dotSources = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot
    }, $true))
    foreach ($command in $dotSources) {
        $fileFailures.Add("dot-source command line $($command.Extent.StartLineNumber)")
    }

    $scriptDependencies = @($ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $false }
        $node.Value.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    foreach ($dependency in $scriptDependencies) {
        $fileFailures.Add("script dependency line $($dependency.Extent.StartLineNumber): $($dependency.Value)")
    }

    $dllNames = [regex]::Matches($source, '(?i)(?<name>[a-z0-9_.-]+\.dll)') |
        ForEach-Object { $_.Groups['name'].Value } |
        Sort-Object -Unique
    foreach ($dllName in $dllNames) {
        if (-not $allowedSystemDlls.Contains($dllName)) {
            $fileFailures.Add("non-system DLL: $dllName")
        }
    }

    foreach ($failure in $fileFailures) {
        $failures.Add("$($file.Name): $failure")
    }
    $receipts.Add([PSCustomObject]@{
        File = $file.Name
        Passed = $fileFailures.Count -eq 0
        Checks = 8
        Failures = $fileFailures.ToArray()
        Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    })
}

$receipts
if ($failures.Count) {
    throw "QuickPS binder ratchet failed:`n$($failures -join "`n")"
}
