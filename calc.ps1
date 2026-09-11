#requires -Version 7.0
param(
    [switch] $Headless,
    [string] $HostPath
)

# Host bootstrap is application-generic path discovery. It does not depend
# on the current working directory and does not create an application runtime.
$calculatorHeadless = [bool]$Headless

function Write-HostPanel {
    param([Parameter(Mandatory)][string[]] $Lines)

    $esc = [char]27
    $rev = "$esc[7m"
    $rst = "$esc[0m"
    $maxW = ($Lines | Measure-Object -Property Length -Maximum).Maximum + 2

    Write-Host ""
    foreach ($line in $Lines) {
        Write-Host "$rev  $($line.PadRight($maxW))$rst"
    }
    Write-Host ""
}

function Wait-HostFailureAcknowledge {
    if ([Environment]::UserInteractive -and -not $calculatorHeadless -and -not $env:DP_HEADLESS) {
        [void](Read-Host "Press Enter to exit")
    }
}

$dpAttempts = [Collections.Generic.List[string]]::new()
$explicitOverride = $PSBoundParameters.ContainsKey('HostPath')
$callerOverride = $null
if (-not $explicitOverride) {
    $callerVariable = Get-Variable -Name HOST_PATH -ErrorAction SilentlyContinue
    if ($null -ne $callerVariable) { $callerOverride = [string]$callerVariable.Value }
}

$dpCandidates = [Collections.Generic.List[string]]::new()
if ($explicitOverride) { $dpCandidates.Add($HostPath) }
elseif (-not [string]::IsNullOrWhiteSpace($callerOverride)) { $dpCandidates.Add($callerOverride) }
elseif (-not [string]::IsNullOrWhiteSpace($env:HOST_PATH)) { $dpCandidates.Add($env:HOST_PATH) }
else {
    $dpCandidates.Add((Join-Path $PSScriptRoot 'quips.ps1'))
    $dpCandidates.Add((Join-Path (Split-Path $PSScriptRoot -Parent) 'quips.ps1'))
}

$dpPath = $null
foreach ($candidate in $dpCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { $dpAttempts.Add('<empty>'); continue }
    $canonical = [IO.Path]::GetFullPath($candidate)
    $dpAttempts.Add($canonical)
    if (Test-Path -LiteralPath $canonical -PathType Leaf) { $dpPath = (Get-Item -LiteralPath $canonical).FullName; break }
}

if (-not $dpPath) {
    $kind = if ($explicitOverride) { 'Explicit -HostPath is invalid.' } else { 'quips.ps1 was not found.' }
    throw "$kind Attempted: $($dpAttempts -join '; ')"
}

try {
    $attachmentContext = Get-Variable -Name ScriptContext -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $attachmentContext -and $attachmentContext.AttachedToExistingHost -and $null -eq $attachmentContext.Host) {
        throw "Calculator requires owner dispatch for Host capabilities from execution placement '$($attachmentContext.ExecutionPlacement)'."
    }
    if ($null -ne $attachmentContext -and $null -ne $attachmentContext.Host) {
        $loadedRoot = $attachmentContext.Host
        $global:HostRuntime = $loadedRoot
        $dpPath = [IO.Path]::GetFullPath([string]$attachmentContext.HostPath)
    } else {
        $loadedRoot = Get-Variable -Name HostRuntime -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    }
    if ($null -ne $loadedRoot -and $null -ne $loadedRoot.PSObject.Properties['SourcePath']) {
        if (-not [IO.Path]::GetFullPath([string]$loadedRoot.SourcePath).Equals($dpPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "A different Host runtime substrate is already loaded: $($loadedRoot.SourcePath)"
        }
    } else {
        . $dpPath -Headless
    }

    if ($null -eq $global:HostRuntime -or $null -eq $global:HostRuntime.NewCanvas) {
        throw 'quips.ps1 loaded, but its Canvas capability was not retained.'
    }
    $canvasFactory = $global:HostRuntime.NewCanvas
    if ($null -ne $attachmentContext -and $null -ne $attachmentContext.Node) {
        $canvasEntry = $attachmentContext.Node.ResolveLocal('Canvas.New')
        if ($null -eq $canvasEntry) { throw 'The attached script node has no local Canvas capability.' }
        $canvasFactory = $canvasEntry.Capability
    }
}
catch {
    $errorMessage = ($_.Exception.Message -replace '\r?\n', ' ')
    $errorType = $_.Exception.GetType().FullName
    $errorLine = $_.InvocationInfo.ScriptLineNumber

    $errReport = @(
        ' calc.ps1 startup failure '
        " Host        $dpPath "
        " Type        $errorType "
        " Message     $errorMessage "
        " Line        $errorLine "
    )
    Write-HostPanel $errReport

    # Save to TEMP and clipboard
    $errDump = "$env:TEMP\quips_error_calc.txt"
    ($_ | Out-String) | Set-Content $errDump -Encoding utf8 -ErrorAction SilentlyContinue
    Set-Clipboard -Value ($_ | Out-String) -ErrorAction SilentlyContinue

    Wait-HostFailureAcknowledge
    throw
}

