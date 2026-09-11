#requires -Version 7.4
<#
USB AOA / WINDOWS SMA

Durable host-side Android Open Accessory negotiation cartridge.
Built from the proven LiuKang-LiveDoor-R4 handle path.

Shape:
    PRESENT Android ADB interface
        -> real DeviceClasses door
        -> File handle (overlapped)
        -> WinUsb_Initialize
        -> AOA GET_PROTOCOL
        -> optional SEND_STRING x6
        -> optional START_ACCESSORY
        -> FREE WinUSB
        -> CLOSE file handle
        -> only then wait for 18D1:2D00 / 18D1:2D01 re-enumeration

No Add-Type.
No C#.
No delegates.
No Marshal.
No sockets.
No persistent connection.

Usage:
    # Non-destructive proof only. Reads AOA protocol, then closes everything.
    .\UsbAoa.ps1

    # If adb.exe is already gone:
    .\UsbAoa.ps1 -Start

    # Explicitly ask this cartridge to stop the adb daemon first:
    .\UsbAoa.ps1 -Start -StopAdb

    # Multiple Android ADB interfaces present: choose the exact live PnP child.
    .\UsbAoa.ps1 -Start -StopAdb -DeviceInstance 'USB\VID_....'

AOA authority used by this cartridge:
    GET_PROTOCOL    request 51 / 0x33, vendor IN,  2-byte little-endian result
    SEND_STRING     request 52 / 0x34, vendor OUT, index 0..5, zero-terminated UTF-8
    START_ACCESSORY request 53 / 0x35, vendor OUT, no data
    AOA VID         0x18D1
    AOA PID         0x2D00 accessory, 0x2D01 accessory + ADB

The WinUSB file handle is opened asynchronous/overlapped because WinUsb_Initialize
requires an overlapped device handle. START_ACCESSORY deliberately does not keep
that handle alive across re-enumeration.
#>

[CmdletBinding()]
param(
    [switch] $Start,
    [switch] $StopAdb,

    [string] $DeviceInstance,

    [string] $Manufacturer = 'MansfieldPlumbing',
    [string] $Model        = 'AndroidSMA',
    [string] $Description  = 'SMA USB accessory',
    [string] $Version      = '1',
    [string] $Uri          = '',
    [string] $Serial       = 'AndroidSMA',

    [ValidateRange(0,30000)]
    [int] $WaitMilliseconds = 5000,

    [string] $AdbInterfaceGuid = '{F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# ALREADY AOA?
# -----------------------------------------------------------------------------

$aoaNow = @(
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match '^USB\\VID_18D1&PID_2D0[01](?:&|\\)'
        }
)

if ($aoaNow.Count -gt 0) {
    Write-Host 'USB AOA'
    Write-Host 'STATE   ACCESSORY'
    foreach ($d in $aoaNow) {
        Write-Host ('LIVE    {0}' -f $d.InstanceId)
    }
    return
}

# -----------------------------------------------------------------------------
# ADB OWNS THE SAME DOOR. NEVER KILL IT WITHOUT AN EXPLICIT SWITCH.
# -----------------------------------------------------------------------------

if ($StopAdb) {
    $adbCommand = Get-Command adb -ErrorAction SilentlyContinue
    if ($null -eq $adbCommand) {
        throw 'StopAdb was requested but adb.exe is not on PATH.'
    }

    & $adbCommand.Source kill-server | Out-Null
    Start-Sleep -Milliseconds 250
}

$adbLive = @(Get-Process adb -ErrorAction SilentlyContinue)
if ($adbLive.Count -gt 0) {
    throw 'adb.exe is running and may own the Android WinUSB interface. Run adb kill-server first, or rerun with -StopAdb.'
}

# -----------------------------------------------------------------------------
# PRESENT ADB DEVICE INTERFACE -> REAL WIN32 DOOR
# -----------------------------------------------------------------------------

$deviceClassRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$AdbInterfaceGuid"

if (-not (Test-Path -LiteralPath $deviceClassRoot)) {
    throw "ADB device-interface class is not registered: $AdbInterfaceGuid"
}

$present = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)

[string[]] $candidateInstance = @()
[string[]] $candidateDoor     = @()

