Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BFStatic = [Reflection.BindingFlags]'Static,Public,NonPublic'
$script:BFInst   = [Reflection.BindingFlags]'Instance,Public,NonPublic'

function Resolve-SmaReflectionType {
    param([Parameter(Mandatory)][object]$TypeName)

    $m = $TypeName.GetType().GetMethod(
        'GetReflectionType',
        $script:BFInst,
        $null,
        [type[]]@(),
        $null
    )

    if (-not $m) { throw "GetReflectionType() missing on $($TypeName.GetType().FullName)." }

    $t = $m.Invoke($TypeName, @())
    if (-not $t) { throw "Cannot resolve type '$($TypeName.FullName)'." }

    [type]$t
}

function Get-ClassAst {
    param([Parameter(Mandatory)][string]$Source)

    $tokens = $null
    $errors = $null

    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors -and $errors.Count) {
        throw ($errors.Message -join "`n")
    }

    $typeAst = $ast.FindAll(
        {
            param($n)
            $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and -not $n.IsEnum
        },
        $false
    ) | Select-Object -First 1

    if (-not $typeAst) { throw 'No class found.' }

    [pscustomobject]@{
        Ast     = $ast
        TypeAst = $typeAst
    }
}

function Get-MemberSignature {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionMemberAst]$Member
    )

    if ($Member.IsConstructor) { throw 'Constructor not supported in this proof.' }

    $returnType = Resolve-SmaReflectionType $Member.ReturnType.TypeName

    $pts = [System.Collections.Generic.List[type]]::new()
    $pns = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $Member.Parameters) {
        $tc = $p.Attributes |
            Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } |
            Select-Object -First 1

        $pt = if ($tc) { Resolve-SmaReflectionType $tc.TypeName } else { [object] }

        $pts.Add($pt)
        $pns.Add($p.Name.VariablePath.UserPath)
    }

    [pscustomobject]@{
        Name           = $Member.Name
        IsStatic       = [bool]$Member.IsStatic
        ReturnType     = $returnType
        ParameterTypes = [type[]]$pts.ToArray()
        ParameterNames = [string[]]$pns.ToArray()
    }
}

function New-SmaMemberScriptBlock {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionMemberAst]$Member
    )

    $sma = [System.Management.Automation.PSObject].Assembly
    $ipmp = $sma.GetType(
        'System.Management.Automation.Language.IParameterMetadataProvider',
        $true
    )

    $ctor = [ScriptBlock].GetConstructors($script:BFInst) |
        Where-Object {
            $p = $_.GetParameters()
            $p.Count -eq 2 -and
            $p[0].ParameterType -eq $ipmp -and
            $p[1].ParameterType -eq [bool]
        } |
        Select-Object -First 1

    if (-not $ctor) {
        throw 'ScriptBlock(IParameterMetadataProvider,bool) ctor not found.'
    }

    [ScriptBlock]$ctor.Invoke([object[]]@($Member, $false))
}

function Get-SmaMemberLowering {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionMemberAst]$Member,

        [switch]$Optimize
    )

    $sb = New-SmaMemberScriptBlock $Member

    $dataField = [ScriptBlock].GetField('_scriptBlockData', $script:BFInst)
    if (-not $dataField) { throw 'ScriptBlock._scriptBlockData missing.' }

    $data = $dataField.GetValue($sb)

    $sma = [System.Management.Automation.PSObject].Assembly
    $compilerType = $sma.GetType(
        'System.Management.Automation.Language.Compiler',
        $true
    )

    $compiler = [Activator]::CreateInstance($compilerType, $true)

    $compile = $compilerType.GetMethods($script:BFInst) |
        Where-Object {
            $p = $_.GetParameters()
            $_.Name -eq 'Compile' -and
            $p.Count -eq 2 -and
            $p[1].ParameterType -eq [bool]
        } |
        Select-Object -First 1

    if (-not $compile) { throw 'Compiler.Compile(data,bool) missing.' }

    $null = $compile.Invoke($compiler, [object[]]@($data, [bool]$Optimize))

    $lambdaField = $compilerType.GetField('_endBlockLambda', $script:BFInst)
    $lambda = $lambdaField.GetValue($compiler)

    if (-not $lambda) { throw 'SMA did not produce _endBlockLambda.' }

    $map = $null
    $mapProp = $data.GetType().GetProperty('NameToIndexMap', $script:BFInst)
    if ($mapProp) { $map = $mapProp.GetValue($data) }

    [pscustomobject]@{
        Lambda         = [Linq.Expressions.LambdaExpression]$lambda
        NameToIndexMap = $map
        Data           = $data
        Compiler       = $compiler
    }
}

function Get-ExpressionChildren {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.Expression]$Expression
    )

    if ($Expression -is [Linq.Expressions.BlockExpression]) {
        return @($Expression.Expressions)
    }

    if ($Expression -is [Linq.Expressions.TryExpression]) {
        $r = @($Expression.Body)
        if ($Expression.Finally) { $r += $Expression.Finally }
        if ($Expression.Fault)   { $r += $Expression.Fault }
        foreach ($h in $Expression.Handlers) {
            if ($h.Filter) { $r += $h.Filter }
            if ($h.Body)   { $r += $h.Body }
        }
        return $r
    }

    if ($Expression -is [Linq.Expressions.MethodCallExpression]) {
        $r = @()
        if ($Expression.Object) { $r += $Expression.Object }
        $r += @($Expression.Arguments)
        return $r
    }

    if ($Expression -is [Linq.Expressions.InvocationExpression]) {
        return @($Expression.Expression) + @($Expression.Arguments)
    }

    if ($Expression -is [Linq.Expressions.DynamicExpression]) {
        return @($Expression.Arguments)
    }

    if ($Expression -is [Linq.Expressions.UnaryExpression]) {
        return @($Expression.Operand)
    }

    if ($Expression -is [Linq.Expressions.BinaryExpression]) {
        $r = @($Expression.Left, $Expression.Right)
        if ($Expression.Conversion) { $r += $Expression.Conversion }
        return $r
    }

    if ($Expression -is [Linq.Expressions.ConditionalExpression]) {
        return @($Expression.Test, $Expression.IfTrue, $Expression.IfFalse)
    }

    if ($Expression -is [Linq.Expressions.MemberExpression]) {
        if ($Expression.Expression) { return @($Expression.Expression) }
        return @()
    }

    if ($Expression -is [Linq.Expressions.GotoExpression]) {
        if ($Expression.Value) { return @($Expression.Value) }
        return @()
    }

    if ($Expression -is [Linq.Expressions.LabelExpression]) {
        if ($Expression.DefaultValue) { return @($Expression.DefaultValue) }
        return @()
    }

    if ($Expression -is [Linq.Expressions.NewExpression]) {
        return @($Expression.Arguments)
    }

    if ($Expression -is [Linq.Expressions.NewArrayExpression]) {
        return @($Expression.Expressions)
    }

    if ($Expression -is [Linq.Expressions.IndexExpression]) {
        $r = @()
        if ($Expression.Object) { $r += $Expression.Object }
        $r += @($Expression.Arguments)
        return $r
    }

    if ($Expression -is [Linq.Expressions.TypeBinaryExpression]) {
        return @($Expression.Expression)
    }

    if ($Expression.NodeType -eq [Linq.Expressions.ExpressionType]::Extension -and $Expression.CanReduce) {
        return @($Expression.Reduce())
    }

    @()
}

function Find-ReturnPipeAdd {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.Expression]$Expression
    )

    if (
        $Expression -is [Linq.Expressions.MethodCallExpression] -and
        $Expression.Method.Name -eq 'Add' -and
        $Expression.Object -and
        $Expression.Object.Type.FullName -eq 'System.Management.Automation.Internal.Pipe' -and
        $Expression.Arguments.Count -eq 1
    ) {
        return $Expression
    }

    foreach ($child in (Get-ExpressionChildren $Expression)) {
        $hit = Find-ReturnPipeAdd $child
        if ($hit) { return $hit }
    }

    $null
}