class ButtonDef {
    [string] $Label
    [string] $Type  # 'num', 'fn', 'op'
    [int]    $GridX
    [int]    $GridY
    [int]    $W
    [int]    $H

    ButtonDef([string]$label, [string]$type, [int]$gx, [int]$gy, [int]$w, [int]$h) {
        $this.Label = $label; $this.Type  = $type
        $this.GridX = $gx;    $this.GridY = $gy
        $this.W     = $w;     $this.H     = $h
    }
}

$script:Buttons = @(
    [ButtonDef]::new("C",  "fn", 0, 0, 1, 1),
    [ButtonDef]::new([char]0x00B1, "fn", 1, 0, 1, 1),
    [ButtonDef]::new("%",  "fn", 2, 0, 1, 1),
    [ButtonDef]::new([char]0x00F7, "op", 3, 0, 1, 1),
    [ButtonDef]::new("7",  "num", 0, 1, 1, 1),
    [ButtonDef]::new("8",  "num", 1, 1, 1, 1),
    [ButtonDef]::new("9",  "num", 2, 1, 1, 1),
    [ButtonDef]::new([char]0x00D7, "op", 3, 1, 1, 1),
    [ButtonDef]::new("4",  "num", 0, 2, 1, 1),
    [ButtonDef]::new("5",  "num", 1, 2, 1, 1),
    [ButtonDef]::new("6",  "num", 2, 2, 1, 1),
    [ButtonDef]::new([char]0x2212, "op", 3, 2, 1, 1),
    [ButtonDef]::new("1",  "num", 0, 3, 1, 1),
    [ButtonDef]::new("2",  "num", 1, 3, 1, 1),
    [ButtonDef]::new("3",  "num", 2, 3, 1, 1),
    [ButtonDef]::new("+",  "op", 3, 3, 1, 1),
    [ButtonDef]::new("0",  "num", 0, 4, 2, 1),
    [ButtonDef]::new(".",  "num", 2, 4, 1, 1),
    [ButtonDef]::new("=",  "op", 3, 4, 1, 1)
)

class CalculatorState {
    [string] $DisplayValue   = "0"
    [string] $EquationString = ""
    [object] $PrevValue      = $null
    [string] $ActiveOp       = $null
    [bool]   $ResetOnNext    = $false
    [string] $HoveredButton  = $null
    [string] $PressedButton  = $null
    [bool]   $CloseHover     = $false
    [bool]   $MinHover       = $false
    [single] $MouseX         = -1000.0
    [single] $MouseY         = -1000.0
    [single] $Width          = 340.0
    [single] $Height         = 520.0
    [bool]   $RenderRequested = $true
    [string] $LastOp         = $null
    [double] $LastOperand    = 0.0
    [bool]   $HasLastRepeat  = $false
}

