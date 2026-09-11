#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\generated\AndroidSMA.dll')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Build-RecoveryTree.ps1 owns the Android metadata and expression factories.
if ($null -eq (Get-Command New-ClrCall -ErrorAction SilentlyContinue)) {
    $null = . (Join-Path $PSScriptRoot 'Build-RecoveryTree.ps1')
}

function New-StaticCall {
    param([Reflection.MethodInfo] $Method, [Linq.Expressions.Expression[]] $Arguments = @())
    New-ClrCall $null $Method $Arguments
}

function New-Field {
    param([Linq.Expressions.Expression] $Instance, [Reflection.FieldInfo] $Field)
    [Linq.Expressions.Expression]::Field($Instance, $Field)
}

function New-If {
    param([Linq.Expressions.Expression] $Test, [Linq.Expressions.Expression] $Then, [Linq.Expressions.Expression] $Else)
    [Linq.Expressions.Expression]::IfThenElse($Test, $Then, $Else)
}

function New-ReturnBlock {
    param([Type] $Type, [Linq.Expressions.Expression[]] $Expressions)
    [Linq.Expressions.Expression]::Block($Type, [Linq.Expressions.Expression[]]$Expressions)
}

$null = . (Join-Path $PSScriptRoot 'Write-MicrosoftLambdaToMethodBuilder.ps1')
Import-Module (Join-Path $PSScriptRoot 'PersistedSMA.psm1') -Force

$output = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
if ([IO.File]::Exists($output)) { [IO.File]::Delete($output) }

