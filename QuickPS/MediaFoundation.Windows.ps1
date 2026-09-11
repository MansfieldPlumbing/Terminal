[CmdletBinding()]
param()

if ($MyInvocation.InvocationName -eq '.') {
    throw 'MediaFoundation.Windows.ps1 must be invoked with &, not dot-sourced.'
}

$MediaFoundation = & {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('QuickPS.MediaFoundation.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('Native')
    $types = [Collections.Generic.Dictionary[string,Type]]::new()
    $calls = [Collections.Generic.Dictionary[string,Delegate]]::new()
    $nativeCall = ({
        param([IntPtr] $Address, [Type] $ReturnType, [Type[]] $ParameterTypes)
        $signature = $ReturnType.FullName + ':' + (($ParameterTypes | ForEach-Object FullName) -join ',')
        if (-not $types.ContainsKey($signature)) {
            $builder = $module.DefineType('Call_' + [Guid]::NewGuid().ToString('N'), 'Class,Public,Sealed', [MulticastDelegate])
            $constructor = $builder.DefineConstructor('Public,HideBySig,RTSpecialName', [Reflection.CallingConventions]::Standard, @([object],[IntPtr]))
            $constructor.SetImplementationFlags('Runtime,Managed')
            $invoke = $builder.DefineMethod('Invoke', 'Public,HideBySig,NewSlot,Virtual', $ReturnType, $ParameterTypes)
            $invoke.SetImplementationFlags('Runtime,Managed')
            $attribute = [Reflection.Emit.CustomAttributeBuilder]::new(
                [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(@([Runtime.InteropServices.CallingConvention])),
                @([Runtime.InteropServices.CallingConvention]::StdCall))
            $builder.SetCustomAttribute($attribute)
            $types[$signature] = $builder.CreateType()
        }
        $key = $Address.ToInt64().ToString() + ':' + $signature
        if (-not $calls.ContainsKey($key)) {
            $calls[$key] = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($Address, $types[$signature])
        }
        $calls[$key]
    }).GetNewClosure()
    $exportCall = ({
        param([IntPtr] $Library, [string] $Name, [Type] $ReturnType, [Type[]] $ParameterTypes)
        & $nativeCall ([Runtime.InteropServices.NativeLibrary]::GetExport($Library, $Name)) $ReturnType $ParameterTypes
    }).GetNewClosure()
    $comCall = ({
        param([IntPtr] $Object, [int] $Slot, [Type] $ReturnType, [object[]] $Arguments, [Type[]] $ParameterTypes)
        $vtable = [Runtime.InteropServices.Marshal]::ReadIntPtr($Object)
        $address = [Runtime.InteropServices.Marshal]::ReadIntPtr($vtable, $Slot * [IntPtr]::Size)
        $call = & $nativeCall $address $ReturnType (@([IntPtr]) + $ParameterTypes)
        $call.DynamicInvoke(@($Object) + $Arguments)
    }).GetNewClosure()
    $allocate = ({
        param([int] $Bytes)
        $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
        for ($index = 0; $index -lt $Bytes; $index++) { [Runtime.InteropServices.Marshal]::WriteByte($pointer, $index, 0) }
        $pointer
    }).GetNewClosure()

    $mfplat = [Runtime.InteropServices.NativeLibrary]::Load('mfplat.dll')
    $mf = [Runtime.InteropServices.NativeLibrary]::Load('mf.dll')
    $startup = & $exportCall $mfplat 'MFStartup' ([int32]) @([uint32], [uint32])
    $shutdown = & $exportCall $mfplat 'MFShutdown' ([int32]) @()
    $createAttributes = & $exportCall $mfplat 'MFCreateAttributes' ([int32]) @([IntPtr], [uint32])
    $createMediaType = & $exportCall $mfplat 'MFCreateMediaType' ([int32]) @([IntPtr])
    $enumDeviceSources = & $exportCall $mf 'MFEnumDeviceSources' ([int32]) @([IntPtr], [IntPtr], [IntPtr])
    $ole32 = [Runtime.InteropServices.NativeLibrary]::Load('ole32.dll')
    $coTaskMemFree = & $exportCall $ole32 'CoTaskMemFree' ([void]) @([IntPtr])

    $guidBlock = ({
        param([Guid] $Guid)
        $pointer = & $allocate 16
        [Runtime.InteropServices.Marshal]::Copy($Guid.ToByteArray(), 0, $pointer, 16)
        $pointer
    }).GetNewClosure()

    {
        $hr = [int32]$startup.DynamicInvoke([uint32]0x00020070, [uint32]0)
        if ($hr -lt 0) { throw ("MFStartup failed: 0x{0:X8}" -f [uint32]$hr) }

        $instance = [PSCustomObject]@{
            PSTypeName = 'QuickPS.MediaFoundation'
            Started = $true
            ShutdownCall = $shutdown
            CreateAttributesCall = $createAttributes
            CreateMediaTypeCall = $createMediaType
            EnumDeviceSourcesCall = $enumDeviceSources
            CoTaskMemFreeCall = $coTaskMemFree
            GuidBlock = $guidBlock
            Allocate = $allocate
            ComCall = $comCall
        }

        $instance | Add-Member ScriptMethod CreateAttributes ({
            param([uint32] $InitialSize = 4)
            $output = & $this.Allocate ([IntPtr]::Size)
            try {
                $hr = [int32]$this.CreateAttributesCall.DynamicInvoke($output, $InitialSize)
                $pointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($output)
            }
            finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($output) }
            if ($hr -lt 0 -or $pointer -eq [IntPtr]::Zero) { throw ("MFCreateAttributes failed: 0x{0:X8}" -f [uint32]$hr) }
            $pointer
        }.GetNewClosure())

        $instance | Add-Member ScriptMethod CreateMediaType ({
            $output = & $this.Allocate ([IntPtr]::Size)
            try {
                $hr = [int32]$this.CreateMediaTypeCall.DynamicInvoke($output)
                $pointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($output)
            }
            finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($output) }
            if ($hr -lt 0 -or $pointer -eq [IntPtr]::Zero) { throw ("MFCreateMediaType failed: 0x{0:X8}" -f [uint32]$hr) }
            $pointer
        }.GetNewClosure())

        $instance | Add-Member ScriptMethod SetGuid ({
            param([IntPtr] $Attributes, [Guid] $Key, [Guid] $Value)
            $keyPointer = & $this.GuidBlock $Key
            $valuePointer = & $this.GuidBlock $Value
            try {
                $hr = [int32](& $this.ComCall $Attributes 24 ([int32]) @($keyPointer, $valuePointer) @([IntPtr], [IntPtr]))
            }
            finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($keyPointer); [Runtime.InteropServices.Marshal]::FreeHGlobal($valuePointer) }
            if ($hr -lt 0) { throw ("IMFAttributes::SetGUID failed: 0x{0:X8}" -f [uint32]$hr) }
        }.GetNewClosure())

        $instance | Add-Member ScriptMethod EnumerateVideoDevices ({
            $attributes = $this.CreateAttributes(1)
            $activatesOut = & $this.Allocate ([IntPtr]::Size)
            $countOut = & $this.Allocate 4
            $activates = [IntPtr]::Zero
            try {
                $this.SetGuid(
                    $attributes,
                    [Guid]'c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3',
                    [Guid]'8ac3587a-4ae7-42d8-99e0-0a6013eef90f')
                $hr = [int32]$this.EnumDeviceSourcesCall.DynamicInvoke($attributes, $activatesOut, $countOut)
                $activates = [Runtime.InteropServices.Marshal]::ReadIntPtr($activatesOut)
                $count = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($countOut)
                if ($hr -lt 0) { throw ("MFEnumDeviceSources failed: 0x{0:X8}" -f [uint32]$hr) }
                $result = [IntPtr[]]::new($count)
                for ($index = 0; $index -lt $count; $index++) {
                    $result[$index] = [Runtime.InteropServices.Marshal]::ReadIntPtr($activates, $index * [IntPtr]::Size)
                }
                $result
            }
            finally {
                if ($activates -ne [IntPtr]::Zero) { [void]$this.CoTaskMemFreeCall.DynamicInvoke($activates) }
                [void](& $this.ComCall $attributes 2 ([uint32]) @() @())
                [Runtime.InteropServices.Marshal]::FreeHGlobal($activatesOut)
                [Runtime.InteropServices.Marshal]::FreeHGlobal($countOut)
            }
        }.GetNewClosure())

        $instance | Add-Member ScriptMethod Dispose ({
            if (-not $this.Started) { return }
            $hr = [int32]$this.ShutdownCall.DynamicInvoke()
            $this.Started = $false
            if ($hr -lt 0) { throw ("MFShutdown failed: 0x{0:X8}" -f [uint32]$hr) }
        }.GetNewClosure())

        $instance
    }.GetNewClosure()
}

& $MediaFoundation
