$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\PersistedSMA.psm1" -Force

'PROBE_VERSION=8_REAL_CLR_THIS_AND_FIELD'
$source = @'
class YakProof {
    [int] $Base

    [int] Add([int] $x) {
        return $this.Base + $x
    }
}
'@

$dll = Export-PersistedThisProof -Source $source -MethodName Add `
    -OutputPath (Join-Path $PSScriptRoot '..\build\proof\YakProof-This.dll') -Optimize

$escaped = $dll.Replace("'", "''")
$child = @"
`$assembly = [Reflection.Assembly]::LoadFrom('$escaped')
`$type = `$assembly.GetType('YakProof', `$true)
`$instance = [Activator]::CreateInstance(`$type)
`$field = `$type.GetField('Base')
`$field.SetValue(`$instance, 10)
`$method = `$type.GetMethod('Add')
`$result = `$method.Invoke(`$instance, [object[]]@(32))
"FIELD_VALUE=`$(`$field.GetValue(`$instance))"
"FRESH_METHOD=`$method"
"FRESH_RESULT=`$result"
if ([int]`$result -ne 42) { throw "Expected 42, got `$result." }
'FRESH_THIS_PROOF=PASS'
"@

& pwsh -NoProfile -ExecutionPolicy Bypass -Command $child
if ($LASTEXITCODE -ne 0) { throw "Fresh-process proof failed with exit code $LASTEXITCODE." }