$assemblyName = [Reflection.AssemblyName]::new('AndroidSMA')
$assemblyBuilder = [Reflection.Emit.PersistedAssemblyBuilder]::new($assemblyName, [object].Assembly)
$moduleBuilder = $assemblyBuilder.DefineDynamicModule('AndroidSMA.dll')
$programType = $moduleBuilder.DefineType(
    'AndroidSMA.RecoveryProgram',
    [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
$mainType = $moduleBuilder.DefineType(
    'AndroidSMA.SMActivity',
    [Reflection.TypeAttributes]'Public,Sealed,Class,BeforeFieldInit',
    $activityType)
$mainType.DefineDefaultConstructor([Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName') | Out-Null

$runspaceType = [Management.Automation.Runspaces.Runspace]
$runspaceField = $programType.DefineField(
    's_runspace', $runspaceType,
    [Reflection.FieldAttributes]'Private,Static')
$powerShellLoadContextInitializedField = $programType.DefineField(
    's_powerShellLoadContextInitialized', [bool],
    [Reflection.FieldAttributes]'Private,Static')
$animationCallbackField = $programType.DefineField(
    's_animationCallback', [Action],
    [Reflection.FieldAttributes]'Private,Static')

$activityAttributeType = Get-AndroidType 'Android.App.ActivityAttribute'
$activityAttribute = [Reflection.Emit.CustomAttributeBuilder]::new(
    (Get-ExactConstructor $activityAttributeType @()),
    [object[]]@(),
    [Reflection.PropertyInfo[]]@(
        (Get-ExactProperty $activityAttributeType 'Name'),
        (Get-ExactProperty $activityAttributeType 'Label'),
        (Get-ExactProperty $activityAttributeType 'MainLauncher'),
        (Get-ExactProperty $activityAttributeType 'Exported'),
        (Get-ExactProperty $activityAttributeType 'LaunchMode'),
        (Get-ExactProperty $activityAttributeType 'Theme')),
    [object[]]@(
        'dev.mansfieldplumbing.androidsma.SMActivity',
        'AndroidSMA',
        $true,
        $true,
        ([Enum]::Parse((Get-AndroidType 'Android.Content.PM.LaunchMode'), 'SingleTop')),
        '@android:style/Theme.Material.NoActionBar'))
$mainType.SetCustomAttribute($activityAttribute)

$emitted = [Collections.Generic.List[object]]::new()
function Add-PersistedMethod {
    param(
        [Reflection.Emit.TypeBuilder] $Owner,
        [string] $Name,
        [Reflection.MethodAttributes] $Attributes,
        [Type] $ReturnType,
        [Type[]] $ParameterTypes,
        [Type] $DelegateType,
        [Linq.Expressions.ParameterExpression[]] $LambdaParameters,
        [Linq.Expressions.Expression] $Body
    )
    $method = $Owner.DefineMethod($Name, $Attributes, $ReturnType, $ParameterTypes)
    $lambda = New-ClrLambda $DelegateType $Body $LambdaParameters
    try { Write-MicrosoftLambdaToMethodBuilder -Lambda $lambda -MethodBuilder $method }
    catch {
        throw "Microsoft LambdaCompiler failed for $($Owner.FullName).$Name ($($Body.NodeType)): $($_.Exception.GetBaseException().GetType().FullName): $($_.Exception.GetBaseException().Message)"
    }
    $emitted.Add([pscustomobject]@{ Name = $Name; Method = $method; Success = $true })
    $method
}

$publicStatic = [Reflection.MethodAttributes]'Public,Static,HideBySig'
$privateStatic = [Reflection.MethodAttributes]'Private,Static,HideBySig'

# Small factories keep every persisted method closure-free.
$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$v = [Linq.Expressions.Expression]::Parameter([int], 'value')
$dpBody = [Linq.Expressions.Expression]::Convert(
    (New-ClrCall $null $applyDimension @(
        (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Dip')) $complexUnitType),
        ([Linq.Expressions.Expression]::Convert($v, [single])),
        (New-ClrProperty (New-ClrProperty $a $resourcesProperty) $displayMetricsProperty))),
    [int])
$dpMethod = Add-PersistedMethod $programType 'Dp' $privateStatic ([int]) @($activityType, [int]) `
    ([Func``3].MakeGenericType($activityType, [int], [int])) @($a, $v) $dpBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$parameters = [Linq.Expressions.Expression]::Parameter($layoutParamsType, 'parameters')
$margin = New-StaticCall $dpMethod @($a, (New-ClrConstant 8 ([int])))
$buttonParamsBody = New-ReturnBlock $layoutParamsType @(
    (New-ClrAssign (New-ClrProperty $parameters $topMarginProperty) $margin),
    $parameters)
$buttonParamsMethod = Add-PersistedMethod $programType 'ConfigureButtonParameters' $privateStatic $layoutParamsType `
    @($activityType, $layoutParamsType) `
    ([Func``3].MakeGenericType($activityType, $layoutParamsType, $layoutParamsType)) `
    @($a, $parameters) $buttonParamsBody

$typeGetType = Get-ExactMethod ([Type]) 'GetType' @([string], [bool]) ([Reflection.BindingFlags]'Public,Static')
$typeGetMethod = Get-ExactMethod ([Type]) 'GetMethod' @([string], [Reflection.BindingFlags])
$createDelegate = Get-ExactMethod ([Delegate]) 'CreateDelegate' @([Type], [Reflection.MethodInfo]) ([Reflection.BindingFlags]'Public,Static')
$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$handlerName = [Linq.Expressions.Expression]::Parameter([string], 'handlerName')
$recoveryProgramRuntimeType = New-StaticCall $typeGetType @(
    (New-ClrConstant 'AndroidSMA.RecoveryProgram, AndroidSMA' ([string])),
    (New-ClrConstant $true ([bool])))
$eventHandlerRuntimeType = New-StaticCall $typeGetType @(
    (New-ClrConstant 'System.EventHandler' ([string])),
    (New-ClrConstant $true ([bool])))
$handlerMethodInfo = New-ClrCall $recoveryProgramRuntimeType $typeGetMethod @(
    $handlerName,
    (New-ClrConstant ([Reflection.BindingFlags]'Public,Static') ([Reflection.BindingFlags])))
$handlerBody = [Linq.Expressions.Expression]::Convert(
    (New-StaticCall $createDelegate @($eventHandlerRuntimeType, $handlerMethodInfo)),
    [EventHandler])
$createHandlerMethod = Add-PersistedMethod $programType 'CreateHandler' $privateStatic ([EventHandler]) `
    @($activityType, [string]) ([Func``3].MakeGenericType($activityType, [string], [EventHandler])) `
    @($a, $handlerName) $handlerBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$parent = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'parent')
$buttonText = [Linq.Expressions.Expression]::Parameter([string], 'text')
$handlerName = [Linq.Expressions.Expression]::Parameter([string], 'handlerName')
$buttonDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
$button = [Linq.Expressions.Expression]::Parameter($buttonType, 'button')
$contentDescriptionProperty = Get-ExactProperty $viewType 'ContentDescription'
$focusableProperty = Get-ExactProperty $viewType 'Focusable'
$focusableInTouchModeProperty = Get-ExactProperty $viewType 'FocusableInTouchMode'
$configureButtonBody = New-ReturnBlock ([void]) @(
    (New-ClrAssign (New-ClrProperty $button $buttonTextProperty) $buttonText),
    (New-ClrAssign (New-ClrProperty $button $contentDescriptionProperty) $buttonDetails),
    (New-ClrAssign (New-ClrProperty $button $focusableProperty) (New-ClrConstant $true ([bool]))),
    (New-ClrAssign (New-ClrProperty $button $focusableInTouchModeProperty) (New-ClrConstant $true ([bool]))),
    (New-ClrCall $button $buttonAddClick @(
        (New-StaticCall $createHandlerMethod @($a, $handlerName)))),
    (New-ClrCall $parent $addViewWithParams @(
        $button,
        (New-StaticCall $buttonParamsMethod @(
            $a,
            (New-ClrNew $buttonLayoutParamsConstructor @(
                ([Linq.Expressions.Expression]::Field($null, $matchParentField)),
                ([Linq.Expressions.Expression]::Field($null, $wrapContentField)))))))),
    [Linq.Expressions.Expression]::Empty())
$configureButtonMethod = Add-PersistedMethod $programType 'ConfigureButton' $privateStatic ([void]) `
    @($activityType, $linearLayoutType, [string], [string], [string], $buttonType) `
    ([Action``6].MakeGenericType($activityType, $linearLayoutType, [string], [string], [string], $buttonType)) `
    @($a, $parent, $buttonText, $handlerName, $buttonDetails, $button) $configureButtonBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$parent = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'parent')
$buttonText = [Linq.Expressions.Expression]::Parameter([string], 'text')
$handlerName = [Linq.Expressions.Expression]::Parameter([string], 'handlerName')
$buttonDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
$addButtonBody = New-StaticCall $configureButtonMethod @(
    $a, $parent, $buttonText, $handlerName, $buttonDetails, (New-ClrNew $buttonConstructor @($a)))
$addButtonMethod = Add-PersistedMethod $programType 'AddButton' $privateStatic ([void]) `
    @($activityType, $linearLayoutType, [string], [string], [string]) `
    ([Action``5].MakeGenericType($activityType, $linearLayoutType, [string], [string], [string])) `
    @($a, $parent, $buttonText, $handlerName, $buttonDetails) $addButtonBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$headingText = [Linq.Expressions.Expression]::Parameter([string], 'text')
$heading = [Linq.Expressions.Expression]::Parameter($textViewType, 'heading')
$headingBody = New-ReturnBlock $textViewType @(
    (New-ClrAssign (New-ClrProperty $heading $textViewTextProperty) $headingText),
    (New-ClrCall $heading $setTextColor @((New-ClrProperty $null $whiteProperty))),
    (New-ClrCall $heading $setTextSize @(
        (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Sp')) $complexUnitType),
        (New-ClrConstant ([single]64) ([single])))),
    $heading)
$headingMethod = Add-PersistedMethod $programType 'ConfigureHeading' $privateStatic $textViewType `
    @($activityType, [string], $textViewType) `
    ([Func``4].MakeGenericType($activityType, [string], $textViewType, $textViewType)) `
    @($a, $headingText, $heading) $headingBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$messageText = [Linq.Expressions.Expression]::Parameter([string], 'text')
$message = [Linq.Expressions.Expression]::Parameter($textViewType, 'message')
$messageBody = New-ReturnBlock $textViewType @(
    (New-ClrAssign (New-ClrProperty $message $textViewTextProperty) $messageText),
    (New-ClrCall $message $setTextIsSelectable @((New-ClrConstant $true ([bool])))),
    (New-ClrCall $message $setTextColor @((New-ClrProperty $null $whiteProperty))),
    (New-ClrCall $message $setTextSize @(
        (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Sp')) $complexUnitType),
        (New-ClrConstant ([single]15) ([single])))),
    $message)
$messageMethod = Add-PersistedMethod $programType 'ConfigureMessage' $privateStatic $textViewType `
    @($activityType, [string], $textViewType) `
    ([Func``4].MakeGenericType($activityType, [string], $textViewType, $textViewType)) `
    @($a, $messageText, $message) $messageBody

$scroll = [Linq.Expressions.Expression]::Parameter($scrollViewType, 'scroll')
$message = [Linq.Expressions.Expression]::Parameter($textViewType, 'message')
$scrollBody = New-ReturnBlock $scrollViewType @(
    (New-ClrCall $scroll $scrollAddView @($message)),
    $scroll)
$scrollMethod = Add-PersistedMethod $programType 'ConfigureScroll' $privateStatic $scrollViewType `
    @($scrollViewType, $textViewType) `
    ([Func``3].MakeGenericType($scrollViewType, $textViewType, $scrollViewType)) `
    @($scroll, $message) $scrollBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$messageParameters = [Linq.Expressions.Expression]::Parameter($layoutParamsType, 'parameters')
$dp16 = New-StaticCall $dpMethod @($a, (New-ClrConstant 16 ([int])))
$messageParamsBody = New-ReturnBlock $layoutParamsType @(
    (New-ClrAssign (New-ClrProperty $messageParameters $topMarginProperty) $dp16),
    (New-ClrAssign (New-ClrProperty $messageParameters $bottomMarginProperty) $dp16),
    $messageParameters)
$messageParamsMethod = Add-PersistedMethod $programType 'ConfigureMessageParameters' $privateStatic $layoutParamsType `
    @($activityType, $layoutParamsType) `
    ([Func``3].MakeGenericType($activityType, $layoutParamsType, $layoutParamsType)) `
    @($a, $messageParameters) $messageParamsBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$layoutTitle = [Linq.Expressions.Expression]::Parameter([string], 'title')
$layoutDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
$layout = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'layout')
$padding24 = New-StaticCall $dpMethod @($a, (New-ClrConstant 24 ([int])))
$newHeading = New-StaticCall $headingMethod @($a, $layoutTitle, (New-ClrNew $textViewConstructor @($a)))
$newMessage = New-StaticCall $messageMethod @($a, $layoutDetails, (New-ClrNew $textViewConstructor @($a)))
$newScroll = New-StaticCall $scrollMethod @(
    (New-ClrNew $scrollViewConstructor @($a)), $newMessage)
$messageParametersValue = New-StaticCall $messageParamsMethod @(
    $a,
    (New-ClrNew $layoutParamsConstructor @(
        ([Linq.Expressions.Expression]::Field($null, $matchParentField)),
        (New-ClrConstant 0 ([int])),
        (New-ClrConstant ([single]1) ([single])))))
$copyCondition = New-If `
    ([Linq.Expressions.Expression]::Equal($layoutTitle, (New-ClrConstant ':(' ([string])))) `
    (New-StaticCall $addButtonMethod @(
        $a, $layout,
        (New-ClrConstant 'COPY TO CLIPBOARD' ([string])),
        (New-ClrConstant 'CopyClick' ([string])),
        $layoutDetails)) `
    ([Linq.Expressions.Expression]::Empty())
$layoutBody = New-ReturnBlock $linearLayoutType @(
    (New-ClrAssign `
        (New-ClrProperty $layout $orientationProperty) `
        (New-ClrConstant ([Enum]::Parse($orientationType, 'Vertical')) $orientationType)),
    (New-ClrCall $layout $setBackgroundColor @(
        (New-StaticCall $rgb @(
            (New-ClrConstant 11 ([int])),
            (New-ClrConstant 61 ([int])),
            (New-ClrConstant 46 ([int])))))),
    (New-ClrCall $layout $setPadding @($padding24, $padding24, $padding24, $padding24)),
    (New-ClrCall $layout $addView @($newHeading)),
    (New-ClrCall $layout $addViewWithParams @($newScroll, $messageParametersValue)),
    $copyCondition,
    (New-StaticCall $addButtonMethod @(
        $a, $layout,
        (New-ClrConstant 'IMPORT FILE' ([string])),
        (New-ClrConstant 'ImportClick' ([string])),
        $layoutDetails)),
    (New-StaticCall $addButtonMethod @(
        $a, $layout,
        (New-ClrConstant 'RETRY' ([string])),
        (New-ClrConstant 'RetryClick' ([string])),
        $layoutDetails)),
    $layout)
$buildLayoutMethod = Add-PersistedMethod $programType 'BuildRecoveryLayout' $privateStatic $linearLayoutType `
    @($activityType, [string], [string], $linearLayoutType) `
    ([Func``5].MakeGenericType($activityType, [string], [string], $linearLayoutType, $linearLayoutType)) `
    @($a, $layoutTitle, $layoutDetails, $layout) $layoutBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$showTitle = [Linq.Expressions.Expression]::Parameter([string], 'title')
$showDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
$shownLayout = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'layout')
$getChildAt = Get-ExactMethod $linearLayoutType 'GetChildAt' @([int])
$requestFocus = Get-ExactMethod $viewType 'RequestFocus' @()
$showBody = New-ClrBlock @($shownLayout) @(
    (New-ClrAssign $shownLayout (New-StaticCall $buildLayoutMethod @(
        $a, $showTitle, $showDetails, (New-ClrNew $linearLayoutConstructor @($a))))),
    (New-ClrCall $a $setContentView @($shownLayout)),
    (New-ClrCall (New-ClrCall $shownLayout $getChildAt @((New-ClrConstant 2 ([int])))) $requestFocus @()),
    [Linq.Expressions.Expression]::Empty())
$showRecoveryMethod = Add-PersistedMethod $programType 'ShowRecovery' $publicStatic ([void]) `
    @($activityType, [string], [string]) `
    ([Action``3].MakeGenericType($activityType, [string], [string])) `
    @($a, $showTitle, $showDetails) $showBody

# The emitted recovery floor owns its own distress beacon. This remains usable
# when SMA can load but the application runspace or Profile.ps1 cannot start.
$androidLogType = Get-AndroidType 'Android.Util.Log'
$androidLogError = Get-ExactMethod $androidLogType 'Error' @([string], [string]) `
    ([Reflection.BindingFlags]'Public,Static')
$distressMessage = [Linq.Expressions.Expression]::Parameter([string], 'message')
$writeDistressBody = New-ClrBlock @() @(
    (New-StaticCall $androidLogError @(
        (New-ClrConstant 'AndroidSMA' ([string])),
        $distressMessage)),
    [Linq.Expressions.Expression]::Empty())
$writeDistressMethod = Add-PersistedMethod $programType 'WriteDistress' $privateStatic ([void]) `
    @([string]) ([Action``1].MakeGenericType([string])) @($distressMessage) $writeDistressBody

# Profile.ps1 runtime. The runspace remains alive after successful startup so
# event handlers and application state created by the Start script remain usable.
$defaultRunspaceProperty = Get-ExactProperty $runspaceType 'DefaultRunspace' ([Reflection.BindingFlags]'Public,Static')
$runspaceDispose = Get-ExactMethod $runspaceType 'Dispose' @()
$runspaceOpen = Get-ExactMethod $runspaceType 'Open' @()
$runspaceSessionState = Get-ExactProperty $runspaceType 'SessionStateProxy'
$sessionStateType = [Management.Automation.Runspaces.SessionStateProxy]
$setVariable = Get-ExactMethod $sessionStateType 'SetVariable' @([string], [object])
$initialStateType = [Management.Automation.Runspaces.InitialSessionState]
$createInitialState = Get-ExactMethod $initialStateType 'CreateDefault2' @() ([Reflection.BindingFlags]'Public,Static')
$languageModeProperty = Get-ExactProperty $initialStateType 'LanguageMode'
$threadOptionsProperty = Get-ExactProperty $initialStateType 'ThreadOptions'
$createRunspace = Get-ExactMethod ([Management.Automation.Runspaces.RunspaceFactory]) 'CreateRunspace' @($initialStateType) ([Reflection.BindingFlags]'Public,Static')
$powerShellType = [Management.Automation.PowerShell]
$createPowerShell = Get-ExactMethod $powerShellType 'Create' @() ([Reflection.BindingFlags]'Public,Static')
$powerShellRunspace = Get-ExactProperty $powerShellType 'Runspace'
$commandInfoType = [Management.Automation.CommandInfo]
$commandTypesType = [Management.Automation.CommandTypes]
$invokeCommandProperty = Get-ExactProperty $sessionStateType 'InvokeCommand'
$getCommand = Get-ExactMethod ([Management.Automation.CommandInvocationIntrinsics]) 'GetCommand' `
    @([string], $commandTypesType)
$powerShellAddCommand = Get-ExactMethod $powerShellType 'AddCommand' @($commandInfoType)
$powerShellAddParameter = Get-ExactMethod $powerShellType 'AddParameter' @([string], [object])
$powerShellInvoke = $powerShellType.GetMethods([Reflection.BindingFlags]'Public,Instance') |
    Where-Object { $_.Name -eq 'Invoke' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 0 } |
    Select-Object -First 1
if (-not $powerShellInvoke) { throw 'PowerShell.Invoke() could not be resolved.' }
$powerShellHadErrors = Get-ExactProperty $powerShellType 'HadErrors'
$powerShellStreams = Get-ExactProperty $powerShellType 'Streams'
$errorStreamProperty = Get-ExactProperty ([Management.Automation.PSDataStreams]) 'Error'
$errorCollectionType = $errorStreamProperty.PropertyType
$errorCountProperty = Get-ExactProperty $errorCollectionType 'Count'
$errorItemProperty = $errorCollectionType.GetProperty('Item', [type[]]@([int]))
$errorRecordToString = Get-ExactMethod ([Management.Automation.ErrorRecord]) 'ToString' @()
$powerShellDispose = Get-ExactMethod $powerShellType 'Dispose' @()
$invalidOperationCtor = Get-ExactConstructor ([InvalidOperationException]) @([string])
$exceptionToString = Get-ExactMethod ([Exception]) 'ToString' @()
$concat2 = Get-ExactMethod ([string]) 'Concat' @([string], [string]) ([Reflection.BindingFlags]'Public,Static')
$concat3 = Get-ExactMethod ([string]) 'Concat' @([string], [string], [string]) ([Reflection.BindingFlags]'Public,Static')
$fileExists = Get-ExactMethod ([IO.File]) 'Exists' @([string]) ([Reflection.BindingFlags]'Public,Static')

$runspaceFieldExpression = [Linq.Expressions.Expression]::Field($null, $runspaceField)
$nullRunspace = [Linq.Expressions.Expression]::Constant($null, $runspaceType)
$resetBody = New-ClrBlock @() @(
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::NotEqual(
            $runspaceFieldExpression,
            $nullRunspace)),
        (New-ClrCall $runspaceFieldExpression $runspaceDispose @()))),
    (New-ClrAssign $runspaceFieldExpression $nullRunspace),
    (New-ClrAssign (New-ClrProperty $null $defaultRunspaceProperty) $nullRunspace),
    [Linq.Expressions.Expression]::Empty())