function Rewrite-ExpressionLeaf {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.Expression]$Expression,

        [Parameter(Mandatory)]
        [string]$TupleMemberName,

        [Parameter(Mandatory)]
        [Linq.Expressions.Expression]$Replacement,

        [Parameter(Mandatory)]
        [ref]$ReplacementCount
    )

    # SMA represents the automatic $this variable as a tuple-presence test with
    # an ExecutionContext fallback. A persisted CLR instance method always has
    # an authoritative arg0, so replace the complete shell expression.
    if ($TupleMemberName -eq 'Item002' -and
        $Expression -is [Linq.Expressions.ConditionalExpression] -and
        $Expression.Test -is [Linq.Expressions.MethodCallExpression] -and
        $Expression.Test.Method.Name -eq 'IsValueSet' -and
        $Expression.Test.Object -is [Linq.Expressions.ParameterExpression] -and
        $Expression.Test.Object.Name -eq 'locals' -and
        $Expression.Test.Arguments.Count -eq 1 -and
        $Expression.Test.Arguments[0] -is [Linq.Expressions.ConstantExpression] -and
        [int]$Expression.Test.Arguments[0].Value -eq 2) {
        $ReplacementCount.Value++
        return $Replacement
    }

    if ($Expression -is [Linq.Expressions.MemberExpression]) {
        if (
            $Expression.Member.Name -eq $TupleMemberName -and
            $Expression.Expression -is [Linq.Expressions.ParameterExpression] -and
            $Expression.Expression.Name -eq 'locals'
        ) {
            $ReplacementCount.Value++
            return $Replacement
        }

        if (-not $Expression.Expression) { return $Expression }

        $obj = Rewrite-ExpressionLeaf `
            -Expression $Expression.Expression `
            -TupleMemberName $TupleMemberName `
            -Replacement $Replacement `
            -ReplacementCount $ReplacementCount

        return $Expression.Update($obj)
    }

    if ($Expression -is [Linq.Expressions.UnaryExpression]) {
        $op = Rewrite-ExpressionLeaf $Expression.Operand $TupleMemberName $Replacement $ReplacementCount
        return $Expression.Update($op)
    }

    if ($Expression -is [Linq.Expressions.InvocationExpression]) {
        $target = Rewrite-ExpressionLeaf $Expression.Expression $TupleMemberName $Replacement $ReplacementCount
        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Rewrite-ExpressionLeaf $_ $TupleMemberName $Replacement $ReplacementCount
            }
        )
        return $Expression.Update($target, $args)
    }

    if ($Expression -is [Linq.Expressions.DynamicExpression]) {
        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Rewrite-ExpressionLeaf $_ $TupleMemberName $Replacement $ReplacementCount
            }
        )
        return $Expression.Update($args)
    }

    if ($Expression -is [Linq.Expressions.MethodCallExpression]) {
        $obj = if ($Expression.Object) {
            Rewrite-ExpressionLeaf $Expression.Object $TupleMemberName $Replacement $ReplacementCount
        }
        else {
            $null
        }

        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Rewrite-ExpressionLeaf $_ $TupleMemberName $Replacement $ReplacementCount
            }
        )

        return $Expression.Update($obj, $args)
    }

    if ($Expression -is [Linq.Expressions.BinaryExpression]) {
        $left  = Rewrite-ExpressionLeaf $Expression.Left  $TupleMemberName $Replacement $ReplacementCount
        $right = Rewrite-ExpressionLeaf $Expression.Right $TupleMemberName $Replacement $ReplacementCount

        $conversion = if ($Expression.Conversion) {
            [Linq.Expressions.LambdaExpression](
                Rewrite-ExpressionLeaf $Expression.Conversion $TupleMemberName $Replacement $ReplacementCount
            )
        }
        else {
            $null
        }

        return $Expression.Update($left, $conversion, $right)
    }

    if ($Expression -is [Linq.Expressions.ConditionalExpression]) {
        $test = Rewrite-ExpressionLeaf $Expression.Test $TupleMemberName $Replacement $ReplacementCount
        $yes  = Rewrite-ExpressionLeaf $Expression.IfTrue $TupleMemberName $Replacement $ReplacementCount
        $no   = Rewrite-ExpressionLeaf $Expression.IfFalse $TupleMemberName $Replacement $ReplacementCount
        return $Expression.Update($test, $yes, $no)
    }

    if ($Expression -is [Linq.Expressions.NewExpression]) {
        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Rewrite-ExpressionLeaf $_ $TupleMemberName $Replacement $ReplacementCount
            }
        )
        return $Expression.Update($args)
    }

    if ($Expression -is [Linq.Expressions.NewArrayExpression]) {
        $items = [Linq.Expressions.Expression[]]@(
            $Expression.Expressions | ForEach-Object {
                Rewrite-ExpressionLeaf $_ $TupleMemberName $Replacement $ReplacementCount
            }
        )
        return $Expression.Update($items)
    }

    if ($Expression -is [Linq.Expressions.IndexExpression]) {
        $obj = if ($Expression.Object) {
            Rewrite-ExpressionLeaf $Expression.Object $TupleMemberName $Replacement $ReplacementCount
        }
        else {
            $null
        }

        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Rewrite-ExpressionLeaf $_ $TupleMemberName $Replacement $ReplacementCount
            }
        )

        return $Expression.Update($obj, $args)
    }

    if ($Expression -is [Linq.Expressions.TypeBinaryExpression]) {
        $obj = Rewrite-ExpressionLeaf $Expression.Expression $TupleMemberName $Replacement $ReplacementCount
        return $Expression.Update($obj)
    }

    if ($Expression.NodeType -eq [Linq.Expressions.ExpressionType]::Extension -and $Expression.CanReduce) {
        $reduced = $Expression.Reduce()
        return Rewrite-ExpressionLeaf $reduced $TupleMemberName $Replacement $ReplacementCount
    }

    return $Expression
}


function Get-ExpressionDynamicCount {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.Expression]$Expression
    )

    $count = 0

    if ($Expression -is [Linq.Expressions.DynamicExpression]) {
        $count++
    }

    foreach ($child in (Get-ExpressionChildren $Expression)) {
        $count += Get-ExpressionDynamicCount $child
    }

    return $count
}

function Get-StaticFactoryMethod {
    param(
        [Parameter(Mandatory)]
        [type]$Type,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [type[]]$ParameterTypes
    )

    $m = $Type.GetMethod(
        $Name,
        [Reflection.BindingFlags]'Static,Public,NonPublic',
        $null,
        $ParameterTypes,
        $null
    )

    if (-not $m) {
        throw "Factory $($Type.FullName).$Name($($ParameterTypes.Name -join ',')) not found."
    }

    return $m
}