function Invoke-CalculatorLogic([CalculatorState]$state, [string]$label, [string]$type) {
    if ($type -eq 'num') {
        if ($state.DisplayValue -eq '0' -or $state.ResetOnNext) {
            $state.DisplayValue = if ($label -eq '.') { '0.' } else { $label }
            $state.ResetOnNext = $false
        } else {
            if ($label -eq '.' -and $state.DisplayValue.Contains('.')) { return }
            $state.DisplayValue += $label
        }
        $state.HasLastRepeat = $false
    } elseif ($type -eq 'fn') {
        if ($label -eq 'C') {
            $state.DisplayValue   = '0'
            $state.EquationString = ''
            $state.PrevValue      = $null
            $state.ActiveOp       = $null
            $state.ResetOnNext    = $false
            $state.LastOp         = $null
            $state.HasLastRepeat  = $false
        } elseif ($label -eq [char]0x00B1) {
            $val = [double]::Parse($state.DisplayValue)
            $state.DisplayValue = (-$val).ToString()
        } elseif ($label -eq '%') {
            $val = [double]::Parse($state.DisplayValue) / 100.0
            $state.DisplayValue = $val.ToString()
        }
    } elseif ($type -eq 'op') {
        if ($label -eq '=') {
            if ($null -ne $state.ActiveOp -and $null -ne $state.PrevValue) {
                $v1 = [double]$state.PrevValue
                $v2 = [double]::Parse($state.DisplayValue)
                $state.LastOp = $state.ActiveOp
                $state.LastOperand = $v2
                $state.HasLastRepeat = $true
                $res = switch ($state.ActiveOp) {
                    '+'            { $v1 + $v2 }
                    ([char]0x2212) { $v1 - $v2 }
                    ([char]0x00D7) { $v1 * $v2 }
                    ([char]0x00F7) { if ($v2 -eq 0) { 0.0 } else { $v1 / $v2 } }
                    default        { $v2 }
                }
                $state.EquationString = "$v1 $($state.ActiveOp) $v2 ="
                $state.DisplayValue = $res.ToString()
                $state.PrevValue = $null
                $state.ActiveOp = $null
                $state.ResetOnNext = $true
            } elseif ($state.HasLastRepeat -and $null -ne $state.LastOp) {
                $v1 = [double]::Parse($state.DisplayValue)
                $v2 = $state.LastOperand
                $op = $state.LastOp
                $res = switch ($op) {
                    '+'            { $v1 + $v2 }
                    ([char]0x2212) { $v1 - $v2 }
                    ([char]0x00D7) { $v1 * $v2 }
                    ([char]0x00F7) { if ($v2 -eq 0) { 0.0 } else { $v1 / $v2 } }
                    default        { $v2 }
                }
                $state.EquationString = "$v1 $op $v2 ="
                $state.DisplayValue = $res.ToString()
                $state.ResetOnNext = $true
            }
        } else {
            $state.PrevValue = [double]::Parse($state.DisplayValue)
            $state.ActiveOp = $label
            $state.EquationString = "$($state.DisplayValue) $label"
            $state.ResetOnNext = $true
            $state.HasLastRepeat = $false
        }
    }
}