$resetRuntimeMethod = Add-PersistedMethod $programType 'ResetRuntime' $privateStatic ([void]) @() `
    ([Action]) @() $resetBody

$callback = [Linq.Expressions.Expression]::Parameter([Action], 'callback')
$animationCallbackFieldExpression = [Linq.Expressions.Expression]::Field($null, $animationCallbackField)
$setAnimationCallbackMethod = Add-PersistedMethod $programType 'SetAnimationCallback' $publicStatic ([void]) `
    @([Action]) ([Action``1].MakeGenericType([Action])) @($callback) `
    (New-ClrAssign $animationCallbackFieldExpression $callback)

$actionInvoke = Get-ExactMethod ([Action]) 'Invoke' @()
$runAnimationBody = New-ClrBlock @() @(
    (New-ClrAssign (New-ClrProperty $null $defaultRunspaceProperty) $runspaceFieldExpression),
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::NotEqual(
            $animationCallbackFieldExpression,
            ([Linq.Expressions.Expression]::Constant($null, [Action])))),
        (New-ClrCall $animationCallbackFieldExpression $actionInvoke @()))),
    [Linq.Expressions.Expression]::Empty())
$runAnimationCallbackMethod = Add-PersistedMethod $programType 'RunAnimationCallback' $publicStatic ([void]) `
    @() ([Action]) @() $runAnimationBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$profilePath = [Linq.Expressions.Expression]::Parameter([string], 'profilePath')