function Get-SmaBinderRecipe {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.DynamicExpression]$Dynamic
    )

    $binder = $Dynamic.Binder
    $binderType = $binder.GetType()
    $name = $binderType.FullName

    switch ($name) {
        'System.Management.Automation.Language.PSBinaryOperationBinder' {
            $factory = Get-StaticFactoryMethod `
                -Type $binderType `
                -Name 'Get' `
                -ParameterTypes ([type[]]@(
                    [Linq.Expressions.ExpressionType],
                    [bool],
                    [bool]
                ))

            foreach ($op in [Enum]::GetValues([Linq.Expressions.ExpressionType])) {
                foreach ($ignoreCase in @($false, $true)) {
                    foreach ($scalarCompare in @($false, $true)) {
                        try {
                            $candidate = $factory.Invoke(
                                $null,
                                [object[]]@(
                                    $op,
                                    $ignoreCase,
                                    $scalarCompare
                                )
                            )

                            if ([object]::ReferenceEquals($candidate, $binder)) {
                                return [pscustomobject]@{
                                    Kind                = 'PSBinaryOperationBinder'
                                    BinderTypeName      = "$($binderType.FullName), System.Management.Automation"
                                    FactoryName         = 'Get'
                                    ParameterTypeNames  = [string[]]@(
                                        [Linq.Expressions.ExpressionType].AssemblyQualifiedName,
                                        [bool].AssemblyQualifiedName,
                                        [bool].AssemblyQualifiedName
                                    )
                                    ArgumentKinds       = [string[]]@(
                                        'ExpressionType',
                                        'Boolean',
                                        'Boolean'
                                    )
                                    ArgumentValues      = [object[]]@(
                                        [int]$op,
                                        [bool]$ignoreCase,
                                        [bool]$scalarCompare
                                    )
                                }
                            }
                        }
                        catch {
                            # Some ExpressionType values are not meaningful to this binder.
                        }
                    }
                }
            }

            throw 'Could not recover PSBinaryOperationBinder factory recipe by cache identity.'
        }

        'System.Management.Automation.Language.PSConvertBinder' {
            $factory = Get-StaticFactoryMethod `
                -Type $binderType `
                -Name 'Get' `
                -ParameterTypes ([type[]]@([type]))

            $targetType = $Dynamic.Type
            $candidate = $factory.Invoke(
                $null,
                [object[]]@($targetType)
            )

            if (-not [object]::ReferenceEquals($candidate, $binder)) {
                throw "PSConvertBinder.Get($($targetType.FullName)) did not reproduce binder identity."
            }

            return [pscustomobject]@{
                Kind                = 'PSConvertBinder'
                BinderTypeName      = "$($binderType.FullName), System.Management.Automation"
                FactoryName         = 'Get'
                ParameterTypeNames  = [string[]]@(
                    [type].AssemblyQualifiedName
                )
                ArgumentKinds       = [string[]]@(
                    'Type'
                )
                ArgumentValues      = [object[]]@(
                    $targetType.AssemblyQualifiedName
                )
            }
        }

        'System.Management.Automation.Language.PSGetMemberBinder' {
            $nameProperty = $binderType.GetProperty('Name', $script:BFInst)
            $classScopeField = $binderType.GetField('_classScope', $script:BFInst)
            if (-not $nameProperty -or -not $classScopeField) {
                throw 'PSGetMemberBinder recipe metadata is unavailable.'
            }
            $memberName = [string]$nameProperty.GetValue($binder)
            $classScope = [type]$classScopeField.GetValue($binder)
            if (-not $classScope) { throw 'PSGetMemberBinder has no class scope.' }
            $factory = Get-StaticFactoryMethod -Type $binderType -Name 'Get' `
                -ParameterTypes ([type[]]@([string], [type], [bool], [bool]))
            foreach ($isStatic in @($false, $true)) {
                foreach ($nonEnumerating in @($false, $true)) {
                    $candidate = $factory.Invoke($null, [object[]]@(
                        $memberName, $classScope, $isStatic, $nonEnumerating))
                    if ([object]::ReferenceEquals($candidate, $binder)) {
                        $classScopeName = $classScope.AssemblyQualifiedName
                        if ([string]::IsNullOrWhiteSpace($classScopeName)) {
                            $classScopeName = "$($classScope.FullName), $($classScope.Assembly.GetName().Name)"
                        }
                        return [pscustomobject]@{
                            Kind = 'PSGetMemberBinder'
                            BinderTypeName = "$($binderType.FullName), System.Management.Automation"
                            FactoryName = 'Get'
                            ParameterTypeNames = [string[]]@(
                                [string].AssemblyQualifiedName,
                                [type].AssemblyQualifiedName,
                                [bool].AssemblyQualifiedName,
                                [bool].AssemblyQualifiedName)
                            ArgumentKinds = [string[]]@('String', 'Type', 'Boolean', 'Boolean')
                            ArgumentValues = [object[]]@(
                                $memberName,
                                $classScopeName,
                                [bool]$isStatic,
                                [bool]$nonEnumerating)
                        }
                    }
                }
            }
            throw 'Could not recover PSGetMemberBinder factory recipe by cache identity.'
        }

        'System.Management.Automation.Language.PSInvokeMemberBinder' {
            $callInfo = $binder.CallInfo
            $classScope = [type]$binderType.GetField('_classScope', $script:BFInst).GetValue($binder)
            $isStatic = [bool]$binderType.GetField('_static', $script:BFInst).GetValue($binder)
            $propertySetter = [bool]$binderType.GetField('_propertySetter', $script:BFInst).GetValue($binder)
            $nonEnumerating = [bool]$binderType.GetField('_nonEnumerating', $script:BFInst).GetValue($binder)
            $constraints = $binderType.GetField('_invocationConstraints', $script:BFInst).GetValue($binder)
            if (-not $classScope -or -not $constraints) {
                throw 'PSInvokeMemberBinder class scope or invocation constraints are unavailable.'
            }
            $classScopeName = $classScope.AssemblyQualifiedName
            if ([string]::IsNullOrWhiteSpace($classScopeName)) {
                $classScopeName = "$($classScope.FullName), $($classScope.Assembly.GetName().Name)"
            }
            $constraintParameterNames = [Collections.Generic.List[object]]::new()
            foreach ($constraintParameter in $constraints.ParameterTypes) {
                if ($constraintParameter) {
                    $constraintParameterNames.Add($constraintParameter.AssemblyQualifiedName)
                } else {
                    $constraintParameterNames.Add($null)
                }
            }
            $factory = Get-StaticFactoryMethod -Type $binderType -Name 'Get' `
                -ParameterTypes ([type[]]@(
                    [string], [type], [System.Dynamic.CallInfo], [bool], [bool], [bool],
                    $constraints.GetType()))
            $candidate = $factory.Invoke($null, [object[]]@(
                $binder.Name, $classScope, $callInfo, $isStatic, $propertySetter,
                $nonEnumerating, $constraints))
            if (-not [object]::ReferenceEquals($candidate, $binder)) {
                throw 'PSInvokeMemberBinder.Get(...) did not reproduce binder identity.'
            }
            return [pscustomobject]@{
                Kind = 'PSInvokeMemberBinder'
                BinderTypeName = "$($binderType.FullName), System.Management.Automation"
                FactoryName = 'Get'
                ParameterTypeNames = [string[]]@(
                    [string].AssemblyQualifiedName,
                    [type].AssemblyQualifiedName,
                    [System.Dynamic.CallInfo].AssemblyQualifiedName,
                    [bool].AssemblyQualifiedName,
                    [bool].AssemblyQualifiedName,
                    [bool].AssemblyQualifiedName,
                    "$($constraints.GetType().FullName), System.Management.Automation")
                ArgumentKinds = [string[]]@(
                    'String', 'Type', 'CallInfo', 'Boolean', 'Boolean', 'Boolean',
                    'InvocationConstraints')
                ArgumentValues = [object[]]@(
                    [string]$binder.Name,
                    $classScopeName,
                    [pscustomobject]@{
                        ArgumentCount = [int]$callInfo.ArgumentCount
                        ArgumentNames = [string[]]@($callInfo.ArgumentNames)
                    },
                    $isStatic,
                    $propertySetter,
                    $nonEnumerating,
                    [pscustomobject]@{
                        TypeName = "$($constraints.GetType().FullName), System.Management.Automation"
                        TargetTypeName = $constraints.MethodTargetType.AssemblyQualifiedName
                        ParameterTypeNames = [object[]]$constraintParameterNames.ToArray()
                    })
            }
        }

        default {
            throw "No persistence recipe yet for SMA binder '$name'."
        }
    }
}

function New-RuntimeTypeFromNameExpression {
    param(
        [Parameter(Mandatory)]
        [string]$AssemblyQualifiedName
    )

    $getType = [type].GetMethod(
        'GetType',
        [Reflection.BindingFlags]'Static,Public',
        $null,
        [type[]]@([string], [bool]),
        $null
    )

    [Linq.Expressions.Expression]::Call(
        $getType,
        [Linq.Expressions.Expression]::Constant($AssemblyQualifiedName),
        [Linq.Expressions.Expression]::Constant($true)
    )
}