foreach ($key in Get-ChildItem -LiteralPath $deviceClassRoot -ErrorAction Stop) {
    $property = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        continue
    }

    [string] $instance = $property.DeviceInstance
    if ([string]::IsNullOrWhiteSpace($instance)) {
        continue
    }

    if ($DeviceInstance -and $instance -ne $DeviceInstance) {
        continue
    }

    [bool] $isPresent = $false
    foreach ($device in $present) {
        if ($device.InstanceId -eq $instance) {
            $isPresent = $true
            break
        }
    }

    if (-not $isPresent) {
        continue
    }

    # DeviceClasses encodes only the leading \\?\ as ##?#.
    [string] $door = $key.PSChildName -replace '^##\?#', '\\?\'

    $candidateInstance += $instance
    $candidateDoor     += $door
}

if ($candidateDoor.Count -eq 0) {
    if ($DeviceInstance) {
        throw "No present ADB WinUSB door matches DeviceInstance '$DeviceInstance'."
    }
    throw 'No present Android ADB WinUSB door was found.'
}

if ($candidateDoor.Count -gt 1) {
    Write-Host 'Multiple present Android ADB doors:'
    for ($i = 0; $i -lt $candidateDoor.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f $i, $candidateInstance[$i])
    }
    throw 'More than one Android ADB interface is present. Rerun with -DeviceInstance <exact InstanceId>.'
}

[string] $instance = $candidateInstance[0]
[string] $door     = $candidateDoor[0]

Write-Host 'USB AOA'
Write-Host ('LIVE    {0}' -f $instance)
Write-Host ('DOOR    {0}' -f $door)

# -----------------------------------------------------------------------------
# OPEN EXACTLY ONCE. FILEOPTIONS.ASYNCHRONOUS => OVERLAPPED WIN32 HANDLE.
# -----------------------------------------------------------------------------

$dev = [IO.File]::OpenHandle(
    $door,
    [IO.FileMode]::Open,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::ReadWrite,
    [IO.FileOptions]::Asynchronous
)

[uint16] $protocol       = 0
[uint32] $startError     = 0
[bool]   $startCallGreen = $false