$initialState = [Linq.Expressions.Expression]::Parameter($initialStateType, 'initialState')
$shell = [Linq.Expressions.Expression]::Parameter($powerShellType, 'shell')
$startCommand = [Linq.Expressions.Expression]::Parameter($commandInfoType, 'startCommand')
$createRunspaceBlock = New-ClrBlock @($initialState) @(
    (New-StaticCall $writeDistressMethod @((New-ClrConstant 'HOST_CREATEDEFAULT2_BEGIN' ([string])))),
    (New-ClrAssign $initialState (New-StaticCall $createInitialState @())),
    (New-StaticCall $writeDistressMethod @((New-ClrConstant 'HOST_CREATEDEFAULT2_END' ([string])))),
    (New-ClrAssign (New-ClrProperty $initialState $languageModeProperty) `
        (New-ClrConstant ([Management.Automation.PSLanguageMode]::FullLanguage) ([Management.Automation.PSLanguageMode]))),
    (New-ClrAssign (New-ClrProperty $initialState $threadOptionsProperty) `
        (New-ClrConstant ([Management.Automation.Runspaces.PSThreadOptions]::UseCurrentThread) ([Management.Automation.Runspaces.PSThreadOptions]))),
    (New-ClrAssign $runspaceFieldExpression (New-StaticCall $createRunspace @($initialState))),
    (New-ClrCall $runspaceFieldExpression $runspaceOpen @()),
    (New-StaticCall $writeDistressMethod @((New-ClrConstant 'HOST_RUNSPACE_OPEN' ([string])))))
$profileErrors = New-ClrProperty (New-ClrProperty $shell $powerShellStreams) $errorStreamProperty
$firstProfileError = [Linq.Expressions.Expression]::MakeIndex(
    $profileErrors, $errorItemProperty,
    [Linq.Expressions.Expression[]]@((New-ClrConstant 0 ([int]))))
$profileErrorMessage = [Linq.Expressions.Expression]::Condition(
    ([Linq.Expressions.Expression]::GreaterThan(
        (New-ClrProperty $profileErrors $errorCountProperty),
        (New-ClrConstant 0 ([int])))),
    (New-ClrCall $firstProfileError $errorRecordToString @()),
    (New-ClrConstant 'Profile.ps1 reported one or more PowerShell errors.' ([string])))
$hadErrorsException = New-ClrNew $invalidOperationCtor @($profileErrorMessage)
$throwHadErrors = [Linq.Expressions.Expression]::Throw($hadErrorsException)
$throwOnErrors = [Linq.Expressions.Expression]::IfThen(
    (New-ClrProperty $shell $powerShellHadErrors),
    $throwHadErrors)
$resolveStartCommand = New-ClrCall `
    (New-ClrProperty (New-ClrProperty $runspaceFieldExpression $runspaceSessionState) $invokeCommandProperty) `
    $getCommand @(
        $profilePath,
        (New-ClrConstant ([Management.Automation.CommandTypes]::ExternalScript) $commandTypesType))
$executeShellBody = New-ClrBlock @($startCommand) @(
    (New-ClrAssign (New-ClrProperty $shell $powerShellRunspace) $runspaceFieldExpression),
    (New-ClrCall (New-ClrProperty $runspaceFieldExpression $runspaceSessionState) $setVariable @(
        (New-ClrConstant 'Activity' ([string])), [Linq.Expressions.Expression]::Convert($a, [object]))),
    (New-ClrCall (New-ClrProperty $runspaceFieldExpression $runspaceSessionState) $setVariable @(
        (New-ClrConstant 'PSScriptRoot' ([string])),
        [Linq.Expressions.Expression]::Convert((New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty), [object]))),
    (New-ClrAssign $startCommand $resolveStartCommand),
    (New-ClrCall $shell $powerShellAddCommand @($startCommand)),
    (New-ClrCall $shell $powerShellAddParameter @(
        (New-ClrConstant 'Activity' ([string])),
        [Linq.Expressions.Expression]::Convert($a, [object]))),
    (New-StaticCall $writeDistressMethod @((New-ClrConstant 'START_INVOKE_BEGIN' ([string])))),
    (New-ClrCall $shell $powerShellInvoke @()),
    (New-StaticCall $writeDistressMethod @((New-ClrConstant 'START_INVOKE_END' ([string])))),
    $throwOnErrors,
    (New-StaticCall $runAnimationCallbackMethod @()),
    [Linq.Expressions.Expression]::Empty())
$executeProfileBody = New-ClrBlock @($shell) @(
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::Equal(
            $runspaceFieldExpression,
            $nullRunspace)),
        $createRunspaceBlock)),
    (New-ClrAssign (New-ClrProperty $null $defaultRunspaceProperty) $runspaceFieldExpression),
    (New-ClrAssign $shell (New-StaticCall $createPowerShell @())),
    ([Linq.Expressions.Expression]::TryFinally(
        $executeShellBody,
        (New-ClrCall $shell $powerShellDispose @()))),
    [Linq.Expressions.Expression]::Empty())
$executeProfileMethod = Add-PersistedMethod $programType 'ExecuteProfile' $privateStatic ([void]) `
    @($activityType, [string]) ([Action``2].MakeGenericType($activityType, [string])) `
    @($a, $profilePath) $executeProfileBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$profilePath = [Linq.Expressions.Expression]::Parameter([string], 'profilePath')
$startupError = [Linq.Expressions.Expression]::Parameter([Exception], 'error')
$profilePathValue = New-StaticCall $pathCombine @(
    (New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty),
    (New-ClrConstant 'Profile.ps1' ([string])))
$missingDetails = New-StaticCall $concat2 @(
    (New-ClrConstant "message: Profile.ps1 is missing.`nsource: " ([string])),
    $profilePath)
$failedStartup = New-ClrBlock @() @(
    (New-StaticCall $writeDistressMethod @(
        (New-StaticCall $concat2 @(
            (New-ClrConstant 'START_FAILURE ' ([string])),
            (New-ClrCall $startupError $exceptionToString @()))))),
    (New-StaticCall $resetRuntimeMethod @()),
    (New-StaticCall $showRecoveryMethod @(
        $a,
        (New-ClrConstant ':(' ([string])),
        (New-ClrCall $startupError $exceptionToString @()))))
$executeOrRecover = [Linq.Expressions.Expression]::TryCatch(
    (New-StaticCall $executeProfileMethod @($a, $profilePath)),
    ([Linq.Expressions.Expression]::Catch($startupError, $failedStartup)))
$missingRecovery = New-StaticCall $showRecoveryMethod @(
    $a,
    (New-ClrConstant ':(' ([string])),
    $missingDetails)
$missingRecovery = New-ClrBlock @() @(
    (New-StaticCall $writeDistressMethod @(
        (New-StaticCall $concat2 @(
            (New-ClrConstant 'START_MISSING ' ([string])),
            $missingDetails)))),
    $missingRecovery,
    [Linq.Expressions.Expression]::Empty())
$startupChoice = [Linq.Expressions.Expression]::IfThenElse(
    (New-StaticCall $fileExists @($profilePath)),
    $executeOrRecover,
    $missingRecovery)
$startProfileBody = New-ClrBlock @($profilePath) @(
    (New-ClrAssign $profilePath $profilePathValue),
    $startupChoice,
    [Linq.Expressions.Expression]::Empty())
