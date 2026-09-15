#Requires -Version 7.0
[CmdletBinding()]
param([string] $MonoAndroidAssemblyPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dotnetCommand = Get-Command dotnet.exe, dotnet -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$dotnetRoot = if ($env:DOTNET_ROOT) {
    $env:DOTNET_ROOT
} elseif ($dotnetCommand) {
    Split-Path $dotnetCommand.Source -Parent
} else {
    $null
}
if (-not $MonoAndroidAssemblyPath -and $dotnetRoot) {
    $MonoAndroidAssemblyPath = Get-ChildItem (Join-Path $dotnetRoot 'packs') -Recurse -File `
        -Filter 'Mono.Android.dll' -ErrorAction SilentlyContinue |
        Where-Object FullName -Match 'Microsoft\.Android\.Runtime' |
        Sort-Object FullName -Descending |
        Select-Object -ExpandProperty FullName -First 1
}
$mono = if ($MonoAndroidAssemblyPath) {
    [IO.Path]::GetFullPath($MonoAndroidAssemblyPath)
} else {
    $null
}
if (-not [IO.File]::Exists($mono)) {
    throw 'Mono.Android runtime assembly was not found. Pass -MonoAndroidAssemblyPath or configure DOTNET_ROOT.'
}

$android = [Reflection.Assembly]::LoadFrom($mono)
$expressionType = [Linq.Expressions.Expression]
$expressionArrayType = [Linq.Expressions.Expression[]]
$parameterArrayType = [Linq.Expressions.ParameterExpression[]]

$newFactory = $expressionType.GetMethod(
    'New', [Type[]]@([Reflection.ConstructorInfo], $expressionArrayType))
$callFactory = $expressionType.GetMethod(
    'Call', [Type[]]@($expressionType, [Reflection.MethodInfo], $expressionArrayType))
$blockFactory = $expressionType.GetMethod(
    'Block', [Type[]]@(
        [Collections.Generic.IEnumerable[Linq.Expressions.ParameterExpression]],
        $expressionArrayType))
$lambdaFactory = $expressionType.GetMethod(
    'Lambda', [Type[]]@([Type], $expressionType, $parameterArrayType))
$invokeFactory = $expressionType.GetMethod(
    'Invoke', [Type[]]@($expressionType, $expressionArrayType))

foreach ($factory in @($newFactory, $callFactory, $blockFactory, $lambdaFactory, $invokeFactory)) {
    if ($null -eq $factory) { throw 'A required System.Linq.Expressions factory overload was not found.' }
}

function Get-AndroidType {
    param([Parameter(Mandatory)][string] $Name)

    $type = $android.GetType($Name, $false)
    if ($null -eq $type) { throw "Android type not found: $Name" }
    $type
}

function Get-ExactConstructor {
    param(
        [Parameter(Mandatory)][Type] $Type,
        [Parameter()][AllowEmptyCollection()][Type[]] $ParameterTypes = @()
    )

    $constructor = $Type.GetConstructor($ParameterTypes)
    if ($null -eq $constructor) {
        throw "Constructor not found: $($Type.FullName)($($ParameterTypes.FullName -join ', '))"
    }
    $constructor
}

function Get-ExactMethod {
    param(
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][string] $Name,
        [Parameter()][AllowEmptyCollection()][Type[]] $ParameterTypes = @(),
        [Reflection.BindingFlags] $Flags = [Reflection.BindingFlags]'Public,Instance,Static'
    )

    $method = $Type.GetMethod($Name, $Flags, $null, $ParameterTypes, $null)
    if ($null -eq $method) {
        throw "Method not found: $($Type.FullName).$Name($($ParameterTypes.FullName -join ', '))"
    }
    $method
}

function Get-ExactProperty {
    param(
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][string] $Name,
        [Reflection.BindingFlags] $Flags = [Reflection.BindingFlags]'Public,Instance,Static'
    )

    $property = $Type.GetProperty($Name, $Flags)
    if ($null -eq $property) { throw "Property not found: $($Type.FullName).$Name" }
    $property
}

function New-ClrNew {
    param(
        [Parameter(Mandatory)][Reflection.ConstructorInfo] $Constructor,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.Expression[]] $Arguments = @()
    )

    $newFactory.Invoke($null, [object[]]@($Constructor, [Linq.Expressions.Expression[]]$Arguments))
}

function New-ClrCall {
    param(
        [AllowNull()][Linq.Expressions.Expression] $Instance,
        [Parameter(Mandatory)][Reflection.MethodInfo] $Method,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.Expression[]] $Arguments = @()
    )

    $callFactory.Invoke($null, [object[]]@($Instance, $Method, [Linq.Expressions.Expression[]]$Arguments))
}

function New-ClrAssign {
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Left,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Right
    )

    [Linq.Expressions.Expression]::Assign($Left, $Right)
}

function New-ClrProperty {
    param(
        [AllowNull()][Linq.Expressions.Expression] $Instance,
        [Parameter(Mandatory)][Reflection.PropertyInfo] $Property
    )

    [Linq.Expressions.Expression]::Property($Instance, $Property)
}

function New-ClrConstant {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory)][Type] $Type
    )

    [Linq.Expressions.Expression]::Constant($Value, $Type)
}

function New-ClrBlock {
    param(
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.ParameterExpression[]] $Variables = @(),
        [Parameter(Mandatory)][Linq.Expressions.Expression[]] $Expressions
    )

    $blockFactory.Invoke($null, [object[]]@(
        [Linq.Expressions.ParameterExpression[]]$Variables,
        [Linq.Expressions.Expression[]]$Expressions))
}

function New-ClrLambda {
    param(
        [Parameter(Mandatory)][Type] $DelegateType,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Body,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.ParameterExpression[]] $Parameters = @()
    )

    $lambdaFactory.Invoke($null, [object[]]@(
        $DelegateType,
        $Body,
        [Linq.Expressions.ParameterExpression[]]$Parameters))
}

function New-ClrInvoke {
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Lambda,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.Expression[]] $Arguments = @()
    )

    $invokeFactory.Invoke($null, [object[]]@($Lambda, [Linq.Expressions.Expression[]]$Arguments))
}

$activityType = Get-AndroidType 'Android.App.Activity'
$buttonType = Get-AndroidType 'Android.Widget.Button'
$clipDataType = Get-AndroidType 'Android.Content.ClipData'
$clipboardManagerType = Get-AndroidType 'Android.Content.ClipboardManager'
$complexUnitType = Get-AndroidType 'Android.Util.ComplexUnitType'
$contextType = Get-AndroidType 'Android.Content.Context'
$displayMetricsType = Get-AndroidType 'Android.Util.DisplayMetrics'
$intentType = Get-AndroidType 'Android.Content.Intent'
$javaFileType = Get-AndroidType 'Java.IO.File'
$javaObjectType = Get-AndroidType 'Java.Lang.Object'
$linearLayoutType = Get-AndroidType 'Android.Widget.LinearLayout'
$layoutParamsType = Get-AndroidType 'Android.Widget.LinearLayout+LayoutParams'
$orientationType = Get-AndroidType 'Android.Widget.Orientation'
$resourcesType = Get-AndroidType 'Android.Content.Res.Resources'
$scrollViewType = Get-AndroidType 'Android.Widget.ScrollView'
$textViewType = Get-AndroidType 'Android.Widget.TextView'
$typedValueType = Get-AndroidType 'Android.Util.TypedValue'
$viewType = Get-AndroidType 'Android.Views.View'
$viewGroupLayoutParamsType = Get-AndroidType 'Android.Views.ViewGroup+LayoutParams'
$colorType = Get-AndroidType 'Android.Graphics.Color'

$eventHandlerType = [EventHandler]

$linearLayoutConstructor = Get-ExactConstructor $linearLayoutType @($contextType)
$textViewConstructor = Get-ExactConstructor $textViewType @($contextType)
$scrollViewConstructor = Get-ExactConstructor $scrollViewType @($contextType)
$buttonConstructor = Get-ExactConstructor $buttonType @($contextType)
$layoutParamsConstructor = Get-ExactConstructor $layoutParamsType @([int], [int], [single])
$buttonLayoutParamsConstructor = Get-ExactConstructor $layoutParamsType @([int], [int])
$intentConstructor = Get-ExactConstructor $intentType @([string])

$orientationProperty = Get-ExactProperty $linearLayoutType 'Orientation'
$textViewTextProperty = Get-ExactProperty $textViewType 'Text'
$buttonTextProperty = Get-ExactProperty $buttonType 'Text'
$topMarginProperty = Get-ExactProperty $layoutParamsType 'TopMargin'
$bottomMarginProperty = Get-ExactProperty $layoutParamsType 'BottomMargin'
$filesDirProperty = Get-ExactProperty $contextType 'FilesDir'
$absolutePathProperty = Get-ExactProperty $javaFileType 'AbsolutePath'
$resourcesProperty = Get-ExactProperty $contextType 'Resources'
$displayMetricsProperty = Get-ExactProperty $resourcesType 'DisplayMetrics'
$primaryClipProperty = Get-ExactProperty $clipboardManagerType 'PrimaryClip'
$actionOpenDocumentField = $intentType.GetField('ActionOpenDocument', [Reflection.BindingFlags]'Public,Static')
$categoryOpenableField = $intentType.GetField('CategoryOpenable', [Reflection.BindingFlags]'Public,Static')
$whiteProperty = Get-ExactProperty $colorType 'White' ([Reflection.BindingFlags]'Public,Static')
$matchParentField = $viewGroupLayoutParamsType.GetField('MatchParent', [Reflection.BindingFlags]'Public,Static')
$wrapContentField = $viewGroupLayoutParamsType.GetField('WrapContent', [Reflection.BindingFlags]'Public,Static')
if ($null -eq $actionOpenDocumentField -or $null -eq $categoryOpenableField -or
    $null -eq $matchParentField -or $null -eq $wrapContentField) {
    throw 'Required Android constant fields were not found.'
}

$setBackgroundColor = Get-ExactMethod $viewType 'SetBackgroundColor' @($colorType)
$setPadding = Get-ExactMethod $viewType 'SetPadding' @([int], [int], [int], [int])
$setTextColor = Get-ExactMethod $textViewType 'SetTextColor' @($colorType)
$setTextSize = Get-ExactMethod $textViewType 'SetTextSize' @($complexUnitType, [single])
$setTextIsSelectable = Get-ExactMethod $textViewType 'SetTextIsSelectable' @([bool])
$addView = Get-ExactMethod $linearLayoutType 'AddView' @($viewType)
$addViewWithParams = Get-ExactMethod $linearLayoutType 'AddView' @($viewType, $viewGroupLayoutParamsType)
$scrollAddView = Get-ExactMethod $scrollViewType 'AddView' @($viewType)
$buttonAddClick = Get-ExactMethod $buttonType 'add_Click' @($eventHandlerType)
$rgb = Get-ExactMethod $colorType 'Rgb' @([int], [int], [int]) ([Reflection.BindingFlags]'Public,Static')
$applyDimension = Get-ExactMethod $typedValueType 'ApplyDimension' @($complexUnitType, [single], $displayMetricsType) ([Reflection.BindingFlags]'Public,Static')
$setContentView = Get-ExactMethod $activityType 'SetContentView' @($viewType)
$getSystemService = Get-ExactMethod $contextType 'GetSystemService' @([string])
$newPlainText = Get-ExactMethod $clipDataType 'NewPlainText' @([string], [string]) ([Reflection.BindingFlags]'Public,Static')
$addCategory = Get-ExactMethod $intentType 'AddCategory' @([string])
$setType = Get-ExactMethod $intentType 'SetType' @([string])
$startActivityForResult = Get-ExactMethod $activityType 'StartActivityForResult' @($intentType, [int])
$pathCombine = Get-ExactMethod ([IO.Path]) 'Combine' @([string], [string]) ([Reflection.BindingFlags]'Public,Static')
$readAllText = Get-ExactMethod ([IO.File]) 'ReadAllText' @([string]) ([Reflection.BindingFlags]'Public,Static')
$getFileSystemEntries = Get-ExactMethod ([IO.Directory]) 'GetFileSystemEntries' @([string]) ([Reflection.BindingFlags]'Public,Static')
$stringConcat3 = Get-ExactMethod ([string]) 'Concat' @([string], [string], [string]) ([Reflection.BindingFlags]'Public,Static')

$stringBuilderType = [Text.StringBuilder]
$stringBuilderConstructor = Get-ExactConstructor $stringBuilderType @()
$appendString = Get-ExactMethod $stringBuilderType 'Append' @([string])
$appendLineString = Get-ExactMethod $stringBuilderType 'AppendLine' @([string])
$builderToString = Get-ExactMethod $stringBuilderType 'ToString' @()
$currentDomainProperty = Get-ExactProperty ([AppDomain]) 'CurrentDomain' ([Reflection.BindingFlags]'Public,Static')
$getAssemblies = Get-ExactMethod ([AppDomain]) 'GetAssemblies' @()
$assemblyFullNameProperty = Get-ExactProperty ([Reflection.Assembly]) 'FullName'
$assemblyLocationProperty = Get-ExactProperty ([Reflection.Assembly]) 'Location'
$packageNameProperty = Get-ExactProperty $contextType 'PackageName'
$manufacturerProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build') 'Manufacturer' ([Reflection.BindingFlags]'Public,Static')
$modelProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build') 'Model' ([Reflection.BindingFlags]'Public,Static')
$androidReleaseProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build+VERSION') 'Release' ([Reflection.BindingFlags]'Public,Static')
$androidSdkProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build+VERSION') 'SdkInt' ([Reflection.BindingFlags]'Public,Static')
$supportedAbisProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build') 'SupportedAbis' ([Reflection.BindingFlags]'Public,Static')
$frameworkDescriptionProperty = Get-ExactProperty ([Runtime.InteropServices.RuntimeInformation]) 'FrameworkDescription' ([Reflection.BindingFlags]'Public,Static')
$processArchitectureProperty = Get-ExactProperty ([Runtime.InteropServices.RuntimeInformation]) 'ProcessArchitecture' ([Reflection.BindingFlags]'Public,Static')
$osArchitectureProperty = Get-ExactProperty ([Runtime.InteropServices.RuntimeInformation]) 'OSArchitecture' ([Reflection.BindingFlags]'Public,Static')
$joinStrings = Get-ExactMethod ([string]) 'Join' @(
    [string], [Collections.Generic.IEnumerable[string]]) ([Reflection.BindingFlags]'Public,Static')

# Canonical parameters for the eventual ShowRecovery method body.
$activity = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
$title = [Linq.Expressions.Expression]::Parameter([string], 'title')
$details = [Linq.Expressions.Expression]::Parameter([string], 'details')
$retry = [Linq.Expressions.Expression]::Parameter([Action], 'retry')

function New-DpExpression {
    param([Parameter(Mandatory)][int] $Value)

    $metrics = New-ClrProperty (New-ClrProperty $activity $resourcesProperty) $displayMetricsProperty
    $dimension = New-ClrCall $null $applyDimension @(
        (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Dip')) $complexUnitType),
        (New-ClrConstant ([single]$Value) ([single])),
        $metrics)
    [Linq.Expressions.Expression]::Convert($dimension, [int])
}

function New-BuildClipboardPayloadLambda {
    $payloadActivity = $activity
    $payloadDetails = $details
    $profilePath = [Linq.Expressions.Expression]::Variable([string], 'profilePath')
    $profile = [Linq.Expressions.Expression]::Variable([string], 'profile')
    $privateRoot = [Linq.Expressions.Expression]::Variable([string], 'privateRoot')
    $builder = [Linq.Expressions.Expression]::Variable($stringBuilderType, 'report')
    $assemblies = [Linq.Expressions.Expression]::Variable([Reflection.Assembly[]], 'assemblies')
    $assemblyIndex = [Linq.Expressions.Expression]::Variable([int], 'assemblyIndex')
    $files = [Linq.Expressions.Expression]::Variable([string[]], 'privateFiles')
    $fileIndex = [Linq.Expressions.Expression]::Variable([int], 'fileIndex')

    function New-ReportLine {
        param([Linq.Expressions.Expression] $Value)
        New-ClrCall $builder $appendLineString @($Value)
    }
    function New-ReportText {
        param([Linq.Expressions.Expression] $Value)
        New-ClrCall $builder $appendString @($Value)
    }
    function New-ReportConstantLine {
        param([string] $Value)
        New-ReportLine (New-ClrConstant $Value ([string]))
    }
    function New-ObjectString {
        param([Linq.Expressions.Expression] $Value)
        $convertToString = Get-ExactMethod ([Convert]) 'ToString' @([object]) ([Reflection.BindingFlags]'Public,Static')
        New-ClrCall $null $convertToString @([Linq.Expressions.Expression]::Convert($Value, [object]))
    }

    $privateRootValue = New-ClrProperty (New-ClrProperty $payloadActivity $filesDirProperty) $absolutePathProperty
    $currentDomain = New-ClrProperty $null $currentDomainProperty

    $assembly = [Linq.Expressions.Expression]::ArrayIndex($assemblies, $assemblyIndex)
    $assemblyLocation = New-ClrProperty $assembly $assemblyLocationProperty
    $locationTry = [Linq.Expressions.Expression]::TryCatch(
        (New-ReportLine $assemblyLocation),
        ([Linq.Expressions.Expression]::Catch([Exception], (New-ReportConstantLine '<unavailable>'))))
    $assemblyLoopBreak = [Linq.Expressions.Expression]::Label('assembliesComplete')
    $assemblyLoopBody = New-ClrBlock @() @(
        (New-ReportText (New-ClrConstant '  ' ([string]))),
        (New-ReportLine (New-ClrProperty $assembly $assemblyFullNameProperty)),
        (New-ReportText (New-ClrConstant '    location: ' ([string]))),
        $locationTry,
        ([Linq.Expressions.Expression]::PostIncrementAssign($assemblyIndex)),
        [Linq.Expressions.Expression]::Empty())
    $assemblyLoop = [Linq.Expressions.Expression]::Loop(
        ([Linq.Expressions.Expression]::IfThenElse(
            ([Linq.Expressions.Expression]::LessThan(
                $assemblyIndex,
                ([Linq.Expressions.Expression]::ArrayLength($assemblies)))),
            $assemblyLoopBody,
            ([Linq.Expressions.Expression]::Break($assemblyLoopBreak)))),
        $assemblyLoopBreak)

    $file = [Linq.Expressions.Expression]::ArrayIndex($files, $fileIndex)
    $fileLoopBreak = [Linq.Expressions.Expression]::Label('filesComplete')
    $fileLoopBody = New-ClrBlock @() @(
        (New-ReportText (New-ClrConstant '  ' ([string]))),
        (New-ReportLine $file),
        ([Linq.Expressions.Expression]::PostIncrementAssign($fileIndex)),
        [Linq.Expressions.Expression]::Empty())
    $fileLoop = [Linq.Expressions.Expression]::Loop(
        ([Linq.Expressions.Expression]::IfThenElse(
            ([Linq.Expressions.Expression]::LessThan(
                $fileIndex,
                ([Linq.Expressions.Expression]::ArrayLength($files)))),
            $fileLoopBody,
            ([Linq.Expressions.Expression]::Break($fileLoopBreak)))),
        $fileLoopBreak)

    $profileTry = [Linq.Expressions.Expression]::TryCatch(
        (New-ClrBlock @() @(
            (New-ClrAssign $profile (New-ClrCall $null $readAllText @($profilePath))),
            (New-ReportLine $profile),
            (New-ReportConstantLine '--- Profile.ps1 END ---'))),
        ([Linq.Expressions.Expression]::Catch([Exception],
            (New-ReportConstantLine 'Profile.ps1: unavailable'))))

    $expressions = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
    $expressions.Add((New-ClrAssign $builder (New-ClrNew $stringBuilderConstructor @())))
    $expressions.Add((New-ClrAssign $privateRoot $privateRootValue))
    $expressions.Add((New-ClrAssign $profilePath (New-ClrCall $null $pathCombine @(
        $privateRoot,
        (New-ClrConstant 'Profile.ps1' ([string]))))))
    foreach ($line in @(
        'TERMINAL RECOVERY REPORT',
        '',
        'REQUEST TO OUTSIDE MODEL',
        'Diagnose the startup failure below and return a complete replacement Profile.ps1.',
        'The replacement must use the assemblies and files actually listed in this report.',
        '',
        'RUNTIME CONTRACT',
        'Profile.ps1 runs inside the Terminal process in a PowerShell runspace.',
        '$Activity is the live Android.App.Activity.',
        '$PSScriptRoot is the private app-files directory shown below.',
        'Sibling imported files can be referenced beneath $PSScriptRoot.',
        'IMPORT FILE copies a selected document into that private directory.',
        'RETRY disposes the failed application runtime and runs Profile.ps1 again.',
        '',
        'FAILURE DETAILS')) {
        $expressions.Add((New-ReportConstantLine $line))
    }
    $expressions.Add((New-ReportLine $payloadDetails))
    foreach ($line in @('', 'ENVIRONMENT')) { $expressions.Add((New-ReportConstantLine $line)) }

    foreach ($fact in @(
        @('privateRoot: ', $privateRoot),
        @('package: ', (New-ClrProperty $payloadActivity $packageNameProperty)),
        @('manufacturer: ', (New-ClrProperty $null $manufacturerProperty)),
        @('model: ', (New-ClrProperty $null $modelProperty)),
        @('android: ', (New-ClrProperty $null $androidReleaseProperty)),
        @('api: ', (New-ObjectString (New-ClrProperty $null $androidSdkProperty))),
        @('abis: ', (New-ClrCall $null $joinStrings @(
            (New-ClrConstant ',' ([string])),
            (New-ClrProperty $null $supportedAbisProperty)))),
        @('dotnet: ', (New-ClrProperty $null $frameworkDescriptionProperty)),
        @('processArchitecture: ', (New-ObjectString (New-ClrProperty $null $processArchitectureProperty))),
        @('osArchitecture: ', (New-ObjectString (New-ClrProperty $null $osArchitectureProperty))))) {
        $expressions.Add((New-ReportText (New-ClrConstant ([string]$fact[0]) ([string]))))
        $expressions.Add((New-ReportLine ([Linq.Expressions.Expression]$fact[1])))
    }

    $expressions.Add((New-ReportConstantLine ''))
    $expressions.Add((New-ReportConstantLine 'LOADED ASSEMBLIES'))
    $expressions.Add((New-ClrAssign $assemblies (New-ClrCall $currentDomain $getAssemblies @())))
    $expressions.Add((New-ClrAssign $assemblyIndex (New-ClrConstant 0 ([int]))))
    $expressions.Add($assemblyLoop)
    $expressions.Add((New-ReportConstantLine ''))
    $expressions.Add((New-ReportConstantLine 'PRIVATE FILES'))
    $expressions.Add((New-ClrAssign $files (New-ClrCall $null $getFileSystemEntries @($privateRoot))))
    $expressions.Add((New-ClrAssign $fileIndex (New-ClrConstant 0 ([int]))))
    $expressions.Add($fileLoop)
    $expressions.Add((New-ReportConstantLine ''))
    $expressions.Add((New-ReportConstantLine '--- Profile.ps1 BEGIN ---'))
    $expressions.Add($profileTry)
    $expressions.Add((New-ClrCall $builder $builderToString @()))

    $body = New-ClrBlock @(
        $profilePath, $profile, $privateRoot, $builder,
        $assemblies, $assemblyIndex, $files, $fileIndex) $expressions.ToArray()
    New-ClrLambda ([Func``3].MakeGenericType($activityType, [string], [string])) $body @($payloadActivity, $payloadDetails)
}

function New-CopyTextLambda {
    $copyActivity = [Linq.Expressions.Expression]::Parameter($activityType, 'copyActivity')
    $copyLabel = [Linq.Expressions.Expression]::Parameter([string], 'copyLabel')
    $copyText = [Linq.Expressions.Expression]::Parameter([string], 'copyText')
    $clipboard = [Linq.Expressions.Expression]::Variable($clipboardManagerType, 'clipboard')

    $service = New-ClrCall $copyActivity $getSystemService @(
        (New-ClrConstant ([string]$contextType.GetField('ClipboardService').GetValue($null)) ([string])))
    $assignClipboard = New-ClrAssign $clipboard ([Linq.Expressions.Expression]::Convert($service, $clipboardManagerType))
    $clip = New-ClrCall $null $newPlainText @($copyLabel, $copyText)
    $assignClip = New-ClrAssign (New-ClrProperty $clipboard $primaryClipProperty) $clip
    $body = New-ClrBlock @($clipboard) @($assignClipboard, $assignClip, [Linq.Expressions.Expression]::Empty())

    New-ClrLambda ([Action``3].MakeGenericType($activityType, [string], [string])) $body @(
        $copyActivity, $copyLabel, $copyText)
}

$buildClipboardPayload = New-BuildClipboardPayloadLambda
$copyText = New-CopyTextLambda

function New-CopyFailureHandler {
    $sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
    $eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
    $payload = New-ClrInvoke $buildClipboardPayload @($activity, $details)
    $body = New-ClrInvoke $copyText @(
        $activity,
        (New-ClrConstant 'Terminal startup failure' ([string])),
        $payload)
    New-ClrLambda $eventHandlerType $body @($sender, $eventArgs)
}

function New-ImportHandler {
    $sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
    $eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
    $picker = [Linq.Expressions.Expression]::Variable($intentType, 'picker')
    $action = [Linq.Expressions.Expression]::Field($null, $actionOpenDocumentField)
    $category = [Linq.Expressions.Expression]::Field($null, $categoryOpenableField)
    $body = New-ClrBlock @($picker) @(
        (New-ClrAssign $picker (New-ClrNew $intentConstructor @($action))),
        (New-ClrCall $picker $addCategory @($category)),
        (New-ClrCall $picker $setType @((New-ClrConstant '*/*' ([string])))),
        (New-ClrCall $activity $startActivityForResult @($picker, (New-ClrConstant 1001 ([int])))))
    New-ClrLambda $eventHandlerType $body @($sender, $eventArgs)
}

function New-RetryHandler {
    $sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
    $eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
    New-ClrLambda $eventHandlerType (New-ClrInvoke $retry @()) @($sender, $eventArgs)
}

function New-AndroidButton {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][Linq.Expressions.LambdaExpression] $Handler
    )

    $button = [Linq.Expressions.Expression]::Variable($buttonType, "button_$($Text.Replace(' ', '_'))")
    $parameters = [Linq.Expressions.Expression]::Variable($layoutParamsType, "buttonParams_$($Text.Replace(' ', '_'))")
    $body = New-ClrBlock @($button, $parameters) @(
        (New-ClrAssign $button (New-ClrNew $buttonConstructor @($activity))),
        (New-ClrAssign (New-ClrProperty $button $buttonTextProperty) (New-ClrConstant $Text ([string]))),
        (New-ClrCall $button $buttonAddClick @($Handler)),
        (New-ClrAssign $parameters (New-ClrNew $buttonLayoutParamsConstructor @(
            ([Linq.Expressions.Expression]::Field($null, $matchParentField)),
            ([Linq.Expressions.Expression]::Field($null, $wrapContentField))))),
        (New-ClrAssign (New-ClrProperty $parameters $topMarginProperty) (New-DpExpression 8)),
        (New-ClrCall $layout $addViewWithParams @($button, $parameters)),
        [Linq.Expressions.Expression]::Empty())
    $body
}

$layout = [Linq.Expressions.Expression]::Variable($linearLayoutType, 'layout')
$heading = [Linq.Expressions.Expression]::Variable($textViewType, 'heading')
$message = [Linq.Expressions.Expression]::Variable($textViewType, 'message')
$scroll = [Linq.Expressions.Expression]::Variable($scrollViewType, 'scroll')
$messageLayout = [Linq.Expressions.Expression]::Variable($layoutParamsType, 'messageLayout')
$padding = [Linq.Expressions.Expression]::Variable([int], 'padding')

$copyButton = New-AndroidButton 'COPY TO CLIPBOARD' (New-CopyFailureHandler)
$importButton = New-AndroidButton 'IMPORT FILE' (New-ImportHandler)
$retryButton = New-AndroidButton 'RETRY' (New-RetryHandler)

$vertical = New-ClrConstant ([Enum]::Parse($orientationType, 'Vertical')) $orientationType
$white = New-ClrProperty $null $whiteProperty
$root = New-ClrBlock @($layout, $heading, $message, $scroll, $messageLayout, $padding) @(
    (New-ClrAssign $layout (New-ClrNew $linearLayoutConstructor @($activity))),
    (New-ClrAssign (New-ClrProperty $layout $orientationProperty) $vertical),
    (New-ClrCall $layout $setBackgroundColor @((New-ClrCall $null $rgb @(
        (New-ClrConstant 11 ([int])),
        (New-ClrConstant 61 ([int])),
        (New-ClrConstant 46 ([int])))))),
    (New-ClrAssign $padding (New-DpExpression 24)),
    (New-ClrCall $layout $setPadding @($padding, $padding, $padding, $padding)),

    (New-ClrAssign $heading (New-ClrNew $textViewConstructor @($activity))),
    (New-ClrAssign (New-ClrProperty $heading $textViewTextProperty) $title),
    (New-ClrCall $heading $setTextColor @($white)),
    (New-ClrCall $heading $setTextSize @(
        (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Sp')) $complexUnitType),
        (New-ClrConstant ([single]64) ([single])))),
    (New-ClrCall $layout $addView @($heading)),

    (New-ClrAssign $message (New-ClrNew $textViewConstructor @($activity))),
    (New-ClrAssign (New-ClrProperty $message $textViewTextProperty) $details),
    (New-ClrCall $message $setTextIsSelectable @((New-ClrConstant $true ([bool])))),
    (New-ClrCall $message $setTextColor @($white)),
    (New-ClrCall $message $setTextSize @(
        (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Sp')) $complexUnitType),
        (New-ClrConstant ([single]15) ([single])))),

    (New-ClrAssign $scroll (New-ClrNew $scrollViewConstructor @($activity))),
    (New-ClrCall $scroll $scrollAddView @($message)),
    (New-ClrAssign $messageLayout (New-ClrNew $layoutParamsConstructor @(
        ([Linq.Expressions.Expression]::Field($null, $matchParentField)),
        (New-ClrConstant 0 ([int])),
        (New-ClrConstant ([single]1) ([single]))))),
    (New-ClrAssign (New-ClrProperty $messageLayout $topMarginProperty) (New-DpExpression 16)),
    (New-ClrAssign (New-ClrProperty $messageLayout $bottomMarginProperty) (New-DpExpression 16)),
    (New-ClrCall $layout $addViewWithParams @($scroll, $messageLayout)),

    ([Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::Equal($title, (New-ClrConstant ':(' ([string])))),
        $copyButton)),
    $importButton,
    $retryButton,
    (New-ClrCall $activity $setContentView @($layout)))

$visited = [Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
$dynamicNodes = 0
$callSiteConstants = 0
$callSiteReferences = 0

function Test-CallSiteType {
    param([AllowNull()][Type] $Type)

    if ($null -eq $Type) { return $false }
    if ($Type.IsArray -or $Type.IsByRef -or $Type.IsPointer) {
        return Test-CallSiteType ($Type.GetElementType())
    }
    if ($Type.IsGenericType -and
        $Type.GetGenericTypeDefinition().FullName -eq 'System.Runtime.CompilerServices.CallSite`1') {
        return $true
    }
    foreach ($argument in $Type.GetGenericArguments()) {
        if (Test-CallSiteType $argument) { return $true }
    }
    $false
}

