$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\PersistedSMA.psm1" -Force
$module = Get-Module PersistedSMA

& $module {
    $source = @'
class YakProof {
    [int] $Base
    [int] Add([int] $x) { return $this.Base + $x }
}
'@
    $parsed = Get-ClassAst $source
    $member = $parsed.TypeAst.Members | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionMemberAst]
    } | Select-Object -First 1
    $assembly = [Reflection.Emit.PersistedAssemblyBuilder]::new(
        [Reflection.AssemblyName]::new('BinderInspection'), [object].Assembly)
    $type = $assembly.DefineDynamicModule('BinderInspection').DefineType('YakProof')
    $null = $type.DefineField('Base', [int], [Reflection.FieldAttributes]'Public')
    $typeProperty = $parsed.TypeAst.GetType().GetProperty('Type', $script:BFInst)
    $typeProperty.SetValue($parsed.TypeAst, $type)
    $lowering = Get-SmaMemberLowering $member
    $root = (Find-ReturnPipeAdd $lowering.Lambda.Body).Arguments[0]
    $stack = [Collections.Generic.Stack[Linq.Expressions.Expression]]::new()
    $stack.Push($root)
    while ($stack.Count) {
        $node = $stack.Pop()
        if ($node -is [Linq.Expressions.DynamicExpression]) {
            $binder = $node.Binder
            "BINDER=$($binder.GetType().FullName)"
            "DYNAMIC_TYPE=$($node.Type.AssemblyQualifiedName)"
            foreach ($propertyName in @('Name', 'IgnoreCase', 'ReturnType', 'IsStandardBinder')) {
                $property = $binder.GetType().GetProperty($propertyName, $script:BFInst)
                if ($property) { "PROPERTY_$propertyName=$($property.GetValue($binder))" }
            }
            foreach ($field in $binder.GetType().GetFields($script:BFInst)) {
                "FIELD_$($field.Name)=$($field.GetValue($binder))"
            }
        }
        foreach ($child in Get-ExpressionChildren $node) {
            if ($child) { $stack.Push($child) }
        }
    }
}