$startProfileMethod = Add-PersistedMethod $programType 'StartProfile' $publicStatic ([void]) `
    @($activityType) ([Action``1].MakeGenericType($activityType)) @($a) $startProfileBody

# Irreducible Android-to-PowerShell admission. The Activity override performs
# only the nonvirtual CLR base call, then enters this persisted expression body.
$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$setPowerShellAssemblyLoadContext =
    [Management.Automation.PowerShellAssemblyLoadContextInitializer].GetMethod(
        'SetPowerShellAssemblyLoadContext',
        [Reflection.BindingFlags]'Public,Static', $null, [type[]]@([string]), $null)
$setAppContextData = Get-ExactMethod ([AppContext]) 'SetData' @([string], [object]) `
    ([Reflection.BindingFlags]'Public,Static')
$applicationBase = New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty
$powerShellLoadContextInitialized = [Linq.Expressions.Expression]::Field(
    $null, $powerShellLoadContextInitializedField)
$initializePowerShellLoadContext = New-StaticCall $setPowerShellAssemblyLoadContext @(
    $applicationBase)
$admitActivityBody = New-ClrBlock @() @(
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::IsFalse($powerShellLoadContextInitialized)),
        (New-ClrBlock @() @(
            (New-StaticCall $setAppContextData @(
                (New-ClrConstant 'APP_CONTEXT_BASE_DIRECTORY' ([string])),
                ([Linq.Expressions.Expression]::Convert($applicationBase, [object])))),
            $initializePowerShellLoadContext,
            (New-ClrAssign $powerShellLoadContextInitialized (New-ClrConstant $true ([bool]))),
            [Linq.Expressions.Expression]::Empty())))),
    (New-StaticCall $startProfileMethod @($a)),
    [Linq.Expressions.Expression]::Empty())
