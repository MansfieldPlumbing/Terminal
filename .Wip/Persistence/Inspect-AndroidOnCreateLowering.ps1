param([string] $MonoAndroidAssemblyPath)

$ErrorActionPreference = 'Stop'
if (-not $MonoAndroidAssemblyPath) {
    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $dotnetRoot = if ($env:DOTNET_ROOT) {
        $env:DOTNET_ROOT
    } elseif ($dotnet) {
        Split-Path $dotnet.Source -Parent
    }
    if ($dotnetRoot) {
        $MonoAndroidAssemblyPath = Get-ChildItem -LiteralPath (Join-Path $dotnetRoot 'packs') `
            -Filter Mono.Android.dll -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $MonoAndroidAssemblyPath -or -not (Test-Path -LiteralPath $MonoAndroidAssemblyPath)) {
    throw 'Mono.Android.dll was not found. Pass -MonoAndroidAssemblyPath or configure DOTNET_ROOT.'
}
$mono = (Resolve-Path -LiteralPath $MonoAndroidAssemblyPath).Path
$android = [Reflection.Assembly]::LoadFrom($mono)
Import-Module "$PSScriptRoot\PersistedSMA.psm1" -Force
$module = Get-Module PersistedSMA

& $module {
    param($android)
    $activityType = $android.GetType('Android.App.Activity', $true)
    $source = @'
class RecoveryProgram {
    static [void] ShowRecovery([Android.App.Activity] $activity, [string] $title, [string] $details) {}
}
class MainActivity : Android.App.Activity {
    [void] OnCreate([Android.OS.Bundle] $state) {
        ([Android.App.Activity] $this).OnCreate($state)
        [RecoveryProgram]::ShowRecovery($this, ':(', 'PROFILE.PS1 recovery')
    }
}
'@
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join "`n") }
    $types = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.TypeDefinitionAst] }, $false))
    $recoveryAst = $types | Where-Object Name -eq 'RecoveryProgram'
    $mainAst = $types | Where-Object Name -eq 'MainActivity'
    $member = $mainAst.Members | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionMemberAst]
    } | Select-Object -First 1
    $assembly = [Reflection.Emit.PersistedAssemblyBuilder]::new(
        [Reflection.AssemblyName]::new('AndroidLifecycleInspection'), [object].Assembly)
    $moduleBuilder = $assembly.DefineDynamicModule('AndroidLifecycleInspection')
    $recoveryType = $moduleBuilder.DefineType(
        'RecoveryProgram', [Reflection.TypeAttributes]'Public,Abstract,Sealed')
    $null = $recoveryType.DefineMethod(
        'ShowRecovery', [Reflection.MethodAttributes]'Public,Static', [void],
        [type[]]@($activityType, [string], [string]))
    $type = $moduleBuilder.DefineType(
        'AndroidSMA.MainActivity', [Reflection.TypeAttributes]'Public,Class', $activityType)
    $typeProperty = $mainAst.GetType().GetProperty('Type', $script:BFInst)
    $typeProperty.SetValue($mainAst, $type)
    $typeProperty.SetValue($recoveryAst, $recoveryType)
    $lowering = Get-SmaMemberLowering $member -Optimize
    $debugProperty = [Linq.Expressions.Expression].GetProperty('DebugView', $script:BFInst)
    $debug = [string]$debugProperty.GetValue($lowering.Lambda)
    $path = Join-Path $PSScriptRoot '..\build\proof\Android-OnCreate-SMA.lambda.txt'
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($path), $debug, [Text.UTF8Encoding]::new($false))
    "LAMBDA_TYPE=$($lowering.Lambda.Type)"
    "LOCALS_MAP=$($null -ne $lowering.NameToIndexMap)"
    $stack = [Collections.Generic.Stack[Linq.Expressions.Expression]]::new()
    $stack.Push($lowering.Lambda.Body)
    while ($stack.Count) {
        $node = $stack.Pop()
        if ($node -is [Linq.Expressions.DynamicExpression]) {
            $binder = $node.Binder
            "BINDER=$($binder.GetType().FullName) RESULT=$($node.Type.FullName)"
            foreach ($propertyName in @('Name', 'IgnoreCase', 'ReturnType', 'CallInfo')) {
                $property = $binder.GetType().GetProperty($propertyName, $script:BFInst)
                if ($property) {
                    try { "  $propertyName=$($property.GetValue($binder))" } catch {}
                }
            }
            foreach ($fieldName in @('_static', '_nonEnumerating', '_classScope', '_methodName', '_propertySetter', '_isStatic', '_invocationConstraints')) {
                $field = $binder.GetType().GetField($fieldName, $script:BFInst)
                if ($field) {
                    try { "  $fieldName=$($field.GetValue($binder))" } catch {}
                }
            }
            $callInfoProperty = $binder.GetType().GetProperty('CallInfo', $script:BFInst)
            if ($callInfoProperty) {
                $callInfo = $callInfoProperty.GetValue($binder)
                "  CALLINFO_COUNT=$($callInfo.ArgumentCount)"
                "  CALLINFO_NAMES=$([string]::Join(',', $callInfo.ArgumentNames))"
            }
            $constraintsField = $binder.GetType().GetField('_invocationConstraints', $script:BFInst)
            if ($constraintsField) {
                $constraints = $constraintsField.GetValue($binder)
                if ($constraints) {
                    "  CONSTRAINT_TARGET=$($constraints.MethodTargetType.AssemblyQualifiedName)"
                    "  CONSTRAINT_PARAM_COUNT=$(@($constraints.ParameterTypes).Count)"
                    for ($constraintIndex = 0; $constraintIndex -lt @($constraints.ParameterTypes).Count; $constraintIndex++) {
                        $constraintType = $constraints.ParameterTypes[$constraintIndex]
                        "  CONSTRAINT_PARAM_$constraintIndex=$(if ($constraintType) { $constraintType.AssemblyQualifiedName } else { '<null>' })"
                    }
                    "  CONSTRAINT_GENERIC_COUNT=$(@($constraints.GenericTypeParameters).Count)"
                }
            }
        }
        foreach ($child in Get-ExpressionChildren $node) { if ($child) { $stack.Push($child) } }
    }
    "DEBUG_VIEW=$([IO.Path]::GetFullPath($path))"
} $android