function Render-CalculatorWidget($canvas, [CalculatorState]$state) {
    $w = $state.Width
    $h = $state.Height

    # 1. Clear target with transparent background to let Mica shine through
    [void]$canvas.BeginDraw(0x00000000)

    # Centered Card Layout
    $devW = [single]$w
    $devH = [single]$h
    $devX = [single]0.0
    $devY = [single]0.0

    $screenH = [single]($devH * 0.20)
    $padY    = [single]($devY + $screenH + 20.0)
    $padH    = [single]($devH - $screenH - 32.0)

    # 2. Card Body: Translucent Mica acrylic tint (85% opacity dark acrylic)
    $canvas.FillRect($devX, $devY, $devW, $devH, 0xD9202020, 12.0)
    $canvas.DrawRect($devX, $devY, $devW, $devH, 0x26FFFFFF, 1.0, 12.0)

    # 3. Windows 11 Edge-Flush Caption Controls (Minimize & Close)
    $capW = [single]46.0
    $capH = [single]32.0
    $clsX = [single]($w - $capW)
    $minX = [single]($w - ($capW * 2.0))

    # Minimize Button
    if ($state.MinHover) {
        $canvas.FillRect($minX, 0.0, $capW, $capH, 0x26FFFFFF, 0.0)
    }
    $minColor = if ($state.MinHover) { 0xFFFFFFFF } else { 0x80FFFFFF }
    $canvas.FillRect($minX + 18.0, 15.0, 10.0, 1.0, $minColor, 0.0)

    # Close Button
    if ($state.CloseHover) {
        $canvas.FillRect($clsX, 0.0, $capW, $capH, 0xFFE81123, 0.0)
        $canvas.DrawText([char]0x2715, $clsX + 18.0, 9.0, 16.0, 16.0, 0xFFFFFFFF, 11.0, "Segoe UI", $false)
    } else {
        $canvas.DrawText([char]0x2715, $clsX + 18.0, 9.0, 16.0, 16.0, 0x80FFFFFF, 11.0, "Segoe UI", $false)
    }

    # 4. LCD Display Plate
    $scrX = [single]($devX + 12.0)
    $scrY = [single]($devY + 38.0)
    $scrW = [single]($devW - 24.0)
    $actualScreenH = [single]($screenH - 14.0)

    $canvas.FillRect($scrX, $scrY, $scrW, $actualScreenH, 0x99141414, 8.0)
    $canvas.DrawRect($scrX, $scrY, $scrW, $actualScreenH, 0x14FFFFFF, 1.0, 8.0)

    # Equation String (Top-Right of Plate)
    $eqText = if ([string]::IsNullOrEmpty($state.EquationString)) { " " } else { $state.EquationString }
    $mEq = $canvas.MeasureText($eqText, 11.0, "Segoe UI", $false)
    $canvas.DrawText($eqText, [single]($scrX + $scrW - $mEq.Width - 12.0), [single]($scrY + 8.0), $mEq.Width + 4.0, 16.0, 0x80FFFFFF, 11.0, "Segoe UI", $false)

    # Main Readout Number (Bottom-Right of Plate)
    $dispLen = $state.DisplayValue.Length
    $fontSize = if ($dispLen -gt 15) { 14.0 } elseif ($dispLen -gt 10) { 20.0 } else { 28.0 }
    $mDisp = $canvas.MeasureText($state.DisplayValue, [single]$fontSize, "Segoe UI", $true)
    $dispY = [single]($scrY + $actualScreenH - $mDisp.Height - 6.0)
    $canvas.DrawText($state.DisplayValue, [single]($scrX + $scrW - $mDisp.Width - 12.0), $dispY, $mDisp.Width + 4.0, $mDisp.Height + 4.0, 0xFFFFFFFF, [single]$fontSize, "Segoe UI", $true)

    # 5. Keypad Grid: 4 Columns x 5 Rows
    $cellW = [single](($devW - 24.0) / 4.0)
    $cellH = [single]($padH / 5.0)

    foreach ($btn in $script:Buttons) {
        $bx = [single]($devX + 12.0 + ($btn.GridX * $cellW) + 3.0)
        $by = [single]($padY + ($btn.GridY * $cellH) + 3.0)
        $bw = [single](($cellW * $btn.W) - 6.0)
        $bh = [single](($cellH * $btn.H) - 6.0)

        $isHovered  = ($state.HoveredButton -eq $btn.Label)
        $isPressed  = ($state.PressedButton -eq $btn.Label)
        $isActiveOp = ($state.ActiveOp -eq $btn.Label)

        $btnBg = switch ($btn.Type) {
            'num' { 0x14FFFFFF }
            'fn'  { 0x1AFFFFFF }
            'op'  { 0xD9336EF3 }
        }
        $textColor = 0xFFFFFFFF

        if ($isActiveOp) {
            $btnBg = 0xFFFFFFFF
            $textColor = 0xFF0F172A
        } elseif ($isPressed) {
            $btnBg = 0x40FFFFFF
        } elseif ($isHovered) {
            $btnBg = if ($btn.Type -eq 'op') { 0xFF336EF3 } else { 0x26FFFFFF }
        }

        $centerX = [single]($bx + $bw / 2.0)
        $centerY = [single]($by + $bh / 2.0)

        # Base Key Cap Geometry
        $canvas.FillRect($bx, $by, $bw, $bh, $btnBg, 6.0)

        # Canvas edge border
        $bdrColor = if ($isPressed) { 0x33000000 } else { 0x14FFFFFF }
        $canvas.DrawRect($bx, $by, $bw, $bh, $bdrColor, 1.0, 6.0)

        # Minesweeper 8-Neighbor Proximity Glow
        if ($state.HoveredButton) {
            $hovBtn = $script:Buttons | Where-Object Label -eq $state.HoveredButton | Select-Object -First 1
            if ($hovBtn) {
                $hx = $hovBtn.GridX
                $hy = $hovBtn.GridY
                $minX = $btn.GridX
                $maxX = $btn.GridX + $btn.W - 1
                $gxDiff = if ($hx -lt $minX) { $minX - $hx } elseif ($hx -gt $maxX) { $hx - $maxX } else { 0 }
                $gyDiff = [Math]::Abs($btn.GridY - $hy)

                if ($gxDiff -le 1 -and $gyDiff -le 1) {
                    $glowColor = if ($gxDiff -eq 0 -and $gyDiff -eq 0) {
                        0x80FFFFFF # Active hovered key: 50% white
                    } elseif (($gxDiff + $gyDiff) -eq 1) {
                        0x4DFFFFFF # Orthogonal neighbor: 30% white
                    } else {
                        0x26FFFFFF # Diagonal neighbor: 15% white
                    }
                    $canvas.DrawRect([single]($bx - 0.5), [single]($by - 0.5), [single]($bw + 1.0), [single]($bh + 1.0), $glowColor, 1.5, 6.0)
                }
            }
        }

        # Centered Typography
        $tx = [single]($centerX - 6.0)
        $ty = [single]($centerY - 9.0)
        $canvas.DrawText($btn.Label, $tx, $ty, [single]16.0, [single]18.0, $textColor, 14.0, "Segoe UI", ($btn.Type -ne 'fn'))
    }

    return [bool]$canvas.Present()
}