function New-ReflectedFactoryInvokeExpression {
    param(
        [Parameter(Mandatory)]
        [psobject]$Recipe
    )

    $binderTypeExpr = New-RuntimeTypeFromNameExpression `
        $Recipe.BinderTypeName

    $parameterTypeExprs = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()

    foreach ($typeName in $Recipe.ParameterTypeNames) {
        $parameterTypeExprs.Add(
            (New-RuntimeTypeFromNameExpression $typeName)
        )
    }

    $parameterTypesArray = [Linq.Expressions.Expression]::NewArrayInit(
        [type],
        [Linq.Expressions.Expression[]]$parameterTypeExprs.ToArray()
    )

    $getMethod = [type].GetMethod(
        'GetMethod',
        [Reflection.BindingFlags]'Instance,Public',
        $null,
        [type[]]@(
            [string],
            [Reflection.BindingFlags],
            [Reflection.Binder],
            [type[]],
            [Reflection.ParameterModifier[]]
        ),
        $null
    )

    $factoryExpr = [Linq.Expressions.Expression]::Call(
        $binderTypeExpr,
        $getMethod,
        [Linq.Expressions.Expression]::Constant($Recipe.FactoryName),
        [Linq.Expressions.Expression]::Constant(
            [Reflection.BindingFlags]'Static,Public,NonPublic'
        ),
        [Linq.Expressions.Expression]::Constant(
            $null,
            [Reflection.Binder]
        ),
        $parameterTypesArray,
        [Linq.Expressions.Expression]::Constant(
            $null,
            [Reflection.ParameterModifier[]]
        )
    )

    $argumentExprs = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()

    for ($i = 0; $i -lt $Recipe.ArgumentKinds.Count; $i++) {
        $kind = $Recipe.ArgumentKinds[$i]
        $value = $Recipe.ArgumentValues[$i]

        switch ($kind) {
            'String' {
                $argumentExprs.Add(
                    [Linq.Expressions.Expression]::Convert(
                        [Linq.Expressions.Expression]::Constant([string]$value),
                        [object]
                    )
                )
            }

            'CallInfo' {
                $nameExpressions = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
                foreach ($argumentName in $value.ArgumentNames) {
                    $nameExpressions.Add([Linq.Expressions.Expression]::Constant([string]$argumentName))
                }
                $namesArray = [Linq.Expressions.Expression]::NewArrayInit(
                    [string], [Linq.Expressions.Expression[]]$nameExpressions.ToArray())
                $callInfoConstructor = [System.Dynamic.CallInfo].GetConstructor(
                    [type[]]@([int], [string[]]))
                $newFactory = [Linq.Expressions.Expression].GetMethod(
                    'New', [type[]]@(
                        [Reflection.ConstructorInfo], [Linq.Expressions.Expression[]]))
                $callInfoExpression = $newFactory.Invoke($null, [object[]]@(
                    $callInfoConstructor,
                    [Linq.Expressions.Expression[]]@(
                        [Linq.Expressions.Expression]::Constant([int]$value.ArgumentCount),
                        $namesArray)))
                $argumentExprs.Add([Linq.Expressions.Expression]::Convert($callInfoExpression, [object]))
            }

            'InvocationConstraints' {
                $constraintsTypeExpression = New-RuntimeTypeFromNameExpression $value.TypeName
                $constructorParameterTypes = [Linq.Expressions.Expression]::NewArrayInit(
                    [type],
                    [Linq.Expressions.Expression[]]@(
                        (New-RuntimeTypeFromNameExpression 'System.Type, System.Private.CoreLib'),
                        (New-RuntimeTypeFromNameExpression 'System.Type[], System.Private.CoreLib')))
                $getConstructor = [type].GetMethod(
                    'GetConstructor',
                    [Reflection.BindingFlags]'Instance,Public',
                    $null,
                    [type[]]@(
                        [Reflection.BindingFlags], [Reflection.Binder], [type[]],
                        [Reflection.ParameterModifier[]]),
                    $null)
                $constructorExpression = [Linq.Expressions.Expression]::Call(
                    $constraintsTypeExpression,
                    $getConstructor,
                    [Linq.Expressions.Expression]::Constant(
                        [Reflection.BindingFlags]'Instance,Public,NonPublic'),
                    [Linq.Expressions.Expression]::Constant($null, [Reflection.Binder]),
                    $constructorParameterTypes,
                    [Linq.Expressions.Expression]::Constant($null, [Reflection.ParameterModifier[]]))
                $constraintParameterExpressions = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
                foreach ($constraintParameterName in $value.ParameterTypeNames) {
                    if ($null -eq $constraintParameterName) {
                        $constraintParameterExpressions.Add(
                            [Linq.Expressions.Expression]::Constant($null, [type]))
                    } else {
                        $constraintParameterExpressions.Add(
                            (New-RuntimeTypeFromNameExpression $constraintParameterName))
                    }
                }
                $constraintParametersArray = [Linq.Expressions.Expression]::NewArrayInit(
                    [type], [Linq.Expressions.Expression[]]$constraintParameterExpressions.ToArray())
                $constructorArguments = [Linq.Expressions.Expression]::NewArrayInit(
                    [object],
                    [Linq.Expressions.Expression[]]@(
                        [Linq.Expressions.Expression]::Convert(
                            (New-RuntimeTypeFromNameExpression $value.TargetTypeName), [object]),
                        [Linq.Expressions.Expression]::Convert($constraintParametersArray, [object])))
                $invokeConstructor = [Reflection.ConstructorInfo].GetMethod(
                    'Invoke', [type[]]@([object[]]))
                $argumentExprs.Add([Linq.Expressions.Expression]::Call(
                    $constructorExpression, $invokeConstructor, $constructorArguments))
            }

            'ExpressionType' {
                $arg = [Linq.Expressions.Expression]::Convert(
                    [Linq.Expressions.Expression]::Constant([int]$value),
                    [Linq.Expressions.ExpressionType]
                )
                $argumentExprs.Add(
                    [Linq.Expressions.Expression]::Convert($arg, [object])
                )
            }

            'Boolean' {
                $argumentExprs.Add(
                    [Linq.Expressions.Expression]::Convert(
                        [Linq.Expressions.Expression]::Constant([bool]$value),
                        [object]
                    )
                )
            }

            'Type' {
                $typeExpr = New-RuntimeTypeFromNameExpression ([string]$value)
                $argumentExprs.Add(
                    [Linq.Expressions.Expression]::Convert(
                        $typeExpr,
                        [object]
                    )
                )
            }

            default {
                throw "Unsupported persisted binder argument kind '$kind'."
            }
        }
    }

    $argsArray = [Linq.Expressions.Expression]::NewArrayInit(
        [object],
        [Linq.Expressions.Expression[]]$argumentExprs.ToArray()
    )

    $invoke = [Reflection.MethodBase].GetMethod(
        'Invoke',
        [Reflection.BindingFlags]'Instance,Public',
        $null,
        [type[]]@([object], [object[]]),
        $null
    )

    $binderObject = [Linq.Expressions.Expression]::Call(
        $factoryExpr,
        $invoke,
        [Linq.Expressions.Expression]::Constant($null, [object]),
        $argsArray
    )

    return [Linq.Expressions.Expression]::Convert(
        $binderObject,
        [Runtime.CompilerServices.CallSiteBinder]
    )
}

function Convert-DynamicToPersistedCallSites {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.Expression]$Expression,

        [Parameter(Mandatory)]
        [Reflection.Emit.TypeBuilder]$TypeBuilder,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Sites
    )

    if ($Expression -is [Linq.Expressions.DynamicExpression]) {
        $rewrittenArgs = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Convert-DynamicToPersistedCallSites `
                    -Expression $_ `
                    -TypeBuilder $TypeBuilder `
                    -Sites $Sites
            }
        )

        $recipe = Get-SmaBinderRecipe $Expression

        $delegateType = $Expression.DelegateType

        $callSiteType = [Runtime.CompilerServices.CallSite``1].MakeGenericType(
            [type[]]@($delegateType)
        )

        $index = $Sites.Count
        $field = $TypeBuilder.DefineField(
            "__psSite$index",
            $callSiteType,
            [Reflection.FieldAttributes]'Private,Static'
        )

        $fieldExpr = [Linq.Expressions.Expression]::Field(
            $null,
            $field
        )

        $targetField = $callSiteType.GetField(
            'Target',
            [Reflection.BindingFlags]'Instance,Public'
        )

        if (-not $targetField) {
            throw "Target field not found on $($callSiteType.FullName)."
        }

        $targetExpr = [Linq.Expressions.Expression]::Field(
            $fieldExpr,
            $targetField
        )

        $invokeArgs = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        $invokeArgs.Add($fieldExpr)

        foreach ($arg in $rewrittenArgs) {
            $invokeArgs.Add($arg)
        }

        $replacement = [Linq.Expressions.Expression]::Invoke(
            $targetExpr,
            [Linq.Expressions.Expression[]]$invokeArgs.ToArray()
        )

        if ($replacement.Type -ne $Expression.Type) {
            throw "CallSite replacement type '$($replacement.Type)' != dynamic type '$($Expression.Type)'."
        }

        $Sites.Add(
            [pscustomobject]@{
                Index        = $index
                Field        = $field
                CallSiteType = $callSiteType
                DelegateType = $delegateType
                Recipe       = $recipe
            }
        )

        Write-Host "CALLSITE_$index=$($recipe.Kind)"
        Write-Host "CALLSITE_${index}_DELEGATE=$($delegateType.FullName)"

        return $replacement
    }

    if ($Expression -is [Linq.Expressions.MemberExpression]) {
        if (-not $Expression.Expression) { return $Expression }

        $obj = Convert-DynamicToPersistedCallSites `
            $Expression.Expression $TypeBuilder $Sites

        return $Expression.Update($obj)
    }

    if ($Expression -is [Linq.Expressions.UnaryExpression]) {
        $op = Convert-DynamicToPersistedCallSites `
            $Expression.Operand $TypeBuilder $Sites

        return $Expression.Update($op)
    }

    if ($Expression -is [Linq.Expressions.InvocationExpression]) {
        $target = Convert-DynamicToPersistedCallSites `
            $Expression.Expression $TypeBuilder $Sites

        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Convert-DynamicToPersistedCallSites $_ $TypeBuilder $Sites
            }
        )

        return $Expression.Update($target, $args)
    }

    if ($Expression -is [Linq.Expressions.MethodCallExpression]) {
        $obj = if ($Expression.Object) {
            Convert-DynamicToPersistedCallSites `
                $Expression.Object $TypeBuilder $Sites
        }
        else {
            $null
        }

        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Convert-DynamicToPersistedCallSites $_ $TypeBuilder $Sites
            }
        )

        return $Expression.Update($obj, $args)
    }

    if ($Expression -is [Linq.Expressions.BinaryExpression]) {
        $left = Convert-DynamicToPersistedCallSites `
            $Expression.Left $TypeBuilder $Sites

        $right = Convert-DynamicToPersistedCallSites `
            $Expression.Right $TypeBuilder $Sites

        $conversion = if ($Expression.Conversion) {
            [Linq.Expressions.LambdaExpression](
                Convert-DynamicToPersistedCallSites `
                    $Expression.Conversion $TypeBuilder $Sites
            )
        }
        else {
            $null
        }

        return $Expression.Update($left, $conversion, $right)
    }

    if ($Expression -is [Linq.Expressions.ConditionalExpression]) {
        $test = Convert-DynamicToPersistedCallSites `
            $Expression.Test $TypeBuilder $Sites
        $yes = Convert-DynamicToPersistedCallSites `
            $Expression.IfTrue $TypeBuilder $Sites
        $no = Convert-DynamicToPersistedCallSites `
            $Expression.IfFalse $TypeBuilder $Sites

        return $Expression.Update($test, $yes, $no)
    }

    if ($Expression -is [Linq.Expressions.BlockExpression]) {
        $exprs = [Linq.Expressions.Expression[]]@(
            $Expression.Expressions | ForEach-Object {
                Convert-DynamicToPersistedCallSites $_ $TypeBuilder $Sites
            }
        )

        return $Expression.Update(
            $Expression.Variables,
            $exprs
        )
    }

    if ($Expression -is [Linq.Expressions.TryExpression]) {
        $body = Convert-DynamicToPersistedCallSites `
            $Expression.Body $TypeBuilder $Sites

        $finally = if ($Expression.Finally) {
            Convert-DynamicToPersistedCallSites `
                $Expression.Finally $TypeBuilder $Sites
        } else { $null }

        $fault = if ($Expression.Fault) {
            Convert-DynamicToPersistedCallSites `
                $Expression.Fault $TypeBuilder $Sites
        } else { $null }

        $handlers = [System.Collections.Generic.List[Linq.Expressions.CatchBlock]]::new()

        foreach ($h in $Expression.Handlers) {
            $filter = if ($h.Filter) {
                Convert-DynamicToPersistedCallSites `
                    $h.Filter $TypeBuilder $Sites
            } else { $null }

            $hbody = Convert-DynamicToPersistedCallSites `
                $h.Body $TypeBuilder $Sites

            $handlers.Add(
                [Linq.Expressions.Expression]::MakeCatchBlock(
                    $h.Test,
                    $h.Variable,
                    $hbody,
                    $filter
                )
            )
        }

        return [Linq.Expressions.Expression]::MakeTry(
            $Expression.Type,
            $body,
            $finally,
            $fault,
            $handlers
        )
    }

    if ($Expression -is [Linq.Expressions.GotoExpression]) {
        $value = if ($Expression.Value) {
            Convert-DynamicToPersistedCallSites `
                $Expression.Value $TypeBuilder $Sites
        } else { $null }

        return [Linq.Expressions.Expression]::MakeGoto(
            $Expression.Kind,
            $Expression.Target,
            $value,
            $Expression.Type
        )
    }

    if ($Expression -is [Linq.Expressions.LabelExpression]) {
        $default = if ($Expression.DefaultValue) {
            Convert-DynamicToPersistedCallSites `
                $Expression.DefaultValue $TypeBuilder $Sites
        } else { $null }

        return [Linq.Expressions.Expression]::Label(
            $Expression.Target,
            $default
        )
    }

    if ($Expression -is [Linq.Expressions.NewExpression]) {
        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Convert-DynamicToPersistedCallSites $_ $TypeBuilder $Sites
            }
        )

        return $Expression.Update($args)
    }

    if ($Expression -is [Linq.Expressions.NewArrayExpression]) {
        $items = [Linq.Expressions.Expression[]]@(
            $Expression.Expressions | ForEach-Object {
                Convert-DynamicToPersistedCallSites $_ $TypeBuilder $Sites
            }
        )

        return $Expression.Update($items)
    }

    if ($Expression -is [Linq.Expressions.IndexExpression]) {
        $obj = if ($Expression.Object) {
            Convert-DynamicToPersistedCallSites `
                $Expression.Object $TypeBuilder $Sites
        } else { $null }

        $args = [Linq.Expressions.Expression[]]@(
            $Expression.Arguments | ForEach-Object {
                Convert-DynamicToPersistedCallSites $_ $TypeBuilder $Sites
            }
        )

        return $Expression.Update($obj, $args)
    }

    if ($Expression -is [Linq.Expressions.TypeBinaryExpression]) {
        $obj = Convert-DynamicToPersistedCallSites `
            $Expression.Expression $TypeBuilder $Sites

        return $Expression.Update($obj)
    }

    if (
        $Expression.NodeType -eq [Linq.Expressions.ExpressionType]::Extension -and
        $Expression.CanReduce
    ) {
        return Convert-DynamicToPersistedCallSites `
            $Expression.Reduce() $TypeBuilder $Sites
    }

    return $Expression
}