try {
    [IntPtr] $h = $dev.DangerousGetHandle()
    Write-Host ('PC      0x{0:X}' -f $h.ToInt64())

    # -------------------------------------------------------------------------
    # extern C DECLARATIONS ONLY.
    # Unique dynamic assembly name means this file can be run repeatedly in one
    # pwsh process without type-name collisions.
    # -------------------------------------------------------------------------

    [string] $suffix = [Guid]::NewGuid().ToString('N')

    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new("UsbAoa.Native.$suffix"),
        [Reflection.Emit.AssemblyBuilderAccess]::Run
    )

    $module = $assembly.DefineDynamicModule("UsbAoa.Native.$suffix")

    $type = $module.DefineType(
        "UsbAoa.Native_$suffix",
        [Reflection.TypeAttributes]'Public,Abstract,Sealed'
    )

    $flags = [Reflection.MethodAttributes]'Public,Static,PinvokeImpl'
    $cc    = [Runtime.InteropServices.CallingConvention]::Winapi
    $cs    = [Runtime.InteropServices.CharSet]::None

    $method = $type.DefinePInvokeMethod(
        'GetLastError',
        'kernel32.dll',
        'GetLastError',
        $flags,
        [Reflection.CallingConventions]::Standard,
        [uint32],
        [Type[]]::new(0),
        $cc,
        $cs
    )
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

    $method = $type.DefinePInvokeMethod(
        'WinUsb_Initialize',
        'winusb.dll',
        'WinUsb_Initialize',
        $flags,
        [Reflection.CallingConventions]::Standard,
        [int32],
        [Type[]]@([IntPtr],[IntPtr]),
        $cc,
        $cs
    )
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

    # WINUSB_SETUP_PACKET is exactly 8 bytes. R4 proved that passing its packed
    # little-endian bits as uint64 gives WinUSB the required by-value packet.
    $method = $type.DefinePInvokeMethod(
        'WinUsb_ControlTransfer',
        'winusb.dll',
        'WinUsb_ControlTransfer',
        $flags,
        [Reflection.CallingConventions]::Standard,
        [int32],
        [Type[]]@(
            [IntPtr],
            [uint64],
            [IntPtr],
            [uint32],
            [IntPtr],
            [IntPtr]
        ),
        $cc,
        $cs
    )
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

    $method = $type.DefinePInvokeMethod(
        'WinUsb_Free',
        'winusb.dll',
        'WinUsb_Free',
        $flags,
        [Reflection.CallingConventions]::Standard,
        [int32],
        [Type[]]@([IntPtr]),
        $cc,
        $cs
    )
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

    $Native = $type.CreateType()

    # -------------------------------------------------------------------------
    # HANDLE -> WINUSB HANDLE
    # -------------------------------------------------------------------------

    [IntPtr[]] $usbOut = [IntPtr[]]::new(1)
    $usbPin = [Runtime.InteropServices.GCHandle]::Alloc(
        $usbOut,
        [Runtime.InteropServices.GCHandleType]::Pinned
    )

    [IntPtr] $usb = [IntPtr]::Zero

    try {
        [int32] $ok = $Native::WinUsb_Initialize(
            $h,
            $usbPin.AddrOfPinnedObject()
        )

        if ($ok -eq 0) {
            [uint32] $e = $Native::GetLastError()
            throw ('WINUSB {0} : {1}' -f $e, ([ComponentModel.Win32Exception]::new([int]$e).Message))
        }

        $usb = $usbOut[0]
        Write-Host ('USB     0x{0:X}' -f $usb.ToInt64())

        # ---------------------------------------------------------------------
        # GET_PROTOCOL
        # setup bytes: C0 33 00 00 00 00 02 00
        # ---------------------------------------------------------------------

        [uint64] $setupGetProtocol =
            ([uint64]0xC0) `
            -bor (([uint64]0x33) -shl 8) `
            -bor (([uint64]2)    -shl 48)

        [byte[]]   $answer = [byte[]]::new(2)
        [uint32[]] $n      = [uint32[]]::new(1)

        $answerPin = [Runtime.InteropServices.GCHandle]::Alloc(
            $answer,
            [Runtime.InteropServices.GCHandleType]::Pinned
        )

        $nPin = [Runtime.InteropServices.GCHandle]::Alloc(
            $n,
            [Runtime.InteropServices.GCHandleType]::Pinned
        )

        try {
            Write-Host 'KANG    GET_PROTOCOL ->'

            $n[0] = 0
            $ok = $Native::WinUsb_ControlTransfer(
                $usb,
                $setupGetProtocol,
                $answerPin.AddrOfPinnedObject(),
                2,
                $nPin.AddrOfPinnedObject(),
                [IntPtr]::Zero
            )

            if ($ok -eq 0) {
                [uint32] $e = $Native::GetLastError()
                throw ('GET_PROTOCOL {0} : {1}' -f $e, ([ComponentModel.Win32Exception]::new([int]$e).Message))
            }

            if ($n[0] -ne 2) {
                throw "GET_PROTOCOL returned $($n[0]) bytes; expected 2."
            }

            $protocol = [BitConverter]::ToUInt16($answer,0)
            if ($protocol -eq 0) {
                throw 'Android returned AOA protocol 0.'
            }

            Write-Host ('PROTO   {0}' -f $protocol)

            if ($Start) {

            # -----------------------------------------------------------------
            # SEND_STRING 0..5
            # Each is UTF-8 + NUL and <=256 bytes including terminator.
            # -----------------------------------------------------------------

            [string[]] $identity = @(
                $Manufacturer,
                $Model,
                $Description,
                $Version,
                $Uri,
                $Serial
            )

            for ([int] $index = 0; $index -lt $identity.Length; $index++) {
                [string] $text = $identity[$index]
                if ($null -eq $text) {
                    $text = ''
                }

                if ($text.IndexOf([char]0) -ge 0) {
                    throw "AOA identity string index $index contains an embedded NUL."
                }

                [byte[]] $raw = [Text.Encoding]::UTF8.GetBytes($text)
                if (($raw.Length + 1) -gt 256) {
                    throw "AOA identity string index $index is $($raw.Length + 1) bytes including NUL; max is 256."
                }

                [byte[]] $z = [byte[]]::new($raw.Length + 1)
                if ($raw.Length -gt 0) {
                    [Buffer]::BlockCopy($raw,0,$z,0,$raw.Length)
                }

                [uint16] $wireLength = [uint16]$z.Length
                [uint16] $wireIndex  = [uint16]$index

                [uint64] $setupSendString =
                    ([uint64]0x40) `
                    -bor (([uint64]0x34)       -shl 8) `
                    -bor (([uint64]$wireIndex) -shl 32) `
                    -bor (([uint64]$wireLength)-shl 48)

                $zPin = [Runtime.InteropServices.GCHandle]::Alloc(
                    $z,
                    [Runtime.InteropServices.GCHandleType]::Pinned
                )

                try {
                    $n[0] = 0
                    $ok = $Native::WinUsb_ControlTransfer(
                        $usb,
                        $setupSendString,
                        $zPin.AddrOfPinnedObject(),
                        [uint32]$z.Length,
                        $nPin.AddrOfPinnedObject(),
                        [IntPtr]::Zero
                    )

                    if ($ok -eq 0) {
                        [uint32] $e = $Native::GetLastError()
                        throw ('SEND_STRING[{0}] {1} : {2}' -f $index, $e, ([ComponentModel.Win32Exception]::new([int]$e).Message))
                    }

                    if ($n[0] -ne $z.Length) {
                        throw "SEND_STRING[$index] transferred $($n[0])/$($z.Length) bytes."
                    }

                    Write-Host ('STRING  {0}  {1} bytes' -f $index, $n[0])
                }
                finally {
                    $zPin.Free()
                }
            }

            # -----------------------------------------------------------------
            # START_ACCESSORY
            # setup bytes: 40 35 00 00 00 00 00 00
            # The device may disappear immediately after accepting this request.
            # Record the call result, but do not keep the old interface alive.
            # -----------------------------------------------------------------

            [uint64] $setupStart =
                ([uint64]0x40) `
                -bor (([uint64]0x35) -shl 8)

            Write-Host 'KANG    START_ACCESSORY ->'

            $ok = $Native::WinUsb_ControlTransfer(
                $usb,
                $setupStart,
                [IntPtr]::Zero,
                0,
                [IntPtr]::Zero,
                [IntPtr]::Zero
            )

            if ($ok -eq 0) {
                $startError = $Native::GetLastError()
            }
            else {
                $startCallGreen = $true
            }
            }
        }
        finally {
            $nPin.Free()
            $answerPin.Free()
        }
    }
    finally {
        if ($usb -ne [IntPtr]::Zero) {
            [void]$Native::WinUsb_Free($usb)
        }
        $usbPin.Free()
    }
}
finally {
    $dev.Dispose()
}