function Find-HitButton([single]$mx, [single]$my, [single]$w, [single]$h) {
    $devW = [single]$w
    $devH = [single]$h
    $devX = [single]0.0
    $devY = [single]0.0

    $screenH = [single]($devH * 0.20)
    $padY    = [single]($devY + $screenH + 20.0)
    $padH    = [single]($devH - $screenH - 32.0)

    $cellW = [single](($devW - 24.0) / 4.0)
    $cellH = [single]($padH / 5.0)

    foreach ($btn in $script:Buttons) {
        $bx = [single]($devX + 12.0 + ($btn.GridX * $cellW) + 3.0)
        $by = [single]($padY + ($btn.GridY * $cellH) + 3.0)
        $bw = [single](($cellW * $btn.W) - 6.0)
        $bh = [single](($cellH * $btn.H) - 6.0)

        if ($mx -ge $bx -and $mx -le ($bx + $bw) -and $my -ge $by -and $my -le ($by + $bh)) {
            return $btn
        }
    }
    return $null
}

function Start-Calculator([switch] $Headless) {
    $state = [CalculatorState]::new()
    $gpu = & $canvasFactory -Width 340 -Height 520 -Title "Calculator" -Borderless -Headless:$Headless

    try {
        $presented = [bool](Render-CalculatorWidget $gpu $state)
        $diagnostics = $gpu.Diagnostics

        if (-not $presented) {
            throw ("Presentation failed with HRESULT 0x{0:X8}." -f ([uint32]$diagnostics.LastPresentHResult))
        }
        # The initial image is now current. Future presents require an actual
        # Canvas invalidation or a visual calculator-state change.
        $state.RenderRequested = $false

        $runtime = Get-Variable -Name HostRuntimeState -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $runtimeVersion = if ($null -ne $runtime) { [string]$runtime.Version } else { 'unknown' }
        $runtimePlatform = if ($null -ne $runtime) { [string]$runtime.Platform } else { 'unknown' }
        $delegateCount = if ($null -ne $runtime -and $null -ne $runtime.PSObject.Properties['DelegateTypes']) { $runtime.DelegateTypes.Count } else { 0 }
        $stubCount = if ($null -ne $runtime -and $null -ne $runtime.PSObject.Properties['NativeStubs']) { $runtime.NativeStubs.Count } else { 0 }
        $hwndValue = if ($diagnostics.AssociatedHwnd -ne [IntPtr]::Zero) {
            "0x{0:X}" -f $diagnostics.AssociatedHwnd.ToInt64()
        } else {
            '0x0'
        }

        Write-HostPanel @(
            ' Calculator.ps1 initialized '
            " Script      $PSCommandPath "
            " Host  $dpPath "
            " Runtime     Host $runtimeVersion ($runtimePlatform) "
            " PowerShell  $($PSVersionTable.PSVersion) "
            " PID         $PID "
            " Canvas      $($gpu.Width) x $($gpu.Height) "
            " HWND        $hwndValue "
            (" Render HR   0x{0:X8} " -f ([uint32]$diagnostics.RenderTargetHResult))
            (" Present HR  0x{0:X8} " -f ([uint32]$diagnostics.LastPresentHResult))
            " Window      shown=$($diagnostics.WindowShown) state=$($diagnostics.WindowState) "
            " Sharing     $($diagnostics.SharingEnabled) "
            " ABI cache   delegates=$delegateCount stubs=$stubCount "
        )

        if ($Headless -or $env:DP_HEADLESS) {
            return
        }

        $previousLeftDown = $false
        $lastRedrawSerial = [uint64]0
        $lastResizeSerial = [uint64]0
        while ($gpu.Alive) {
            # WaitEvent returns exactly one decoded Windows message. Do not call
            # Pump() before consuming it: doing so can drain WM_LBUTTONDOWN and
            # WM_LBUTTONUP into the same persistent state object and lose clicks.
            $event = $gpu.WaitEvent()
            if ($null -eq $event -or -not $event.Alive) { break }

            # Render only when Host reports that the Canvas itself needs
            # repainting/resizing, or when calculator state changes below.
            if ([uint64]$event.RedrawSerial -ne $lastRedrawSerial) {
                $lastRedrawSerial = [uint64]$event.RedrawSerial
                $state.RenderRequested = $true
            }
            if ([uint64]$event.ResizeSerial -ne $lastResizeSerial) {
                $lastResizeSerial = [uint64]$event.ResizeSerial
                $state.RenderRequested = $true
            }

            $leftPressedThisEvent  = ([bool]$event.LeftDown -and -not $previousLeftDown)
            $leftReleasedThisEvent = (-not [bool]$event.LeftDown -and $previousLeftDown)
            $previousLeftDown = [bool]$event.LeftDown

            $state.Width  = [single]$event.Width
            $state.Height = [single]$event.Height
            $state.MouseX = [single]$event.MouseX
            $state.MouseY = [single]$event.MouseY

            # Check Flush Caption Buttons (Close: w-46 to w, Min: w-92 to w-46, Height: 32)
            $isOverClose = ($state.MouseX -ge ($state.Width - 46.0) -and $state.MouseY -le 32.0 -and $state.MouseY -ge 0.0)
            $isOverMin   = ($state.MouseX -ge ($state.Width - 92.0) -and $state.MouseX -lt ($state.Width - 46.0) -and $state.MouseY -le 32.0 -and $state.MouseY -ge 0.0)

            if ($isOverClose -ne $state.CloseHover -or $isOverMin -ne $state.MinHover) {
                $state.CloseHover = $isOverClose
                $state.MinHover   = $isOverMin
                $state.RenderRequested = $true
            }

            # Keyboard admission
            if ($event.KeyCode -ne 0) {
                switch ($event.KeyCode) {
                    0x1B { Invoke-CalculatorLogic $state 'C' 'fn'; $state.RenderRequested = $true }
                    0x30 { Invoke-CalculatorLogic $state '0' 'num'; $state.RenderRequested = $true }
                    0x31 { Invoke-CalculatorLogic $state '1' 'num'; $state.RenderRequested = $true }
                    0x32 { Invoke-CalculatorLogic $state '2' 'num'; $state.RenderRequested = $true }
                    0x33 { Invoke-CalculatorLogic $state '3' 'num'; $state.RenderRequested = $true }
                    0x34 { Invoke-CalculatorLogic $state '4' 'num'; $state.RenderRequested = $true }
                    0x35 { Invoke-CalculatorLogic $state '5' 'num'; $state.RenderRequested = $true }
                    0x36 { Invoke-CalculatorLogic $state '6' 'num'; $state.RenderRequested = $true }
                    0x37 { Invoke-CalculatorLogic $state '7' 'num'; $state.RenderRequested = $true }
                    0x38 { Invoke-CalculatorLogic $state '8' 'num'; $state.RenderRequested = $true }
                    0x39 { Invoke-CalculatorLogic $state '9' 'num'; $state.RenderRequested = $true }
                    0x60 { Invoke-CalculatorLogic $state '0' 'num'; $state.RenderRequested = $true }
                    0x61 { Invoke-CalculatorLogic $state '1' 'num'; $state.RenderRequested = $true }
                    0x62 { Invoke-CalculatorLogic $state '2' 'num'; $state.RenderRequested = $true }
                    0x63 { Invoke-CalculatorLogic $state '3' 'num'; $state.RenderRequested = $true }
                    0x64 { Invoke-CalculatorLogic $state '4' 'num'; $state.RenderRequested = $true }
                    0x65 { Invoke-CalculatorLogic $state '5' 'num'; $state.RenderRequested = $true }
                    0x66 { Invoke-CalculatorLogic $state '6' 'num'; $state.RenderRequested = $true }
                    0x67 { Invoke-CalculatorLogic $state '7' 'num'; $state.RenderRequested = $true }
                    0x68 { Invoke-CalculatorLogic $state '8' 'num'; $state.RenderRequested = $true }
                    0x69 { Invoke-CalculatorLogic $state '9' 'num'; $state.RenderRequested = $true }
                    0x6B { Invoke-CalculatorLogic $state '+' 'op';  $state.RenderRequested = $true }
                    0x6D { Invoke-CalculatorLogic $state ([char]0x2212) 'op'; $state.RenderRequested = $true }
                    0x6A { Invoke-CalculatorLogic $state ([char]0x00D7) 'op'; $state.RenderRequested = $true }
                    0x6F { Invoke-CalculatorLogic $state ([char]0x00F7) 'op'; $state.RenderRequested = $true }
                    0x0D { Invoke-CalculatorLogic $state '=' 'op';  $state.RenderRequested = $true }
                }
            }

            # Hit Resolution
            $hitBtn = Find-HitButton $state.MouseX $state.MouseY $state.Width $state.Height
            $newHovered = if ($hitBtn) { $hitBtn.Label } else { $null }
            if ($newHovered -ne $state.HoveredButton) {
                $state.HoveredButton = $newHovered
                $state.RenderRequested = $true
            }

            # Mouse Button Action -- semantic mousedown/mouseup edges, matching
            # the HTML donor instead of treating every move-while-held as a click.
            if ($leftPressedThisEvent) {
                if ($isOverClose) {
                    break
                }
                if ($isOverMin) {
                    $gpu.Minimize()
                    continue
                }
                if ($null -ne $hitBtn) {
                    $state.PressedButton = $hitBtn.Label
                    Invoke-CalculatorLogic $state $hitBtn.Label $hitBtn.Type
                    $state.RenderRequested = $true
                } elseif ($state.MouseY -lt 36.0 -and $state.MouseX -lt ($state.Width - 92.0)) {
                    [void]$gpu.DragWindow()
                }
            }

            if ($leftReleasedThisEvent -and $null -ne $state.PressedButton) {
                $state.PressedButton = $null
                $state.RenderRequested = $true
            }

            if ($state.RenderRequested) {
                $state.RenderRequested = $false
                [void](Render-CalculatorWidget $gpu $state)
            }
        }
    }
    finally {
        if ($null -ne $gpu) { $gpu.Dispose() }
    }
}

# InvocationName is exactly '.' for dot-sourcing. Do not inspect the raw command
# line: normal relative execution (`./Calculator.ps1`) also starts with a dot.
$isDotSourced = ($MyInvocation.InvocationName -eq '.')
if (-not $isDotSourced -and -not $env:DP_SKIP_START) {
    try {
        Start-Calculator -Headless:$calculatorHeadless
    }
    catch {
        $errorMessage = ($_.Exception.Message -replace '\r?\n', ' ')
        $errorType = $_.Exception.GetType().FullName
        $errorLine = $_.InvocationInfo.ScriptLineNumber

        Write-HostPanel @(
            ' Calculator.ps1 startup failure '
            " Type        $errorType "
            " Message     $errorMessage "
            " Line        $errorLine "
        )
        Wait-HostFailureAcknowledge
        exit 1
    }
}