function New-CallSiteInitializerExpression {
    param(
        [Parameter(Mandatory)]
        [psobject]$Site
    )

    $binderExpr = New-ReflectedFactoryInvokeExpression $Site.Recipe

    $create = $Site.CallSiteType.GetMethod(
        'Create',
        [Reflection.BindingFlags]'Static,Public',
        $null,
        [type[]]@([Runtime.CompilerServices.CallSiteBinder]),
        $null
    )

    if (-not $create) {
        throw "CallSite.Create(CallSiteBinder) missing on $($Site.CallSiteType.FullName)."
    }

    $siteExpr = [Linq.Expressions.Expression]::Call(
        $create,
        $binderExpr
    )

    return [Linq.Expressions.Expression]::Assign(
        [Linq.Expressions.Expression]::Field(
            $null,
            $Site.Field
        ),
        $siteExpr
    )
}

function Define-CallSiteTypeInitializer {
    param(
        [Parameter(Mandatory)]
        [Reflection.Emit.TypeBuilder]$TypeBuilder,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Sites,

        [Linq.Expressions.Expression[]]$PrefixExpressions = @(),

        [switch]$Deferred
    )

    if ($Sites.Count -eq 0) {
        return $null
    }

    # LambdaCompiler retargeting is proven against MethodBuilder, not ConstructorBuilder.
    # Keep the real .cctor deliberately tiny and put the expression-generated
    # rehydration body in a private static helper method.
    $helper = $TypeBuilder.DefineMethod(
        '__InitializePowerShellCallSites',
        [Reflection.MethodAttributes]'Private,Static,HideBySig',
        [void],
        [type[]]@()
    )

    $initializers = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()

    foreach ($prefixExpression in $PrefixExpressions) {
        $initializers.Add($prefixExpression)
    }

    foreach ($site in $Sites) {
        $initializers.Add(
            (New-CallSiteInitializerExpression $site)
        )
    }

    $initializers.Add(
        [Linq.Expressions.Expression]::Empty()
    )

    $body = [Linq.Expressions.Expression]::Block(
        [Linq.Expressions.Expression[]]$initializers.ToArray()
    )

    $lambda = [Linq.Expressions.Expression]::Lambda(
        [Action],
        $body,
        '__InitializePowerShellCallSites',
        $false,
        [Linq.Expressions.ParameterExpression[]]@()
    )

    $null = Write-MicrosoftLambdaToMethodBuilder `
        -Lambda $lambda `
        -MethodBuilder $helper

    Write-Host 'CALLSITE_INIT_HELPER=True'

    if ($Deferred) {
        return $helper
    }

    $cctor = $TypeBuilder.DefineTypeInitializer()
    $ilg = $cctor.GetILGenerator()
    $ilg.Emit([Reflection.Emit.OpCodes]::Call, $helper)
    $ilg.Emit([Reflection.Emit.OpCodes]::Ret)

    return $cctor
}