Write-Host 'CLOSED  ADB door + WinUSB handle'

if (-not $Start) {
    return
}

# -----------------------------------------------------------------------------
# OLD DOOR IS DEAD/CLOSED. NOW WATCH THE BUS FOR THE NEW AOA INCARNATION.
# -----------------------------------------------------------------------------

$deadline = [Environment]::TickCount64 + [int64]$WaitMilliseconds
$aoa = @()

do {
    $aoa = @(
        Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InstanceId -match '^USB\\VID_18D1&PID_2D0[01](?:&|\\)'
            }
    )

    if ($aoa.Count -gt 0) {
        break
    }

    if ([Environment]::TickCount64 -ge $deadline) {
        break
    }

    Start-Sleep -Milliseconds 100
}
while ($true)

if ($aoa.Count -gt 0) {
    Write-Host 'STATE   ACCESSORY'
    foreach ($d in $aoa) {
        Write-Host ('AOA     {0}' -f $d.InstanceId)
    }
    Write-Host 'PASS    True'
    return
}

if (-not $startCallGreen) {
    throw ('START_ACCESSORY returned false ({0}: {1}) and no AOA re-enumeration was observed.' -f $startError, ([ComponentModel.Win32Exception]::new([int]$startError).Message))
}

Write-Host 'START   accepted'
Write-Host ('WAIT    no 18D1:2D00/2D01 device observed within {0} ms' -f $WaitMilliseconds)
Write-Host 'PASS    Start request sent; re-enumeration not proven'