$admitActivityMethod = Add-PersistedMethod $programType 'AdmitActivity' $publicStatic ([void]) `
    @($activityType) ([Action``1].MakeGenericType($activityType)) @($a) $admitActivityBody

# File-picker completion. Selected documents retain their display name in the
# private app directory; Profile.ps1 is restarted immediately after import.
$intentType = Get-AndroidType 'Android.Content.Intent'
$uriType = Get-AndroidType 'Android.Net.Uri'
$contentResolverType = Get-AndroidType 'Android.Content.ContentResolver'
$cursorType = Get-AndroidType 'Android.Database.ICursor'
$resultType = Get-AndroidType 'Android.App.Result'
$contentResolverProperty = Get-ExactProperty $activityType 'ContentResolver'
$intentDataProperty = Get-ExactProperty $intentType 'Data'
$queryMethod = Get-ExactMethod $contentResolverType 'Query' @(
    $uriType, [string[]], [string], [string[]], [string])
$openInputStream = Get-ExactMethod $contentResolverType 'OpenInputStream' @($uriType)
$moveToFirst = Get-ExactMethod $cursorType 'MoveToFirst' @()
$getColumnIndex = Get-ExactMethod $cursorType 'GetColumnIndex' @([string])
$cursorGetString = Get-ExactMethod $cursorType 'GetString' @([int])
$disposeMethod = Get-ExactMethod ([IDisposable]) 'Dispose' @()
$displayNameField = (Get-AndroidType 'Android.Provider.IOpenableColumns').GetField(
    'DisplayName', [Reflection.BindingFlags]'Public,Static')
$ioExceptionCtor = Get-ExactConstructor ([IO.IOException]) @([string])
$isNullOrWhiteSpace = Get-ExactMethod ([string]) 'IsNullOrWhiteSpace' @([string]) ([Reflection.BindingFlags]'Public,Static')
$stringEqualsComparison = Get-ExactMethod ([string]) 'Equals' @([string], [string], [StringComparison]) ([Reflection.BindingFlags]'Public,Static')
$stringContainsChar = Get-ExactMethod ([string]) 'Contains' @([char])
$fileStreamCtor = Get-ExactConstructor ([IO.FileStream]) @([string], [IO.FileMode], [IO.FileAccess], [IO.FileShare])
$streamCopyTo = Get-ExactMethod ([IO.Stream]) 'CopyTo' @([IO.Stream])
$fileStreamFlushDisk = Get-ExactMethod ([IO.FileStream]) 'Flush' @([bool])
$fileMoveOverwrite = Get-ExactMethod ([IO.File]) 'Move' @([string], [string], [bool]) ([Reflection.BindingFlags]'Public,Static')
$fileDelete = Get-ExactMethod ([IO.File]) 'Delete' @([string]) ([Reflection.BindingFlags]'Public,Static')

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$uri = [Linq.Expressions.Expression]::Parameter($uriType, 'uri')
$cursor = [Linq.Expressions.Expression]::Parameter($cursorType, 'cursor')
$column = [Linq.Expressions.Expression]::Parameter([int], 'column')
$displayName = [Linq.Expressions.Expression]::Parameter([string], 'displayName')
$nullCursor = [Linq.Expressions.Expression]::Constant($null, $cursorType)
$noDisplayName = New-ClrNew $ioExceptionCtor @(
    (New-ClrConstant 'The selected document has no display name.' ([string])))
$queryCursor = New-ClrCall (New-ClrProperty $a $contentResolverProperty) $queryMethod @(
    $uri,
    ([Linq.Expressions.Expression]::NewArrayInit([string], @(
        (New-ClrConstant ([string]$displayNameField.GetValue($null)) ([string]))))),
    [Linq.Expressions.Expression]::Constant($null, [string]),
    [Linq.Expressions.Expression]::Constant($null, [string[]]),
    [Linq.Expressions.Expression]::Constant($null, [string]))
$readDisplayName = New-ReturnBlock ([string]) @(
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::OrElse(
            ([Linq.Expressions.Expression]::Equal($cursor, $nullCursor)),
            ([Linq.Expressions.Expression]::Not((New-ClrCall $cursor $moveToFirst @()))))),
        ([Linq.Expressions.Expression]::Throw($noDisplayName)))),
    (New-ClrAssign $column (New-ClrCall $cursor $getColumnIndex @(
        (New-ClrConstant ([string]$displayNameField.GetValue($null)) ([string]))))),
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::LessThan($column, (New-ClrConstant 0 ([int])))),
        ([Linq.Expressions.Expression]::Throw($noDisplayName)))),
    (New-ClrAssign $displayName (New-ClrCall $cursor $cursorGetString @($column))),
    ([Linq.Expressions.Expression]::IfThen(
        (New-StaticCall $isNullOrWhiteSpace @($displayName)),
        ([Linq.Expressions.Expression]::Throw($noDisplayName)))),
    $displayName)
$closeCursor = [Linq.Expressions.Expression]::IfThen(
    ([Linq.Expressions.Expression]::NotEqual($cursor, $nullCursor)),
    (New-ClrCall ([Linq.Expressions.Expression]::Convert($cursor, [IDisposable])) $disposeMethod @()))
$getDisplayNameBody = New-ClrBlock @($cursor, $column, $displayName) @(
    (New-ClrAssign $cursor $queryCursor),
    ([Linq.Expressions.Expression]::TryFinally($readDisplayName, $closeCursor)))
$getDisplayNameMethod = Add-PersistedMethod $programType 'GetDisplayName' $privateStatic ([string]) `
    @($activityType, $uriType) ([Func``3].MakeGenericType($activityType, $uriType, [string])) `
    @($a, $uri) $getDisplayNameBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$intent = [Linq.Expressions.Expression]::Parameter($intentType, 'data')
$uri = [Linq.Expressions.Expression]::Parameter($uriType, 'uri')
$displayName = [Linq.Expressions.Expression]::Parameter([string], 'displayName')
$destination = [Linq.Expressions.Expression]::Parameter([string], 'destination')
$incoming = [Linq.Expressions.Expression]::Parameter([string], 'incoming')
$source = [Linq.Expressions.Expression]::Parameter([IO.Stream], 'source')
$target = [Linq.Expressions.Expression]::Parameter([IO.FileStream], 'target')
$importError = [Linq.Expressions.Expression]::Parameter([Exception], 'error')
$invalidDotName = [Linq.Expressions.Expression]::OrElse(
    ([Linq.Expressions.Expression]::Equal($displayName, (New-ClrConstant '.' ([string])))),
    ([Linq.Expressions.Expression]::Equal($displayName, (New-ClrConstant '..' ([string])))))
$slashCharacter = New-ClrConstant ([char]47) ([char])
$backslashCharacter = New-ClrConstant ([char]92) ([char])
$hasSlash = New-ClrCall $displayName $stringContainsChar @($slashCharacter)
$hasBackslash = New-ClrCall $displayName $stringContainsChar @($backslashCharacter)
$invalidSeparator = [Linq.Expressions.Expression]::OrElse($hasSlash, $hasBackslash)
$invalidName = [Linq.Expressions.Expression]::OrElse(
    (New-StaticCall $isNullOrWhiteSpace @($displayName)),
    ([Linq.Expressions.Expression]::OrElse($invalidDotName, $invalidSeparator)))
$invalidNameThrow = [Linq.Expressions.Expression]::Throw(
    (New-ClrNew $ioExceptionCtor @(
        (New-ClrConstant 'The selected document name is invalid.' ([string])))))
$isProfile = New-StaticCall $stringEqualsComparison @(
    $displayName,
    (New-ClrConstant 'Profile.ps1' ([string])),
    (New-ClrConstant ([StringComparison]::OrdinalIgnoreCase) ([StringComparison])))
$copyFileBody = New-ClrBlock @() @(
    (New-ClrCall $source $streamCopyTo @($target)),
    (New-ClrCall $target $fileStreamFlushDisk @((New-ClrConstant $true ([bool])))),
    [Linq.Expressions.Expression]::Empty())
$disposeTarget = New-ClrCall ([Linq.Expressions.Expression]::Convert($target, [IDisposable])) $disposeMethod @()
$disposeSource = New-ClrCall ([Linq.Expressions.Expression]::Convert($source, [IDisposable])) $disposeMethod @()
$restartAfterImport = New-ClrBlock @() @(
    (New-StaticCall $resetRuntimeMethod @()),
    (New-StaticCall $startProfileMethod @($a)))
$importedTitle = New-StaticCall $concat2 @(
    (New-ClrConstant 'IMPORTED: ' ([string])), $displayName)
$importedDetails = New-StaticCall $concat2 @(
    (New-ClrConstant 'source: ' ([string])), $destination)
$showImported = New-StaticCall $showRecoveryMethod @(
    $a, $importedTitle, $importedDetails)
$afterImport = [Linq.Expressions.Expression]::IfThenElse(
    $isProfile, $restartAfterImport, $showImported)
$importSuccess = New-ClrBlock @() @(
    (New-ClrAssign $uri (New-ClrProperty $intent $intentDataProperty)),
    (New-ClrAssign $displayName (New-StaticCall $getDisplayNameMethod @($a, $uri))),
    ([Linq.Expressions.Expression]::IfThen($invalidName, $invalidNameThrow)),
    ([Linq.Expressions.Expression]::IfThen(
        $isProfile,
        (New-ClrAssign $displayName (New-ClrConstant 'Profile.ps1' ([string]))))),
    (New-ClrAssign $destination (New-StaticCall $pathCombine @(
        (New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty),
        $displayName))),
    (New-ClrAssign $incoming (New-StaticCall $concat2 @(
        $destination, (New-ClrConstant '.incoming' ([string]))))),
    (New-ClrAssign $source (New-ClrCall (New-ClrProperty $a $contentResolverProperty) $openInputStream @($uri))),
    (New-ClrAssign $target (New-ClrNew $fileStreamCtor @(
        $incoming,
        (New-ClrConstant ([IO.FileMode]::Create) ([IO.FileMode])),
        (New-ClrConstant ([IO.FileAccess]::Write) ([IO.FileAccess])),
        (New-ClrConstant ([IO.FileShare]::None) ([IO.FileShare]))))),
    ([Linq.Expressions.Expression]::TryFinally(
        ([Linq.Expressions.Expression]::TryFinally($copyFileBody, $disposeTarget)),
        $disposeSource)),
    (New-StaticCall $fileMoveOverwrite @(
        $incoming, $destination, (New-ClrConstant $true ([bool])))),
    $afterImport,
    [Linq.Expressions.Expression]::Empty())
$importFailure = New-ClrBlock @() @(
    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::NotEqual(
            $incoming, ([Linq.Expressions.Expression]::Constant($null, [string])))),
        (New-StaticCall $fileDelete @($incoming)))),
    (New-StaticCall $showRecoveryMethod @(
        $a,
        (New-ClrConstant ':(' ([string])),
        (New-ClrCall $importError $exceptionToString @()))))
$importDocumentBody = New-ClrBlock @($uri, $displayName, $destination, $incoming, $source, $target) @(
    (New-ClrAssign $incoming ([Linq.Expressions.Expression]::Constant($null, [string]))),
    ([Linq.Expressions.Expression]::TryCatch(
        $importSuccess,
        ([Linq.Expressions.Expression]::Catch($importError, $importFailure)))),
    [Linq.Expressions.Expression]::Empty())
$importDocumentMethod = Add-PersistedMethod $programType 'ImportDocument' $privateStatic ([void]) `
    @($activityType, $intentType) ([Action``2].MakeGenericType($activityType, $intentType)) `
    @($a, $intent) $importDocumentBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$requestCode = [Linq.Expressions.Expression]::Parameter([int], 'requestCode')
$resultCode = [Linq.Expressions.Expression]::Parameter($resultType, 'resultCode')
$intent = [Linq.Expressions.Expression]::Parameter($intentType, 'data')
$requestMatches = [Linq.Expressions.Expression]::Equal(
    $requestCode, (New-ClrConstant 1001 ([int])))
$resultMatches = [Linq.Expressions.Expression]::Equal(
    $resultCode,
    (New-ClrConstant ([Enum]::Parse($resultType, 'Ok')) $resultType))
$hasIntent = [Linq.Expressions.Expression]::NotEqual(
    $intent, ([Linq.Expressions.Expression]::Constant($null, $intentType)))
$hasUri = [Linq.Expressions.Expression]::NotEqual(
    (New-ClrProperty $intent $intentDataProperty),
    ([Linq.Expressions.Expression]::Constant($null, $uriType)))
$hasIntentAndUri = [Linq.Expressions.Expression]::AndAlso($hasIntent, $hasUri)
$resultAndDataMatch = [Linq.Expressions.Expression]::AndAlso($resultMatches, $hasIntentAndUri)
$validResult = [Linq.Expressions.Expression]::AndAlso($requestMatches, $resultAndDataMatch)
$handleResultBody = New-ClrBlock @() @(
    ([Linq.Expressions.Expression]::IfThen(
        $validResult,
        (New-StaticCall $importDocumentMethod @($a, $intent)))),
    [Linq.Expressions.Expression]::Empty())
$handleResultMethod = Add-PersistedMethod $programType 'HandleActivityResult' $publicStatic ([void]) `
    @($activityType, [int], $resultType, $intentType) `
    ([Action``4].MakeGenericType($activityType, [int], $resultType, $intentType)) `
    @($a, $requestCode, $resultCode, $intent) $handleResultBody

# Clipboard payload: recursive helpers avoid persisted local variables while
# retaining a complete inventory of assemblies, files, runtime, and Profile.ps1.
$builderType = [Text.StringBuilder]
$appendLine = Get-ExactMethod $builderType 'AppendLine' @([string])
$append = Get-ExactMethod $builderType 'Append' @([string])
$builderToStringMethod = Get-ExactMethod $builderType 'ToString' @()
$builderCtor = Get-ExactConstructor $builderType @()
$assembliesType = [Reflection.Assembly[]]
$getAssembliesMethod = Get-ExactMethod ([AppDomain]) 'GetAssemblies' @()
$currentDomain = Get-ExactProperty ([AppDomain]) 'CurrentDomain' ([Reflection.BindingFlags]'Public,Static')
$index = [Linq.Expressions.Expression]::Parameter([int], 'index')
$builder = [Linq.Expressions.Expression]::Parameter($builderType, 'builder')
$assemblies = [Linq.Expressions.Expression]::Parameter($assembliesType, 'assemblies')
$appendAssembliesMethod = $programType.DefineMethod(
    'AppendAssemblies', $privateStatic, [void], [Type[]]@($builderType, $assembliesType, [int]))