function Write-MicrosoftLambdaToMethodBuilder {
    param(
        [Parameter(Mandatory)]
        [Linq.Expressions.LambdaExpression]$Lambda,

        [Parameter(Mandatory)]
        [Reflection.Emit.MethodBuilder]$MethodBuilder,

        [switch]$ExplicitThis
    )

    $exprAsm = [Linq.Expressions.Expression].Assembly
    $lcType = $exprAsm.GetType('System.Linq.Expressions.Compiler.LambdaCompiler', $true)

    $analyze = $lcType.GetMethods($script:BFStatic) |
        Where-Object {
            $_.Name -eq 'AnalyzeLambda' -and $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    [object[]]$analyzeArgs = @($Lambda)
    $tree = $analyze.Invoke($null, $analyzeArgs)
    $lowered = [Linq.Expressions.LambdaExpression]$analyzeArgs[0]

    $ctor = $lcType.GetConstructors($script:BFInst) |
        Where-Object {
            $p = $_.GetParameters()
            $p.Count -eq 2 -and
            $p[1].ParameterType -eq [Linq.Expressions.LambdaExpression]
        } |
        Select-Object -First 1

    $lc = $ctor.Invoke([object[]]@($tree, $lowered))

    $fMethod = $lcType.GetField('_method', $script:BFInst)
    $fIL     = $lcType.GetField('_ilg', $script:BFInst)
    $fClos   = $lcType.GetField('_hasClosureArgument', $script:BFInst)
    $fTB     = $lcType.GetField('_typeBuilder', $script:BFInst)

    $methodIdentity = $MethodBuilder
    if ($ExplicitThis) {
        # LambdaCompiler normally reserves arg0 for an instance method and maps
        # lambda parameters from arg1. The semantic-core lambda explicitly
        # contains CLR self. Give LambdaCompiler a static signature descriptor
        # while retaining the real instance MethodBuilder's ILGenerator.
        $methodIdentity = [Reflection.Emit.DynamicMethod]::new(
            "__PersistedSignature_$($MethodBuilder.Name)",
            $Lambda.ReturnType,
            [type[]]@($Lambda.Parameters | ForEach-Object Type),
            $true)
    }
    $fMethod.SetValue($lc, $methodIdentity)
    $fIL.SetValue($lc, $MethodBuilder.GetILGenerator())
    $fClos.SetValue($lc, $false)

    if ($fTB) {
        $fTB.SetValue($lc, $MethodBuilder.DeclaringType)
    }

    $emit = $lcType.GetMethods($script:BFInst) |
        Where-Object {
            $_.Name -eq 'EmitLambdaBody' -and $_.GetParameters().Count -eq 0
        } |
        Select-Object -First 1

    $null = $emit.Invoke($lc, @())

    [pscustomobject]@{
        LambdaCompiler = $lc
        LoweredLambda  = $lowered
        AnalyzedTree   = $tree
        TypeBuilderSet = [bool]$fTB
    }
}

function Export-PersistedClass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$MethodName,

        [switch]$Optimize
    )

    $parsed = Get-ClassAst $Source
    $typeAst = $parsed.TypeAst

    $member = @(
        $typeAst.Members |
            Where-Object {
                $_ -is [System.Management.Automation.Language.FunctionMemberAst] -and
                -not $_.IsConstructor -and
                (-not $MethodName -or $_.Name -eq $MethodName)
            }
    ) | Select-Object -First 1

    if (-not $member) { throw 'No matching method.' }

    $sig = Get-MemberSignature $member

    if ($sig.ParameterTypes.Count -ne 1) {
        throw 'This first end-to-end proof intentionally supports exactly one parameter.'
    }

    if ($sig.IsStatic) {
        throw 'This first end-to-end proof expects an instance method.'
    }

    $fullOut = if ([IO.Path]::IsPathFullyQualified($OutputPath)) {
        [IO.Path]::GetFullPath($OutputPath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
    }

    $outDir = [IO.Path]::GetDirectoryName($fullOut)
    if ($outDir -and -not [IO.Directory]::Exists($outDir)) {
        [IO.Directory]::CreateDirectory($outDir) | Out-Null
    }

    $id = [Guid]::NewGuid().ToString('N')
    $asmNameText = "$($typeAst.Name)_Persisted_$id"

    $pab = [Reflection.Emit.PersistedAssemblyBuilder]::new(
        [Reflection.AssemblyName]::new($asmNameText),
        [object].Assembly
    )

    $module = $pab.DefineDynamicModule($asmNameText)

    $tb = $module.DefineType(
        $typeAst.Name,
        [Reflection.TypeAttributes]'Public,Class'
    )

    $null = $tb.DefineDefaultConstructor(
        [Reflection.MethodAttributes]'Public'
    )

    # Bind declaring CLR type BEFORE asking SMA to compile the member.
    $typeProperty = $typeAst.GetType().GetProperty('Type', $script:BFInst)
    $typeProperty.SetValue($typeAst, $tb)

    $lowering = Get-SmaMemberLowering -Member $member -Optimize:$Optimize

    if (-not $lowering.NameToIndexMap) {
        throw 'SMA did not expose NameToIndexMap.'
    }

    $paramName = $sig.ParameterNames[0]

    if (-not $lowering.NameToIndexMap.ContainsKey($paramName)) {
        throw "SMA locals map has no '$paramName'."
    }

    $slot = [int]$lowering.NameToIndexMap[$paramName]
    $tupleMemberName = 'Item{0:D3}' -f $slot

    # Find the semantic return expression SMA generated.
    $pipeAdd = Find-ReturnPipeAdd $lowering.Lambda.Body

    if (-not $pipeAdd) {
        throw 'Could not find SMA returnPipe.Add(value) expression.'
    }

    $boxedValue = $pipeAdd.Arguments[0]

    # SMA boxes the already-converted member return value to object for Pipe.Add.
    $value = if (
        $boxedValue -is [Linq.Expressions.UnaryExpression] -and
        $boxedValue.NodeType -eq [Linq.Expressions.ExpressionType]::Convert -and
        $boxedValue.Type -eq [object]
    ) {
        $boxedValue.Operand
    }
    else {
        $boxedValue
    }

    Write-Host "EXTRACTED_VALUE_TYPE=$($value.Type.FullName)"
    Write-Host "PARAM_SLOT=$slot"
    Write-Host "PARAM_TUPLE_MEMBER=$tupleMemberName"

    $x = [Linq.Expressions.Expression]::Parameter(
        $sig.ParameterTypes[0],
        $paramName
    )

    $replacementCount = 0

    $rewritten = Rewrite-ExpressionLeaf `
        -Expression $value `
        -TupleMemberName $tupleMemberName `
        -Replacement $x `
        -ReplacementCount ([ref]$replacementCount)

    Write-Host "LEAF_REPLACEMENTS=$replacementCount"

    if ($replacementCount -ne 1) {
        throw "Expected exactly one '$tupleMemberName' replacement; got $replacementCount."
    }

    if ($rewritten.Type -ne $sig.ReturnType) {
        throw "Rewritten expression type '$($rewritten.Type)' does not match return type '$($sig.ReturnType)'."
    }

    $dynamicBefore = Get-ExpressionDynamicCount $rewritten
    Write-Host "DYNAMIC_NODES_BEFORE=$dynamicBefore"

    $sites = [System.Collections.Generic.List[object]]::new()

    $persistable = Convert-DynamicToPersistedCallSites `
        -Expression $rewritten `
        -TypeBuilder $tb `
        -Sites $sites

    $dynamicAfter = Get-ExpressionDynamicCount $persistable

    Write-Host "PERSISTED_CALLSITES=$($sites.Count)"
    Write-Host "DYNAMIC_NODES_AFTER=$dynamicAfter"

    if ($dynamicAfter -ne 0) {
        throw "CallSite persistence rewrite incomplete: $dynamicAfter DynamicExpression node(s) remain."
    }

    if ($sites.Count -ne $dynamicBefore) {
        throw "Expected $dynamicBefore persisted call sites, created $($sites.Count)."
    }

    if ($persistable.Type -ne $sig.ReturnType) {
        throw "Persistable expression type '$($persistable.Type)' does not match return type '$($sig.ReturnType)'."
    }

    $delegateType = [Linq.Expressions.Expression]::GetDelegateType(
        [type[]]@(
            $sig.ParameterTypes[0],
            $sig.ReturnType
        )
    )

    $coreLambda = [Linq.Expressions.Expression]::Lambda(
        $delegateType,
        $persistable,
        $sig.Name,
        $false,
        [Linq.Expressions.ParameterExpression[]]@($x)
    )

    $debugProp = [Linq.Expressions.Expression].GetProperty(
        'DebugView',
        $script:BFInst
    )

    $coreDebug = [string]$debugProp.GetValue($coreLambda)
    $debugPath = [IO.Path]::ChangeExtension($fullOut, '.core.lambda.txt')
    [IO.File]::WriteAllText(
        $debugPath,
        $coreDebug,
        [Text.UTF8Encoding]::new($false)
    )

    $attrs = [Reflection.MethodAttributes]'Public,HideBySig,Virtual'

    $mb = $tb.DefineMethod(
        $sig.Name,
        $attrs,
        $sig.ReturnType,
        $sig.ParameterTypes
    )

    $null = $mb.DefineParameter(
        1,
        [Reflection.ParameterAttributes]::None,
        $paramName
    )

    $emitResult = Write-MicrosoftLambdaToMethodBuilder `
        -Lambda $coreLambda `
        -MethodBuilder $mb

    $cctor = Define-CallSiteTypeInitializer `
        -TypeBuilder $tb `
        -Sites $sites

    if ($cctor) {
        Write-Host "TYPE_INITIALIZER=True"
    }
    else {
        Write-Host "TYPE_INITIALIZER=False"
    }

    $null = $tb.CreateType()
    $pab.Save($fullOut)

    $asm = [Reflection.Assembly]::LoadFrom($fullOut)
    $t = $asm.GetType($typeAst.Name, $true)
    $o = [Activator]::CreateInstance($t)
    $m = $t.GetMethod($sig.Name)

    Write-Host "FILE=$([IO.File]::Exists($fullOut))"
    Write-Host "CORE_DEBUG_VIEW=$debugPath"
    Write-Host "RELOADED_METHOD=$m"
    Write-Host "METHOD_BODY=$($null -ne $m.GetMethodBody())"
    Write-Host "LAMBDA_TYPEBUILDER_RETARGETED=$($emitResult.TypeBuilderSet)"

    $result = $m.Invoke(
        $o,
        [object[]]@([Convert]::ChangeType(41, $sig.ParameterTypes[0]))
    )

    Write-Host "RESULT=$result"

    if ($result -ne 42) {
        throw "Expected 42, got $result."
    }

    Write-Host 'YAKPROOF_42=PASS'

    $fullOut
}

function Export-PersistedThisProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$MethodName = 'Add',
        [switch]$Optimize
    )

    $parsed = Get-ClassAst $Source
    $typeAst = $parsed.TypeAst
    $member = @($typeAst.Members | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionMemberAst] -and
        -not $_.IsConstructor -and $_.Name -eq $MethodName
    }) | Select-Object -First 1
    if (-not $member) { throw "Method '$MethodName' was not found." }

    $sig = Get-MemberSignature $member
    if ($sig.IsStatic -or $sig.ParameterTypes.Count -ne 1) {
        throw 'The real-this proof requires one instance method with one parameter.'
    }

    $fullOut = [IO.Path]::GetFullPath($OutputPath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOut)) | Out-Null
    $assemblyName = "$($typeAst.Name)_ThisProof_$([Guid]::NewGuid().ToString('N'))"
    $pab = [Reflection.Emit.PersistedAssemblyBuilder]::new(
        [Reflection.AssemblyName]::new($assemblyName), [object].Assembly)
    $module = $pab.DefineDynamicModule($assemblyName)
    $tb = $module.DefineType($typeAst.Name, [Reflection.TypeAttributes]'Public,Class')
    $null = $tb.DefineDefaultConstructor([Reflection.MethodAttributes]'Public')
    $baseField = $tb.DefineField('Base', [int], [Reflection.FieldAttributes]'Public')

    # The real FunctionMemberAst must see its actual declaring CLR TypeBuilder.
    $typeProperty = $typeAst.GetType().GetProperty('Type', $script:BFInst)
    $typeProperty.SetValue($typeAst, $tb)
    $lowering = Get-SmaMemberLowering -Member $member -Optimize:$Optimize
    if (-not $lowering.NameToIndexMap) { throw 'SMA did not expose NameToIndexMap.' }

    $thisSlot = [int]$lowering.NameToIndexMap['this']
    $parameterName = $sig.ParameterNames[0]
    $parameterSlot = [int]$lowering.NameToIndexMap[$parameterName]
    $thisTupleMember = 'Item{0:D3}' -f $thisSlot
    $parameterTupleMember = 'Item{0:D3}' -f $parameterSlot
    Write-Host "THIS_SLOT=$thisSlot"
    Write-Host "THIS_TUPLE_MEMBER=$thisTupleMember"
    Write-Host "PARAM_SLOT=$parameterSlot"
    Write-Host "PARAM_TUPLE_MEMBER=$parameterTupleMember"

    $pipeAdd = Find-ReturnPipeAdd $lowering.Lambda.Body
    if (-not $pipeAdd) { throw 'Could not find SMA returnPipe.Add(value) expression.' }
    $boxedValue = $pipeAdd.Arguments[0]
    $value = if ($boxedValue -is [Linq.Expressions.UnaryExpression] -and
        $boxedValue.NodeType -eq [Linq.Expressions.ExpressionType]::Convert -and
        $boxedValue.Type -eq [object]) { $boxedValue.Operand } else { $boxedValue }

    # LambdaCompiler maps this extra leading lambda parameter to CLR arg0.
    # Keeping its delegate-facing type as object avoids constructing a delegate
    # type over an unfinished TypeBuilder; the cast restores the exact CLR type.
    $self = [Linq.Expressions.Expression]::Parameter([object], 'self')
    $selfAsGeneratedType = [Linq.Expressions.Expression]::Convert($self, $tb)
    $argument = [Linq.Expressions.Expression]::Parameter(
        $sig.ParameterTypes[0], $parameterName)

    $thisReplacementCount = 0
    $rewrittenThis = Rewrite-ExpressionLeaf -Expression $value `
        -TupleMemberName $thisTupleMember -Replacement $selfAsGeneratedType `
        -ReplacementCount ([ref]$thisReplacementCount)
    $parameterReplacementCount = 0
    $rewritten = Rewrite-ExpressionLeaf -Expression $rewrittenThis `
        -TupleMemberName $parameterTupleMember -Replacement $argument `
        -ReplacementCount ([ref]$parameterReplacementCount)
    Write-Host "THIS_REPLACEMENTS=$thisReplacementCount"
    Write-Host "PARAM_REPLACEMENTS=$parameterReplacementCount"
    if ($thisReplacementCount -ne 1 -or $parameterReplacementCount -ne 1) {
        throw "Expected one this and one parameter replacement; got $thisReplacementCount and $parameterReplacementCount."
    }

    $remainingTupleMembers = [Collections.Generic.HashSet[string]]::new()
    $remainingLocalsParameters = 0
    $inspectionStack = [Collections.Generic.Stack[Linq.Expressions.Expression]]::new()
    $inspectionStack.Push($rewritten)
    while ($inspectionStack.Count) {
        $inspectionNode = $inspectionStack.Pop()
        if ($inspectionNode -is [Linq.Expressions.ParameterExpression] -and
            $inspectionNode.Name -eq 'locals') {
            $remainingLocalsParameters++
        }
        if ($inspectionNode -is [Linq.Expressions.MemberExpression] -and
            $inspectionNode.Expression -is [Linq.Expressions.ParameterExpression] -and
            $inspectionNode.Expression.Name -eq 'locals') {
            $null = $remainingTupleMembers.Add($inspectionNode.Member.Name)
        }
        foreach ($inspectionChild in Get-ExpressionChildren $inspectionNode) {
            if ($inspectionChild) { $inspectionStack.Push($inspectionChild) }
        }
    }
    Write-Host "REMAINING_TUPLE_MEMBERS=$([string]::Join(',', $remainingTupleMembers))"
    Write-Host "REMAINING_LOCALS_PARAMETERS=$remainingLocalsParameters"
    $debugProperty = [Linq.Expressions.Expression].GetProperty('DebugView', $script:BFInst)
    [IO.File]::WriteAllText(
        [IO.Path]::ChangeExtension($fullOut, '.this-rewritten.txt'),
        [string]$debugProperty.GetValue($rewritten),
        [Text.UTF8Encoding]::new($false))

    $dynamicBefore = Get-ExpressionDynamicCount $rewritten
    Write-Host "DYNAMIC_NODES_BEFORE=$dynamicBefore"
    $sites = [System.Collections.Generic.List[object]]::new()
    $persistable = Convert-DynamicToPersistedCallSites `
        -Expression $rewritten -TypeBuilder $tb -Sites $sites
    $dynamicAfter = Get-ExpressionDynamicCount $persistable
    Write-Host "PERSISTED_CALLSITES=$($sites.Count)"
    Write-Host "DYNAMIC_NODES_AFTER=$dynamicAfter"
    if ($dynamicAfter -ne 0) { throw "$dynamicAfter DynamicExpression nodes remain." }

    $delegateType = [Linq.Expressions.Expression]::GetDelegateType(
        [type[]]@([object], $sig.ParameterTypes[0], $sig.ReturnType))
    $lambda = [Linq.Expressions.Expression]::Lambda(
        $delegateType, $persistable, $sig.Name, $false,
        [Linq.Expressions.ParameterExpression[]]@($self, $argument))
    $method = $tb.DefineMethod(
        $sig.Name, [Reflection.MethodAttributes]'Public,HideBySig,Virtual',
        $sig.ReturnType, $sig.ParameterTypes)
    $null = $method.DefineParameter(1, [Reflection.ParameterAttributes]::None, $parameterName)
    $null = Write-MicrosoftLambdaToMethodBuilder -Lambda $lambda -MethodBuilder $method -ExplicitThis
    $cctor = Define-CallSiteTypeInitializer -TypeBuilder $tb -Sites $sites
    Write-Host "TYPE_INITIALIZER=$($null -ne $cctor)"
    $null = $tb.CreateType()
    $pab.Save($fullOut)
    Write-Host "FILE=$([IO.File]::Exists($fullOut))"
    Write-Host "METHOD_BODY=True"
    $fullOut
}

