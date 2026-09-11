Set-StrictMode -Version Latest

function Write-MicrosoftLambdaToMethodBuilder {
    param(
        [Parameter(Mandatory)][Linq.Expressions.LambdaExpression] $Lambda,
        [Parameter(Mandatory)][Reflection.Emit.MethodBuilder] $MethodBuilder,
        [switch] $ExplicitThis
    )

    $instanceFlags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
    $compiler = [Linq.Expressions.Expression].Assembly.GetType(
        'System.Linq.Expressions.Compiler.LambdaCompiler', $true)
    $analyze = $compiler.GetMethods($staticFlags) |
        Where-Object { $_.Name -eq 'AnalyzeLambda' -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    if ($null -eq $analyze) { throw 'Microsoft LambdaCompiler.AnalyzeLambda was not found.' }

    [object[]] $analyzeArguments = @($Lambda)
    $tree = $analyze.Invoke($null, $analyzeArguments)
    $lowered = [Linq.Expressions.LambdaExpression]$analyzeArguments[0]
    $constructor = $compiler.GetConstructors($instanceFlags) |
        Where-Object {
            $parameters = $_.GetParameters()
            $parameters.Count -eq 2 -and
                $parameters[1].ParameterType -eq [Linq.Expressions.LambdaExpression]
        } | Select-Object -First 1
    if ($null -eq $constructor) { throw 'Microsoft LambdaCompiler constructor was not found.' }

    $instance = $constructor.Invoke([object[]]@($tree, $lowered))
    $methodField = $compiler.GetField('_method', $instanceFlags)
    $ilField = $compiler.GetField('_ilg', $instanceFlags)
    $closureField = $compiler.GetField('_hasClosureArgument', $instanceFlags)
    $typeBuilderField = $compiler.GetField('_typeBuilder', $instanceFlags)
    foreach ($field in @($methodField, $ilField, $closureField)) {
        if ($null -eq $field) { throw 'The current Microsoft LambdaCompiler layout is unsupported.' }
    }
    $methodIdentity = $MethodBuilder
    if ($ExplicitThis) {
        $methodIdentity = [Reflection.Emit.DynamicMethod]::new(
            "__PersistedSignature_$($MethodBuilder.Name)",
            $Lambda.ReturnType,
            [type[]]@($Lambda.Parameters | ForEach-Object Type),
            $true)
    }
    $methodField.SetValue($instance, $methodIdentity)
    $ilField.SetValue($instance, $MethodBuilder.GetILGenerator())
    $closureField.SetValue($instance, $false)
    if ($null -ne $typeBuilderField) {
        $typeBuilderField.SetValue($instance, $MethodBuilder.DeclaringType)
    }
    $emit = $compiler.GetMethods($instanceFlags) |
        Where-Object { $_.Name -eq 'EmitLambdaBody' -and $_.GetParameters().Count -eq 0 } |
        Select-Object -First 1
    if ($null -eq $emit) { throw 'Microsoft LambdaCompiler.EmitLambdaBody was not found.' }
    $null = $emit.Invoke($instance, @())
}