$assemblyAtIndex = [Linq.Expressions.Expression]::ArrayIndex($assemblies, $index)
$nextAssemblyIndex = [Linq.Expressions.Expression]::Add($index, (New-ClrConstant 1 ([int])))
$appendNextAssembly = New-StaticCall $appendAssembliesMethod @(
    $builder, $assemblies, $nextAssemblyIndex)
$appendAssemblyStep = New-ClrBlock @() @(
    (New-ClrCall $builder $appendLine @((New-ClrProperty $assemblyAtIndex $assemblyFullNameProperty))),
    $appendNextAssembly)
$appendAssembliesBody = [Linq.Expressions.Expression]::IfThen(
    ([Linq.Expressions.Expression]::LessThan($index, [Linq.Expressions.Expression]::ArrayLength($assemblies))),
    $appendAssemblyStep)
$appendAssembliesLambda = New-ClrLambda `
    ([Action``3].MakeGenericType($builderType, $assembliesType, [int])) `
    $appendAssembliesBody @($builder, $assemblies, $index)
Write-MicrosoftLambdaToMethodBuilder $appendAssembliesLambda $appendAssembliesMethod
$emitted.Add([pscustomobject]@{ Name = 'AppendAssemblies'; Method = $appendAssembliesMethod; Success = $true })

$files = [Linq.Expressions.Expression]::Parameter([string[]], 'files')
$index = [Linq.Expressions.Expression]::Parameter([int], 'index')
$builder = [Linq.Expressions.Expression]::Parameter($builderType, 'builder')
$appendFilesMethod = $programType.DefineMethod(
    'AppendFiles', $privateStatic, [void], [Type[]]@($builderType, [string[]], [int]))
$nextFileIndex = [Linq.Expressions.Expression]::Add($index, (New-ClrConstant 1 ([int])))
$appendNextFile = New-StaticCall $appendFilesMethod @($builder, $files, $nextFileIndex)
$appendFileStep = New-ClrBlock @() @(
    (New-ClrCall $builder $appendLine @([Linq.Expressions.Expression]::ArrayIndex($files, $index))),
    $appendNextFile)
$appendFilesBody = [Linq.Expressions.Expression]::IfThen(
    ([Linq.Expressions.Expression]::LessThan($index, [Linq.Expressions.Expression]::ArrayLength($files))),
    $appendFileStep)
$appendFilesLambda = New-ClrLambda ([Action``3].MakeGenericType($builderType, [string[]], [int])) `
    $appendFilesBody @($builder, $files, $index)
Write-MicrosoftLambdaToMethodBuilder $appendFilesLambda $appendFilesMethod
$emitted.Add([pscustomobject]@{ Name = 'AppendFiles'; Method = $appendFilesMethod; Success = $true })

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$profilePathValue = New-StaticCall $pathCombine @(
    (New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty),
    (New-ClrConstant 'Profile.ps1' ([string])))
$fileExists = Get-ExactMethod ([IO.File]) 'Exists' @([string]) ([Reflection.BindingFlags]'Public,Static')
$readProfileBody = [Linq.Expressions.Expression]::Condition(
    (New-StaticCall $fileExists @($profilePathValue)),
    (New-StaticCall $readAllText @($profilePathValue)),
    (New-ClrConstant 'Profile.ps1: unavailable' ([string])))
$readProfileMethod = Add-PersistedMethod $programType 'ReadProfileOrUnavailable' $privateStatic ([string]) `
    @($activityType) ([Func``2].MakeGenericType($activityType, [string])) @($a) $readProfileBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$payloadDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
$builder = [Linq.Expressions.Expression]::Parameter($builderType, 'builder')
$convertObjectToString = Get-ExactMethod ([Convert]) 'ToString' @([object]) ([Reflection.BindingFlags]'Public,Static')
function New-AppendLiteral([string] $Text) {
    New-ClrCall $builder $appendLine @((New-ClrConstant $Text ([string])))
}
function New-AppendFact([string] $Label, [Linq.Expressions.Expression] $Value) {
    New-ClrBlock @() @(
        (New-ClrCall $builder $append @((New-ClrConstant $Label ([string])))),
        (New-ClrCall $builder $appendLine @($Value)))
}
$privateRootValue = New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty
$payloadBody = New-ReturnBlock ([string]) @(
    (New-AppendLiteral 'ANDROIDSMA RECOVERY REPORT'),
    (New-AppendLiteral ''),
    (New-AppendLiteral 'REQUEST TO OUTSIDE MODEL'),
    (New-AppendLiteral 'Diagnose this startup failure and return a complete replacement Profile.ps1.'),
    (New-AppendLiteral 'Use only assemblies and files actually listed in this report.'),
    (New-AppendLiteral ''),
    (New-AppendLiteral 'RUNTIME CONTRACT'),
    (New-AppendLiteral 'Profile.ps1 runs in-process in a PowerShell runspace.'),
    (New-AppendLiteral '$Activity is the live Android.App.Activity.'),
    (New-AppendLiteral '$PSScriptRoot is the private app-files directory.'),
    (New-AppendLiteral 'IMPORT FILE copies a selected document there; RETRY starts Profile.ps1 again.'),
    (New-AppendLiteral ''),
    (New-AppendLiteral 'FAILURE DETAILS'),
    (New-ClrCall $builder $appendLine @($payloadDetails)),
    (New-AppendLiteral ''),
    (New-AppendLiteral 'ENVIRONMENT'),
    (New-AppendFact 'privateRoot: ' $privateRootValue),
    (New-AppendFact 'package: ' (New-ClrProperty $a $packageNameProperty)),
    (New-AppendFact 'manufacturer: ' (New-ClrProperty $null $manufacturerProperty)),
    (New-AppendFact 'model: ' (New-ClrProperty $null $modelProperty)),
    (New-AppendFact 'android: ' (New-ClrProperty $null $androidReleaseProperty)),
    (New-AppendFact 'api: ' (New-StaticCall $convertObjectToString @(
        [Linq.Expressions.Expression]::Convert((New-ClrProperty $null $androidSdkProperty), [object])))),
    (New-AppendFact 'dotnet: ' (New-ClrProperty $null $frameworkDescriptionProperty)),
    (New-AppendLiteral ''),
    (New-AppendLiteral 'LOADED ASSEMBLIES'),
    (New-StaticCall $appendAssembliesMethod @(
        $builder,
        (New-ClrCall (New-ClrProperty $null $currentDomain) $getAssembliesMethod @()),
        (New-ClrConstant 0 ([int])))),
    (New-AppendLiteral ''),
    (New-AppendLiteral 'PRIVATE FILES'),
    (New-StaticCall $appendFilesMethod @(
        $builder,
        (New-StaticCall $getFileSystemEntries @($privateRootValue)),
        (New-ClrConstant 0 ([int])))),
    (New-AppendLiteral ''),
    (New-AppendLiteral '--- Profile.ps1 BEGIN ---'),
    (New-ClrCall $builder $appendLine @((New-StaticCall $readProfileMethod @($a)))),
    (New-AppendLiteral '--- Profile.ps1 END ---'),
    (New-ClrCall $builder $builderToStringMethod @()))