function Write-PersistedAndroidOnCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Reflection.Emit.TypeBuilder]$MainTypeBuilder,
        [Parameter(Mandatory)][Reflection.Emit.MethodBuilder]$AdmissionMethod,
        [Parameter(Mandatory)][type]$ActivityType,
        [Parameter(Mandatory)][type]$BundleType
    )
    $baseMethod = $ActivityType.GetMethod(
        'OnCreate', [Reflection.BindingFlags]'Instance,NonPublic', $null,
        [type[]]@($BundleType), $null)
    if ($null -eq $baseMethod -or $baseMethod.DeclaringType -ne $ActivityType) {
        throw 'Android.App.Activity.OnCreate(Bundle) could not be identified unambiguously.'
    }
    $method = $MainTypeBuilder.DefineMethod(
        'OnCreate', [Reflection.MethodAttributes]'Family,Virtual,HideBySig',
        [void], [type[]]@($BundleType))
    $ilg = $method.GetILGenerator()
    $ilg.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $ilg.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $ilg.Emit([Reflection.Emit.OpCodes]::Call, $baseMethod)
    $ilg.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $ilg.Emit([Reflection.Emit.OpCodes]::Call, $AdmissionMethod)
    $ilg.Emit([Reflection.Emit.OpCodes]::Ret)
    $MainTypeBuilder.DefineMethodOverride($method, $baseMethod)
    [pscustomobject]@{
        Method = $method
        PersistedCallSites = 0
        DynamicNodesAfter = 0
        TypeInitializer = $false
        DeferredCallSiteInitializer = $false
        BaseCallOpcode = 'call'
        BaseMethod = $baseMethod
        AdmissionMethod = $AdmissionMethod
    }
}

Export-ModuleMember -Function `
    Export-PersistedClass, Export-PersistedThisProof, Write-PersistedAndroidOnCreate