function Visit-ExpressionGraph {
    param([AllowNull()] $Node)

    if ($null -eq $Node -or -not $visited.Add($Node)) { return }

    if ($Node -is [Linq.Expressions.Expression]) {
        $nodeTypeName = $Node.GetType().Name
        if ($Node -is [Linq.Expressions.DynamicExpression] -or $nodeTypeName -like 'TypedDynamicExpression*') {
            $script:dynamicNodes++
        }
        if (Test-CallSiteType $Node.Type) { $script:callSiteReferences++ }
        if ($Node -is [Linq.Expressions.ConstantExpression] -and $null -ne $Node.Value) {
            $valueType = $Node.Value.GetType()
            if (Test-CallSiteType $valueType) {
                $script:callSiteConstants++
            }
        }
        if ($Node -is [Linq.Expressions.MethodCallExpression]) {
            if ((Test-CallSiteType $Node.Method.DeclaringType) -or
                (Test-CallSiteType $Node.Method.ReturnType)) {
                $script:callSiteReferences++
            }
            foreach ($parameter in $Node.Method.GetParameters()) {
                if (Test-CallSiteType $parameter.ParameterType) { $script:callSiteReferences++ }
            }
        }
    }

    $namespace = $Node.GetType().Namespace
    if ($namespace -ne 'System.Linq.Expressions') { return }

    foreach ($property in $Node.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance')) {
        if ($property.GetIndexParameters().Length -ne 0) { continue }
        try { $value = $property.GetValue($Node) } catch { continue }
        if ($null -eq $value -or $value -is [string] -or $value -is [Type] -or
            $value -is [Reflection.MemberInfo]) { continue }
        if ($value -is [Linq.Expressions.Expression] -or
            $value.GetType().Namespace -eq 'System.Linq.Expressions') {
            Visit-ExpressionGraph $value
            continue
        }
        if ($value -is [Collections.IEnumerable]) {
            foreach ($item in $value) {
                if ($null -ne $item -and
                    ($item -is [Linq.Expressions.Expression] -or
                     $item.GetType().Namespace -eq 'System.Linq.Expressions')) {
                    Visit-ExpressionGraph $item
                }
            }
        }
    }
}

Visit-ExpressionGraph $root
if ($dynamicNodes -ne 0) { throw "Recovery graph contains $dynamicNodes dynamic expression node(s)." }
if ($callSiteConstants -ne 0) { throw "Recovery graph contains $callSiteConstants CallSite constant(s)." }
if ($callSiteReferences -ne 0) { throw "Recovery graph contains $callSiteReferences CallSite type reference(s)." }

$debugViewProperty = $expressionType.GetProperty(
    'DebugView', [Reflection.BindingFlags]'Instance,NonPublic')
if ($null -eq $debugViewProperty) { throw 'Expression.DebugView was not found.' }

"ROOT_NODE=$($root.NodeType)"
"ROOT_TYPE=$($root.Type.FullName)"
"DYNAMIC_NODES=$dynamicNodes"
"CALLSITE_CONSTANTS=$callSiteConstants"
'DEBUG_VIEW_BEGIN'
$debugViewProperty.GetValue($root)
'DEBUG_VIEW_END'

# Keep the graph available to callers that dot-source the builder.
$script:RecoveryTree = $root
$script:RecoveryTreeParameters = [ordered]@{
    Activity = $activity
    Title = $title
    Details = $details
    Retry = $retry
}