$buildPayloadCoreMethod = Add-PersistedMethod $programType 'BuildClipboardPayloadCore' $privateStatic ([string]) `
    @($activityType, [string], $builderType) `
    ([Func``4].MakeGenericType($activityType, [string], $builderType, [string])) `
    @($a, $payloadDetails, $builder) $payloadBody

$a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$payloadDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
$buildPayloadBody = New-StaticCall $buildPayloadCoreMethod @(
    $a, $payloadDetails, (New-ClrNew $builderCtor @()))
$buildPayloadMethod = Add-PersistedMethod $programType 'BuildClipboardPayload' $publicStatic ([string]) `
    @($activityType, [string]) ([Func``3].MakeGenericType($activityType, [string], [string])) `
    @($a, $payloadDetails) $buildPayloadBody

$sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
$eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
$senderButton = [Linq.Expressions.Expression]::Convert($sender, $buttonType)
$senderActivity = [Linq.Expressions.Expression]::Convert(
    (New-ClrProperty $senderButton (Get-ExactProperty $viewType 'Context')), $activityType)
$clipboard = [Linq.Expressions.Expression]::Convert(
    (New-ClrCall $senderActivity $getSystemService @(
        (New-ClrConstant ([string]$contextType.GetField('ClipboardService').GetValue($null)) ([string])))),
    $clipboardManagerType)
$copyBody = New-ClrAssign (New-ClrProperty $clipboard $primaryClipProperty) `
    (New-StaticCall $newPlainText @(
        (New-ClrConstant 'AndroidSMA recovery report' ([string])),
        (New-StaticCall $buildPayloadMethod @(
            $senderActivity, (New-ClrProperty $senderButton $contentDescriptionProperty)))))
$null = Add-PersistedMethod $programType 'CopyClick' $publicStatic ([void]) @([object], [EventArgs]) `
    ([EventHandler]) @($sender, $eventArgs) $copyBody

$sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
$eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
$senderButton = [Linq.Expressions.Expression]::Convert($sender, $buttonType)
$senderActivity = [Linq.Expressions.Expression]::Convert(
    (New-ClrProperty $senderButton (Get-ExactProperty $viewType 'Context')), $activityType)
$picker = New-ClrNew $intentConstructor @(
    (New-ClrConstant ([string]$actionOpenDocumentField.GetValue($null)) ([string])))
$pickConfiguredMethod = $programType.DefineMethod(
    'ConfigurePicker', $privateStatic, $intentType, [Type[]]@($intentType))
$pickerParameter = [Linq.Expressions.Expression]::Parameter($intentType, 'picker')
$pickerBody = New-ReturnBlock $intentType @(
    (New-ClrCall $pickerParameter $addCategory @(
        (New-ClrConstant ([string]$categoryOpenableField.GetValue($null)) ([string])))),
    (New-ClrCall $pickerParameter $setType @((New-ClrConstant '*/*' ([string])))),
    $pickerParameter)
$pickerLambda = New-ClrLambda ([Func``2].MakeGenericType($intentType, $intentType)) $pickerBody @($pickerParameter)
Write-MicrosoftLambdaToMethodBuilder $pickerLambda $pickConfiguredMethod
$emitted.Add([pscustomobject]@{ Name = 'ConfigurePicker'; Method = $pickConfiguredMethod; Success = $true })
$importBody = New-ClrCall $senderActivity $startActivityForResult @(
    (New-StaticCall $pickConfiguredMethod @($picker)), (New-ClrConstant 1001 ([int])))
$null = Add-PersistedMethod $programType 'ImportClick' $publicStatic ([void]) @([object], [EventArgs]) `
    ([EventHandler]) @($sender, $eventArgs) $importBody

$sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
$eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
$senderButton = [Linq.Expressions.Expression]::Convert($sender, $buttonType)
$senderActivity = [Linq.Expressions.Expression]::Convert(
    (New-ClrProperty $senderButton (Get-ExactProperty $viewType 'Context')), $activityType)
$retryBody = New-ClrBlock @() @(
    (New-StaticCall $resetRuntimeMethod @()),
    (New-StaticCall $startProfileMethod @($senderActivity)),
    [Linq.Expressions.Expression]::Empty())
$null = Add-PersistedMethod $programType 'RetryClick' $publicStatic ([void]) @([object], [EventArgs]) `
    ([EventHandler]) @($sender, $eventArgs) $retryBody

# Android entry type. SMA lowers the authored PowerShell lifecycle, including
# PowerShell's cast-to-base method-call semantics.
$bundleType = Get-AndroidType 'Android.OS.Bundle'
$lifecycle = Write-PersistedAndroidOnCreate `
    -MainTypeBuilder $mainType `
    -AdmissionMethod $admitActivityMethod `
    -ActivityType $activityType `
    -BundleType $bundleType
$emitted.Add([pscustomobject]@{
    Name = 'OnCreate'
    Method = $lifecycle.Method
    Success = $true
})

$resultSelf = [Linq.Expressions.Expression]::Parameter($activityType, 'self')
$resultRequest = [Linq.Expressions.Expression]::Parameter([int], 'requestCode')
$resultCodeParameter = [Linq.Expressions.Expression]::Parameter($resultType, 'resultCode')
$resultData = [Linq.Expressions.Expression]::Parameter($intentType, 'data')
$onActivityResultBody = New-StaticCall $handleResultMethod @(
    $resultSelf, $resultRequest, $resultCodeParameter, $resultData)
$onActivityResultDelegate = [Action``4].MakeGenericType(
    $activityType, [int], $resultType, $intentType)
$onActivityResultLambda = New-ClrLambda $onActivityResultDelegate $onActivityResultBody @(
    $resultSelf, $resultRequest, $resultCodeParameter, $resultData)
$onActivityResultMethod = $mainType.DefineMethod(
    'OnActivityResult',
    [Reflection.MethodAttributes]'Family,Virtual,HideBySig',
    [void],
    [type[]]@([int], $resultType, $intentType))
$null = Write-MicrosoftLambdaToMethodBuilder `
    -Lambda $onActivityResultLambda `
    -MethodBuilder $onActivityResultMethod `
    -ExplicitThis
$baseOnActivityResult = $activityType.GetMethod(
    'OnActivityResult', [Reflection.BindingFlags]'Instance,NonPublic', $null,
    [type[]]@([int], $resultType, $intentType), $null)
$mainType.DefineMethodOverride($onActivityResultMethod, $baseOnActivityResult)
$emitted.Add([pscustomobject]@{
    Name = 'OnActivityResult'
    Method = $onActivityResultMethod
    Success = $true
})

$programType.CreateType() | Out-Null
$mainType.CreateType() | Out-Null
$assemblyBuilder.Save($output)

if (-not [IO.File]::Exists($output)) { throw "AndroidSMA.dll was not created: $output" }

$stream = [IO.File]::OpenRead($output)
try {
    $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $typeNames = [Collections.Generic.List[string]]::new()
        $methodBodies = 0
        foreach ($handle in $metadata.TypeDefinitions) {
            $definition = $metadata.GetTypeDefinition($handle)
            $typeNames.Add(($metadata.GetString($definition.Namespace) + '.' + $metadata.GetString($definition.Name)).Trim('.'))
        }
        foreach ($handle in $metadata.MethodDefinitions) {
            if ($metadata.GetMethodDefinition($handle).RelativeVirtualAddress -ne 0) { $methodBodies++ }
        }
        $references = foreach ($handle in $metadata.AssemblyReferences) {
            $metadata.GetString($metadata.GetAssemblyReference($handle).Name)
        }
    }
    finally { $pe.Dispose() }
}
finally { $stream.Dispose() }

"DLL_EXISTS=$([IO.File]::Exists($output))"
"ASSEMBLY=AndroidSMA"
"SM_ACTIVITY_TYPE=$($typeNames -contains 'AndroidSMA.SMActivity')"
"RECOVERY_PROGRAM_TYPE=$($typeNames -contains 'AndroidSMA.RecoveryProgram')"
"METHOD_BODIES=$methodBodies"
"MONO_ANDROID_REFERENCE=$($references -contains 'Mono.Android')"
"PERSISTENCE_BACKEND=Microsoft.LambdaCompiler"
"ONCREATE_SMA_CALLSITES=$($lifecycle.PersistedCallSites)"
"ONCREATE_DYNAMIC_NODES_AFTER=$($lifecycle.DynamicNodesAfter)"
"ONCREATE_TYPE_INITIALIZER=$($lifecycle.TypeInitializer)"
"ONCREATE_BASE_OPCODE=$($lifecycle.BaseCallOpcode)"
"ONCREATE_BASE_METHOD=$($lifecycle.BaseMethod)"
"ONCREATE_ADMISSION_METHOD=$($lifecycle.AdmissionMethod)"
foreach ($item in $emitted) { "METHOD=$($item.Name) PERSISTED=$($item.Success)" }
"OUTPUT=$output"
