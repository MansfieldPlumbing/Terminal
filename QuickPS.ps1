#requires -Version 7.0
<#
.SYNOPSIS
    DirectPort.ps1 - Normative Implementation Architecture (DP-ARCH-005 Conforming)
.DESCRIPTION
    Universal graphical application compatibility shim and presentation runtime for PowerShell.
    Implements DP-ARCH-005 specification:
    - Zero C# Add-Type compilation (pure .NET BCL NativeLibrary + cached dynamic delegates)
    - Separated Windows Host, Windows Canvas/Text, and optional D3D12 SysRAM IPC Sharing
    - Normalized portable contracts ($Canvas, $Input, $App)
    - Deduplicated input message decoding
    - Hot-path allocation freeze (cached text metrics, scratch blocks, zero per-frame delegate generation)
    - Built-in self-contained script bundler / linker (Export-ScriptBundle)
    - Backward-compatible New-Canvas & $DirectPort conformance carrier
#>

[CmdletBinding()]
param(
    [bool] $EnableCanvas = $true,
    [Alias('Canvas')]
    [switch] $Interactive,
    [switch] $Headless,
    [int] $Width = 960,
    [int] $Height = 540,
    [string] $Title = "QuickPS Unified Canvas Carrier",
    [string] $Bundle = $null,
    [string] $OutFile = $null,
    [switch] $EnableSharing = $false,
    [switch] $SoftwareRendering = $false,
    [string] $AssemblyPath,
    [string] $AtlasPng,
    [string] $MetricsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QuickPSSourcePath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

function global:// { [CmdletBinding()]param([Parameter(ValueFromRemainingArguments)]$Args) }
Set-Item -Path "function:global:////////////////////////////////" -Value ${function:global://} -Force
Set-Item -Path "function:global:////////////////////////////////////////////////////////////////////////////////" -Value ${function:global://} -Force

# ==============================================================================
# TELEMETRY
# ==============================================================================

$script:Block_TelemetryPanel = {
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
function script:Write-TelemetryPanel([string[]]$Lines) {
    & $script:Block_TelemetryPanel $Lines
}

# ==============================================================================
# SECTION 00: VERSION & DIRECTPORT RUNTIME STATE
# ==============================================================================

$dpVar = Get-Variable -Name NativeInteropState -Scope Global -ErrorAction SilentlyContinue
$dpRuntime = $null
if ($null -ne $dpVar) {
    $candidate = $dpVar.Value
    if ($null -ne $candidate) {
        $hasMarker = $null -ne $candidate.PSObject.Properties['RuntimeKind']
        $hasAsm    = $null -ne $candidate.PSObject.Properties['NativeAssembly']
        $hasMod    = $null -ne $candidate.PSObject.Properties['NativeModule']

        if ($hasMarker -and $hasAsm -and $hasMod -and $candidate.RuntimeKind -eq 'DirectPort') {
            $dpRuntime = $candidate
        }
    }
}

if ($null -eq $dpRuntime) {
    $dpRuntime = [PSCustomObject]@{
        RuntimeKind    = 'QuickPS'
        Version        = '0.5.0-rehab'
        Spec           = 'DP-ARCH-005'
        Platform       = if ($IsWindows) { 'Windows' } elseif ($IsLinux -and (Test-Path '/system/build.prop')) { 'Android' } else { 'Generic' }
        NativeAssembly = $null
        NativeModule   = $null
        DelegateTypes  = [System.Collections.Concurrent.ConcurrentDictionary[string, Type]]::new()
        NativeStubs    = [System.Collections.Concurrent.ConcurrentDictionary[string, [Delegate]]]::new()
    }
}

if ($null -eq $dpRuntime.NativeAssembly -or $null -eq $dpRuntime.NativeModule) {
    $nativeAssembly = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [System.Reflection.AssemblyName]::new("QuickPS.Native." + [Guid]::NewGuid().ToString('N')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    )
    $dpRuntime.NativeAssembly = $nativeAssembly
    $dpRuntime.NativeModule   = $nativeAssembly.DefineDynamicModule("QuickPS.NativeModule")
}

$global:NativeInteropState = $dpRuntime

# ==============================================================================
# SECTION 10: PORTABLE PUBLIC CONTRACTS
# ==============================================================================
<#
    Normative contracts according to DP-ARCH-005 Section 6:
    $Canvas:
      BeginDraw, FillRect, DrawRect, DrawText, MeasureText, DrawBitmap, Present, Width, Height, Alive, Dispose
    $Input:
      Alive, Width, Height, PointerX, PointerY, PrimaryDown, Key, Text, ResizeSerial, RedrawSerial
    $App:
      Close, Minimize, BeginWindowMove, DragWindow, RequestExit, Title
#>

# ==============================================================================
# SECTION 125: RETAINED PACKED-CELL CANVAS CAPABILITY
# ==============================================================================

# Mechanically retained Canvas program: packed storage, Build-Cells, stress
# behavior, telemetry, and the one-call TryPresent boundary stay together.
$script:Canvas = {
    param(
        [Parameter(Mandatory)][string] $AssemblyPath,
        [Parameter(Mandatory)][string] $AtlasPng,
        [Parameter(Mandatory)][string] $MetricsJson
    )

    enum CanvasMode { Touch; Pan; Colors; Charset; Grid; Noise }

    [Reflection.Assembly]::LoadFrom($AssemblyPath) | Out-Null
    $gpu = $null
    $script:Cells = [uint32[]]::new(1)
    $script:Columns = 1
    $script:Rows = 1
    $script:Mode = [CanvasMode]::Touch
    $script:GlyphAnimationStep = [uint64]0
    $script:Scale = 1
    $script:PanX = 0.0
    $script:PanY = 0.0
    $script:Dirty = $true
    $script:WasAnimating = $false
    $script:Ready = $false
    $script:Rng = [Random]::new()
    $script:NoiseBytes = [byte[]]::new(2)
    $script:TouchX = [Collections.Generic.List[int]]::new()
    $script:TouchY = [Collections.Generic.List[int]]::new()
    $script:TouchAt = [Collections.Generic.List[long]]::new()
    $script:LastTouchCell = -1
    $script:LastResizeSerial = [uint64]::MaxValue
    $script:LastFps = 0.0
    $script:LastBuild = 0.0
    $script:LastDropped = [uint64]0
    $script:EmitSample = $true

    $labels = @(
        @{ Text = ' 1 TOUCH '; Mode = [CanvasMode]::Touch },
        @{ Text = ' 2 PAN '; Mode = [CanvasMode]::Pan },
        @{ Text = ' 3 COLORS '; Mode = [CanvasMode]::Colors },
        @{ Text = ' 4 GLYPHS '; Mode = [CanvasMode]::Charset },
        @{ Text = ' 5 GRID '; Mode = [CanvasMode]::Grid },
        @{ Text = ' 6 NOISE '; Mode = [CanvasMode]::Noise }
    )

    function Set-Mode([CanvasMode] $Mode) {
        $wasAnimated = $script:Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
        $script:Mode = $Mode
        $isAnimated = $Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
        if ($wasAnimated -and -not $isAnimated) { $script:WasAnimating = $true }
        $script:Dirty = $true
        $script:EmitSample = $true
    }

    function Add-TouchCell([int] $X, [int] $Y) {
        if ($X -lt 0 -or $X -ge $script:Columns -or $Y -lt 1 -or $Y -ge $script:Rows) { return }
        $cell = $Y * $script:Columns + $X
        if ($cell -eq $script:LastTouchCell) { return }
        $script:LastTouchCell = $cell
        $script:TouchX.Add($X)
        $script:TouchY.Add($Y)
        $script:TouchAt.Add([Environment]::TickCount64)
        $script:Dirty = $true
    }

    function Put-Text([uint32[]] $Cells, [int] $Columns, [int] $Rows, [int] $X, [int] $Y,
                      [string] $Text, [int] $Foreground, [int] $Background) {
        if ($Y -lt 0 -or $Y -ge $Rows) { return }
        for ($i = 0; $i -lt $Text.Length -and ($X + $i) -lt $Columns; $i++) {
            if (($X + $i) -ge 0) {
                $Cells[$Y * $Columns + $X + $i] = [uint32](($Background -shl 24) -bor ($Foreground -shl 16) -bor [int]$Text[$i])
            }
        }
    }

    function Build-Cells([int] $ViewWidth, [int] $ViewHeight) {
        $cellWidth = 9 * $script:Scale
        $cellHeight = 18 * $script:Scale
        $columns = [Math]::Clamp([int][Math]::Floor($ViewWidth / $cellWidth), 1, 512)
        $rows = [Math]::Clamp([int][Math]::Floor($ViewHeight / $cellHeight), 2, 512)
        while (($columns * $rows) -gt 262144) { $rows-- }
        $shape = $columns -ne $script:Columns -or $rows -ne $script:Rows
        if ($shape) {
            $script:Columns = $columns
            $script:Rows = $rows
            $script:Cells = [uint32[]]::new($columns * $rows)
            $script:NoiseBytes = [byte[]]::new(2 * $columns * $rows)
        }
        else { [Array]::Clear($script:Cells, 0, $script:Cells.Length) }

        $cells = $script:Cells
        $mode = $script:Mode
        $px = [int][Math]::Floor($script:PanX)
        $py = [int][Math]::Floor($script:PanY)
        $centerX = [int]($columns / 2)
        $centerY = [int]($rows / 2)
        $band = [Math]::Max(1.0, $columns / 16.0)

        # Select the producer once per frame, never once per cell.
        if ($mode -eq [CanvasMode]::Grid) {
            for ($y = 1; $y -lt $rows; $y++) {
                $rowAt = $y * $columns
                for ($x = 0; $x -lt $columns; $x++) {
                    $cp = 32; $fg = 15; $bg = if ((($x + $y) -band 1) -eq 0) { 8 } else { 0 }
                    if ($x -eq 0 -or $y -eq 1 -or $x -eq ($columns - 1) -or $y -eq ($rows - 1)) { $bg = 1; $cp = 35 }
                    if (($x % 10) -eq 0 -and (($y - 1) % 5) -eq 0) { $bg = 4; $cp = 79 }
                    $cells[$rowAt + $x] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp)
                }
            }
        }
        elseif ($mode -eq [CanvasMode]::Colors) {
            for ($y = 1; $y -lt $rows; $y++) {
                $rowAt = $y * $columns; $cp = 65 + ($y % 26)
                for ($x = 0; $x -lt $columns; $x++) {
                    $bg = [int][Math]::Floor($x / $band) % 16; $fg = ($bg + 8) % 16
                    $cells[$rowAt + $x] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp)
                }
            }
        }
        elseif ($mode -eq [CanvasMode]::Charset) {
            for ($y = 1; $y -lt $rows; $y++) {
                $rowAt = $y * $columns; $fg = ($y % 15) + 1
                for ($x = 0; $x -lt $columns; $x++) {
                    $cp = 33 + (($rowAt + $x + $script:GlyphAnimationStep) % 94)
                    $cells[$rowAt + $x] = [uint32](($fg -shl 16) -bor $cp)
                }
            }
        }
        elseif ($mode -eq [CanvasMode]::Noise) {
            # Entropy generation stays in one native call; PowerShell only packs cells.
            $script:Rng.NextBytes($script:NoiseBytes)
            for ($y = 1; $y -lt $rows; $y++) {
                $rowAt = $y * $columns
                for ($x = 0; $x -lt $columns; $x++) {
                    $at = $rowAt + $x; $v = $script:NoiseBytes[2 * $at]
                    if (($v -band 15) -eq 0) {
                        $cp = 33 + ($v % 90); $fg = $script:NoiseBytes[2 * $at + 1] -band 15
                        $cells[$at] = [uint32](($fg -shl 16) -bor $cp)
                    }
                }
            }
        }
        elseif ($mode -eq [CanvasMode]::Pan) {
            for ($y = 1; $y -lt $rows; $y++) {
                $rowAt = $y * $columns; $wy = ($y - 1) - $py
                for ($x = 0; $x -lt $columns; $x++) {
                    $cp = 32; $fg = 15; $bg = 0; $wx = $x - $px
                    if ((([Math]::Abs($wx) -band 1) -eq 0) -eq (([Math]::Abs($wy) -band 1) -eq 0)) { $bg = 8 }
                    if ($wx -eq 0 -and $wy -eq 0) { $bg = 4; $cp = 88 }
                    elseif (($wx % 10) -eq 0 -and ($wy % 10) -eq 0) { $cp = 43 }
                    if ($x -eq $centerX -and $y -eq $centerY) { $bg = 1; $cp = 64 }
                    $cells[$rowAt + $x] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp)
                }
            }
        }

        # Oldest -> newest: normal last-write-wins makes the newest touch authoritative.
        $now = [Environment]::TickCount64
        for ($i = $script:TouchAt.Count - 1; $i -ge 0; $i--) {
            if (($now - $script:TouchAt[$i]) -ge 500) {
                $script:TouchAt.RemoveAt($i); $script:TouchX.RemoveAt($i); $script:TouchY.RemoveAt($i)
            }
        }
        for ($i = 0; $i -lt $script:TouchAt.Count; $i++) {
            $age = $now - $script:TouchAt[$i]
            if ($age -lt 100) { $bg = 14; $fg = 0; $cp = 88 }
            elseif ($age -lt 300) { $bg = 6; $fg = 15; $cp = 120 }
            else { $bg = 8; $fg = 15; $cp = 46 }
            $at = $script:TouchY[$i] * $columns + $script:TouchX[$i]
            if ($at -ge 0 -and $at -lt $cells.Length) { $cells[$at] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp) }
        }

        if ($mode -eq [CanvasMode]::Touch) {
            Put-Text $cells $columns $rows 3 3 ' CANVAS HOST: DIRECTPORT D3D12 ' 15 4
            $status = if ($script:TouchX.Count) {
                ' COORDS: [X:{0:D3} Y:{1:D3}] ' -f $script:TouchX[$script:TouchX.Count - 1], $script:TouchY[$script:TouchY.Count - 1]
            } else { ' WAITING FOR INPUT... ' }
            Put-Text $cells $columns $rows 3 5 $status 10 0
        }

        # Toolbar is itself cells; click ranges are reconstructed from these labels.
        $toolbarX = 0
        foreach ($button in $labels) {
            $selected = $button.Mode -eq $mode
            Put-Text $cells $columns $rows $toolbarX 0 $button.Text $(if ($selected) { 15 } else { 7 }) $(if ($selected) { 4 } else { 8 })
            $toolbarX += $button.Text.Length
        }
        if ($toolbarX -lt $columns) {
            $telemetry = ' {0}x{1} {2:0}fps {3:0.0}ms D{4} ' -f $columns, $rows, $script:LastFps, $script:LastBuild, $script:LastDropped
            Put-Text $cells $columns $rows $toolbarX 0 $telemetry 8 0
        }
        return $shape
    }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $frequency = [double][System.Diagnostics.Stopwatch]::Frequency
    $targetTicks = [long]($frequency / 120.0)
    $nextFrame = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $sampleAt = $nextFrame
    $sampleFrames = 0
    $buildTotal = 0.0
    $publishValue = [uint64]0
    $previousLeft = $false
    $previousX = 0
    $previousY = 0

    try {
        $suffix = "${PID}_debugcanvas"
        $gpu = [DirectPort.PowerShell.GpuConsole]::new(
            1280, 720, 262144,
            "Global\D3D12_Texture_$suffix", "Global\D3D12_Fence_$suffix",
            $AtlasPng, $MetricsJson)
        $gpu.EnableManifest("D3D12_Producer_Manifest_$PID")
        $gpu.Show('DirectPort Debug Canvas r6', 1000, 650)

        while ($true) {
            $animated = $script:Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
            $live = $script:Dirty -or $animated -or ($script:TouchAt.Count -gt 0)
            # Animated stress owns its cadence. A nonzero millisecond wait is
            # scheduler-quantized when no input arrives and throttles untouched
            # Glyphs/Noise despite the dirty transaction taking only a few ms.
            $wait = if ($live) { 0 } else { 1000 }
            $state = $gpu.Pump([uint32]$wait)
            if (-not $state.Alive) { break }

            if ($state.ResizeSerial -ne $script:LastResizeSerial) {
                $script:LastResizeSerial = $state.ResizeSerial
                $script:Dirty = $true
                if ($script:Ready) { "RESIZE $($state.Width)x$($state.Height)" }
            }
            if ($state.KeyCode -ge 49 -and $state.KeyCode -le 54) { Set-Mode ([CanvasMode]($state.KeyCode - 49)) }
            elseif ($state.KeyCode -eq 27) { break }
            elseif ($state.KeyCode -eq 187 -or $state.KeyCode -eq 107) { $script:Scale = [Math]::Min(8, $script:Scale + 1); $script:Dirty = $true }
            elseif ($state.KeyCode -eq 189 -or $state.KeyCode -eq 109) { $script:Scale = [Math]::Max(1, $script:Scale - 1); $script:Dirty = $true }

            $columns = [Math]::Max(1, $script:Columns); $rows = [Math]::Max(2, $script:Rows)
            $cellX = [Math]::Clamp([int][Math]::Floor($state.MouseX / [Math]::Max(1.0, $state.Width / $columns)), 0, $columns - 1)
            $cellY = [Math]::Clamp([int][Math]::Floor($state.MouseY / [Math]::Max(1.0, $state.Height / $rows)), 0, $rows - 1)
            if ($state.LeftDown -and -not $previousLeft -and $cellY -eq 0) {
                $hitX = 0
                foreach ($button in $labels) {
                    if ($cellX -ge $hitX -and $cellX -lt ($hitX + $button.Text.Length)) { Set-Mode $button.Mode; break }
                    $hitX += $button.Text.Length
                }
            }
            elseif ($state.LeftDown -and $cellY -gt 0) {
                if ($script:Mode -eq [CanvasMode]::Pan -and $previousLeft) {
                    $script:PanX -= ($state.MouseX - $previousX) / [Math]::Max(1.0, $state.Width / $columns)
                    $script:PanY -= ($state.MouseY - $previousY) / [Math]::Max(1.0, $state.Height / $rows)
                    $script:Dirty = $true
                }
                Add-TouchCell $cellX $cellY
            }
            if (-not $state.LeftDown) { $script:LastTouchCell = -1 }
            if ($state.WheelDelta -and $script:Mode -eq [CanvasMode]::Pan) {
                $script:PanY -= $state.WheelDelta / 120.0
                $script:Dirty = $true
            }
            $previousLeft = $state.LeftDown; $previousX = $state.MouseX; $previousY = $state.MouseY

            $nowTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $animated = $script:Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
            $live = $script:Dirty -or $animated -or ($script:TouchAt.Count -gt 0)
            if (-not $live -or $nowTicks -lt $nextFrame) { continue }
            $buildAt = $nowTicks
            $shape = Build-Cells $state.Width $state.Height
            if ($shape -and $script:Ready) { "RESIZE $($script:Columns)x$($script:Rows)" }
            $publishValue++
            $submitted = $gpu.TryPresent($script:Cells, $script:Columns, $script:Rows, [single]$clock.Elapsed.TotalSeconds, $publishValue)
            $builtAt = [System.Diagnostics.Stopwatch]::GetTimestamp()
            if ($submitted) {
                if (-not $script:Ready) { 'READY'; $script:Ready = $true }
                if ($script:Mode -eq [CanvasMode]::Charset) { $script:GlyphAnimationStep++ }
                $script:Dirty = $false
                $sampleFrames++
                $buildTotal += 1000.0 * ($builtAt - $buildAt) / $frequency
                if ($script:WasAnimating -and -not $animated) { 'IDLE'; $script:WasAnimating = $false }
                if ($animated) { $script:WasAnimating = $true }
            }
            if (($builtAt - $sampleAt) -ge $frequency) {
                $elapsed = ($builtAt - $sampleAt) / $frequency
                $script:LastFps = $sampleFrames / $elapsed
                $script:LastBuild = $buildTotal / [Math]::Max(1, $sampleFrames)
                $script:LastDropped = $gpu.DroppedFrames
                if ($script:EmitSample) {
                    'FPS={0:0} BUILD={1:0.0}ms' -f $script:LastFps, $script:LastBuild
                    $script:EmitSample = $false
                }
                $sampleAt = $builtAt; $sampleFrames = 0; $buildTotal = 0.0
            }
            $nextFrame = [Math]::Max($nextFrame + $targetTicks, $builtAt)
        }
    }
    finally {
        if ($null -ne $gpu) { $gpu.Dispose() }
        'CLOSED'
    }

}

function global:New-DirectPortRetainedCanvas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AssemblyPath,
        [Parameter(Mandatory)][string] $AtlasPng,
        [Parameter(Mandatory)][string] $MetricsJson
    )

    foreach ($requiredPath in @($AssemblyPath, $AtlasPng, $MetricsJson)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Retained Canvas dependency not found: $requiredPath"
        }
    }

    $owner = [PSCustomObject]@{
        PSTypeName  = 'DirectPort.Capability.Canvas'
        Program     = $script:Canvas
        Runspace    = $null
        PowerShell  = $null
        AsyncResult = $null
        Output      = $null
        Attached    = $false
    }

    $owner | Add-Member -MemberType ScriptMethod -Name 'Attach' -Value {
        if ($this.Attached) { return $this }
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $powerShell = [System.Management.Automation.PowerShell]::Create()
        $powerShell.Runspace = $runspace
        # Parse the retained PowerShell program in the owned runspace so its
        # script scope and Canvas state belong to that runspace, not the caller.
        [void]$powerShell.AddScript($this.Program.ToString()).AddParameter('AssemblyPath', $AssemblyPath).AddParameter('AtlasPng', $AtlasPng).AddParameter('MetricsJson', $MetricsJson)
        $output = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $this.Runspace = $runspace
        $this.PowerShell = $powerShell
        $this.Output = $output
        $this.AsyncResult = $powerShell.BeginInvoke[psobject,psobject]($null, $output)
        $this.Attached = $true
        return $this
    }.GetNewClosure()

    $owner | Add-Member -MemberType ScriptMethod -Name 'Wait' -Value {
        if (-not $this.Attached) { return @() }
        [void]$this.AsyncResult.AsyncWaitHandle.WaitOne()
        try {
            [void]$this.PowerShell.EndInvoke($this.AsyncResult)
            if ($this.PowerShell.Streams.Error.Count) { throw $this.PowerShell.Streams.Error[0] }
            return @($this.Output)
        }
        finally { $this.Detach() }
    }

    $owner | Add-Member -MemberType ScriptMethod -Name 'Detach' -Value {
        if (-not $this.Attached) { return }
        try {
            if ($null -ne $this.PowerShell -and
                $this.PowerShell.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running) {
                $this.PowerShell.Stop()
            }
        }
        finally {
            if ($null -ne $this.PowerShell) { $this.PowerShell.Dispose() }
            if ($null -ne $this.Runspace) { $this.Runspace.Dispose() }
            $this.PowerShell = $null
            $this.Runspace = $null
            $this.AsyncResult = $null
            $this.Attached = $false
        }
    }

    $owner | Add-Member -MemberType ScriptMethod -Name 'Run' -Value {
        [void]$this.Attach()
        return $this.Wait()
    }
    return $owner
}

function global:Resolve-DirectPortCanvasDependencies {
    [CmdletBinding()]
    param(
        [string] $AssemblyPath,
        [string] $AtlasPng,
        [string] $MetricsJson
    )

    $sourceRoot = if ($script:QuickPSSourcePath) {
        Split-Path -Parent $script:QuickPSSourcePath
    } else { [Environment]::CurrentDirectory }

    if (-not $AssemblyPath -or -not (Test-Path -LiteralPath $AssemblyPath)) {
        foreach ($candidate in @(
            $AssemblyPath,
            $env:DIRECTPORT_DLL,
            $(if ($env:DIRECTPORT) { Join-Path $env:DIRECTPORT 'DirectPort.PowerShell.dll' }),
            (Join-Path $sourceRoot 'DirectPort.PowerShell.dll'),
            (Join-Path $sourceRoot 'bin\DirectPort.PowerShell.dll'),
            (Join-Path $PSHOME 'DirectPort.PowerShell.dll')
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { $AssemblyPath = $candidate; break }
        }
    }
    if (-not $AtlasPng -or -not (Test-Path -LiteralPath $AtlasPng)) {
        foreach ($candidate in @(
            $AtlasPng, $env:DIRECTPORT_ATLAS,
            (Join-Path $sourceRoot 'cascadia-code-atlas.png'),
            (Join-Path $sourceRoot 'assets\cascadia-code-atlas.png'),
            (Join-Path $PSHOME 'cascadia-code-atlas.png')
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { $AtlasPng = $candidate; break }
        }
    }
    if (-not $MetricsJson -or -not (Test-Path -LiteralPath $MetricsJson)) {
        foreach ($candidate in @(
            $MetricsJson, $env:DIRECTPORT_METRICS,
            (Join-Path $sourceRoot 'cascadia-code-metrics.json'),
            (Join-Path $sourceRoot 'assets\cascadia-code-metrics.json'),
            (Join-Path $PSHOME 'cascadia-code-metrics.json')
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { $MetricsJson = $candidate; break }
        }
    }

    foreach ($dependency in @($AssemblyPath, $AtlasPng, $MetricsJson)) {
        if (-not $dependency -or -not (Test-Path -LiteralPath $dependency)) {
            throw 'DirectPort retained Canvas dependencies were not found. Pass -AssemblyPath, -AtlasPng, and -MetricsJson.'
        }
    }
    return [PSCustomObject]@{ AssemblyPath = $AssemblyPath; AtlasPng = $AtlasPng; MetricsJson = $MetricsJson }
}

$script:DirectPortSurface = [PSCustomObject]@{
    PSTypeName = 'DirectPort.Surface'
    Canvas     = $null
}
$script:DirectPortSurface | Add-Member -MemberType ScriptMethod -Name 'AttachCanvas' -Value {
    param(
        [Parameter(Mandatory)][string] $AssemblyPath,
        [Parameter(Mandatory)][string] $AtlasPng,
        [Parameter(Mandatory)][string] $MetricsJson
    )
    if ($null -ne $this.Canvas -and $this.Canvas.Attached) { return $this.Canvas }
    $this.Canvas = New-DirectPortRetainedCanvas -AssemblyPath $AssemblyPath -AtlasPng $AtlasPng -MetricsJson $MetricsJson
    [void]$this.Canvas.Attach()
    return $this.Canvas
}
$script:DirectPortSurface | Add-Member -MemberType ScriptMethod -Name 'DetachCanvas' -Value {
    if ($null -eq $this.Canvas) { return }
    $this.Canvas.Detach()
    $this.Canvas = $null
}

# ==============================================================================
# SECTION 20: INERT BINDING RECORDS (DP-ARCH-005 SECTION 9)
# ==============================================================================

$script:DirectPortBindings = {
    # DP-ARCH-005 Stage 10: Binding records are admitted only after
    # working implementation functions exist and pass tests.
}

# ==============================================================================
# SECTION 30: COMMON HELPERS & DUCK-TYPING SYNTHESIS
# ==============================================================================

function global:Initialize-WindowsGraphicsTypes {
    if ([System.Management.Automation.PSTypeName]::new('Windows.Graphics.Color').Type -ne $null -and
        [System.Management.Automation.PSTypeName]::new('Windows.Graphics.CanvasWindowState').Type -ne $null) {
        return
    }

    $asmName = [System.Reflection.AssemblyName]::new("SMADirect.WindowsGraphics." + [Guid]::NewGuid().ToString('N'))
    $assembly = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($asmName, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule("SMADirectDuckTypes")

    # 1. Windows.Graphics.Color
    if ([System.Management.Automation.PSTypeName]::new('Windows.Graphics.Color').Type -eq $null) {
        $tbColor = $module.DefineType("Windows.Graphics.Color", [System.Reflection.TypeAttributes]'Public,Class')

        $mbRgb = $tbColor.DefineMethod("Rgb", [System.Reflection.MethodAttributes]'Public,Static', [int32], @([int32],[int32],[int32]))
        $il = $mbRgb.GetILGenerator()
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, [int32]-16777216)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [byte]16)
        $il.Emit([System.Reflection.Emit.OpCodes]::Shl)
        $il.Emit([System.Reflection.Emit.OpCodes]::Or)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_1)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [byte]8)
        $il.Emit([System.Reflection.Emit.OpCodes]::Shl)
        $il.Emit([System.Reflection.Emit.OpCodes]::Or)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_2)
        $il.Emit([System.Reflection.Emit.OpCodes]::Or)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ret)

        $mbArgb = $tbColor.DefineMethod("Argb", [System.Reflection.MethodAttributes]'Public,Static', [int32], @([int32],[int32],[int32],[int32]))
        $il = $mbArgb.GetILGenerator()
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [byte]24)
        $il.Emit([System.Reflection.Emit.OpCodes]::Shl)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_1)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [byte]16)
        $il.Emit([System.Reflection.Emit.OpCodes]::Shl)
        $il.Emit([System.Reflection.Emit.OpCodes]::Or)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_2)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [byte]8)
        $il.Emit([System.Reflection.Emit.OpCodes]::Shl)
        $il.Emit([System.Reflection.Emit.OpCodes]::Or)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_3)
        $il.Emit([System.Reflection.Emit.OpCodes]::Or)
        $il.Emit([System.Reflection.Emit.OpCodes]::Ret)

        $fields = @{}
        $palette = @{
            'White'       = [int32]-1;
            'Black'       = [int32]-16777216;
            'Transparent' = [int32]0;
            'Red'         = [int32]-65536;
            'Green'       = [int32]-16711936;
            'Blue'        = [int32]-16776961;
            'Yellow'      = [int32]-256;
            'Cyan'        = [int32]-16711681;
            'Magenta'     = [int32]-65281;
            'Gray'        = [int32]-8355712;
            'DarkGray'    = [int32]-12303292;
            'LightGray'   = [int32]-3355444;
        }
        foreach ($p in $palette.GetEnumerator()) {
            $fields[$p.Key] = $tbColor.DefineField($p.Key, [int32], [System.Reflection.FieldAttributes]'Public,Static,InitOnly')
        }

        $cctor = $tbColor.DefineConstructor([System.Reflection.MethodAttributes]'Private,Static,SpecialName,RTSpecialName', [System.Reflection.CallingConventions]::Standard, [Type[]]@())
        $il = $cctor.GetILGenerator()
        foreach ($p in $palette.GetEnumerator()) {
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, [int32]$p.Value)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stsfld, $fields[$p.Key])
        }
        $il.Emit([System.Reflection.Emit.OpCodes]::Ret)
        [void]$tbColor.CreateType()
    }

    # 2. Windows.Graphics.CanvasWindowState
    if ([System.Management.Automation.PSTypeName]::new('Windows.Graphics.CanvasWindowState').Type -eq $null) {
        $tbCws = $module.DefineType("Windows.Graphics.CanvasWindowState", [System.Reflection.TypeAttributes]'Public,Class')
        [void]$tbCws.DefineField("Alive", [bool], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("Width", [int32], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("Height", [int32], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("MouseX", [int32], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("MouseY", [int32], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("LeftDown", [bool], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("RightDown", [bool], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("WheelDelta", [int32], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("KeyCode", [int32], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("CharCode", [char], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("IsDoubleClick", [bool], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("ResizeSerial", [uint64], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.DefineField("RedrawSerial", [uint64], [System.Reflection.FieldAttributes]'Public')
        [void]$tbCws.CreateType()
    }

    # 3. Windows.Graphics.TextMetrics
    if ([System.Management.Automation.PSTypeName]::new('Windows.Graphics.TextMetrics').Type -eq $null) {
        $tbTm = $module.DefineType("Windows.Graphics.TextMetrics", [System.Reflection.TypeAttributes]'Public,Class')
        [void]$tbTm.DefineField("Width", [single], [System.Reflection.FieldAttributes]'Public')
        [void]$tbTm.DefineField("Height", [single], [System.Reflection.FieldAttributes]'Public')
        [void]$tbTm.CreateType()
    }
}

Initialize-WindowsGraphicsTypes

# ==============================================================================
# SECTION 40: NATIVE ABI MATERIALIZATION (ZERO C# ADD-TYPE, CACHED STUBS)
# ==============================================================================

function global:Open-NativeLibrary([string]$Name) {
    if ([System.Runtime.InteropServices.NativeLibrary] -as [type]) {
        return [System.Runtime.InteropServices.NativeLibrary]::Load($Name)
    }
    throw "NativeLibrary BCL API is required on PowerShell 7+."
}

function global:Get-NativeExport([IntPtr]$hModule, [string]$Name) {
    if ([System.Runtime.InteropServices.NativeLibrary] -as [type]) {
        return [System.Runtime.InteropServices.NativeLibrary]::GetExport($hModule, $Name)
    }
    throw "NativeLibrary BCL API is required on PowerShell 7+."
}

function global:New-NativeBlock([int]$Size) {
    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($Size)
    $bytes = New-Object byte[] $Size
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $Size)
    return $ptr
}

function global:Remove-NativeBlock([IntPtr]$Ptr) {
    if ($Ptr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($Ptr) }
}

function global:Get-NativeDelegateType([Type]$ReturnType, [Type[]]$ParameterTypes) {
    $paramNames = ($ParameterTypes | ForEach-Object { $_.FullName }) -join ';'
    $sigKey = "$($ReturnType.FullName)::$paramNames"

    $existing = $null
    if ($global:NativeInteropState.DelegateTypes.TryGetValue($sigKey, [ref]$existing)) {
        return $existing
    }

    $typeName = "DirectPortDelegate_" + [Guid]::NewGuid().ToString('N')
    $tb = $global:NativeInteropState.NativeModule.DefineType(
        $typeName,
        [System.Reflection.TypeAttributes]'Class,Public,Sealed,AnsiClass,AutoClass',
        [System.MulticastDelegate]
    )
    $ctor = $tb.DefineConstructor(
        [System.Reflection.MethodAttributes]'RTSpecialName,HideBySig,Public',
        [System.Reflection.CallingConventions]::Standard,
        @([object], [IntPtr])
    )
    $ctor.SetImplementationFlags([System.Reflection.MethodImplAttributes]'Runtime,Managed')

    $invoke = $tb.DefineMethod(
        "Invoke",
        [System.Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual',
        $ReturnType,
        $ParameterTypes
    )
    $invoke.SetImplementationFlags([System.Reflection.MethodImplAttributes]'Runtime,Managed')

    $callConv = [System.Runtime.InteropServices.CallingConvention]::StdCall
    $attrCtor = [System.Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(@([System.Runtime.InteropServices.CallingConvention]))
    $attrBldr = [System.Reflection.Emit.CustomAttributeBuilder]::new($attrCtor, @($callConv))
    $tb.SetCustomAttribute($attrBldr)

    $delType = $tb.CreateType()
    $global:NativeInteropState.DelegateTypes[$sigKey] = $delType
    return $delType
}

function global:Get-NativeCall([IntPtr]$FuncPtr, [Type]$ReturnType, [Type[]]$ParameterTypes) {
    if ($FuncPtr -eq [IntPtr]::Zero) { throw "Cannot bind native call on null function pointer." }
    $paramNames = ($ParameterTypes | ForEach-Object { $_.FullName }) -join ';'
    $stubKey = "$($FuncPtr.ToInt64()):$($ReturnType.FullName)::$paramNames"

    $existing = $null
    if ($global:NativeInteropState.NativeStubs.TryGetValue($stubKey, [ref]$existing)) {
        return $existing
    }

    $delType = Get-NativeDelegateType -ReturnType $ReturnType -ParameterTypes $ParameterTypes
    $del = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($FuncPtr, $delType)
    $global:NativeInteropState.NativeStubs[$stubKey] = $del
    return $del
}

function global:Get-ComCall([IntPtr]$ComObj, [int]$VTableIndex, [Type]$ReturnType, [Type[]]$ParameterTypes) {
    if ($ComObj -eq [IntPtr]::Zero) { throw "Cannot bind COM call on null interface pointer." }
    $vtable = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ComObj)
    if ($vtable -eq [IntPtr]::Zero) { throw "Interface pointer vtable is null." }
    $funcPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($vtable, $VTableIndex * [IntPtr]::Size)
    return Get-NativeCall -FuncPtr $funcPtr -ReturnType $ReturnType -ParameterTypes $ParameterTypes
}

function global:Invoke-ComVtableMethod {
    <#
    .SYNOPSIS
        Call a COM method by vtable slot index. Real vtable dispatch, zero wrapper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IntPtr] $ComObject,
        [Parameter(Mandatory)][int] $SlotIndex,
        [AllowEmptyCollection()][object[]] $ParamTypes = @(),
        [Parameter(Mandatory)][object] $ReturnType = [int32],
        [AllowEmptyCollection()][object[]] $Args = @()
    )
    $retType = if ($ReturnType -is [Type]) { $ReturnType } else { [Type]$ReturnType }
    $pTypes = @([IntPtr])
    if ($ParamTypes) {
        $pTypes += ($ParamTypes | ForEach-Object { if ($_ -is [Type]) { $_ } else { [Type]$_ } })
    }
    $comCall = Get-ComCall -ComObj $ComObject -VTableIndex $SlotIndex -ReturnType $retType -ParameterTypes $pTypes
    $allArgs = @($ComObject)
    if ($Args) {
        $allArgs += $Args
    }
    return $comCall.DynamicInvoke($allArgs)
}

# ==============================================================================
# SECTION 50: WINDOWS HOST (HWND & LIFECYCLE MANAGEMENT)
# ==============================================================================

function global:New-WindowsHost {
    [CmdletBinding()]
    param(
        [int] $Width = 960,
        [int] $Height = 540,
        [string] $Title = 'DirectPort Window',
        [switch] $Borderless,
        [switch] $Headless
    )

    if ($Headless) {
        return [PSCustomObject]@{
            Hwnd         = [IntPtr]::Zero
            HModule      = [IntPtr]::Zero
            ClassName    = $null
            Title        = $Title
            Width        = $Width
            Height       = $Height
            Borderless   = [bool]$Borderless
            Headless     = $true
            Alive        = $true
            WindowShown  = $false
        }
    }

    $user32   = Open-NativeLibrary "user32.dll"
    $kernel32 = Open-NativeLibrary "kernel32.dll"
    $dwmapi   = Open-NativeLibrary "dwmapi.dll"

    $fnGetModuleHandleW = Get-NativeCall (Get-NativeExport $kernel32 'GetModuleHandleW') ([IntPtr]) ([Type[]]@([IntPtr]))
    $hModule = $fnGetModuleHandleW.DynamicInvoke([IntPtr]::Zero)
    $pDefWndProc = Get-NativeExport $user32 'DefWindowProcW'

    $className = "QuickPSCanvasClass_" + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $pClassName = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($className)
    $pTitle = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($Title)

    $cbSize = 80
    $pClass = New-NativeBlock $cbSize
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pClass, 0, $cbSize)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pClass, 4, 3)
    [System.Runtime.InteropServices.Marshal]::WriteIntPtr($pClass, 8, $pDefWndProc)
    [System.Runtime.InteropServices.Marshal]::WriteIntPtr($pClass, 24, $hModule)
    [System.Runtime.InteropServices.Marshal]::WriteIntPtr($pClass, 64, $pClassName)

    $fnRegisterClass = Get-NativeCall (Get-NativeExport $user32 'RegisterClassExW') ([uint16]) ([Type[]]@([IntPtr]))
    $atom = [uint16]$fnRegisterClass.DynamicInvoke($pClass)
    Remove-NativeBlock $pClass

    $fnCreateWindow = Get-NativeCall (Get-NativeExport $user32 'CreateWindowExW') ([IntPtr]) ([Type[]]@(
        [uint32],[IntPtr],[IntPtr],[uint32],[int32],[int32],[int32],[int32],[IntPtr],[IntPtr],[IntPtr],[IntPtr]
    ))

    $winStyle = if ($Borderless) { 0x80000000u } else { 0x00CF0000u }
    $exStyle  = if ($Borderless) { 0x00040000u } else { 0u }
    $hwnd = [IntPtr]$fnCreateWindow.DynamicInvoke(
        $exStyle, $pClassName, $pTitle, $winStyle,
        [int32]150, [int32]150, [int32]$Width, [int32]$Height,
        [IntPtr]::Zero, [IntPtr]::Zero, $hModule, [IntPtr]::Zero
    )

    if ($Borderless -and $hwnd -ne [IntPtr]::Zero) {
        $fnDwmSetWindowAttribute = Get-NativeCall (Get-NativeExport $dwmapi 'DwmSetWindowAttribute') ([int32]) ([Type[]]@([IntPtr], [uint32], [IntPtr], [uint32]))
        $fnDwmExtendFrameIntoClientArea = Get-NativeCall (Get-NativeExport $dwmapi 'DwmExtendFrameIntoClientArea') ([int32]) ([Type[]]@([IntPtr], [IntPtr]))

        $pDark = New-NativeBlock 4; [System.Runtime.InteropServices.Marshal]::WriteInt32($pDark, 0, 1)
        [void]$fnDwmSetWindowAttribute.DynamicInvoke($hwnd, [uint32]20, $pDark, [uint32]4)
        $pCorner = New-NativeBlock 4; [System.Runtime.InteropServices.Marshal]::WriteInt32($pCorner, 0, 2)
        [void]$fnDwmSetWindowAttribute.DynamicInvoke($hwnd, [uint32]33, $pCorner, [uint32]4)
        $pBackdrop = New-NativeBlock 4; [System.Runtime.InteropServices.Marshal]::WriteInt32($pBackdrop, 0, 2)
        $hrB = [int32]$fnDwmSetWindowAttribute.DynamicInvoke($hwnd, [uint32]38, $pBackdrop, [uint32]4)
        if ($hrB -ne 0) { [void]$fnDwmSetWindowAttribute.DynamicInvoke($hwnd, [uint32]1029, $pDark, [uint32]4) }
        $pMargins = New-NativeBlock 16
        [System.Runtime.InteropServices.Marshal]::WriteInt32($pMargins, 0, -1); [System.Runtime.InteropServices.Marshal]::WriteInt32($pMargins, 4, -1); [System.Runtime.InteropServices.Marshal]::WriteInt32($pMargins, 8, -1); [System.Runtime.InteropServices.Marshal]::WriteInt32($pMargins, 12, -1)
        [void]$fnDwmExtendFrameIntoClientArea.DynamicInvoke($hwnd, $pMargins)
        Remove-NativeBlock $pDark; Remove-NativeBlock $pCorner; Remove-NativeBlock $pBackdrop; Remove-NativeBlock $pMargins
    }

    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pClassName)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pTitle)

    return [PSCustomObject]@{
        Hwnd         = $hwnd
        HModule      = $hModule
        ClassName    = $className
        Title        = $Title
        Width        = $Width
        Height       = $Height
        Borderless   = [bool]$Borderless
        Headless     = $false
        Alive        = $true
        WindowShown  = $false
    }
}

# ==============================================================================
# SECTION 60: WINDOWS INPUT (UNIFIED MESSAGE DECODER)
# ==============================================================================

function global:Decode-WindowsInputMessage {
    param(
        $State,
        [IntPtr] $Hwnd,
        [IntPtr] $ScratchMsg,
        [IntPtr] $ScratchPoint,
        [IntPtr] $ScratchPaint,
        $FnBeginPaint,
        $FnScreenToClient,
        [ref]$PaintActive
    )

    # Event-scoped fields must not leak into the next Windows message.
    # Persistent state (pointer position/buttons, dimensions, Alive) is left intact.
    $State.KeyCode = 0
    $State.CharCode = [char]0
    $State.WheelDelta = 0
    $State.IsDoubleClick = $false

    $msgId = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchMsg, 8)
    switch ($msgId) {
        0x0010 { # WM_CLOSE
            $State.Alive = $false
            return $false
        }
        0x0002 { # WM_DESTROY
            $State.Alive = $false
            return $false
        }
        0x0014 { # WM_ERASEBKGND
            return $true
        }
        0x0005 { # WM_SIZE
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            $newWidth  = [int32]($lParam -band 0xFFFF)
            $newHeight = [int32](($lParam -shr 16) -band 0xFFFF)
            if ($newWidth -gt 0 -and $newHeight -gt 0 -and
                ($newWidth -ne $State.Width -or $newHeight -ne $State.Height)) {
                $State.Width = $newWidth
                $State.Height = $newHeight
                $State.ResizeSerial = [uint64]($State.ResizeSerial + 1)
                $State.RedrawSerial = [uint64]($State.RedrawSerial + 1)
            }
            return $true
        }
        0x000F { # WM_PAINT
            # A paint request means the application image must be redrawn, but
            # DirectPort does not start a paint transaction here.  The window's
            # DefWindowProc validates WM_PAINT during DispatchMessage; the
            # application redraws exactly once after WaitEvent returns.
            $State.RedrawSerial = [uint64]($State.RedrawSerial + 1)
            return $true
        }
        0x0200 { # WM_MOUSEMOVE
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            $wParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 16)
            $State.MouseX = [int16]($lParam -band 0xFFFF)
            $State.MouseY = [int16](($lParam -shr 16) -band 0xFFFF)
            $State.LeftDown = (($wParam -band 0x0001) -ne 0)
            return $true
        }
        0x0201 { # WM_LBUTTONDOWN
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            $State.MouseX = [int16]($lParam -band 0xFFFF)
            $State.MouseY = [int16](($lParam -shr 16) -band 0xFFFF)
            $State.LeftDown = $true
            return $true
        }
        0x0202 { # WM_LBUTTONUP
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            $State.MouseX = [int16]($lParam -band 0xFFFF)
            $State.MouseY = [int16](($lParam -shr 16) -band 0xFFFF)
            $State.LeftDown = $false
            return $true
        }
        0x0245 { # WM_POINTERUPDATE
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            $wParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 16)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($ScratchPoint, 0, [int16]($lParam -band 0xFFFF))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($ScratchPoint, 4, [int16](($lParam -shr 16) -band 0xFFFF))
            if ($null -ne $FnScreenToClient -and $Hwnd -ne [IntPtr]::Zero) {
                [void]$FnScreenToClient.DynamicInvoke($Hwnd, $ScratchPoint)
                $State.MouseX = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchPoint, 0)
                $State.MouseY = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchPoint, 4)
            }
            $State.LeftDown = ((($wParam -shr 16) -band 0x0004) -ne 0)
            return $true
        }
        0x0246 { # WM_POINTERDOWN
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($ScratchPoint, 0, [int16]($lParam -band 0xFFFF))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($ScratchPoint, 4, [int16](($lParam -shr 16) -band 0xFFFF))
            if ($null -ne $FnScreenToClient -and $Hwnd -ne [IntPtr]::Zero) {
                [void]$FnScreenToClient.DynamicInvoke($Hwnd, $ScratchPoint)
                $State.MouseX = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchPoint, 0)
                $State.MouseY = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchPoint, 4)
            }
            $State.LeftDown = $true
            return $true
        }
        0x0247 { # WM_POINTERUP
            $lParam = [System.Runtime.InteropServices.Marshal]::ReadInt64($ScratchMsg, 24)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($ScratchPoint, 0, [int16]($lParam -band 0xFFFF))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($ScratchPoint, 4, [int16](($lParam -shr 16) -band 0xFFFF))
            if ($null -ne $FnScreenToClient -and $Hwnd -ne [IntPtr]::Zero) {
                [void]$FnScreenToClient.DynamicInvoke($Hwnd, $ScratchPoint)
                $State.MouseX = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchPoint, 0)
                $State.MouseY = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchPoint, 4)
            }
            $State.LeftDown = $false
            return $true
        }
        0x0100 { # WM_KEYDOWN
            $State.KeyCode = [System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchMsg, 16)
            return $true
        }
        0x0102 { # WM_CHAR
            $State.CharCode = [char][System.Runtime.InteropServices.Marshal]::ReadInt32($ScratchMsg, 16)
            return $true
        }
    }
    return $true
}

# ==============================================================================
# SECTION 70: WINDOWS CANVAS & TEXT (DIRECT2D, DIRECTWRITE, WIC)
# ==============================================================================

function global:New-Canvas {
    [CmdletBinding()]
    param(
        [int] $Width = 960,
        [int] $Height = 540,
        [string] $Title = 'DirectPort Window',
        [switch] $Borderless,
        [switch] $Headless,
        [switch] $SoftwareRendering,
        [switch] $EnableSharing
    )

    # 1. Initialize Windows Host
    $hostState = New-WindowsHost -Width $Width -Height $Height -Title $Title -Borderless:$Borderless -Headless:$Headless
    $hwnd = $hostState.Hwnd

    $user32   = Open-NativeLibrary "user32.dll"
    $kernel32 = Open-NativeLibrary "kernel32.dll"
    $d2d1     = Open-NativeLibrary "d2d1.dll"
    $dwrite   = Open-NativeLibrary "dwrite.dll"
    $ole32    = Open-NativeLibrary "ole32.dll"

    # 2. Native User32 bindings
    $fnGetMessage      = Get-NativeCall (Get-NativeExport $user32 'GetMessageW') ([int32]) ([Type[]]@([IntPtr],[IntPtr],[uint32],[uint32]))
    $fnPeekMessage     = Get-NativeCall (Get-NativeExport $user32 'PeekMessageW') ([bool]) ([Type[]]@([IntPtr],[IntPtr],[uint32],[uint32],[uint32]))
    $fnTranslateMsg    = Get-NativeCall (Get-NativeExport $user32 'TranslateMessage') ([bool]) ([Type[]]@([IntPtr]))
    $fnDispatchMsg     = Get-NativeCall (Get-NativeExport $user32 'DispatchMessageW') ([IntPtr]) ([Type[]]@([IntPtr]))
    $fnScreenToClient  = Get-NativeCall (Get-NativeExport $user32 'ScreenToClient') ([bool]) ([Type[]]@([IntPtr],[IntPtr]))
    $fnDestroyWindow   = Get-NativeCall (Get-NativeExport $user32 'DestroyWindow') ([bool]) ([Type[]]@([IntPtr]))
    $fnBeginPaint      = Get-NativeCall (Get-NativeExport $user32 'BeginPaint') ([IntPtr]) ([Type[]]@([IntPtr],[IntPtr]))
    $fnEndPaint        = Get-NativeCall (Get-NativeExport $user32 'EndPaint') ([bool]) ([Type[]]@([IntPtr],[IntPtr]))
    $fnReleaseCapture  = Get-NativeCall (Get-NativeExport $user32 'ReleaseCapture') ([bool]) ([Type[]]@())
    $fnSendMessageW    = Get-NativeCall (Get-NativeExport $user32 'SendMessageW') ([IntPtr]) ([Type[]]@([IntPtr],[uint32],[IntPtr],[IntPtr]))
    $fnShowWindow      = Get-NativeCall (Get-NativeExport $user32 'ShowWindow') ([bool]) ([Type[]]@([IntPtr],[int32]))

    # 3. Direct2D & DirectWrite Factories
    $pfnD2D1CreateFactory = Get-NativeExport $d2d1 "D2D1CreateFactory"
    $createD2DFactory = Get-NativeCall $pfnD2D1CreateFactory ([int32]) ([Type[]]@([uint32], [IntPtr], [IntPtr], [IntPtr]))
    $iidD2D1 = [Guid]::Parse("06152247-6f50-465a-9245-118bfd3b6007").ToByteArray()
    $pIidD2D1 = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy($iidD2D1, 0, $pIidD2D1, 16)
    $pD2DFactoryOut = New-NativeBlock ([IntPtr]::Size)
    $d2dFactoryHr = [int32]$createD2DFactory.DynamicInvoke([uint32]0, $pIidD2D1, [IntPtr]::Zero, $pD2DFactoryOut)
    $pD2DFactory = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pD2DFactoryOut)
    Remove-NativeBlock $pIidD2D1
    Remove-NativeBlock $pD2DFactoryOut

    $pfnDWriteCreateFactory = Get-NativeExport $dwrite "DWriteCreateFactory"
    $createDWriteFactory = Get-NativeCall $pfnDWriteCreateFactory ([int32]) ([Type[]]@([uint32], [IntPtr], [IntPtr]))
    $iidDWrite = [Guid]::Parse("b859ee5a-d838-4b5b-a2e8-1adc7d93db48").ToByteArray()
    $pIidDWrite = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy($iidDWrite, 0, $pIidDWrite, 16)
    $pDWriteFactoryOut = New-NativeBlock ([IntPtr]::Size)
    $dwriteFactoryHr = [int32]$createDWriteFactory.DynamicInvoke([uint32]0, $pIidDWrite, $pDWriteFactoryOut)
    $pDWriteFactory = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pDWriteFactoryOut)
    Remove-NativeBlock $pIidDWrite
    Remove-NativeBlock $pDWriteFactoryOut

    # 4. Render Target Initialization (Direct HWND RenderTarget or WIC Staging Target)
    $pWicFactory = [IntPtr]::Zero
    $pWicBitmap = [IntPtr]::Zero
    $pTarget = [IntPtr]::Zero
    $pPreviewTarget = [IntPtr]::Zero
    $fnPreviewBeginDraw = $null
    $fnPreviewEndDraw = $null
    $fnPreviewDrawBitmap = $null
    $fnPreviewCreateBitmapFromWic = $null
    $fnPreviewCheckWindowState = $null
    $targetHr = 0
    $previewTargetHr = 0

    $fnCoInitializeEx = Get-NativeCall (Get-NativeExport $ole32 'CoInitializeEx') ([int32]) ([Type[]]@([IntPtr], [uint32]))
    $coInitHr = [int32]$fnCoInitializeEx.DynamicInvoke([IntPtr]::Zero, [uint32]0) # COINIT_MULTITHREADED
    $coInitOwned = ($coInitHr -eq 0 -or $coInitHr -eq 1)

    # If sharing is requested OR in headless mode, create WIC staging bitmap
    if ($EnableSharing -or $Headless) {
        $fnCoCreateInstance = Get-NativeCall (Get-NativeExport $ole32 'CoCreateInstance') ([int32]) ([Type[]]@(
            [IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr]
        ))
        $pClsidWic = New-NativeBlock 16
        $pIidWic = New-NativeBlock 16
        [System.Runtime.InteropServices.Marshal]::Copy(
            [Guid]::Parse('cacaf262-9370-4615-a13b-9f5539da4c0a').ToByteArray(), 0, $pClsidWic, 16)
        [System.Runtime.InteropServices.Marshal]::Copy(
            [Guid]::Parse('ec5ec8a9-c395-4314-9c77-54d7a935ff70').ToByteArray(), 0, $pIidWic, 16)
        $pWicFactoryOut = New-NativeBlock ([IntPtr]::Size)
        $wicFactoryHr = [int32]$fnCoCreateInstance.DynamicInvoke(
            $pClsidWic, [IntPtr]::Zero, [uint32]1, $pIidWic, $pWicFactoryOut)
        $pWicFactory = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pWicFactoryOut)
        Remove-NativeBlock $pClsidWic
        Remove-NativeBlock $pIidWic
        Remove-NativeBlock $pWicFactoryOut

        $pGuidPbgra = New-NativeBlock 16
        [System.Runtime.InteropServices.Marshal]::Copy(
            [Guid]::Parse('6fddc324-4e03-4bfe-b185-3d77768dc910').ToByteArray(), 0, $pGuidPbgra, 16)
        $fnCreateWicBitmap = Get-ComCall $pWicFactory 17 ([int32]) ([Type[]]@(
            [IntPtr], [uint32], [uint32], [IntPtr], [uint32], [IntPtr]
        ))
        $pWicBitmapOut = New-NativeBlock ([IntPtr]::Size)
        $wicBitmapHr = [int32]$fnCreateWicBitmap.DynamicInvoke(
            $pWicFactory, [uint32]$Width, [uint32]$Height, $pGuidPbgra, [uint32]2, $pWicBitmapOut)
        $pWicBitmap = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pWicBitmapOut)
        Remove-NativeBlock $pGuidPbgra
        Remove-NativeBlock $pWicBitmapOut

        $wicRtProps = New-NativeBlock 28
        [System.Runtime.InteropServices.Marshal]::WriteInt32($wicRtProps, 0, $(if ($SoftwareRendering) { 1 } else { 0 }))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($wicRtProps, 4, 87)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($wicRtProps, 8, 1) # PREMULTIPLIED
        $pTargetOut = New-NativeBlock ([IntPtr]::Size)
        $fnCreateWicTarget = Get-ComCall $pD2DFactory 13 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
        $targetHr = [int32]$fnCreateWicTarget.DynamicInvoke($pD2DFactory, $pWicBitmap, $wicRtProps, $pTargetOut)
        $pTarget = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pTargetOut)
        Remove-NativeBlock $wicRtProps
        Remove-NativeBlock $pTargetOut

        if (-not $Headless -and $hwnd -ne [IntPtr]::Zero) {
            $previewRtProps = New-NativeBlock 28
            [System.Runtime.InteropServices.Marshal]::WriteInt32($previewRtProps, 0, $(if ($SoftwareRendering) { 1 } else { 0 }))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($previewRtProps, 4, 87)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($previewRtProps, 8, 1)
            $hwndProps = New-NativeBlock 24
            [System.Runtime.InteropServices.Marshal]::WriteIntPtr($hwndProps, 0, $hwnd)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndProps, 8, $Width)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndProps, 12, $Height)
            $pPreviewTargetOut = New-NativeBlock ([IntPtr]::Size)
            $fnCreateHwndTarget = Get-ComCall $pD2DFactory 14 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
            $previewTargetHr = [int32]$fnCreateHwndTarget.DynamicInvoke($pD2DFactory, $previewRtProps, $hwndProps, $pPreviewTargetOut)
            $pPreviewTarget = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pPreviewTargetOut)
            Remove-NativeBlock $previewRtProps
            Remove-NativeBlock $hwndProps
            Remove-NativeBlock $pPreviewTargetOut

            $fnPreviewBeginDraw = Get-ComCall $pPreviewTarget 48 ([void]) ([Type[]]@([IntPtr]))
            $fnPreviewEndDraw = Get-ComCall $pPreviewTarget 49 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
            $fnPreviewDrawBitmap = Get-ComCall $pPreviewTarget 26 ([void]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [uint32], [IntPtr]))
            $fnPreviewCreateBitmapFromWic = Get-ComCall $pPreviewTarget 5 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
            $fnPreviewCheckWindowState = Get-ComCall $pPreviewTarget 57 ([uint32]) ([Type[]]@([IntPtr]))
        }
    } else {
        # Direct HWND RenderTarget (Hardware-accelerated primary target, zero blit copy!)
        $hwndRtProps = New-NativeBlock 28
        [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndRtProps, 0, $(if ($SoftwareRendering) { 1 } else { 0 }))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndRtProps, 4, 87)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndRtProps, 8, 1) # PREMULTIPLIED
        $hwndProps = New-NativeBlock 24
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($hwndProps, 0, $hwnd)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndProps, 8, $Width)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($hwndProps, 12, $Height)
        $pTargetOut = New-NativeBlock ([IntPtr]::Size)
        $fnCreateHwndTarget = Get-ComCall $pD2DFactory 14 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
        $targetHr = [int32]$fnCreateHwndTarget.DynamicInvoke($pD2DFactory, $hwndRtProps, $hwndProps, $pTargetOut)
        $pTarget = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pTargetOut)
        Remove-NativeBlock $hwndRtProps
        Remove-NativeBlock $hwndProps
        Remove-NativeBlock $pTargetOut
        $pPreviewTarget = $pTarget
    }

    # 5. Direct2D Active Context Function Table
    $ctx = [PSCustomObject]@{
        Ptr              = $pTarget
        BeginDraw        = Get-ComCall $pTarget 48 ([void])  ([Type[]]@([IntPtr]))
        EndDraw          = Get-ComCall $pTarget 49 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
        Clear            = Get-ComCall $pTarget 47 ([void])  ([Type[]]@([IntPtr], [IntPtr]))
        FillRect         = Get-ComCall $pTarget 17 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
        DrawRect         = Get-ComCall $pTarget 16 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [IntPtr]))
        FillRoundedRect  = Get-ComCall $pTarget 19 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
        DrawRoundedRect  = Get-ComCall $pTarget 18 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [IntPtr]))
        DrawText         = Get-ComCall $pTarget 27 ([void])  ([Type[]]@([IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr], [IntPtr], [uint32], [uint32]))
        DrawBitmap       = Get-ComCall $pTarget 26 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [uint32], [IntPtr]))
        CreateSolidBrush = Get-ComCall $pTarget 8  ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    }

    $fnCreateTextFormat  = Get-ComCall $pDWriteFactory 15 ([int32]) ([Type[]]@([IntPtr],[IntPtr],[IntPtr],[uint32],[uint32],[uint32],[single],[IntPtr],[IntPtr]))
    $fnCreateTextLayout  = Get-ComCall $pDWriteFactory 18 ([int32]) ([Type[]]@([IntPtr],[IntPtr],[uint32],[IntPtr],[single],[single],[IntPtr]))
    $fnCreateCompRT      = Get-ComCall $pTarget 12 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr], [uint32], [IntPtr]))

    # Persistent Reusable Native Scratch Blocks (Hot-path zero allocations!)
    $scratchColor   = New-NativeBlock 16
    $scratchRect    = New-NativeBlock 16
    $scratchRRect   = New-NativeBlock 24
    $scratchMsg     = New-NativeBlock 48
    $scratchPoint   = New-NativeBlock 8
    $scratchPaint   = New-NativeBlock 72
    $scratchOut     = New-NativeBlock ([IntPtr]::Size)
    $scratchMetrics = New-NativeBlock 64

    $brushCache = [System.Collections.Generic.Dictionary[int32, IntPtr]]::new()
    $textFormatCache = [System.Collections.Generic.Dictionary[string, IntPtr]]::new()
    $strCache = [System.Collections.Generic.Dictionary[string, IntPtr]]::new()
    $metricsCache = [System.Collections.Generic.Dictionary[string, object]]::new()
    $fnGetMetrics = $null

    $windowShown = $false

    $stateObj = [Windows.Graphics.CanvasWindowState]::new()
    $stateObj.Alive = $true
    $stateObj.Width = $Width
    $stateObj.Height = $Height
    $paintActive = $false
    $stateObj.ResizeSerial = [uint64]0
    $stateObj.RedrawSerial = [uint64]0

    # 6. Optional Sharing Subsystem (DP-ARCH-005 Section 20: Detached from default Canvas!)
    $shareHandle = $null
    if ($EnableSharing) {
        $shareHandle = Attach-WindowsCanvasShareProducer -Width $Width -Height $Height -WicBitmap $pWicBitmap
    }

    $diagnostics = [PSCustomObject]@{
        D2DFactoryHResult      = $d2dFactoryHr
        DWriteFactoryHResult   = $dwriteFactoryHr
        D3D12DeviceHResult     = if ($shareHandle) { $shareHandle.DeviceHr } else { [int32]0 }
        D3D12ResourceHResult   = if ($shareHandle) { $shareHandle.ResourceHr } else { [int32]0 }
        RenderTargetHResult    = $targetHr
        PreviewTargetHResult   = $previewTargetHr
        AssociatedHwnd         = $hwnd
        SharedTextureName      = if ($shareHandle) { $shareHandle.TextureName } else { $null }
        SharedFenceName        = if ($shareHandle) { $shareHandle.FenceName } else { $null }
        ProducerManifestName   = if ($shareHandle) { $shareHandle.ManifestName } else { $null }
        AdapterLuid            = if ($shareHandle) { $shareHandle.AdapterLuid } else { [uint64]0 }
        RowPitch               = if ($shareHandle) { $shareHandle.RowPitch } else { [uint32]0 }
        MappedAddress          = if ($shareHandle) { $shareHandle.MappedAddress } else { [IntPtr]::Zero }
        LastPresentHResult     = [int32]0
        LastPreviewHResult     = [int32]0
        PresentCount           = [uint64]0
        WindowState            = [uint32]0
        WindowShown            = $false
        SharingEnabled         = [bool]$EnableSharing
    }

    $canvas = [PSCustomObject]@{
        PSTypeName        = 'Windows.Graphics.Canvas'
        Hwnd              = $hwnd
        Target            = $pTarget
        D2DFactory        = $pD2DFactory
        DWriteFactory     = $pDWriteFactory
        D3D12Device       = if ($shareHandle) { $shareHandle.Device } else { [IntPtr]::Zero }
        SharedResource    = if ($shareHandle) { $shareHandle.Resource } else { [IntPtr]::Zero }
        SharedFence       = if ($shareHandle) { $shareHandle.Fence } else { [IntPtr]::Zero }
        SharedTextureName = if ($shareHandle) { $shareHandle.TextureName } else { $null }
        SharedFenceName   = if ($shareHandle) { $shareHandle.FenceName } else { $null }
        ManifestName      = if ($shareHandle) { $shareHandle.ManifestName } else { $null }
        FrameCount        = [uint64]0
        Alive             = $true
        Width             = $Width
        Height            = $Height
        Diagnostics       = $diagnostics
    }

    $getArgbBytes = {
        param([object] $c)
        if ($c -is [uint32] -or $c -is [uint64]) {
            return [System.BitConverter]::GetBytes([uint32]$c)
        }
        $val = [int64]$c
        return [System.BitConverter]::GetBytes([int32]$val)
    }

    $getBrush = {
        param([object] $argb)
        $bArr = & $getArgbBytes $argb
        $key = [System.BitConverter]::ToInt32($bArr, 0)
        if ($brushCache.ContainsKey($key)) {
            return $brushCache[$key]
        }
        $bByte, $gByte, $rByte, $aByte = $bArr
        $b = [single]($bByte / 255.0)
        $g = [single]($gByte / 255.0)
        $r = [single]($rByte / 255.0)
        $a = [single]($aByte / 255.0)

        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 0,  [System.BitConverter]::SingleToInt32Bits($r))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 4,  [System.BitConverter]::SingleToInt32Bits($g))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 8,  [System.BitConverter]::SingleToInt32Bits($b))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 12, [System.BitConverter]::SingleToInt32Bits($a))

        $null = $ctx.CreateSolidBrush.DynamicInvoke($ctx.Ptr, $scratchColor, [IntPtr]::Zero, $scratchOut)
        $brush = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($scratchOut)
        $brushCache[$key] = $brush
        return $brush
    }.GetNewClosure()

    # --- RETAINED MODE BUFFER API ---

    $canvas | Add-Member -MemberType ScriptMethod -Name 'CreateCompatibleTarget' -Value {
        $pOut = New-NativeBlock ([IntPtr]::Size)
        $hr = [int32]$fnCreateCompRT.DynamicInvoke($pTarget, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [uint32]0, $pOut)
        $ptr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)
        Remove-NativeBlock $pOut
        if ($hr -ne 0) { throw "CreateCompatibleRenderTarget HRESULT 0x$($hr.ToString('X8'))" }
        return $ptr
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'SetTarget' -Value {
        param([IntPtr]$newTarget)
        $ctx.Ptr = if ($newTarget -eq [IntPtr]::Zero) { $pTarget } else { $newTarget }
        $ctx.BeginDraw         = Get-ComCall $ctx.Ptr 48 ([void])  ([Type[]]@([IntPtr]))
        $ctx.EndDraw           = Get-ComCall $ctx.Ptr 49 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
        $ctx.Clear             = Get-ComCall $ctx.Ptr 47 ([void])  ([Type[]]@([IntPtr], [IntPtr]))
        $ctx.FillRect          = Get-ComCall $ctx.Ptr 17 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
        $ctx.DrawRect          = Get-ComCall $ctx.Ptr 16 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [IntPtr]))
        $ctx.FillRoundedRect   = Get-ComCall $ctx.Ptr 19 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
        $ctx.DrawRoundedRect   = Get-ComCall $ctx.Ptr 18 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [IntPtr]))
        $ctx.DrawText          = Get-ComCall $ctx.Ptr 27 ([void])  ([Type[]]@([IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr], [IntPtr], [uint32], [uint32]))
        $ctx.DrawBitmap        = Get-ComCall $ctx.Ptr 26 ([void])  ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [single], [uint32], [IntPtr]))
        $ctx.CreateSolidBrush  = Get-ComCall $ctx.Ptr 8  ([int32]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr], [IntPtr]))
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'GetBitmap' -Value {
        param([IntPtr]$compTarget)
        $fnGet = Get-ComCall $compTarget 57 ([int32]) ([Type[]]@([IntPtr], [IntPtr]))
        $pOut = New-NativeBlock ([IntPtr]::Size)
        $hr = [int32]$fnGet.DynamicInvoke($compTarget, $pOut)
        $ptr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)
        Remove-NativeBlock $pOut
        if ($hr -ne 0) { throw "GetBitmap HRESULT 0x$($hr.ToString('X8'))" }
        return $ptr
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'DrawBitmap' -Value {
        param([IntPtr]$bitmap, [single]$opacity = 1.0, [uint32]$interpolationMode = 1)
        [void]$ctx.DrawBitmap.DynamicInvoke($ctx.Ptr, $bitmap, [IntPtr]::Zero, $opacity, $interpolationMode, [IntPtr]::Zero)
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'ReleaseResource' -Value {
        param([IntPtr]$ptr)
        if ($ptr -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($ptr) }
    }.GetNewClosure()

    # --- GEOMETRY API ---

    $canvas | Add-Member -MemberType ScriptMethod -Name 'BeginDraw' -Value {
        param([object] $clearArgb = 0xFF000000)
        $bArr = & $getArgbBytes $clearArgb
        $bByte, $gByte, $rByte, $aByte = $bArr
        $b = [single]($bByte / 255.0)
        $g = [single]($gByte / 255.0)
        $r = [single]($rByte / 255.0)
        $a = [single]($aByte / 255.0)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 0,  [System.BitConverter]::SingleToInt32Bits($r))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 4,  [System.BitConverter]::SingleToInt32Bits($g))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 8,  [System.BitConverter]::SingleToInt32Bits($b))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchColor, 12, [System.BitConverter]::SingleToInt32Bits($a))

        [void]$ctx.BeginDraw.DynamicInvoke($ctx.Ptr)
        [void]$ctx.Clear.DynamicInvoke($ctx.Ptr, $scratchColor)
        return $true
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'EndDraw' -Value {
        $hr = [int32]$ctx.EndDraw.DynamicInvoke($ctx.Ptr, [IntPtr]::Zero, [IntPtr]::Zero)
        $diagnostics.LastPresentHResult = $hr
        if ($paintActive) {
            [void]$fnEndPaint.DynamicInvoke($hwnd, $scratchPaint)
            $paintActive = $false
        }
        return ($hr -eq 0)
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'Present' -Value {
        if (-not $this.EndDraw()) { return $false }

        # If WIC staging target was used and HWND preview target is present
        if ($pWicBitmap -ne [IntPtr]::Zero -and $pPreviewTarget -ne [IntPtr]::Zero -and -not $Headless) {
            $pPreviewBitmapOut = New-NativeBlock ([IntPtr]::Size)
            $previewBitmapHr = [int32]$fnPreviewCreateBitmapFromWic.DynamicInvoke(
                $pPreviewTarget, $pWicBitmap, [IntPtr]::Zero, $pPreviewBitmapOut)
            $pPreviewBitmap = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pPreviewBitmapOut)
            Remove-NativeBlock $pPreviewBitmapOut
            if ($previewBitmapHr -eq 0 -and $pPreviewBitmap -ne [IntPtr]::Zero) {
                [void]$fnPreviewBeginDraw.DynamicInvoke($pPreviewTarget)
                [void]$fnPreviewDrawBitmap.DynamicInvoke(
                    $pPreviewTarget, $pPreviewBitmap, [IntPtr]::Zero, [single]1.0, [uint32]1, [IntPtr]::Zero)
                $previewEndHr = [int32]$fnPreviewEndDraw.DynamicInvoke($pPreviewTarget, [IntPtr]::Zero, [IntPtr]::Zero)
                $diagnostics.LastPreviewHResult = $previewEndHr
                [void][System.Runtime.InteropServices.Marshal]::Release($pPreviewBitmap)
            }
        }

        if (-not $Headless -and -not $windowShown -and $hwnd -ne [IntPtr]::Zero) {
            [void]$fnShowWindow.DynamicInvoke($hwnd, [int32]1)
            $windowShown = $true
            $diagnostics.WindowShown = $true
        }

        # If D3D12 IPC sharing is active, update texture and signal fence
        if ($null -ne $shareHandle) {
            $copyHr = [int32]$shareHandle.CopyPixels($pWicBitmap)
            if ($copyHr -ne 0) {
                $diagnostics.LastPresentHResult = $copyHr
                return $false
            }
            $this.FrameCount = [uint64]($this.FrameCount + 1)
            $signalHr = [int32]$shareHandle.SignalFence($this.FrameCount)
            if ($signalHr -ne 0) {
                $diagnostics.LastPresentHResult = $signalHr
                return $false
            }
        }

        $diagnostics.PresentCount = [uint64]($diagnostics.PresentCount + 1)
        return $true
    }.GetNewClosure()

    # Normative DP-ARCH-005 Stage 6: Publish is compatibility alias for Present
    $canvas | Add-Member -MemberType ScriptMethod -Name 'Publish' -Value {
        return $this.Present()
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'FillRect' -Value {
        param([single]$x, [single]$y, [single]$w, [single]$h, [object]$argb, [single]$radius = 0.0)
        $brush = & $getBrush $argb
        if ($radius -gt 0.0) {
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 0,  [System.BitConverter]::SingleToInt32Bits($x))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 4,  [System.BitConverter]::SingleToInt32Bits($y))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 8,  [System.BitConverter]::SingleToInt32Bits([single]($x + $w)))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 12, [System.BitConverter]::SingleToInt32Bits([single]($y + $h)))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 16, [System.BitConverter]::SingleToInt32Bits($radius))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 20, [System.BitConverter]::SingleToInt32Bits($radius))
            $ctx.FillRoundedRect.DynamicInvoke($ctx.Ptr, $scratchRRect, $brush)
        } else {
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 0,  [System.BitConverter]::SingleToInt32Bits($x))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 4,  [System.BitConverter]::SingleToInt32Bits($y))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 8,  [System.BitConverter]::SingleToInt32Bits([single]($x + $w)))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 12, [System.BitConverter]::SingleToInt32Bits([single]($y + $h)))
            $ctx.FillRect.DynamicInvoke($ctx.Ptr, $scratchRect, $brush)
        }
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'DrawRect' -Value {
        param([single]$x, [single]$y, [single]$w, [single]$h, [object]$argb, [single]$strokeWidth = 1.0, [single]$radius = 0.0)
        $brush = & $getBrush $argb
        if ($radius -gt 0.0) {
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 0,  [System.BitConverter]::SingleToInt32Bits($x))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 4,  [System.BitConverter]::SingleToInt32Bits($y))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 8,  [System.BitConverter]::SingleToInt32Bits([single]($x + $w)))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 12, [System.BitConverter]::SingleToInt32Bits([single]($y + $h)))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 16, [System.BitConverter]::SingleToInt32Bits($radius))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRRect, 20, [System.BitConverter]::SingleToInt32Bits($radius))
            $ctx.DrawRoundedRect.DynamicInvoke($ctx.Ptr, $scratchRRect, $brush, $strokeWidth, [IntPtr]::Zero)
        } else {
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 0,  [System.BitConverter]::SingleToInt32Bits($x))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 4,  [System.BitConverter]::SingleToInt32Bits($y))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 8,  [System.BitConverter]::SingleToInt32Bits([single]($x + $w)))
            [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 12, [System.BitConverter]::SingleToInt32Bits([single]($y + $h)))
            $ctx.DrawRect.DynamicInvoke($ctx.Ptr, $scratchRect, $brush, $strokeWidth, [IntPtr]::Zero)
        }
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'DrawText' -Value {
        param([string]$text, [single]$x, [single]$y, [single]$maxWidth, [single]$maxHeight, [object]$argb, [single]$fontSize = 14.0, [string]$fontFamily = "Segoe UI", [bool]$bold = $false, [object]$alignment = 0)
        if ([string]::IsNullOrEmpty($text)) { return }
        $brush = & $getBrush $argb

        $weight = if ($bold) { [uint32]700 } else { [uint32]400 }
        $fmtKey = "$fontFamily-$fontSize-$bold"
        if ($textFormatCache.ContainsKey($fmtKey)) {
            $pFormat = $textFormatCache[$fmtKey]
        } else {
            if (-not $strCache.ContainsKey($fontFamily)) {
                $strCache[$fontFamily] = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($fontFamily)
            }
            $pFont = $strCache[$fontFamily]
            $locKey = "en-us"
            if (-not $strCache.ContainsKey($locKey)) {
                $strCache[$locKey] = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($locKey)
            }
            $pLoc = $strCache[$locKey]

            $null = $fnCreateTextFormat.DynamicInvoke($pDWriteFactory, $pFont, [IntPtr]::Zero, $weight, [uint32]0, [uint32]5, $fontSize, $pLoc, $scratchOut)
            $pFormat = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($scratchOut)
            $textFormatCache[$fmtKey] = $pFormat
        }

        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 0,  [System.BitConverter]::SingleToInt32Bits($x))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 4,  [System.BitConverter]::SingleToInt32Bits($y))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 8,  [System.BitConverter]::SingleToInt32Bits([single]($x + $maxWidth)))
        [System.Runtime.InteropServices.Marshal]::WriteInt32($scratchRect, 12, [System.BitConverter]::SingleToInt32Bits([single]($y + $maxHeight)))

        if (-not $strCache.ContainsKey($text)) {
            $strCache[$text] = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($text)
        }
        $pStr = $strCache[$text]
        $ctx.DrawText.DynamicInvoke($ctx.Ptr, $pStr, [uint32]$text.Length, $pFormat, $scratchRect, $brush, [uint32]0, [uint32]0)
    }.GetNewClosure()

    # DP-ARCH-005 Stage 8: Reusable scratch metrics & cached delegate stub
    $canvas | Add-Member -MemberType ScriptMethod -Name 'MeasureText' -Value {
        param([string]$text, [single]$fontSize = 14.0, [string]$fontFamily = "Segoe UI", [bool]$bold = $false)
        $m = [Windows.Graphics.TextMetrics]::new()
        if ([string]::IsNullOrEmpty($text)) {
            $m.Width = 0.0; $m.Height = $fontSize * 1.2
            return $m
        }

        $weight = if ($bold) { [uint32]700 } else { [uint32]400 }
        $fmtKey = "$fontFamily-$fontSize-$bold"
        $cacheKey = "$fmtKey|$text"
        if ($metricsCache.ContainsKey($cacheKey)) {
            $cached = $metricsCache[$cacheKey]
            $m.Width = $cached.Width
            $m.Height = $cached.Height
            return $m
        }

        if ($textFormatCache.ContainsKey($fmtKey)) {
            $pFormat = $textFormatCache[$fmtKey]
        } else {
            if (-not $strCache.ContainsKey($fontFamily)) {
                $strCache[$fontFamily] = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($fontFamily)
            }
            $pFont = $strCache[$fontFamily]
            $locKey = "en-us"
            if (-not $strCache.ContainsKey($locKey)) {
                $strCache[$locKey] = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($locKey)
            }
            $pLoc = $strCache[$locKey]

            $null = $fnCreateTextFormat.DynamicInvoke($pDWriteFactory, $pFont, [IntPtr]::Zero, $weight, [uint32]0, [uint32]5, $fontSize, $pLoc, $scratchOut)
            $pFormat = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($scratchOut)
            $textFormatCache[$fmtKey] = $pFormat
        }

        if (-not $strCache.ContainsKey($text)) {
            $strCache[$text] = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($text)
        }
        $pStr = $strCache[$text]

        $null = $fnCreateTextLayout.DynamicInvoke($pDWriteFactory, $pStr, [uint32]$text.Length, $pFormat, [single]10000.0, [single]10000.0, $scratchOut)
        $layout = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($scratchOut)

        if ($null -eq $fnGetMetrics) {
            $fnGetMetrics = Get-ComCall $layout 60 ([int32]) ([Type[]]@([IntPtr], [IntPtr]))
        }
        $null = $fnGetMetrics.DynamicInvoke($layout, $scratchMetrics)

        $w1 = [System.BitConverter]::ToSingle([System.BitConverter]::GetBytes([System.Runtime.InteropServices.Marshal]::ReadInt32($scratchMetrics, 8)), 0)
        $w2 = [System.BitConverter]::ToSingle([System.BitConverter]::GetBytes([System.Runtime.InteropServices.Marshal]::ReadInt32($scratchMetrics, 12)), 0)
        $h  = [System.BitConverter]::ToSingle([System.BitConverter]::GetBytes([System.Runtime.InteropServices.Marshal]::ReadInt32($scratchMetrics, 16)), 0)

        if ($layout -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($layout) }

        $m.Width = [Math]::Max($w1, $w2)
        $m.Height = if ($h -gt 0.0) { $h } else { $fontSize * 1.2 }
        $metricsCache[$cacheKey] = @{ Width = $m.Width; Height = $m.Height }
        return $m
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'Minimize' -Value {
        if ($hwnd -ne [IntPtr]::Zero) {
            [void]$fnShowWindow.DynamicInvoke($hwnd, [int32]6)
        }
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'DragWindow' -Value {
        if ($hwnd -ne [IntPtr]::Zero) {
            [void]$fnReleaseCapture.DynamicInvoke()
            [void]$fnSendMessageW.DynamicInvoke($hwnd, [uint32]0x00A1, [IntPtr]2, [IntPtr]::Zero)
        }
    }.GetNewClosure()

    # DP-ARCH-005 Stage 7: Unified message decoder calls
    $canvas | Add-Member -MemberType ScriptMethod -Name 'WaitEvent' -Value {
        if ($hwnd -eq [IntPtr]::Zero) {
            $stateObj.Alive = $false
            $this.Alive = $false
            return $null
        }

        $ret = [int32]$fnGetMessage.DynamicInvoke($scratchMsg, [IntPtr]::Zero, [uint32]0, [uint32]0)
        if ($ret -le 0) {
            $stateObj.Alive = $false
            $this.Alive = $false
            return $null
        }

        $continue = Decode-WindowsInputMessage -State $stateObj -Hwnd $hwnd -ScratchMsg $scratchMsg -ScratchPoint $scratchPoint -ScratchPaint $scratchPaint -FnBeginPaint $fnBeginPaint -FnScreenToClient $fnScreenToClient -PaintActive ([ref]$paintActive)
        if (-not $continue) {
            $this.Alive = $false
            return $null
        }

        [void]$fnTranslateMsg.DynamicInvoke($scratchMsg)
        [void]$fnDispatchMsg.DynamicInvoke($scratchMsg)
        return $stateObj
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'Pump' -Value {
        param([uint32] $waitMilliseconds = 0)
        if ($hwnd -eq [IntPtr]::Zero) { return $stateObj }

        while ([bool]$fnPeekMessage.DynamicInvoke($scratchMsg, [IntPtr]::Zero, [uint32]0, [uint32]0, [uint32]1)) {
            $continue = Decode-WindowsInputMessage -State $stateObj -Hwnd $hwnd -ScratchMsg $scratchMsg -ScratchPoint $scratchPoint -ScratchPaint $scratchPaint -FnBeginPaint $fnBeginPaint -FnScreenToClient $fnScreenToClient -PaintActive ([ref]$paintActive)
            if (-not $continue) {
                $this.Alive = $false
                break
            }
            [void]$fnTranslateMsg.DynamicInvoke($scratchMsg)
            [void]$fnDispatchMsg.DynamicInvoke($scratchMsg)
        }
        return $stateObj
    }.GetNewClosure()

    $canvas | Add-Member -MemberType ScriptMethod -Name 'Dispose' -Value {
        if (-not $this.Alive) { return }
        $this.Alive = $false
        $stateObj.Alive = $false

        if ($brushCache) {
            foreach ($b in $brushCache.Values) {
                if ($b -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($b) }
            }
            $brushCache.Clear()
        }
        if ($textFormatCache) {
            foreach ($f in $textFormatCache.Values) {
                if ($f -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($f) }
            }
            $textFormatCache.Clear()
        }
        if ($strCache) {
            foreach ($s in $strCache.Values) {
                if ($s -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($s) }
            }
            $strCache.Clear()
        }

        if ($paintActive -and $hwnd -ne [IntPtr]::Zero) {
            [void]$fnEndPaint.DynamicInvoke($hwnd, $scratchPaint)
            $paintActive = $false
        }
        if ($hwnd -ne [IntPtr]::Zero) { [void]$fnDestroyWindow.DynamicInvoke($hwnd) }

        if ($pPreviewTarget -ne [IntPtr]::Zero -and $pPreviewTarget -ne $pTarget) { [void][System.Runtime.InteropServices.Marshal]::Release($pPreviewTarget) }
        if ($pTarget -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pTarget) }
        if ($pWicBitmap -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pWicBitmap) }
        if ($pWicFactory -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pWicFactory) }
        if ($pD2DFactory -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pD2DFactory) }
        if ($pDWriteFactory -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pDWriteFactory) }

        if ($null -ne $shareHandle) { $shareHandle.Dispose() }

        if ($scratchColor -ne [IntPtr]::Zero)   { Remove-NativeBlock $scratchColor }
        if ($scratchRect -ne [IntPtr]::Zero)    { Remove-NativeBlock $scratchRect }
        if ($scratchRRect -ne [IntPtr]::Zero)   { Remove-NativeBlock $scratchRRect }
        if ($scratchMsg -ne [IntPtr]::Zero)     { Remove-NativeBlock $scratchMsg }
        if ($scratchPoint -ne [IntPtr]::Zero)   { Remove-NativeBlock $scratchPoint }
        if ($scratchPaint -ne [IntPtr]::Zero)   { Remove-NativeBlock $scratchPaint }
        if ($scratchOut -ne [IntPtr]::Zero)     { Remove-NativeBlock $scratchOut }
        if ($scratchMetrics -ne [IntPtr]::Zero) { Remove-NativeBlock $scratchMetrics }

        if ($coInitOwned) {
            $fnCoUninitialize = Get-NativeCall (Get-NativeExport $ole32 'CoUninitialize') ([void]) ([Type[]]@())
            [void]$fnCoUninitialize.DynamicInvoke()
        }
    }.GetNewClosure()

    return $canvas
}

# ==============================================================================
# SECTION 80: WINDOWS OPTIONAL SHARING / D3D12 PRODUCER (DETACHED FROM CANVAS)
# ==============================================================================

function global:Attach-WindowsCanvasShareProducer {
    [CmdletBinding()]
    param(
        [int] $Width,
        [int] $Height,
        [IntPtr] $WicBitmap
    )

    $d3d12    = Open-NativeLibrary "d3d12.dll"
    $kernel32 = Open-NativeLibrary "kernel32.dll"

    # D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, IID_ID3D12Device, &device)
    $fnD3D12CreateDevice = Get-NativeCall (Get-NativeExport $d3d12 'D3D12CreateDevice') ([int32]) ([Type[]]@([IntPtr], [int32], [IntPtr], [IntPtr]))
    $pIidD3D12Device = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy(
        [Guid]::Parse('189819f1-1db6-4b57-be54-1821339b85f7').ToByteArray(), 0, $pIidD3D12Device, 16)
    $pDeviceOut = New-NativeBlock ([IntPtr]::Size)
    $d3d12DeviceHr = [int32]$fnD3D12CreateDevice.DynamicInvoke([IntPtr]::Zero, [int32]0xB000, $pIidD3D12Device, $pDeviceOut)
    $pD3D12Device = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pDeviceOut)
    Remove-NativeBlock $pIidD3D12Device
    Remove-NativeBlock $pDeviceOut
    if ($d3d12DeviceHr -ne 0 -or $pD3D12Device -eq [IntPtr]::Zero) {
        throw ("D3D12CreateDevice failed: 0x{0:X8}" -f [uint32]$d3d12DeviceHr)
    }

    # D3D12_HEAP_PROPERTIES
    $heapProps = New-NativeBlock 32
    [System.Runtime.InteropServices.Marshal]::WriteInt32($heapProps, 0, 4)  # CUSTOM
    [System.Runtime.InteropServices.Marshal]::WriteInt32($heapProps, 4, 2)  # WRITE_COMBINE
    [System.Runtime.InteropServices.Marshal]::WriteInt32($heapProps, 8, 1)  # L0
    [System.Runtime.InteropServices.Marshal]::WriteInt32($heapProps, 12, 0)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($heapProps, 16, 0)

    # D3D12_RESOURCE_DESC
    $resDesc = New-NativeBlock 56
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 0, 2)                 # TEXTURE2D
    [System.Runtime.InteropServices.Marshal]::WriteInt64($resDesc, 8, 0)                 # Alignment = default
    [System.Runtime.InteropServices.Marshal]::WriteInt64($resDesc, 16, [int64]$Width)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 24, $Height)
    [System.Runtime.InteropServices.Marshal]::WriteInt16($resDesc, 28, 1)
    [System.Runtime.InteropServices.Marshal]::WriteInt16($resDesc, 30, 1)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 32, 87)                # B8G8R8A8_UNORM
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 36, 1)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 40, 0)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 44, 1)                 # ROW_MAJOR
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resDesc, 48, 0x10)              # ALLOW_CROSS_ADAPTER

    $pIidResource = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy(
        [Guid]::Parse('696442be-a72e-4059-bc79-5b5c98040fad').ToByteArray(), 0, $pIidResource, 16)
    $pResourceOut = New-NativeBlock ([IntPtr]::Size)
    $fnCreateCommitted = Get-ComCall $pD3D12Device 27 ([int32]) ([Type[]]@(
        [IntPtr], [IntPtr], [int32], [IntPtr], [int32], [IntPtr], [IntPtr], [IntPtr]
    ))
    $d3d12ResourceHr = [int32]$fnCreateCommitted.DynamicInvoke(
        $pD3D12Device,
        $heapProps,
        [int32]0x21,             # SHARED | SHARED_CROSS_ADAPTER
        $resDesc,
        [int32]0,                # COMMON
        [IntPtr]::Zero,
        $pIidResource,
        $pResourceOut
    )
    $pResource = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pResourceOut)
    Remove-NativeBlock $pIidResource
    Remove-NativeBlock $pResourceOut
    Remove-NativeBlock $heapProps
    Remove-NativeBlock $resDesc
    if ($d3d12ResourceHr -ne 0 -or $pResource -eq [IntPtr]::Zero) {
        throw ("D3D12 shared SysRAM CreateCommittedResource failed: 0x{0:X8}" -f [uint32]$d3d12ResourceHr)
    }

    # Persistent CPU map
    $fnResourceMap = Get-ComCall $pResource 8 ([int32]) ([Type[]]@([IntPtr], [uint32], [IntPtr], [IntPtr]))
    $fnResourceUnmap = Get-ComCall $pResource 9 ([void]) ([Type[]]@([IntPtr], [uint32], [IntPtr]))
    $pMappedDataOut = New-NativeBlock ([IntPtr]::Size)
    $mapHr = [int32]$fnResourceMap.DynamicInvoke($pResource, [uint32]0, [IntPtr]::Zero, $pMappedDataOut)
    $pMappedData = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pMappedDataOut)
    Remove-NativeBlock $pMappedDataOut
    if ($mapHr -ne 0 -or $pMappedData -eq [IntPtr]::Zero) {
        throw ("ID3D12Resource::Map failed: 0x{0:X8}" -f [uint32]$mapHr)
    }
    $rowPitch = [uint32]((($Width * 4) + 255) -band (-bnot 255))
    $bufferSize = [uint32]([uint64]$rowPitch * [uint64]$Height)

    # Publish named NT handles
    $pidNum = [uint32]$PID
    $texName = "Global\DirectPortTexture_$pidNum"
    $fenceName = "Global\DirectPortFence_$pidNum"

    $fnCreateSharedHandle = Get-ComCall $pD3D12Device 31 ([int32]) ([Type[]]@(
        [IntPtr], [IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr]
    ))
    $pTexName = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($texName)
    $pSharedTexHandleOut = New-NativeBlock ([IntPtr]::Size)
    $shareTextureHr = [int32]$fnCreateSharedHandle.DynamicInvoke(
        $pD3D12Device, $pResource, [IntPtr]::Zero, [uint32]0x10000000, $pTexName, $pSharedTexHandleOut)
    $hSharedTexture = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pSharedTexHandleOut)
    Remove-NativeBlock $pSharedTexHandleOut
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pTexName)

    # Shared cross-adapter fence
    $pIidFence = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy(
        [Guid]::Parse('0a753dcf-c4d8-4b91-adf6-be5a60d95a76').ToByteArray(), 0, $pIidFence, 16)
    $pFenceOut = New-NativeBlock ([IntPtr]::Size)
    $fnCreateFence = Get-ComCall $pD3D12Device 36 ([int32]) ([Type[]]@(
        [IntPtr], [uint64], [int32], [IntPtr], [IntPtr]
    ))
    $createFenceHr = [int32]$fnCreateFence.DynamicInvoke($pD3D12Device, [uint64]0, [int32]0x3, $pIidFence, $pFenceOut)
    $pFence = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pFenceOut)
    Remove-NativeBlock $pIidFence
    Remove-NativeBlock $pFenceOut

    $pFenceName = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($fenceName)
    $pSharedFenceHandleOut = New-NativeBlock ([IntPtr]::Size)
    $shareFenceHr = [int32]$fnCreateSharedHandle.DynamicInvoke(
        $pD3D12Device, $pFence, [IntPtr]::Zero, [uint32]0x10000000, $pFenceName, $pSharedFenceHandleOut)
    $hSharedFence = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pSharedFenceHandleOut)
    Remove-NativeBlock $pSharedFenceHandleOut
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pFenceName)

    $fnFenceSignal = Get-ComCall $pFence 10 ([int32]) ([Type[]]@([IntPtr], [uint64]))
    $fnGetAdapterLuid = Get-ComCall $pD3D12Device 43 ([uint64]) ([Type[]]@([IntPtr]))
    $adapterLuidBits = [uint64]$fnGetAdapterLuid.DynamicInvoke($pD3D12Device)

    # MMF Manifest
    $manifestName = "DirectPort_Producer_Manifest_$pidNum"
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew(
        $manifestName, [int64]1056, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $acc = $mmf.CreateViewAccessor(0, 1056, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $acc.Write(0, [uint64]0)
    $acc.Write(8, [uint32]$Width)
    $acc.Write(12, [uint32]$Height)
    $acc.Write(16, [int32]87)
    $luidBytes = [System.BitConverter]::GetBytes([uint64]$adapterLuidBits)
    $acc.WriteArray(20, $luidBytes, 0, 8)
    $enc = [System.Text.Encoding]::Unicode
    $texNameBytes = $enc.GetBytes($texName + [char]0)
    $fenceNameBytes = $enc.GetBytes($fenceName + [char]0)
    $acc.WriteArray(28, $texNameBytes, 0, $texNameBytes.Length)
    $acc.WriteArray(540, $fenceNameBytes, 0, $fenceNameBytes.Length)

    $fnWicCopyPixels = if ($WicBitmap -ne [IntPtr]::Zero) {
        Get-ComCall $WicBitmap 7 ([int32]) ([Type[]]@([IntPtr], [IntPtr], [uint32], [uint32], [IntPtr]))
    } else { $null }

    $shareObj = [PSCustomObject]@{
        Device         = $pD3D12Device
        Resource       = $pResource
        Fence          = $pFence
        SharedTexture  = $hSharedTexture
        SharedFence    = $hSharedFence
        TextureName    = $texName
        FenceName      = $fenceName
        ManifestName   = $manifestName
        AdapterLuid    = $adapterLuidBits
        RowPitch       = $rowPitch
        MappedAddress  = $pMappedData
        DeviceHr       = $d3d12DeviceHr
        ResourceHr     = $d3d12ResourceHr
    }

    $shareObj | Add-Member -MemberType ScriptMethod -Name 'CopyPixels' -Value {
        param([IntPtr]$pBitmap)
        if ($pBitmap -eq [IntPtr]::Zero -or $null -eq $fnWicCopyPixels) { return 0 }
        return [int32]$fnWicCopyPixels.DynamicInvoke($pBitmap, [IntPtr]::Zero, $rowPitch, $bufferSize, $pMappedData)
    }.GetNewClosure()

    $shareObj | Add-Member -MemberType ScriptMethod -Name 'SignalFence' -Value {
        param([uint64]$frameVal)
        [System.Threading.Thread]::MemoryBarrier()
        $hr = [int32]$fnFenceSignal.DynamicInvoke($pFence, $frameVal)
        $acc.Write(0, $frameVal)
        return $hr
    }.GetNewClosure()

    $shareObj | Add-Member -MemberType ScriptMethod -Name 'Dispose' -Value {
        if ($pResource -ne [IntPtr]::Zero -and $pMappedData -ne [IntPtr]::Zero) {
            [void]$fnResourceUnmap.DynamicInvoke($pResource, [uint32]0, [IntPtr]::Zero)
        }
        if ($pFence -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pFence) }
        if ($pResource -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pResource) }
        if ($pD3D12Device -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pD3D12Device) }
        if ($acc) { $acc.Dispose() }
        if ($mmf) { $mmf.Dispose() }
        $fnCloseHandle = Get-NativeCall (Get-NativeExport $kernel32 'CloseHandle') ([bool]) ([Type[]]@([IntPtr]))
        if ($hSharedFence -ne [IntPtr]::Zero) { [void]$fnCloseHandle.DynamicInvoke($hSharedFence) }
        if ($hSharedTexture -ne [IntPtr]::Zero) { [void]$fnCloseHandle.DynamicInvoke($hSharedTexture) }
    }.GetNewClosure()

    return $shareObj
}

# ==============================================================================
# SECTION 90-120: ANDROID & ADDITIONAL PLATFORM ADAPTERS
# ==============================================================================

function global:Invoke-AndroidCanvasBeginDraw { param($State, [object]$ClearColor) return $true }
function global:Invoke-AndroidCanvasFillRect  { param($State, [single]$X, [single]$Y, [single]$W, [single]$H, [object]$Color, [single]$Radius) }
function global:Invoke-AndroidCanvasDrawRect  { param($State, [single]$X, [single]$Y, [single]$W, [single]$H, [object]$Color, [single]$StrokeWidth, [single]$Radius) }
function global:Invoke-AndroidCanvasDrawText  { param($State, [string]$Text, [single]$X, [single]$Y, [single]$W, [single]$H, [object]$Color, [single]$Size, [string]$Font, [bool]$Bold, [int]$Align) }
function global:Invoke-AndroidCanvasMeasureText {
    param($State, [string]$Text, [single]$Size, [string]$Font, [bool]$Bold)
    return [PSCustomObject]@{ Width = ($Text.Length * $Size * 0.6); Height = ($Size * 1.2) }
}
function global:Invoke-AndroidCanvasPresent   { param($State) return $true }
function global:Invoke-AndroidCanvasDrawBitmap{ param($State, $Bitmap, [single]$Opacity, [uint32]$Interp) }

# ==============================================================================
# SECTION 130: REFERENCE-OBJECT ASSEMBLY & CONFORMANCE CARRIER
# ==============================================================================

# ==============================================================================
# SECTION 127: DIRECTPORT NODE AND SINGLE APPLICATION ATTACHMENT
# ==============================================================================

function global:New-DirectPortGrantDomain {
    [CmdletBinding()]
    param([string] $Name = 'GrantDomain')
    $domain = [PSCustomObject]@{
        PSTypeName  = 'DirectPort.GrantDomain'
        Name        = $Name
        Live        = $true
        ActiveCount = 0
        Lock        = [object]::new()
        Epoch       = 1
    }
    $domain | Add-Member ScriptMethod Acquire {
        [System.Threading.Monitor]::Enter($this.Lock)
        try {
            if (-not $this.Live) { return $false }
            $this.ActiveCount++
            return $true
        }
        finally {
            [System.Threading.Monitor]::Exit($this.Lock)
        }
    }
    $domain | Add-Member ScriptMethod Release {
        [System.Threading.Monitor]::Enter($this.Lock)
        try {
            if ($this.ActiveCount -gt 0) { $this.ActiveCount-- }
        }
        finally {
            [System.Threading.Monitor]::Exit($this.Lock)
        }
    }
    $domain | Add-Member ScriptMethod BeginRundown {
        [System.Threading.Monitor]::Enter($this.Lock)
        try {
            if (-not $this.Live) { return $false }
            $this.Live = $false
            $this.Epoch++
            return $true
        }
        finally {
            [System.Threading.Monitor]::Exit($this.Lock)
        }
    }
    return $domain
}

function global:New-CapabilityScope {
    [CmdletBinding()]
    param([string] $Name = 'DirectPort', $Parent = $null, $ExecutionOwner = $null)

    $node = [PSCustomObject]@{
        PSTypeName             = 'QuickPS.CapabilityScope'
        NodeId                 = [Guid]::NewGuid().ToString('N')
        ResolverIncarnation    = [Guid]::NewGuid().ToString('N')
        SemanticIdentityDomain = [Guid]::NewGuid().ToString('N')
        Name                   = $Name
        Parent                 = $Parent
        ExecutionOwner         = $ExecutionOwner
        LocalCapabilities      = @{}
        LocalHandles           = @{}
        Children               = @{}
        CurrentApplication     = $null
        LastReceipt            = $null
        DiscoveryCount         = 0
        Rundown                = $false
    }
    $node | Add-Member ScriptMethod RetainLocal {
        param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)] $Capability, $ExecutionOwner = $null)
        $entry = [PSCustomObject]@{
            PSTypeName          = 'QuickPS.Capability'
            Name                = $Name
            ObjectHandle        = [Guid]::NewGuid().ToString('N')
            ResolverIncarnation = $this.ResolverIncarnation
            Capability          = $Capability
            ExecutionOwner      = $ExecutionOwner
            OwnerRunspaceId     = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId
            Source              = 'LOCAL'
            Revoked             = $false
            Grants              = @{}
            GrantDomain         = (New-DirectPortGrantDomain -Name $Name)
        }
        $this.LocalCapabilities[$Name] = $entry
        $this.LocalHandles[$entry.ObjectHandle] = $entry
        return $entry
    }
    $node | Add-Member ScriptMethod ResolveLocal {
        param([Parameter(Mandatory)][string] $Name)
        if ($this.LocalCapabilities.ContainsKey($Name)) { return $this.LocalCapabilities[$Name] }
        return $null
    }
    $node | Add-Member ScriptMethod ResolveLocalHandle {
        param([Parameter(Mandatory)][string] $ObjectHandle)
        if ($this.LocalHandles.ContainsKey($ObjectHandle)) { return $this.LocalHandles[$ObjectHandle] }
        return $null
    }
    $node | Add-Member ScriptMethod Discover {
        param([Parameter(Mandatory)][string] $Name, $Context = $null)
        $this.DiscoveryCount++
        if ($null -eq $Context) {
            $Context = [PSCustomObject]@{ AttemptId = [Guid]::NewGuid(); RemainingDepth = 16; Visited = @{} }
        }
        if ($Context.RemainingDepth -le 0 -or $Context.Visited.ContainsKey($this.NodeId)) { return $null }
        $Context.Visited[$this.NodeId] = $true
        $Context.RemainingDepth--
        if ($this.LocalCapabilities.ContainsKey($Name)) {
            return [PSCustomObject]@{ SourceNode = $this; Name = $Name; AttemptId = $Context.AttemptId }
        }
        if ($null -ne $this.Parent) { return $this.Parent.Discover($Name, $Context) }
        return $null
    }
    $node | Add-Member ScriptMethod Checkout {
        param([Parameter(Mandatory)] $Discovered)
        $sourceEntry = $Discovered.SourceNode.ResolveLocal([string]$Discovered.Name)
        if ($null -eq $sourceEntry -or $sourceEntry.Revoked) { throw "Capability is no longer available: $($Discovered.Name)" }
        if ($sourceEntry.ResolverIncarnation -eq $this.ResolverIncarnation) { return $sourceEntry }

        $receiverHandle = [Guid]::NewGuid().ToString('N')
        $targetOwnerHandle = $sourceEntry.ObjectHandle
        $callerNodeId = $this.NodeId
        $sourceEntry.Grants[$callerNodeId] = [PSCustomObject]@{
            ReceiverHandle = $receiverHandle
            AdmittedAt     = [DateTimeOffset]::UtcNow
        }

        $sourceOwnerRunspaceId = $sourceEntry.OwnerRunspaceId
        $sourceOwner = $sourceEntry.ExecutionOwner
        $sourceCapability = $sourceEntry.Capability
        $currentRunspaceId = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId

        $isSameOwner = ($this.ExecutionOwner -eq $sourceOwner -or ($null -ne $sourceOwnerRunspaceId -and $currentRunspaceId -eq $sourceOwnerRunspaceId))
        $callable = if ($isSameOwner) {
            $sourceCapability
        } else {
            $queue = $script:RunspaceDispatchQueue
            $wake = $script:RunspaceDispatchSignal
            {
                $callArgs = if ($PSBoundParameters.Count -gt 0) {
                    $PSBoundParameters
                } elseif ($null -ne $args -and $args.Count -gt 0) {
                    @($args)
                } else {
                    $null
                }
                $request = [PSCustomObject]@{
                    TargetOwnerHandle = $targetOwnerHandle
                    ReceiverHandle    = $receiverHandle
                    CallerNodeId      = $callerNodeId
                    Arguments         = $callArgs
                    Result            = $null
                    ErrorRecord       = $null
                    Completed         = [System.Threading.ManualResetEventSlim]::new($false)
                    Status            = 'Pending'
                }
                $queue.Enqueue($request)
                [void]$wake.Set()
                $signaled = $request.Completed.Wait(30000)
                if (-not $signaled) {
                    $request.Status = 'TimedOut'
                    throw 'Owner dispatch request timed out waiting for owning execution context.'
                }
                try {
                    if ($null -ne $request.ErrorRecord) { throw $request.ErrorRecord }
                    return $request.Result
                }
                finally {
                    $request.Completed.Dispose()
                }
            }.GetNewClosure()
        }

        $entry = [PSCustomObject]@{
            PSTypeName                = 'QuickPS.Capability'
            Name                      = $sourceEntry.Name
            ObjectHandle              = $receiverHandle
            TargetOwnerHandle         = $targetOwnerHandle
            SourceObjectHandle        = $targetOwnerHandle
            ResolverIncarnation       = $this.ResolverIncarnation
            SourceResolverIncarnation = $sourceEntry.ResolverIncarnation
            Capability                = $callable
            ExecutionOwner            = $sourceOwner
            OwnerRunspaceId           = $sourceOwnerRunspaceId
            Source                    = 'CHECKOUT'
            Revoked                   = $false
        }
        $this.LocalCapabilities[$entry.Name] = $entry
        $this.LocalHandles[$entry.ObjectHandle] = $entry
        return $entry
    }
    return $node
}

$applicationContextVariable = Get-Variable -Name QuickPSApplicationContext -Scope Global -ErrorAction SilentlyContinue
$script:RootCapabilityScope = if ($null -ne $applicationContextVariable -and $null -ne $applicationContextVariable.Value.Node) {
    $applicationContextVariable.Value.Node
} else {
    New-CapabilityScope -Name 'DirectPort.Root'
}

$script:RunspaceDispatchQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:RunspaceDispatchSignal = [Threading.AutoResetEvent]::new($false)
$script:RunspaceDispatcher = [PSCustomObject]@{
    Queue = $script:RunspaceDispatchQueue
    Wake  = $script:RunspaceDispatchSignal
}

function global:Invoke-RunspaceDispatch {
    [CmdletBinding()]
    param([int] $Maximum = 64)

    $completed = 0
    $request = $null
    while ($completed -lt $Maximum -and $script:RunspaceDispatchQueue.TryDequeue([ref]$request)) {
        if ($null -eq $request -or $request.Status -ne 'Pending') {
            continue
        }
        $request.Status = 'Executing'
        try {
            $callerNodeId = [string]$request.CallerNodeId
            $targetHandle = [string]$request.TargetOwnerHandle

            $callerNode = if ($callerNodeId -eq $script:RootCapabilityScope.NodeId) {
                $script:RootCapabilityScope
            } else {
                $script:RootCapabilityScope.Children[$callerNodeId]
            }
            if ($null -eq $callerNode -or $callerNode.Rundown) {
                throw "Caller node '$callerNodeId' is not attached or has been rundown."
            }

            $entry = $script:RootCapabilityScope.ResolveLocalHandle($targetHandle)
            if ($null -eq $entry -or $entry.Revoked) {
                throw "Owner-local capability handle is invalid or revoked: $targetHandle"
            }

            if ($callerNodeId -ne $script:RootCapabilityScope.NodeId) {
                if (-not $entry.Grants.ContainsKey($callerNodeId)) {
                    throw "Caller node '$callerNodeId' is not admitted for capability '$($entry.Name)'."
                }
            }

            if ($null -ne $entry.GrantDomain) {
                if (-not $entry.GrantDomain.Acquire()) {
                    throw "Capability '$($entry.Name)' is in rundown."
                }
            }

            try {
                $capArgs = $request.Arguments
                if ($null -ne $capArgs) {
                    if ($capArgs -is [System.Collections.IDictionary]) {
                        $request.Result = & $entry.Capability @capArgs
                    } elseif ($capArgs -is [System.Collections.IEnumerable] -and $capArgs.Count -gt 0) {
                        $arr = @($capArgs)
                        $request.Result = & $entry.Capability @arr
                    } else {
                        $request.Result = & $entry.Capability
                    }
                } else {
                    $request.Result = & $entry.Capability
                }
                $request.Status = 'Completed'
            }
            finally {
                if ($null -ne $entry.GrantDomain) {
                    $entry.GrantDomain.Release()
                }
            }
        }
        catch {
            $request.ErrorRecord = $_
            $request.Status = 'Faulted'
        }
        finally {
            $request.Completed.Set()
            $completed++
        }
        $request = $null
    }
    return $completed
}

function global:New-ConstrainedRunspace {
    [CmdletBinding()]
    param(
        [System.Threading.ApartmentState] $ApartmentState = [System.Threading.ApartmentState]::STA,
        $Node = $null,
        $Commands = @{}
    )
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $grantedCapabilities = @()
    $commandMap = @{}
    if ($null -ne $Node) {
        $initialSessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
            'RunspaceDispatcher', $script:RunspaceDispatcher, 'DirectPort owner-dispatch ingress'))

        if ($Commands -is [System.Collections.IDictionary]) {
            foreach ($k in $Commands.Keys) { $commandMap[[string]$k] = [string]$Commands[$k] }
        } elseif ($Commands -is [System.Collections.IEnumerable]) {
            foreach ($c in $Commands) { $commandMap[[string]$c] = [string]$c }
        }

        foreach ($commandName in $commandMap.Keys) {
            $capName = $commandMap[$commandName]
            $entry = $Node.ResolveLocal($capName)
            if ($null -eq $entry -or $entry.Revoked) {
                throw "Runspace command capability is not local or granted for receiver: $capName"
            }
            $grantedCapabilities += $entry

            $targetOwnerHandle = [string]$entry.SourceObjectHandle
            $receiverHandle = [string]$entry.ObjectHandle
            $callerNodeId = [string]$Node.NodeId

            $definition = @"
`$request = [PSCustomObject]@{
    TargetOwnerHandle = '$targetOwnerHandle'
    ReceiverHandle    = '$receiverHandle'
    CallerNodeId      = '$callerNodeId'
    Arguments         = @(`$args)
    Result            = `$null
    ErrorRecord       = `$null
    Completed         = [System.Threading.ManualResetEventSlim]::new(`$false)
    Status            = 'Pending'
}
`$RunspaceDispatcher.Queue.Enqueue(`$request)
[void]`$RunspaceDispatcher.Wake.Set()
`$signaled = `$request.Completed.Wait(30000)
if (-not `$signaled) {
    `$request.Status = 'TimedOut'
    throw 'Owner dispatch request timed out waiting for owning execution context.'
}
try {
    if (`$null -ne `$request.ErrorRecord) { throw `$request.ErrorRecord }
    return `$request.Result
}
finally {
    `$request.Completed.Dispose()
}
"@
            $initialSessionState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
                [string]$commandName, $definition))
        }
    }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialSessionState)
    $runspace.ApartmentState = $ApartmentState
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $residentId = [Guid]::NewGuid().ToString('N')
    $resolverIncarnation = if ($null -ne $Node) { $Node.ResolverIncarnation } else { [Guid]::NewGuid().ToString('N') }

    $resident = [PSCustomObject]@{
        PSTypeName           = 'DirectPort.Resident.Runspace'
        ObjectId             = [Guid]::NewGuid().ToString('N')
        ResidentId           = $residentId
        ResolverIncarnation  = $resolverIncarnation
        Runspace             = $runspace
        Node                 = $Node
        GrantedCapabilities  = $grantedCapabilities
        Commands             = if ($null -ne $commandMap) { $commandMap } else { @{} }
        PowerShell           = $null
        AsyncResult          = $null
        Output               = $null
        Live                 = $true
        Rundown              = $false
    }
    $resident | Add-Member ScriptMethod StartFile {
        param([string] $Path, [hashtable] $Parameters = @{}, $ApplicationContext = $null)
        if ($this.Rundown) { throw 'Runspace resident is in rundown.' }
        if ($null -ne $this.PowerShell -and $this.PowerShell.InvocationStateInfo.State -eq 'Running') {
            throw 'The retained runspace is already executing an application.'
        }
        if ($null -ne $this.PowerShell) {
            $this.PowerShell.Dispose()
            $this.PowerShell = $null
            $this.AsyncResult = $null
            $this.Output = $null
        }
        if ($null -ne $ApplicationContext) {
            $this.Runspace.SessionStateProxy.SetVariable('QuickPSApplicationContext', $ApplicationContext)
            $this.Runspace.SessionStateProxy.SetVariable('DIRECTPORT_PATH', $ApplicationContext.DirectPortPath)
        }
        $pipeline = [System.Management.Automation.PowerShell]::Create()
        $pipeline.Runspace = $this.Runspace
        [void]$pipeline.AddScript('param($path,$parameters) & $path @parameters').AddArgument($Path).AddArgument($Parameters)
        $this.PowerShell = $pipeline
        $this.Output = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $this.AsyncResult = $pipeline.BeginInvoke[psobject,psobject]($null, $this.Output)
        return $this.AsyncResult
    }
    $resident | Add-Member ScriptMethod Wait {
        param([int] $TimeoutMilliseconds = -1)
        if ($null -eq $this.PowerShell -or $null -eq $this.AsyncResult) { return @() }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $waitHandles = @($this.AsyncResult.AsyncWaitHandle, $script:RunspaceDispatchSignal)
        while (-not $this.AsyncResult.IsCompleted) {
            $remaining = if ($TimeoutMilliseconds -lt 0) {
                [System.Threading.Timeout]::Infinite
            } else {
                $rem = $TimeoutMilliseconds - [int]$sw.ElapsedMilliseconds
                if ($rem -le 0) { break }
                $rem
            }
            $signaledIndex = [System.Threading.WaitHandle]::WaitAny($waitHandles, $remaining)
            if ($signaledIndex -eq 1) {
                [void](Invoke-RunspaceDispatch)
            }
            elseif ($signaledIndex -eq 0) {
                break
            }
            elseif ($signaledIndex -eq [System.Threading.WaitHandle]::WaitTimeout) {
                break
            }
        }
        [void](Invoke-RunspaceDispatch)
        if ($this.AsyncResult.IsCompleted) {
            [void]$this.PowerShell.EndInvoke($this.AsyncResult)
            if ($this.PowerShell.Streams.Error.Count) { throw $this.PowerShell.Streams.Error[0] }
            return @($this.Output)
        }
        return @()
    }
    $resident | Add-Member ScriptMethod Stop {
        if ($null -ne $this.PowerShell -and $this.PowerShell.InvocationStateInfo.State -eq 'Running') {
            $this.PowerShell.Stop()
        }
    }
    $resident | Add-Member ScriptMethod Dispose {
        $this.Rundown = $true
        $this.Live = $false
        $this.Stop()
        if ($null -ne $this.PowerShell) { $this.PowerShell.Dispose(); $this.PowerShell = $null }
        if ($null -ne $this.Runspace) { $this.Runspace.Dispose(); $this.Runspace = $null }
    }
    return $resident
}

function global:Stop-HostedScript {
    $attachment = $script:RootCapabilityScope.CurrentApplication
    if ($null -eq $attachment) { return $false }
    try {
        if ($null -ne $attachment.Execution) { $attachment.Execution.Dispose() }
        if ($null -ne $attachment.Node) {
            $attachment.Node.Rundown = $true
            foreach ($entry in $attachment.Node.LocalHandles.Values) {
                $entry.Revoked = $true
            }
        }
    }
    finally {
        $script:RootCapabilityScope.Children.Remove($attachment.Node.NodeId)
        $script:RootCapabilityScope.CurrentApplication = $null
        $script:RootCapabilityScope.LastReceipt = [PSCustomObject]@{
            Event = 'APPLICATION_DETACHED'; Path = $attachment.Path; At = [DateTimeOffset]::UtcNow
        }
    }
    return $true
}

function global:Start-HostedScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('None','Inline','Dedicated','Supplied')][string] $ExecutionPlacement = 'None',
        $ExecutionOwner = $null,
        [switch] $Start,
        [switch] $Headless
    )

    $applicationPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) { throw "Application script not found: $applicationPath" }
    if ([IO.Path]::GetExtension($applicationPath) -ine '.ps1') { throw "DirectPort loads .ps1 applications only: $applicationPath" }
    if ($null -ne $script:RootCapabilityScope.CurrentApplication) { [void](Stop-HostedScript) }

    $applicationNode = New-CapabilityScope -Name ([IO.Path]::GetFileNameWithoutExtension($applicationPath)) -Parent $script:RootCapabilityScope
    foreach ($capabilityName in @('Canvas.New', 'Runspace.New')) {
        $discovered = $applicationNode.Discover($capabilityName)
        if ($null -ne $discovered) { [void]$applicationNode.Checkout($discovered) }
    }
    if ($ExecutionPlacement -eq 'Supplied' -and $null -eq $ExecutionOwner) { throw 'Supplied execution requires ExecutionOwner.' }
    $execution = switch ($ExecutionPlacement) {
        'Dedicated' {
            New-ConstrainedRunspace -Node $applicationNode -Commands @{
                'New-Canvas' = 'Canvas.New'
            }
        }
        'Supplied' { $ExecutionOwner }
        default { $null }
    }
    $attachment = [PSCustomObject]@{
        PSTypeName         = 'DirectPort.ApplicationAttachment'
        Path               = $applicationPath
        Node               = $applicationNode
        Execution          = $execution
        ExecutionPlacement = $ExecutionPlacement
        AttachedAt         = [DateTimeOffset]::UtcNow
    }
    $script:RootCapabilityScope.Children[$applicationNode.NodeId] = $applicationNode
    $script:RootCapabilityScope.CurrentApplication = $attachment
    $script:RootCapabilityScope.LastReceipt = [PSCustomObject]@{
        Event = 'APPLICATION_ATTACHED'; Path = $applicationPath; NodeId = $applicationNode.NodeId; At = $attachment.AttachedAt
    }
    if ($Start) {
        $parameters = if ($Headless) { @{ Headless = $true } } else { @{} }
        $context = [PSCustomObject]@{
            DirectPort                   = if ($ExecutionPlacement -eq 'Inline') { $global:QuickPS } else { $null }
            Node                         = if ($ExecutionPlacement -eq 'Inline') { $applicationNode } else { $null }
            DirectPortPath               = $script:QuickPSSourcePath
            AttachedToExistingDirectPort = $true
            ExecutionPlacement           = $ExecutionPlacement
        }
        switch ($ExecutionPlacement) {
            'None' { throw 'Start requires Inline, Dedicated, or Supplied execution placement.' }
            'Inline' {
                $priorContext = Get-Variable -Name QuickPSApplicationContext -Scope Global -ErrorAction SilentlyContinue
                try {
                    Set-Variable -Name QuickPSApplicationContext -Scope Global -Value $context
                    & $applicationPath @parameters
                }
                finally {
                    if ($null -ne $priorContext) {
                        Set-Variable -Name QuickPSApplicationContext -Scope Global -Value $priorContext.Value
                    } else {
                        Remove-Variable -Name QuickPSApplicationContext -Scope Global -ErrorAction SilentlyContinue
                    }
                }
            }
            default { [void]$execution.StartFile($applicationPath, $parameters, $context) }
        }
    }
    return $attachment
}



$global:QuickPS = [PSCustomObject]@{
    Version           = '0.5.0-rehab'
    SourcePath        = [IO.Path]::GetFullPath($script:QuickPSSourcePath)
    Node              = $script:RootCapabilityScope
    NewCanvas         = ${function:New-Canvas}
    NewRetainedCanvas = ${function:New-DirectPortRetainedCanvas}
    NewRunspace       = ${function:New-ConstrainedRunspace}
    LoadApplication   = ${function:Start-HostedScript}
    DetachApplication = ${function:Stop-HostedScript}
    Surface           = $script:DirectPortSurface
    Host              = ${function:New-WindowsHost}
    NewCellPresenter  = ${function:New-CellPresenter}
    InvokeVtableMethod = ${function:Invoke-ComVtableMethod}
    Linker            = ${function:Export-ScriptBundle}
}

# These are resolver-local retained capabilities. Application nodes explicitly
# checkout the entries they consume once; subsequent calls use their local entry.
[void]$script:RootCapabilityScope.RetainLocal('Canvas.New', $global:QuickPS.NewCanvas, $script:RootCapabilityScope)
[void]$script:RootCapabilityScope.RetainLocal('Runspace.New', $global:QuickPS.NewRunspace, $script:RootCapabilityScope)
[void]$script:RootCapabilityScope.RetainLocal('Application.Load', $global:QuickPS.LoadApplication, $script:RootCapabilityScope)

# ==============================================================================
# SECTION 150: PACKAGING & LINKER ENGINE (ALL-IN-ONE BUILDER)
# ==============================================================================

function global:Export-ScriptBundle {
    <#
    .SYNOPSIS
        Bundles an application script and DirectPort.ps1 into a standalone All-In-One .ps1 file.
    .DESCRIPTION
        Conforms to DP-ARCH-005 Section 26:
        Builds a self-contained portable PowerShell script by embedding the required DirectPort
        presentation engine and replacing external dot-sourcing logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string] $ScriptPath,

        [Parameter(Mandatory=$false, Position=1)]
        [string] $OutputPath = $null,

        [switch] $StripDevNotes = $true
    )

    $resolvedScript = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ScriptPath)
    if (-not (Test-Path $resolvedScript)) {
        throw "Target application script not found: $ScriptPath"
    }

    if ([string]::IsNullOrEmpty($OutputPath)) {
        $dir = Split-Path $resolvedScript -Parent
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedScript)
        $OutputPath = Join-Path $dir "$baseName.AllInOne.ps1"
    }
    $resolvedOut = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

    $dpSourcePath = if ($script:QuickPSSourcePath -and (Test-Path $script:QuickPSSourcePath)) {
        $script:QuickPSSourcePath
    } else {
        Join-Path $PSScriptRoot "DirectPort.ps1"
    }

    if (-not (Test-Path $dpSourcePath)) {
        throw "DirectPort source file not found at $dpSourcePath"
    }

    Write-Host "[DirectPort Linker] Reading application: $resolvedScript" -ForegroundColor Cyan
    Write-Host "[DirectPort Linker] Reading DirectPort:   $dpSourcePath" -ForegroundColor Cyan

    $appLines = Get-Content -Path $resolvedScript
    $dpLines  = Get-Content -Path $dpSourcePath

    # Filter DirectPort lines: strip the direct execution guard at the end
    $cleanDpLines = [System.Collections.Generic.List[string]]::new()
    $inDirectGuard = $false
    foreach ($line in $dpLines) {
        if ($line -match '^\s*#\s*SECTION 160:\s*DIRECT EXECUTION GUARD' -or
            $line -match '^\s*\$isDirectExecution\s*=') {
            $inDirectGuard = $true
            continue
        }
        if ($inDirectGuard) {
            # Check if guard has ended or reached EOF
            continue
        }
        $cleanDpLines.Add($line)
    }

    # Filter Application lines: replace external dot-sourcing of DirectPort
    $cleanAppLines = [System.Collections.Generic.List[string]]::new()
    $skipDotSourceBlock = $false
    foreach ($line in $appLines) {
        if ($line -match '^\s*#requires -Version 7.0') {
            # Preserved at top of bundle
            continue
        }
        if ($line -match '\$dpPath\s*=\s*Join-Path\s+\$PSScriptRoot\s+"DirectPort\.ps1"') {
            $skipDotSourceBlock = $true
            $cleanAppLines.Add("    # [DirectPort Linker: Inlined Runtime Carrier]")
            continue
        }
        if ($skipDotSourceBlock) {
            if ($line -match '^\s*\}\s*$') {
                $skipDotSourceBlock = $false
            }
            continue
        }
        $cleanAppLines.Add($line)
    }

    # Assemble bundle
    $bundleSb = [System.Text.StringBuilder]::new()
    [void]$bundleSb.AppendLine("#requires -Version 7.0")
    [void]$bundleSb.AppendLine("<#")
    [void]$bundleSb.AppendLine("  ==========================================================================")
    [void]$bundleSb.AppendLine("  DirectPort Self-Contained Standalone Application Bundle")
    [void]$bundleSb.AppendLine("  Target Application : $(Split-Path $resolvedScript -Leaf)")
    [void]$bundleSb.AppendLine("  Engine Specification: DP-ARCH-005 Conforming")
    [void]$bundleSb.AppendLine("  Architecture       : Unified Inlined DirectPort + Application Presentation")
    [void]$bundleSb.AppendLine("  ==========================================================================")
    [void]$bundleSb.AppendLine("#>")
    [void]$bundleSb.AppendLine("")
    [void]$bundleSb.AppendLine("# ==============================================================================")
    [void]$bundleSb.AppendLine("# INLINED DIRECTPORT RUNTIME ENGINE")
    [void]$bundleSb.AppendLine("# ==============================================================================")
    [void]$bundleSb.AppendLine($cleanDpLines -join [Environment]::NewLine)
    [void]$bundleSb.AppendLine("")
    [void]$bundleSb.AppendLine("# ==============================================================================")
    [void]$bundleSb.AppendLine("# APPLICATION SOURCE LOGIC: $(Split-Path $resolvedScript -Leaf)")
    [void]$bundleSb.AppendLine("# ==============================================================================")
    [void]$bundleSb.AppendLine($cleanAppLines -join [Environment]::NewLine)

    [System.IO.File]::WriteAllText($resolvedOut, $bundleSb.ToString(), [System.Text.Encoding]::UTF8)
    Write-Host "[DirectPort Linker] Successfully generated All-In-One bundle:" -ForegroundColor Green
    Write-Host "  Destination: $resolvedOut" -ForegroundColor White
    Write-Host "  Lines      : $($bundleSb.ToString().Split("`n").Length)" -ForegroundColor Gray
    Write-Host "  Bytes      : $((Get-Item $resolvedOut).Length)" -ForegroundColor Gray

    return $resolvedOut
}

# ==============================================================================
# SECTION 145: CELL PRESENTER - D3D12 FAST PATH (NO DLL, NO ASSETS, PURE ABI)
# ==============================================================================
<#
    NewCellPresenter: GPU-accelerated cell rendering via direct D3D12 ABI bindings.

    Contract:
      $presenter = New-CellPresenter -Width 1280 -Height 720 -Title "App"
      $state = $presenter.Pump(1)           # Message loop, returns input state
      $ok = $presenter.Present($cells, $cols, $rows, $elapsed, $frame)  # Render
      $dropped = $presenter.DroppedFrames   # Frame drop counter
      $presenter.Dispose()                   # Cleanup

    Implementation:
      - Window creation via RegisterClassExW -> CreateWindowExW (Win32 ABI, exported functions)
      - D3D12 device/queue/swapchain via D3D12CreateDevice + DXGI (D3D12 ABI, exported functions
        for factory creation, then real COM vtable calls for everything after)
      - Message pump via PeekMessageW/TranslateMessage/DispatchMessageW (Win32 ABI)
      - All delegates cached in NativeInteropState.NativeStubs
      - Zero DLL, zero managed wrappers, zero external assets

    COM vtable slot indices below are verified directly against official Windows SDK headers
    (d3d12.h, dxgi.h, dxgi1_2.h).
#>

# ---- Vtable slot tables (verified against official Windows SDK headers) ----
$script:D3D12_DEVICE_SLOTS = @{
    QueryInterface                   = 0
    AddRef                           = 1
    Release                          = 2
    GetPrivateData                   = 3
    SetPrivateData                   = 4
    SetPrivateDataInterface          = 5
    SetName                          = 6
    GetNodeCount                     = 7
    CreateCommandQueue               = 8
    CreateCommandAllocator           = 9
    CreateGraphicsPipelineState      = 10
    CreateComputePipelineState       = 11
    CreateCommandList                = 12
    CheckFeatureSupport              = 13
    CreateDescriptorHeap             = 14
    GetDescriptorHandleIncrementSize = 15
    CreateRootSignature              = 16
    CreateConstantBufferView         = 17
    CreateShaderResourceView         = 18
    CreateUnorderedAccessView        = 19
    CreateRenderTargetView           = 20
    CreateDepthStencilView           = 21
    CreateSampler                    = 22
    CopyDescriptors                  = 23
    CopyDescriptorsSimple            = 24
    GetResourceAllocationInfo        = 25
    GetCustomHeapProperties          = 26
    CreateCommittedResource          = 27
    CreateHeap                       = 28
    CreatePlacedResource             = 29
    CreateReservedResource           = 30
    CreateSharedHandle               = 31
    OpenSharedHandle                 = 32
    OpenSharedHandleByName           = 33
    MakeResident                     = 34
    Evict                            = 35
    CreateFence                      = 36
    GetDeviceRemovedReason           = 37
    GetCopyableFootprints            = 38
    CreateQueryHeap                  = 39
    SetStablePowerState              = 40
    CreateCommandSignature           = 41
    GetResourceTiling                = 42
    GetAdapterLuid                   = 43
}

$script:D3D12_CMDQUEUE_SLOTS = @{
    # 0-2: IUnknown, 3-6: ID3D12Object, 7: GetDevice (ID3D12DeviceChild) -> queue-specific from 8
    UpdateTileMappings    = 8
    CopyTileMappings      = 9
    ExecuteCommandLists   = 10
    SetMarker             = 11
    BeginEvent            = 12
    EndEvent              = 13
    Signal                = 14
    Wait                  = 15
    GetTimestampFrequency = 16
    GetClockCalibration   = 17
    GetDesc               = 18
}

$script:D3D12_COMMAND_ALLOCATOR_SLOTS = @{
    Reset = 8
}

$script:D3D12_COMMAND_LIST_SLOTS = @{
    Close                 = 9
    Reset                 = 10
    ResourceBarrier       = 26
    ExecuteBundle         = 27
    SetDescriptorHeaps    = 28
    SetGraphicsRootSignature = 30
    RSSetViewports        = 21
    RSSetScissorRects     = 22
    OMSetRenderTargets    = 46
    ClearRenderTargetView = 48
    IASetPrimitiveTopology = 20
    DrawInstanced         = 12
}

$script:D3D12_DESCRIPTOR_HEAP_SLOTS = @{
    GetDesc                      = 8
    GetCPUDescriptorHandleStart = 9
    GetGPUDescriptorHandleStart = 10
}

$script:CompileHlsl = & {
    $compilerLibrary = [IntPtr]::Zero
    $compile = $null

    {
        param(
            [Parameter(Mandatory)][string] $Source,
            [Parameter(Mandatory)][string] $EntryPoint,
            [Parameter(Mandatory)][string] $Target,
            [uint32] $Flags = 0
        )

        if ($compilerLibrary -eq [IntPtr]::Zero) {
            $compilerLibrary = Open-NativeLibrary 'd3dcompiler_47.dll'
            $compile = Get-NativeCall (Get-NativeExport $compilerLibrary 'D3DCompile') ([int32]) @(
                [IntPtr], [UIntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr],
                [IntPtr], [uint32], [uint32], [IntPtr], [IntPtr]
            )
        }

        $sourceBytes = [Text.Encoding]::UTF8.GetBytes($Source)
        $sourceBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($sourceBytes.Length)
        $entryBuffer = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($EntryPoint)
        $targetBuffer = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($Target)
        $codeOut = New-NativeBlock ([IntPtr]::Size)
        $errorsOut = New-NativeBlock ([IntPtr]::Size)
        $codeBlob = [IntPtr]::Zero
        $errorsBlob = [IntPtr]::Zero
        try {
            [Runtime.InteropServices.Marshal]::Copy($sourceBytes, 0, $sourceBuffer, $sourceBytes.Length)
            $hr = [int32]$compile.DynamicInvoke(
                $sourceBuffer, [UIntPtr]::new([uint64]$sourceBytes.Length), [IntPtr]::Zero,
                [IntPtr]::Zero, [IntPtr]::Zero, $entryBuffer, $targetBuffer,
                $Flags, [uint32]0, $codeOut, $errorsOut)
            $codeBlob = [Runtime.InteropServices.Marshal]::ReadIntPtr($codeOut)
            $errorsBlob = [Runtime.InteropServices.Marshal]::ReadIntPtr($errorsOut)

            if ($hr -lt 0 -or $codeBlob -eq [IntPtr]::Zero) {
                $message = 'D3DCompile failed.'
                if ($errorsBlob -ne [IntPtr]::Zero) {
                    $errorPointer = Invoke-ComVtableMethod $errorsBlob 3 @() ([IntPtr]) @()
                    $errorLength = [uint64](Invoke-ComVtableMethod $errorsBlob 4 @() ([UIntPtr]) @()).ToUInt64()
                    if ($errorPointer -ne [IntPtr]::Zero -and $errorLength) {
                        $message = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer, [int]$errorLength).TrimEnd([char]0)
                    }
                }
                throw ("D3DCompile failed: 0x{0:X8}: {1}" -f [uint32]$hr, $message)
            }

            $bytecodePointer = Invoke-ComVtableMethod $codeBlob 3 @() ([IntPtr]) @()
            $bytecodeLength = [uint64](Invoke-ComVtableMethod $codeBlob 4 @() ([UIntPtr]) @()).ToUInt64()
            if ($bytecodePointer -eq [IntPtr]::Zero -or -not $bytecodeLength) { throw 'D3DCompile returned an empty shader blob.' }
            $bytecode = [byte[]]::new([int]$bytecodeLength)
            [Runtime.InteropServices.Marshal]::Copy($bytecodePointer, $bytecode, 0, $bytecode.Length)
            return $bytecode
        }
        finally {
            if ($errorsBlob -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod $errorsBlob 2 @() ([uint32]) @()) }
            if ($codeBlob -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod $codeBlob 2 @() ([uint32]) @()) }
            Remove-NativeBlock $codeOut
            Remove-NativeBlock $errorsOut
            if ($sourceBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($sourceBuffer) }
            if ($entryBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($entryBuffer) }
            if ($targetBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($targetBuffer) }
        }
    }.GetNewClosure()
}

$script:NewPackedCellPipeline = {
    param(
        [Parameter(Mandatory)][IntPtr] $Device,
        [int32] $RenderTargetFormat = 87
    )

    $hlsl = @'
cbuffer CanvasConstants : register(b0) {
    float2 Resolution;
    uint2 Grid;
    float2 CellSize;
    float Time;
    float Padding;
};
StructuredBuffer<uint> Cells : register(t0);

struct PixelInput { float4 Position : SV_POSITION; };

PixelInput VSMain(uint id : SV_VertexID) {
    PixelInput output;
    float2 uv = float2((id << 1) & 2, id & 2);
    output.Position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return output;
}

float3 Palette(uint index) {
    static const float3 colors[16] = {
        float3(0.00,0.00,0.00), float3(0.50,0.00,0.00), float3(0.00,0.50,0.00), float3(0.50,0.50,0.00),
        float3(0.00,0.00,0.50), float3(0.50,0.00,0.50), float3(0.00,0.50,0.50), float3(0.75,0.75,0.75),
        float3(0.50,0.50,0.50), float3(1.00,0.00,0.00), float3(0.00,1.00,0.00), float3(1.00,1.00,0.00),
        float3(0.00,0.00,1.00), float3(1.00,0.00,1.00), float3(0.00,1.00,1.00), float3(1.00,1.00,1.00)
    };
    return colors[index & 15];
}

float4 PSMain(PixelInput input) : SV_TARGET {
    uint2 cell = min((uint2)floor(input.Position.xy / CellSize), Grid - 1);
    uint packed = Cells[cell.y * Grid.x + cell.x];
    return float4(Palette(packed >> 24), 1.0);
}
'@

    $vertexShader = & $script:CompileHlsl -Source $hlsl -EntryPoint VSMain -Target vs_5_0 -Flags 0x8000
    $pixelShader = & $script:CompileHlsl -Source $hlsl -EntryPoint PSMain -Target ps_5_0 -Flags 0x8000
    $d3d12 = Open-NativeLibrary 'd3d12.dll'
    $serialize = Get-NativeCall (Get-NativeExport $d3d12 'D3D12SerializeRootSignature') ([int32]) @(
        [IntPtr], [int32], [IntPtr], [IntPtr]
    )

    $parameters = New-NativeBlock 64
    $rootDesc = New-NativeBlock 40
    $blobOut = New-NativeBlock ([IntPtr]::Size)
    $errorsOut = New-NativeBlock ([IntPtr]::Size)
    $rootBlob = [IntPtr]::Zero
    $errorBlob = [IntPtr]::Zero
    $rootSignature = [IntPtr]::Zero
    $pipelineState = [IntPtr]::Zero
    try {
        # D3D12_ROOT_PARAMETER[0]: CBV b0; [1]: SRV t0.
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 0, 2)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 8, 0)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 12, 0)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 24, 0)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 32, 3)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 40, 0)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 44, 0)
        [Runtime.InteropServices.Marshal]::WriteInt32($parameters, 56, 0)
        [Runtime.InteropServices.Marshal]::WriteInt32($rootDesc, 0, 2)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($rootDesc, 8, $parameters)
        [Runtime.InteropServices.Marshal]::WriteInt32($rootDesc, 16, 0)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($rootDesc, 24, [IntPtr]::Zero)
        [Runtime.InteropServices.Marshal]::WriteInt32($rootDesc, 32, 1)

        $hr = [int32]$serialize.DynamicInvoke($rootDesc, [int32]1, $blobOut, $errorsOut)
        $rootBlob = [Runtime.InteropServices.Marshal]::ReadIntPtr($blobOut)
        $errorBlob = [Runtime.InteropServices.Marshal]::ReadIntPtr($errorsOut)
        if ($hr -lt 0 -or $rootBlob -eq [IntPtr]::Zero) { throw ("D3D12SerializeRootSignature failed: 0x{0:X8}" -f [uint32]$hr) }
        $rootBytes = Invoke-ComVtableMethod $rootBlob 3 @() ([IntPtr]) @()
        $rootLength = Invoke-ComVtableMethod $rootBlob 4 @() ([UIntPtr]) @()
        $iidRoot = New-NativeBlock 16
        $rootOut = New-NativeBlock ([IntPtr]::Size)
        try {
            [Runtime.InteropServices.Marshal]::Copy(([Guid]'c54a6b66-72df-4ee8-8be5-a946a1429214').ToByteArray(), 0, $iidRoot, 16)
            $hr = [int32](Invoke-ComVtableMethod $Device $script:D3D12_DEVICE_SLOTS.CreateRootSignature @([uint32],[IntPtr],[UIntPtr],[IntPtr],[IntPtr]) ([int32]) @([uint32]0,$rootBytes,$rootLength,$iidRoot,$rootOut))
            $rootSignature = [Runtime.InteropServices.Marshal]::ReadIntPtr($rootOut)
        }
        finally { Remove-NativeBlock $iidRoot; Remove-NativeBlock $rootOut }
        if ($hr -lt 0 -or $rootSignature -eq [IntPtr]::Zero) { throw ("CreateRootSignature failed: 0x{0:X8}" -f [uint32]$hr) }

        $vertexBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($vertexShader.Length)
        $pixelBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($pixelShader.Length)
        $psoDesc = New-NativeBlock 656
        $iidPipeline = New-NativeBlock 16
        $pipelineOut = New-NativeBlock ([IntPtr]::Size)
        try {
            [Runtime.InteropServices.Marshal]::Copy($vertexShader, 0, $vertexBuffer, $vertexShader.Length)
            [Runtime.InteropServices.Marshal]::Copy($pixelShader, 0, $pixelBuffer, $pixelShader.Length)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($psoDesc, 0, $rootSignature)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($psoDesc, 8, $vertexBuffer)
            [Runtime.InteropServices.Marshal]::WriteInt64($psoDesc, 16, $vertexShader.Length)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($psoDesc, 24, $pixelBuffer)
            [Runtime.InteropServices.Marshal]::WriteInt64($psoDesc, 32, $pixelShader.Length)
            [Runtime.InteropServices.Marshal]::WriteByte($psoDesc, 120 + 8 + 7 * 40 + 36, 15)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 448, -1)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 452, 3)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 456, 1)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 476, 1)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 496, 0)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 524, 0)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 572, 3)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 576, 1)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 580, $RenderTargetFormat)
            [Runtime.InteropServices.Marshal]::WriteInt32($psoDesc, 616, 1)
            [Runtime.InteropServices.Marshal]::Copy(([Guid]'765a30f3-f624-4c6f-a828-ace948622445').ToByteArray(), 0, $iidPipeline, 16)
            $hr = [int32](Invoke-ComVtableMethod $Device $script:D3D12_DEVICE_SLOTS.CreateGraphicsPipelineState @([IntPtr],[IntPtr],[IntPtr]) ([int32]) @($psoDesc,$iidPipeline,$pipelineOut))
            $pipelineState = [Runtime.InteropServices.Marshal]::ReadIntPtr($pipelineOut)
        }
        finally {
            if ($vertexBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($vertexBuffer) }
            if ($pixelBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pixelBuffer) }
            Remove-NativeBlock $psoDesc; Remove-NativeBlock $iidPipeline; Remove-NativeBlock $pipelineOut
        }
        if ($hr -lt 0 -or $pipelineState -eq [IntPtr]::Zero) { throw ("CreateGraphicsPipelineState failed: 0x{0:X8}" -f [uint32]$hr) }
        return [PSCustomObject]@{ RootSignature = $rootSignature; PipelineState = $pipelineState; Hlsl = $hlsl }
    }
    catch {
        if ($pipelineState -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod $pipelineState 2 @() ([uint32]) @()) }
        if ($rootSignature -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod $rootSignature 2 @() ([uint32]) @()) }
        throw
    }
    finally {
        if ($errorBlob -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod $errorBlob 2 @() ([uint32]) @()) }
        if ($rootBlob -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod $rootBlob 2 @() ([uint32]) @()) }
        Remove-NativeBlock $parameters; Remove-NativeBlock $rootDesc; Remove-NativeBlock $blobOut; Remove-NativeBlock $errorsOut
    }
}

$script:D3D12_FENCE_SLOTS = @{
    GetCompletedValue    = 8
    SetEventOnCompletion = 9
    Signal               = 10
}

$script:D3D11ON12_DEVICE_SLOTS = @{
    CreateWrappedResource    = 3
    ReleaseWrappedResources  = 4
    AcquireWrappedResources  = 5
}

function global:New-D3D11On12Bridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr] $D3D12Device,
        [Parameter(Mandatory)][IntPtr] $D3D12Queue
    )

    if ($D3D12Device -eq [IntPtr]::Zero -or $D3D12Queue -eq [IntPtr]::Zero) {
        throw 'D3D11On12 requires a live D3D12 device and command queue.'
    }

    $d3d11 = Open-NativeLibrary 'd3d11.dll'
    $create = Get-NativeCall (Get-NativeExport $d3d11 'D3D11On12CreateDevice') ([int32]) @(
        [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr], [uint32], [uint32], [IntPtr], [IntPtr], [IntPtr]
    )
    $queueArray = New-NativeBlock ([IntPtr]::Size)
    [System.Runtime.InteropServices.Marshal]::WriteIntPtr($queueArray, 0, $D3D12Queue)
    $pDeviceOut = New-NativeBlock ([IntPtr]::Size)
    $pContextOut = New-NativeBlock ([IntPtr]::Size)
    try {
        $hr = [int32]$create.DynamicInvoke(
            $D3D12Device, [uint32]0x20, [IntPtr]::Zero, [uint32]0,
            $queueArray, [uint32]1, [uint32]0, $pDeviceOut, $pContextOut, [IntPtr]::Zero
        )
        $device11 = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pDeviceOut)
        $context11 = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pContextOut)
    }
    finally {
        Remove-NativeBlock $queueArray
        Remove-NativeBlock $pDeviceOut
        Remove-NativeBlock $pContextOut
    }
    if ($hr -lt 0 -or $device11 -eq [IntPtr]::Zero -or $context11 -eq [IntPtr]::Zero) {
        throw ("D3D11On12CreateDevice failed: 0x{0:X8}" -f [uint32]$hr)
    }

    function Get-BridgeInterface([IntPtr]$source, [Guid]$iid, [string]$name) {
        $pIid = New-NativeBlock 16
        [System.Runtime.InteropServices.Marshal]::Copy($iid.ToByteArray(), 0, $pIid, 16)
        $pOut = New-NativeBlock ([IntPtr]::Size)
        try {
            $queryHr = [int32](Invoke-ComVtableMethod -ComObject $source -SlotIndex 0 -ParamTypes @([IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($pIid, $pOut))
            $result = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)
        }
        finally { Remove-NativeBlock $pIid; Remove-NativeBlock $pOut }
        if ($queryHr -lt 0 -or $result -eq [IntPtr]::Zero) { throw ("QueryInterface({0}) failed: 0x{1:X8}" -f $name, [uint32]$queryHr) }
        $result
    }

    try {
        $on12 = Get-BridgeInterface $device11 ([Guid]'85611e73-70a9-490e-9614-a9e302777904') 'ID3D11On12Device'
        $dxgiDevice = Get-BridgeInterface $device11 ([Guid]'54ec77fa-1377-44e6-8c32-88fd5f44c84c') 'IDXGIDevice'
    }
    catch {
        if ($context11 -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod -ComObject $context11 -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        if ($device11 -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod -ComObject $device11 -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        throw
    }

    $bridge = [PSCustomObject]@{
        PSTypeName = 'QuickPS.D3D11On12Bridge'
        Device11Ptr = $device11
        Context11Ptr = $context11
        On12DevicePtr = $on12
        DxgiDevicePtr = $dxgiDevice
    }
    $bridge | Add-Member -MemberType ScriptMethod -Name Dispose -Value ({
        foreach ($ptr in @($this.DxgiDevicePtr, $this.On12DevicePtr, $this.Context11Ptr, $this.Device11Ptr)) {
            if ($ptr -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod -ComObject $ptr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        }
        $this.DxgiDevicePtr = [IntPtr]::Zero
        $this.On12DevicePtr = [IntPtr]::Zero
        $this.Context11Ptr = [IntPtr]::Zero
        $this.Device11Ptr = [IntPtr]::Zero
    }.GetNewClosure())
    $bridge
}

function global:New-WindowsTextDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Bridge)

    if ($Bridge.DxgiDevicePtr -eq [IntPtr]::Zero) { throw 'Direct2D requires the bridge IDXGIDevice.' }
    $d2d1 = Open-NativeLibrary 'd2d1.dll'
    $dwrite = Open-NativeLibrary 'dwrite.dll'
    $createD2DDevice = Get-NativeCall (Get-NativeExport $d2d1 'D2D1CreateDevice') ([int32]) @([IntPtr], [IntPtr], [IntPtr])
    $pD2DDeviceOut = New-NativeBlock ([IntPtr]::Size)
    try {
        $hr = [int32]$createD2DDevice.DynamicInvoke($Bridge.DxgiDevicePtr, [IntPtr]::Zero, $pD2DDeviceOut)
        $d2dDevice = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pD2DDeviceOut)
    }
    finally { Remove-NativeBlock $pD2DDeviceOut }
    if ($hr -lt 0 -or $d2dDevice -eq [IntPtr]::Zero) { throw ("D2D1CreateDevice failed: 0x{0:X8}" -f [uint32]$hr) }

    $pD2DContextOut = New-NativeBlock ([IntPtr]::Size)
    try {
        $hr = [int32](Invoke-ComVtableMethod -ComObject $d2dDevice -SlotIndex 4 -ParamTypes @([uint32], [IntPtr]) -ReturnType ([int32]) -Args @([uint32]0, $pD2DContextOut))
        $d2dContext = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pD2DContextOut)
    }
    finally { Remove-NativeBlock $pD2DContextOut }
    if ($hr -lt 0 -or $d2dContext -eq [IntPtr]::Zero) {
        [void](Invoke-ComVtableMethod -ComObject $d2dDevice -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        throw ("ID2D1Device::CreateDeviceContext failed: 0x{0:X8}" -f [uint32]$hr)
    }

    $createDWriteFactory = Get-NativeCall (Get-NativeExport $dwrite 'DWriteCreateFactory') ([int32]) @([uint32], [IntPtr], [IntPtr])
    $pIidDWrite = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('b859ee5a-d838-4b5b-a2e8-1adc7d93db48').ToByteArray(), 0, $pIidDWrite, 16)
    $pDWriteOut = New-NativeBlock ([IntPtr]::Size)
    try {
        $hr = [int32]$createDWriteFactory.DynamicInvoke([uint32]0, $pIidDWrite, $pDWriteOut)
        $dwriteFactory = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pDWriteOut)
    }
    finally { Remove-NativeBlock $pIidDWrite; Remove-NativeBlock $pDWriteOut }
    if ($hr -lt 0 -or $dwriteFactory -eq [IntPtr]::Zero) {
        [void](Invoke-ComVtableMethod -ComObject $d2dContext -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $d2dDevice -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        throw ("DWriteCreateFactory failed: 0x{0:X8}" -f [uint32]$hr)
    }

    $textDevice = [PSCustomObject]@{
        PSTypeName = 'QuickPS.WindowsTextDevice'
        D2DDevicePtr = $d2dDevice
        D2DContextPtr = $d2dContext
        DWriteFactoryPtr = $dwriteFactory
    }
    $textDevice | Add-Member -MemberType ScriptMethod -Name Dispose -Value ({
        foreach ($ptr in @($this.DWriteFactoryPtr, $this.D2DContextPtr, $this.D2DDevicePtr)) {
            if ($ptr -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod -ComObject $ptr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        }
        $this.DWriteFactoryPtr = [IntPtr]::Zero
        $this.D2DContextPtr = [IntPtr]::Zero
        $this.D2DDevicePtr = [IntPtr]::Zero
    }.GetNewClosure())
    $textDevice
}

$script:Composition = & {
function New-WindowsCompositionPipeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr] $DxgiDevice
    )

    if ($DxgiDevice -eq [IntPtr]::Zero) { throw 'DirectComposition requires a live IDXGIDevice.' }
    $dcomp = Open-NativeLibrary 'dcomp.dll'
    $createDevice = Get-NativeCall (Get-NativeExport $dcomp 'DCompositionCreateDevice') ([int32]) @([IntPtr], [IntPtr], [IntPtr])
    $pIid = New-NativeBlock 16
    $pDeviceOut = New-NativeBlock ([IntPtr]::Size)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('c37ea93a-e7aa-450d-b16f-9746cb0407f3').ToByteArray(), 0, $pIid, 16)
        $hr = [int32]$createDevice.DynamicInvoke($DxgiDevice, $pIid, $pDeviceOut)
        $device = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pDeviceOut)
}
    finally { Remove-NativeBlock $pIid; Remove-NativeBlock $pDeviceOut }
    if ($hr -lt 0 -or $device -eq [IntPtr]::Zero) { throw ("DCompositionCreateDevice failed: 0x{0:X8}" -f [uint32]$hr) }

    $pipe = [PSCustomObject]@{
        PSTypeName = 'QuickPS.WindowsCompositionPipe'
        DevicePtr = $device
        Targets = [Collections.Generic.List[IntPtr]]::new()
        Visuals = [Collections.Generic.List[IntPtr]]::new()
        CommitSlot = 3
        WaitForCommitCompletionSlot = 4
        CreateTargetForHwndSlot = 6
        CreateVisualSlot = 7
        TargetSetRootSlot = 3
        VisualSetContentSlot = 15
    }
    $pipe | Add-Member -MemberType ScriptMethod -Name CreateTargetForHwnd -Value ({
        param([IntPtr]$Hwnd, [bool]$Topmost = $true)
        if ($Hwnd -eq [IntPtr]::Zero) { throw 'CreateTargetForHwnd requires a live HWND.' }
        $pOut = New-NativeBlock ([IntPtr]::Size)
        try {
            $hr = [int32](Invoke-ComVtableMethod -ComObject $this.DevicePtr -SlotIndex $this.CreateTargetForHwndSlot -ParamTypes @([IntPtr], [int32], [IntPtr]) -ReturnType ([int32]) -Args @($Hwnd, [int32]$Topmost, $pOut))
            $target = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)
        }
        finally { Remove-NativeBlock $pOut }
        if ($hr -lt 0 -or $target -eq [IntPtr]::Zero) { throw ("IDCompositionDevice::CreateTargetForHwnd failed: 0x{0:X8}" -f [uint32]$hr) }
        $this.Targets.Add($target)
        return $target
    }.GetNewClosure())
    $pipe | Add-Member -MemberType ScriptMethod -Name CreateVisual -Value ({
        $pOut = New-NativeBlock ([IntPtr]::Size)
        try {
            $hr = [int32](Invoke-ComVtableMethod -ComObject $this.DevicePtr -SlotIndex $this.CreateVisualSlot -ParamTypes @([IntPtr]) -ReturnType ([int32]) -Args @($pOut))
            $visual = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)
        }
        finally { Remove-NativeBlock $pOut }
        if ($hr -lt 0 -or $visual -eq [IntPtr]::Zero) { throw ("IDCompositionDevice::CreateVisual failed: 0x{0:X8}" -f [uint32]$hr) }
        $this.Visuals.Add($visual)
        return $visual
    }.GetNewClosure())
    $pipe | Add-Member -MemberType ScriptMethod -Name SetRoot -Value ({
        param([IntPtr]$Target, [IntPtr]$Visual)
        $hr = [int32](Invoke-ComVtableMethod -ComObject $Target -SlotIndex $this.TargetSetRootSlot -ParamTypes @([IntPtr]) -ReturnType ([int32]) -Args @($Visual))
        if ($hr -lt 0) { throw ("IDCompositionTarget::SetRoot failed: 0x{0:X8}" -f [uint32]$hr) }
        return $true
    }.GetNewClosure())
    $pipe | Add-Member -MemberType ScriptMethod -Name SetContent -Value ({
        param([IntPtr]$Visual, [IntPtr]$Content)
        $hr = [int32](Invoke-ComVtableMethod -ComObject $Visual -SlotIndex $this.VisualSetContentSlot -ParamTypes @([IntPtr]) -ReturnType ([int32]) -Args @($Content))
        if ($hr -lt 0) { throw ("IDCompositionVisual::SetContent failed: 0x{0:X8}" -f [uint32]$hr) }
        return $true
    }.GetNewClosure())
    $pipe | Add-Member -MemberType ScriptMethod -Name Commit -Value ({
        $hr = [int32](Invoke-ComVtableMethod -ComObject $this.DevicePtr -SlotIndex $this.CommitSlot -ParamTypes @() -ReturnType ([int32]))
        if ($hr -lt 0) { throw ("IDCompositionDevice::Commit failed: 0x{0:X8}" -f [uint32]$hr) }
        return $true
    }.GetNewClosure())
    $pipe | Add-Member -MemberType ScriptMethod -Name WaitForCommitCompletion -Value ({
        $hr = [int32](Invoke-ComVtableMethod -ComObject $this.DevicePtr -SlotIndex $this.WaitForCommitCompletionSlot -ParamTypes @() -ReturnType ([int32]))
        if ($hr -lt 0) { throw ("IDCompositionDevice::WaitForCommitCompletion failed: 0x{0:X8}" -f [uint32]$hr) }
        return $true
    }.GetNewClosure())
    $pipe | Add-Member -MemberType ScriptMethod -Name Dispose -Value ({
        for ($i = $this.Visuals.Count - 1; $i -ge 0; $i--) { [void](Invoke-ComVtableMethod -ComObject $this.Visuals[$i] -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        for ($i = $this.Targets.Count - 1; $i -ge 0; $i--) { [void](Invoke-ComVtableMethod -ComObject $this.Targets[$i] -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        $this.Visuals.Clear(); $this.Targets.Clear()
        if ($this.DevicePtr -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod -ComObject $this.DevicePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])); $this.DevicePtr = [IntPtr]::Zero }
    }.GetNewClosure())
    return $pipe
    }
    [PSCustomObject]@{ NewPipe = ${function:New-WindowsCompositionPipeInternal} }
}

$script:Wic = & {
function New-WindowsWicPipeInternal {
    [CmdletBinding()]
    param()

    $ole32 = Open-NativeLibrary 'ole32.dll'
    $coInitializeEx = Get-NativeCall (Get-NativeExport $ole32 'CoInitializeEx') ([int32]) @([IntPtr], [uint32])
    $coUninitialize = Get-NativeCall (Get-NativeExport $ole32 'CoUninitialize') ([void]) @()
    $coCreateInstance = Get-NativeCall (Get-NativeExport $ole32 'CoCreateInstance') ([int32]) @([IntPtr], [IntPtr], [uint32], [IntPtr], [IntPtr])
    $coHr = [int32]$coInitializeEx.DynamicInvoke([IntPtr]::Zero, [uint32]0)
    $coOwned = $coHr -eq 0 -or $coHr -eq 1
    [uint32]$coHrBits = [uint32]([int64]$coHr -band 0xFFFFFFFFL)
    if ($coHr -lt 0 -and $coHrBits -ne [uint32]2147549446) { throw ("CoInitializeEx failed: 0x{0:X8}" -f $coHrBits) }

    $pClsid = New-NativeBlock 16; $pIid = New-NativeBlock 16; $pOut = New-NativeBlock ([IntPtr]::Size)
    try {
        [Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('cacaf262-9370-4615-a13b-9f5539da4c0a').ToByteArray(), 0, $pClsid, 16)
        [Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('ec5ec8a9-c395-4314-9c77-54d7a935ff70').ToByteArray(), 0, $pIid, 16)
        $hr = [int32]$coCreateInstance.DynamicInvoke($pClsid, [IntPtr]::Zero, [uint32]1, $pIid, $pOut)
        $factory = [Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)
}
    finally { Remove-NativeBlock $pClsid; Remove-NativeBlock $pIid; Remove-NativeBlock $pOut }
    if ($hr -lt 0 -or $factory -eq [IntPtr]::Zero) { if ($coOwned) { $coUninitialize.DynamicInvoke() }; throw ("CoCreateInstance(WIC) failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }

    $pipe = [PSCustomObject]@{ PSTypeName='QuickPS.WindowsWicPipe'; FactoryPtr=$factory; Children=[Collections.Generic.List[IntPtr]]::new(); CoOwned=$coOwned; CoUninitialize=$coUninitialize; PixelFormat32bppPBGRA=[Guid]'6fddc324-4e03-4bfe-b185-3d77768dc910' }
    $pipe | Add-Member ScriptMethod Track ({ param([IntPtr]$Pointer) if($Pointer-ne[IntPtr]::Zero){$this.Children.Add($Pointer)}; return $Pointer }.GetNewClosure())
    $pipe | Add-Member ScriptMethod CreateBitmap ({ param([uint32]$Width,[uint32]$Height,[Guid]$PixelFormat=$this.PixelFormat32bppPBGRA,[uint32]$CacheOption=2)
        $pGuid=New-NativeBlock 16;$pOut=New-NativeBlock ([IntPtr]::Size)
        try{[Runtime.InteropServices.Marshal]::Copy($PixelFormat.ToByteArray(),0,$pGuid,16);$hr=[int32](Invoke-ComVtableMethod $this.FactoryPtr 17 @([uint32],[uint32],[IntPtr],[uint32],[IntPtr]) ([int32]) @($Width,$Height,$pGuid,$CacheOption,$pOut));$value=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pGuid;Remove-NativeBlock $pOut}
        if($hr-lt 0-or$value-eq[IntPtr]::Zero){throw("IWICImagingFactory::CreateBitmap failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $this.Track($value)
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod CreateFormatConverter ({ $pOut=New-NativeBlock ([IntPtr]::Size);try{$hr=[int32](Invoke-ComVtableMethod $this.FactoryPtr 10 @([IntPtr]) ([int32]) @($pOut));$value=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pOut};if($hr-lt 0-or$value-eq[IntPtr]::Zero){throw("CreateFormatConverter failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $this.Track($value) }.GetNewClosure())
    $pipe | Add-Member ScriptMethod InitializeConverter ({ param([IntPtr]$Converter,[IntPtr]$Source,[Guid]$DestinationFormat=$this.PixelFormat32bppPBGRA)
        $pGuid=New-NativeBlock 16;try{[Runtime.InteropServices.Marshal]::Copy($DestinationFormat.ToByteArray(),0,$pGuid,16);$hr=[int32](Invoke-ComVtableMethod $Converter 8 @([IntPtr],[IntPtr],[uint32],[IntPtr],[double],[uint32]) ([int32]) @($Source,$pGuid,[uint32]0,[IntPtr]::Zero,[double]0,[uint32]0))}finally{Remove-NativeBlock $pGuid};if($hr-lt 0){throw("IWICFormatConverter::Initialize failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $true
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod DecodeFile ({ param([string]$Path)
        $pName=[Runtime.InteropServices.Marshal]::StringToHGlobalUni([IO.Path]::GetFullPath($Path));$pOut=New-NativeBlock ([IntPtr]::Size)
        try{$hr=[int32](Invoke-ComVtableMethod $this.FactoryPtr 3 @([IntPtr],[IntPtr],[uint32],[uint32],[IntPtr]) ([int32]) @($pName,[IntPtr]::Zero,[uint32]2147483648,[uint32]0,$pOut));$decoder=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($pName);Remove-NativeBlock $pOut};if($hr-lt 0-or$decoder-eq[IntPtr]::Zero){throw("CreateDecoderFromFilename failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};[void]$this.Track($decoder);$pFrame=New-NativeBlock ([IntPtr]::Size);try{$hr=[int32](Invoke-ComVtableMethod $decoder 13 @([uint32],[IntPtr]) ([int32]) @([uint32]0,$pFrame));$frame=[Runtime.InteropServices.Marshal]::ReadIntPtr($pFrame)}finally{Remove-NativeBlock $pFrame};if($hr-lt 0-or$frame-eq[IntPtr]::Zero){throw("IWICBitmapDecoder::GetFrame failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $this.Track($frame)
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod Dispose ({ for($i=$this.Children.Count-1;$i-ge 0;$i--){[void](Invoke-ComVtableMethod $this.Children[$i] 2 @() ([uint32]))};$this.Children.Clear();if($this.FactoryPtr-ne[IntPtr]::Zero){[void](Invoke-ComVtableMethod $this.FactoryPtr 2 @() ([uint32]));$this.FactoryPtr=[IntPtr]::Zero};if($this.CoOwned){$this.CoUninitialize.DynamicInvoke();$this.CoOwned=$false} }.GetNewClosure())
    return $pipe
    }
    [PSCustomObject]@{ NewPipe = ${function:New-WindowsWicPipeInternal} }
}

$script:Wasapi = & {
function New-WindowsWasapiPipeInternal {
    [CmdletBinding()]
    param()
    $ole32=Open-NativeLibrary 'ole32.dll'
    $coInit=Get-NativeCall (Get-NativeExport $ole32 'CoInitializeEx') ([int32]) @([IntPtr],[uint32])
    $coUninit=Get-NativeCall (Get-NativeExport $ole32 'CoUninitialize') ([void]) @()
    $coCreate=Get-NativeCall (Get-NativeExport $ole32 'CoCreateInstance') ([int32]) @([IntPtr],[IntPtr],[uint32],[IntPtr],[IntPtr])
    $coFree=Get-NativeCall (Get-NativeExport $ole32 'CoTaskMemFree') ([void]) @([IntPtr])
    $coHr=[int32]$coInit.DynamicInvoke([IntPtr]::Zero,[uint32]0);$coOwned=$coHr-eq 0-or$coHr-eq 1
    $coBits=[uint32]([int64]$coHr-band 0xFFFFFFFFL);if($coHr-lt 0-and$coBits-ne[uint32]2147549446){throw("CoInitializeEx failed: 0x{0:X8}"-f$coBits)}
    $pClsid=New-NativeBlock 16;$pIid=New-NativeBlock 16;$pOut=New-NativeBlock ([IntPtr]::Size)
    try{[Runtime.InteropServices.Marshal]::Copy(([Guid]'bcde0395-e52f-467c-8e3d-c4579291692e').ToByteArray(),0,$pClsid,16);[Runtime.InteropServices.Marshal]::Copy(([Guid]'a95664d2-9614-4f35-a746-de8db63617e6').ToByteArray(),0,$pIid,16);$hr=[int32]$coCreate.DynamicInvoke($pClsid,[IntPtr]::Zero,[uint32]23,$pIid,$pOut);$enumerator=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pClsid;Remove-NativeBlock $pIid;Remove-NativeBlock $pOut}
    if($hr-lt 0-or$enumerator-eq[IntPtr]::Zero){if($coOwned){$coUninit.DynamicInvoke()};throw("CoCreateInstance(MMDeviceEnumerator) failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))}
    $kernel32=Open-NativeLibrary 'kernel32.dll';$createEvent=Get-NativeCall (Get-NativeExport $kernel32 'CreateEventW') ([IntPtr]) @([IntPtr],[bool],[bool],[IntPtr]);$closeHandle=Get-NativeCall (Get-NativeExport $kernel32 'CloseHandle') ([bool]) @([IntPtr])
    $pipe=[PSCustomObject]@{PSTypeName='QuickPS.WindowsWasapiPipe';EnumeratorPtr=$enumerator;Children=[Collections.Generic.List[IntPtr]]::new();MixFormats=[Collections.Generic.List[IntPtr]]::new();Events=[Collections.Generic.List[IntPtr]]::new();ActiveClients=[Collections.Generic.List[IntPtr]]::new();CoOwned=$coOwned;CoUninitialize=$coUninit;CoTaskMemFree=$coFree;CreateEvent=$createEvent;CloseHandle=$closeHandle;AudioClientIid=[Guid]'1cb9ad4c-dbfa-4c32-b178-c2f568a703b2';CaptureClientIid=[Guid]'c8adbd64-e71e-48a0-a4de-185c395cd317';RenderClientIid=[Guid]'f294acfc-3146-4483-a7bf-addca7c260e2'}
    $pipe|Add-Member ScriptMethod Track({param([IntPtr]$p)if($p-ne[IntPtr]::Zero){$this.Children.Add($p)};return $p}.GetNewClosure())
    $pipe|Add-Member ScriptMethod GetDefaultEndpoint({param([ValidateSet('Render','Capture')][string]$Flow='Render',[uint32]$Role=1)$pOut=New-NativeBlock ([IntPtr]::Size);try{$flowValue=if($Flow-eq'Render'){[uint32]0}else{[uint32]1};$hr=[int32](Invoke-ComVtableMethod $this.EnumeratorPtr 4 @([uint32],[uint32],[IntPtr]) ([int32]) @($flowValue,$Role,$pOut));$device=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pOut};if($hr-lt 0-or$device-eq[IntPtr]::Zero){throw("GetDefaultAudioEndpoint failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $this.Track($device)}.GetNewClosure())
    $pipe|Add-Member ScriptMethod ActivateAudioClient({param([IntPtr]$Device)$pIid=New-NativeBlock 16;$pOut=New-NativeBlock ([IntPtr]::Size);try{[Runtime.InteropServices.Marshal]::Copy($this.AudioClientIid.ToByteArray(),0,$pIid,16);$hr=[int32](Invoke-ComVtableMethod $Device 3 @([IntPtr],[uint32],[IntPtr],[IntPtr]) ([int32]) @($pIid,[uint32]23,[IntPtr]::Zero,$pOut));$client=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pIid;Remove-NativeBlock $pOut};if($hr-lt 0-or$client-eq[IntPtr]::Zero){throw("IMMDevice::Activate(IAudioClient) failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $this.Track($client)}.GetNewClosure())
    $pipe|Add-Member ScriptMethod GetMixFormat({param([IntPtr]$AudioClient)$pOut=New-NativeBlock ([IntPtr]::Size);try{$hr=[int32](Invoke-ComVtableMethod $AudioClient 8 @([IntPtr]) ([int32]) @($pOut));$format=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pOut};if($hr-lt 0-or$format-eq[IntPtr]::Zero){throw("IAudioClient::GetMixFormat failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};$this.MixFormats.Add($format);return $format}.GetNewClosure())
    $pipe|Add-Member ScriptMethod InitializeShared({param([IntPtr]$AudioClient,[IntPtr]$Format,[bool]$Loopback=$false,[bool]$EventDriven=$true,[int64]$BufferDuration=10000000)$flags=[uint32]0;if($Loopback){$flags=$flags-bor[uint32]0x20000};if($EventDriven){$flags=$flags-bor[uint32]0x40000};$hr=[int32](Invoke-ComVtableMethod $AudioClient 3 @([uint32],[uint32],[int64],[int64],[IntPtr],[IntPtr]) ([int32]) @([uint32]0,$flags,$BufferDuration,[int64]0,$Format,[IntPtr]::Zero));if($hr-lt 0){throw("IAudioClient::Initialize failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};if($EventDriven){$event=[IntPtr]$this.CreateEvent.DynamicInvoke([IntPtr]::Zero,$false,$false,[IntPtr]::Zero);if($event-eq[IntPtr]::Zero){throw'CreateEventW for WASAPI failed.'};$this.Events.Add($event);$hr=[int32](Invoke-ComVtableMethod $AudioClient 13 @([IntPtr]) ([int32]) @($event));if($hr-lt 0){throw("IAudioClient::SetEventHandle failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $event};return [IntPtr]::Zero}.GetNewClosure())
    $pipe|Add-Member ScriptMethod GetService({param([IntPtr]$AudioClient,[ValidateSet('Capture','Render')][string]$Kind)$iid=if($Kind-eq'Capture'){$this.CaptureClientIid}else{$this.RenderClientIid};$pIid=New-NativeBlock 16;$pOut=New-NativeBlock ([IntPtr]::Size);try{[Runtime.InteropServices.Marshal]::Copy($iid.ToByteArray(),0,$pIid,16);$hr=[int32](Invoke-ComVtableMethod $AudioClient 14 @([IntPtr],[IntPtr]) ([int32]) @($pIid,$pOut));$service=[Runtime.InteropServices.Marshal]::ReadIntPtr($pOut)}finally{Remove-NativeBlock $pIid;Remove-NativeBlock $pOut};if($hr-lt 0-or$service-eq[IntPtr]::Zero){throw("IAudioClient::GetService($Kind) failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $this.Track($service)}.GetNewClosure())
    $pipe | Add-Member ScriptMethod GetBufferSize ({
        param([IntPtr] $AudioClient)
        $pFrames = New-NativeBlock 4
        try {
            $hr = [int32](Invoke-ComVtableMethod $AudioClient 4 @([IntPtr]) ([int32]) @($pFrames))
            $frames = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($pFrames)
        }
        finally { Remove-NativeBlock $pFrames }
        if ($hr -lt 0) { throw ("IAudioClient::GetBufferSize failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }
        return $frames
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod GetNextCapturePacketSize ({
        param([IntPtr] $CaptureClient)
        $pFrames = New-NativeBlock 4
        try {
            $hr = [int32](Invoke-ComVtableMethod $CaptureClient 5 @([IntPtr]) ([int32]) @($pFrames))
            $frames = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($pFrames)
        }
        finally { Remove-NativeBlock $pFrames }
        if ($hr -lt 0) { throw ("IAudioCaptureClient::GetNextPacketSize failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }
        return $frames
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod AcquireCaptureBuffer ({
        param([IntPtr] $CaptureClient)
        $scratch = New-NativeBlock 32
        try {
            $pData = $scratch
            $pFrames = [IntPtr]::Add($scratch, 8)
            $pFlags = [IntPtr]::Add($scratch, 12)
            $pDevicePosition = [IntPtr]::Add($scratch, 16)
            $pQpcPosition = [IntPtr]::Add($scratch, 24)
            $hr = [int32](Invoke-ComVtableMethod $CaptureClient 3 @([IntPtr],[IntPtr],[IntPtr],[IntPtr],[IntPtr]) ([int32]) @($pData,$pFrames,$pFlags,$pDevicePosition,$pQpcPosition))
            if ($hr -lt 0) { throw ("IAudioCaptureClient::GetBuffer failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }
            return [PSCustomObject]@{
                Data = [Runtime.InteropServices.Marshal]::ReadIntPtr($pData)
                Frames = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($pFrames)
                Flags = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($pFlags)
                DevicePosition = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($pDevicePosition)
                QpcPosition = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($pQpcPosition)
            }
        }
        finally { Remove-NativeBlock $scratch }
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod ReleaseCaptureBuffer ({
        param([IntPtr] $CaptureClient, [uint32] $Frames)
        $hr = [int32](Invoke-ComVtableMethod $CaptureClient 4 @([uint32]) ([int32]) @($Frames))
        if ($hr -lt 0) { throw ("IAudioCaptureClient::ReleaseBuffer failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }
        return $true
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod AcquireRenderBuffer ({
        param([IntPtr] $RenderClient, [uint32] $Frames)
        $pData = New-NativeBlock ([IntPtr]::Size)
        try {
            $hr = [int32](Invoke-ComVtableMethod $RenderClient 3 @([uint32],[IntPtr]) ([int32]) @($Frames,$pData))
            $data = [Runtime.InteropServices.Marshal]::ReadIntPtr($pData)
        }
        finally { Remove-NativeBlock $pData }
        if ($hr -lt 0 -or $data -eq [IntPtr]::Zero) { throw ("IAudioRenderClient::GetBuffer failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }
        return $data
    }.GetNewClosure())
    $pipe | Add-Member ScriptMethod ReleaseRenderBuffer ({
        param([IntPtr] $RenderClient, [uint32] $Frames, [uint32] $Flags = 0)
        $hr = [int32](Invoke-ComVtableMethod $RenderClient 4 @([uint32],[uint32]) ([int32]) @($Frames,$Flags))
        if ($hr -lt 0) { throw ("IAudioRenderClient::ReleaseBuffer failed: 0x{0:X8}" -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))) }
        return $true
    }.GetNewClosure())
    $pipe|Add-Member ScriptMethod Start({param([IntPtr]$AudioClient)$hr=[int32](Invoke-ComVtableMethod $AudioClient 10 @() ([int32]));if($hr-lt 0){throw("IAudioClient::Start failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};if(-not$this.ActiveClients.Contains($AudioClient)){$this.ActiveClients.Add($AudioClient)};return $true}.GetNewClosure())
    $pipe|Add-Member ScriptMethod Stop({param([IntPtr]$AudioClient)$hr=[int32](Invoke-ComVtableMethod $AudioClient 11 @() ([int32]));[void]$this.ActiveClients.Remove($AudioClient);if($hr-lt 0){throw("IAudioClient::Stop failed: 0x{0:X8}"-f([uint32]([int64]$hr-band 0xFFFFFFFFL)))};return $true}.GetNewClosure())
    $pipe|Add-Member ScriptMethod Dispose({for($i=$this.ActiveClients.Count-1;$i-ge 0;$i--){[void](Invoke-ComVtableMethod $this.ActiveClients[$i] 11 @() ([int32]))};$this.ActiveClients.Clear();for($i=$this.Events.Count-1;$i-ge 0;$i--){[void]$this.CloseHandle.DynamicInvoke($this.Events[$i])};$this.Events.Clear();for($i=$this.MixFormats.Count-1;$i-ge 0;$i--){$this.CoTaskMemFree.DynamicInvoke($this.MixFormats[$i])};$this.MixFormats.Clear();for($i=$this.Children.Count-1;$i-ge 0;$i--){[void](Invoke-ComVtableMethod $this.Children[$i] 2 @() ([uint32]))};$this.Children.Clear();if($this.EnumeratorPtr-ne[IntPtr]::Zero){[void](Invoke-ComVtableMethod $this.EnumeratorPtr 2 @() ([uint32]));$this.EnumeratorPtr=[IntPtr]::Zero};if($this.CoOwned){$this.CoUninitialize.DynamicInvoke();$this.CoOwned=$false}}.GetNewClosure())
    return $pipe
}
    [PSCustomObject]@{ NewPipe = ${function:New-WindowsWasapiPipeInternal} }
}

function global:New-WindowsTextTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Presenter,
        [Parameter(Mandatory)] $Bridge,
        [Parameter(Mandatory)] $TextDevice
    )

    $count = [int]$Presenter.PresentationBufferCount
    $wrapped = [IntPtr[]]::new($count)
    $surfaces = [IntPtr[]]::new($count)
    $bitmaps = [IntPtr[]]::new($count)
    $resourceFlags = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::WriteInt32($resourceFlags, 0, 0x20) # D3D11_BIND_RENDER_TARGET
    $bitmapProperties = New-NativeBlock 32
    [System.Runtime.InteropServices.Marshal]::WriteInt32($bitmapProperties, 0, 87) # DXGI_FORMAT_B8G8R8A8_UNORM
    [System.Runtime.InteropServices.Marshal]::WriteInt32($bitmapProperties, 4, 1)  # D2D1_ALPHA_MODE_PREMULTIPLIED
    [System.Runtime.InteropServices.Marshal]::WriteInt32($bitmapProperties, 8, [BitConverter]::SingleToInt32Bits([single]96.0))
    [System.Runtime.InteropServices.Marshal]::WriteInt32($bitmapProperties, 12, [BitConverter]::SingleToInt32Bits([single]96.0))
    [System.Runtime.InteropServices.Marshal]::WriteInt32($bitmapProperties, 16, 3) # TARGET | CANNOT_DRAW
    $pIidResource11 = New-NativeBlock 16
    $pIidSurface = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('dc8e63f3-d12b-4952-b47b-5e45026a862d').ToByteArray(), 0, $pIidResource11, 16)
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('cafcb56c-6ac3-4889-bf47-9e23bbd260ec').ToByteArray(), 0, $pIidSurface, 16)
    try {
        for ($i = 0; $i -lt $count; $i++) {
            $pWrappedOut = New-NativeBlock ([IntPtr]::Size)
            try {
                $hr = [int32](Invoke-ComVtableMethod -ComObject $Bridge.On12DevicePtr -SlotIndex $script:D3D11ON12_DEVICE_SLOTS.CreateWrappedResource -ParamTypes @([IntPtr], [IntPtr], [uint32], [uint32], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($Presenter.PresentationBuffers[$i], $resourceFlags, [uint32]4, [uint32]0, $pIidResource11, $pWrappedOut))
                $wrapped[$i] = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pWrappedOut)
            }
            finally { Remove-NativeBlock $pWrappedOut }
            if ($hr -lt 0 -or $wrapped[$i] -eq [IntPtr]::Zero) { throw ("CreateWrappedResource({0}) failed: 0x{1:X8}" -f $i, [uint32]$hr) }

            $pSurfaceOut = New-NativeBlock ([IntPtr]::Size)
            try {
                $hr = [int32](Invoke-ComVtableMethod -ComObject $wrapped[$i] -SlotIndex 0 -ParamTypes @([IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($pIidSurface, $pSurfaceOut))
                $surfaces[$i] = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pSurfaceOut)
            }
            finally { Remove-NativeBlock $pSurfaceOut }
            if ($hr -lt 0 -or $surfaces[$i] -eq [IntPtr]::Zero) { throw ("QueryInterface(IDXGISurface,{0}) failed: 0x{1:X8}" -f $i, [uint32]$hr) }

            $pBitmapOut = New-NativeBlock ([IntPtr]::Size)
            try {
                $hr = [int32](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex 62 -ParamTypes @([IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($surfaces[$i], $bitmapProperties, $pBitmapOut))
                $bitmaps[$i] = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pBitmapOut)
            }
            finally { Remove-NativeBlock $pBitmapOut }
            if ($hr -lt 0 -or $bitmaps[$i] -eq [IntPtr]::Zero) { throw ("CreateBitmapFromDxgiSurface({0}) failed: 0x{1:X8}" -f $i, [uint32]$hr) }
        }
    }
    finally {
        Remove-NativeBlock $resourceFlags
        Remove-NativeBlock $bitmapProperties
        Remove-NativeBlock $pIidResource11
        Remove-NativeBlock $pIidSurface
    }

    $brushColor = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([single[]]@(0.94, 0.96, 1.0, 1.0), 0, $brushColor, 4)
    $pBrushOut = New-NativeBlock ([IntPtr]::Size)
    try {
        $hr = [int32](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex 8 -ParamTypes @([IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($brushColor, [IntPtr]::Zero, $pBrushOut))
        $textBrush = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pBrushOut)
    }
    finally { Remove-NativeBlock $brushColor; Remove-NativeBlock $pBrushOut }
    if ($hr -lt 0 -or $textBrush -eq [IntPtr]::Zero) { throw ("CreateSolidColorBrush failed: 0x{0:X8}" -f [uint32]$hr) }

    $pFamily = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni('Cascadia Mono')
    $pLocale = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni('en-us')
    $pFormatOut = New-NativeBlock ([IntPtr]::Size)
    try {
        $hr = [int32](Invoke-ComVtableMethod -ComObject $TextDevice.DWriteFactoryPtr -SlotIndex 15 -ParamTypes @([IntPtr], [IntPtr], [uint32], [uint32], [uint32], [single], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($pFamily, [IntPtr]::Zero, [uint32]400, [uint32]0, [uint32]5, [single]15.0, $pLocale, $pFormatOut))
        $textFormat = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pFormatOut)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pFamily)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pLocale)
        Remove-NativeBlock $pFormatOut
    }
    if ($hr -lt 0 -or $textFormat -eq [IntPtr]::Zero) { throw ("CreateTextFormat failed: 0x{0:X8}" -f [uint32]$hr) }

    $paletteValues = [object[]]::new(16)
    $paletteValues[0]  = [single[]]@(0.00,0.00,0.00,1.0); $paletteValues[1]  = [single[]]@(0.50,0.00,0.00,1.0)
    $paletteValues[2]  = [single[]]@(0.00,0.50,0.00,1.0); $paletteValues[3]  = [single[]]@(0.50,0.50,0.00,1.0)
    $paletteValues[4]  = [single[]]@(0.00,0.00,0.50,1.0); $paletteValues[5]  = [single[]]@(0.50,0.00,0.50,1.0)
    $paletteValues[6]  = [single[]]@(0.00,0.50,0.50,1.0); $paletteValues[7]  = [single[]]@(0.75,0.75,0.75,1.0)
    $paletteValues[8]  = [single[]]@(0.50,0.50,0.50,1.0); $paletteValues[9]  = [single[]]@(1.00,0.00,0.00,1.0)
    $paletteValues[10] = [single[]]@(0.00,1.00,0.00,1.0); $paletteValues[11] = [single[]]@(1.00,1.00,0.00,1.0)
    $paletteValues[12] = [single[]]@(0.00,0.00,1.00,1.0); $paletteValues[13] = [single[]]@(1.00,0.00,1.00,1.0)
    $paletteValues[14] = [single[]]@(0.00,1.00,1.00,1.0); $paletteValues[15] = [single[]]@(1.00,1.00,1.00,1.0)
    $paletteBrushes = [IntPtr[]]::new(16)
    for ($paletteIndex = 0; $paletteIndex -lt 16; $paletteIndex++) {
        $paletteColor = New-NativeBlock 16
        [System.Runtime.InteropServices.Marshal]::Copy([single[]]$paletteValues[$paletteIndex], 0, $paletteColor, 4)
        $pPaletteBrushOut = New-NativeBlock ([IntPtr]::Size)
        try {
            $hr = [int32](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex 8 -ParamTypes @([IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($paletteColor, [IntPtr]::Zero, $pPaletteBrushOut))
            $paletteBrushes[$paletteIndex] = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pPaletteBrushOut)
        }
        finally { Remove-NativeBlock $paletteColor; Remove-NativeBlock $pPaletteBrushOut }
        if ($hr -lt 0 -or $paletteBrushes[$paletteIndex] -eq [IntPtr]::Zero) { throw ("CreateSolidColorBrush({0}) failed: 0x{1:X8}" -f $paletteIndex, [uint32]$hr) }
    }

    $resourceArrayScratch = New-NativeBlock ([IntPtr]::Size)
    $rectScratch = New-NativeBlock 16
    $clearColorScratch = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([single[]]@(0.035, 0.055, 0.085, 1.0), 0, $clearColorScratch, 4)
    $textBufferCapacity = 65536
    $textBufferScratch = New-NativeBlock ($textBufferCapacity * 2)

    $targets = [PSCustomObject]@{
        PSTypeName = 'QuickPS.WindowsTextTargets'
        WrappedResources = $wrapped
        DxgiSurfaces = $surfaces
        D2DBitmaps = $bitmaps
        CreateBitmapFromDxgiSurfaceSlot = 62
        TextBrushPtr = $textBrush
        TextFormatPtr = $textFormat
        PaletteBrushes = $paletteBrushes
        ResourceArrayScratch = $resourceArrayScratch
        RectScratch = $rectScratch
        ClearColorScratch = $clearColorScratch
        TextBufferScratch = $textBufferScratch
        TextBufferCapacity = $textBufferCapacity
        AcquireSlot = [int]$script:D3D11ON12_DEVICE_SLOTS.AcquireWrappedResources
        ReleaseSlot = [int]$script:D3D11ON12_DEVICE_SLOTS.ReleaseWrappedResources
        SetTargetSlot = 74
        ClearSlot = 47
        BeginDrawSlot = 48
        EndDrawSlot = 49
        DrawTextSlot = 27
        FillRectangleSlot = 17
        ContextFlushSlot = 111
    }
    $kernel32 = Open-NativeLibrary 'kernel32.dll'
    $wait_single_text = Get-NativeCall (Get-NativeExport $kernel32 'WaitForSingleObject') ([uint32]) @([IntPtr], [uint32])
    $targets | Add-Member -MemberType ScriptMethod -Name DrawTextFrame -Value ({
        param($Presenter, $Bridge, $TextDevice, [string]$Text, [uint32[]]$Cells = $null, [int]$Columns = 0, [int]$Rows = 0)
        $index = [int]$Presenter.FrameIndex
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($this.ResourceArrayScratch, 0, $this.WrappedResources[$index])
        $acquired = $false
        try {
            [void](Invoke-ComVtableMethod -ComObject $Bridge.On12DevicePtr -SlotIndex $this.AcquireSlot -ParamTypes @([IntPtr], [uint32]) -ReturnType ([void]) -Args @($this.ResourceArrayScratch, [uint32]1))
            $acquired = $true
            [void](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.SetTargetSlot -ParamTypes @([IntPtr]) -ReturnType ([void]) -Args @($this.D2DBitmaps[$index]))
            [void](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.BeginDrawSlot -ParamTypes @() -ReturnType ([void]))
            [void](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.ClearSlot -ParamTypes @([IntPtr]) -ReturnType ([void]) -Args @($this.ClearColorScratch))
            if ($null -ne $Cells -and $Columns -gt 0 -and $Rows -gt 0) {
                [single]$cellWidth = [single]$Presenter.Width / [single]$Columns
                [single]$cellHeight = [single]$Presenter.Height / [single]$Rows
                for ($row = 0; $row -lt $Rows; $row++) {
                    $rowStart = $row * $Columns
                    $runStart = 0
                    while ($runStart -lt $Columns) {
                        $backgroundIndex = [int](($Cells[$rowStart + $runStart] -shr 24) -band 15)
                        $runEnd = $runStart + 1
                        while ($runEnd -lt $Columns -and ((($Cells[$rowStart + $runEnd] -shr 24) -band 15) -eq $backgroundIndex)) { $runEnd++ }
                        if ($backgroundIndex -ne 0) {
                            [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 0, [BitConverter]::SingleToInt32Bits([single]$runStart * $cellWidth))
                            [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 4, [BitConverter]::SingleToInt32Bits([single]$row * $cellHeight))
                            [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 8, [BitConverter]::SingleToInt32Bits([single]$runEnd * $cellWidth))
                            [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 12, [BitConverter]::SingleToInt32Bits([single]($row + 1) * $cellHeight))
                            [void](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.FillRectangleSlot -ParamTypes @([IntPtr], [IntPtr]) -ReturnType ([void]) -Args @($this.RectScratch, $this.PaletteBrushes[$backgroundIndex]))
                        }
                        $runStart = $runEnd
                    }
                    $runStart = 0
                    while ($runStart -lt $Columns) {
                        $foregroundIndex = [int](($Cells[$rowStart + $runStart] -shr 16) -band 15)
                        $runEnd = $runStart + 1
                        while ($runEnd -lt $Columns -and ((($Cells[$rowStart + $runEnd] -shr 16) -band 15) -eq $foregroundIndex)) { $runEnd++ }
                        $runLength = $runEnd - $runStart
                        if ($runLength -gt $this.TextBufferCapacity) { throw "Text run exceeds native scratch capacity." }
                        for ($column = $runStart; $column -lt $runEnd; $column++) {
                            $codeUnit = [int]($Cells[$rowStart + $column] -band 0xFFFF)
                            if ($codeUnit -eq 0) { $codeUnit = 32 }
                            [int16]$nativeCodeUnit = if ($codeUnit -gt 32767) { [int16]($codeUnit - 65536) } else { [int16]$codeUnit }
                            [System.Runtime.InteropServices.Marshal]::WriteInt16($this.TextBufferScratch, (($column - $runStart) * 2), $nativeCodeUnit)
                        }
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 0, [BitConverter]::SingleToInt32Bits([single]$runStart * $cellWidth))
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 4, [BitConverter]::SingleToInt32Bits([single]$row * $cellHeight))
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 8, [BitConverter]::SingleToInt32Bits([single]$runEnd * $cellWidth))
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($this.RectScratch, 12, [BitConverter]::SingleToInt32Bits([single]($row + 1) * $cellHeight))
                        [void](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.DrawTextSlot -ParamTypes @([IntPtr], [uint32], [IntPtr], [IntPtr], [IntPtr], [uint32], [uint32]) -ReturnType ([void]) -Args @($this.TextBufferScratch, [uint32]$runLength, $this.TextFormatPtr, $this.RectScratch, $this.PaletteBrushes[$foregroundIndex], [uint32]0, [uint32]0))
                        $runStart = $runEnd
                    }
                }
            }
            else {
                $layoutRect = New-NativeBlock 16
                [System.Runtime.InteropServices.Marshal]::Copy([single[]]@(16.0, 16.0, [single]($Presenter.Width - 16), [single]($Presenter.Height - 16)), 0, $layoutRect, 4)
                $pText = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($Text)
                try { [void](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.DrawTextSlot -ParamTypes @([IntPtr], [uint32], [IntPtr], [IntPtr], [IntPtr], [uint32], [uint32]) -ReturnType ([void]) -Args @($pText, [uint32]$Text.Length, $this.TextFormatPtr, $layoutRect, $this.TextBrushPtr, [uint32]0, [uint32]0)) }
                finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pText); Remove-NativeBlock $layoutRect }
            }
            $hr = [int32](Invoke-ComVtableMethod -ComObject $TextDevice.D2DContextPtr -SlotIndex $this.EndDrawSlot -ParamTypes @([IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @([IntPtr]::Zero, [IntPtr]::Zero))
            if ($hr -lt 0) { throw ("ID2D1DeviceContext::EndDraw failed: 0x{0:X8}" -f [uint32]$hr) }
        }
        finally {
            if ($acquired) { [void](Invoke-ComVtableMethod -ComObject $Bridge.On12DevicePtr -SlotIndex $this.ReleaseSlot -ParamTypes @([IntPtr], [uint32]) -ReturnType ([void]) -Args @($this.ResourceArrayScratch, [uint32]1)) }
        }
        [void](Invoke-ComVtableMethod -ComObject $Bridge.Context11Ptr -SlotIndex $this.ContextFlushSlot -ParamTypes @() -ReturnType ([void]))
        $hr = [int32](Invoke-ComVtableMethod -ComObject $Presenter.SwapChainPtr -SlotIndex $Presenter.PresentSlot -ParamTypes @([uint32], [uint32]) -ReturnType ([int32]) -Args @([uint32]1, [uint32]0))
        $Presenter.LastPresentHResult = $hr
        if ($hr -lt 0) { return $false }
        $signalValue = [uint64]$Presenter.NextFenceValue
        $Presenter.NextFenceValue = $signalValue + 1
        $signalHr = [int32](Invoke-ComVtableMethod -ComObject $Presenter.QueuePtr -SlotIndex $Presenter.QueueSignalSlot -ParamTypes @([IntPtr], [uint64]) -ReturnType ([int32]) -Args @($Presenter.FencePtr, $signalValue))
        if ($signalHr -lt 0) { return $false }
        $Presenter.FenceValues[$index] = $signalValue
        $next = [uint32](Invoke-ComVtableMethod -ComObject $Presenter.SwapChainPtr -SlotIndex $Presenter.SwapIndexSlot -ParamTypes @() -ReturnType ([uint32]))
        $reuse = [uint64]$Presenter.FenceValues[$next]
        if ($reuse -ne 0) {
            $completed = [uint64](Invoke-ComVtableMethod -ComObject $Presenter.FencePtr -SlotIndex $Presenter.FenceCompletedSlot -ParamTypes @() -ReturnType ([uint64]))
            if ($completed -lt $reuse) {
                $waitHr = [int32](Invoke-ComVtableMethod -ComObject $Presenter.FencePtr -SlotIndex $Presenter.FenceEventSlot -ParamTypes @([uint64], [IntPtr]) -ReturnType ([int32]) -Args @($reuse, $Presenter.FenceEvent))
                if ($waitHr -lt 0) { return $false }
                [void]$wait_single_text.DynamicInvoke($Presenter.FenceEvent, [uint32]::MaxValue)
            }
        }
        $Presenter.FrameIndex = $next
        $true
    }.GetNewClosure())
    $targets | Add-Member -MemberType ScriptMethod -Name Dispose -Value ({
        foreach ($block in @($this.TextBufferScratch, $this.ClearColorScratch, $this.RectScratch, $this.ResourceArrayScratch)) {
            if ($block -ne [IntPtr]::Zero) { Remove-NativeBlock $block }
        }
        $this.TextBufferScratch = [IntPtr]::Zero
        $this.ClearColorScratch = [IntPtr]::Zero
        $this.RectScratch = [IntPtr]::Zero
        $this.ResourceArrayScratch = [IntPtr]::Zero
        foreach ($ptr in @($this.PaletteBrushes) + @($this.TextFormatPtr, $this.TextBrushPtr) + @($this.D2DBitmaps) + @($this.DxgiSurfaces) + @($this.WrappedResources)) {
            if ($ptr -ne [IntPtr]::Zero) { [void](Invoke-ComVtableMethod -ComObject $ptr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32])) }
        }
        $this.D2DBitmaps = [IntPtr[]]::new(0)
        $this.DxgiSurfaces = [IntPtr[]]::new(0)
        $this.WrappedResources = [IntPtr[]]::new(0)
    }.GetNewClosure())
    $targets
}

$script:DXGI_FACTORY_SLOTS = @{
    # 0-2: IUnknown, 3-6: IDXGIObject
    QueryInterface              = 0
    AddRef                      = 1
    Release                     = 2
    SetPrivateData              = 3
    SetPrivateDataInterface     = 4
    GetPrivateData              = 5
    GetParent                   = 6
    EnumAdapters                = 7
    MakeWindowAssociation       = 8
    GetWindowAssociation        = 9
    CreateSwapChain             = 10
    CreateSoftwareAdapter       = 11
    EnumAdapters1               = 12
    IsCurrent                   = 13
    IsWindowedStereoEnabled     = 14
    CreateSwapChainForHwnd      = 15
    CreateSwapChainForCoreWindow = 16
}

$script:DXGI_SWAPCHAIN_SLOTS = @{
    # 0-2: IUnknown, 3-6: IDXGIObject, 7: IDXGIDeviceSubObject (GetDevice)
    QueryInterface          = 0
    AddRef                  = 1
    Release                 = 2
    SetPrivateData          = 3
    SetPrivateDataInterface = 4
    GetPrivateData          = 5
    GetParent               = 6
    GetDevice               = 7
    Present                 = 8
    GetBuffer               = 9
    SetFullscreenState      = 10
    GetFullscreenState      = 11
    GetDesc                 = 12
    ResizeBuffers           = 13
    ResizeTarget            = 14
    GetContainingOutput     = 15
    GetFrameStatistics      = 16
    GetLastPresentCount     = 17
    GetCurrentBackBufferIndex = 36
}

function global:New-CellPresenter {
    [CmdletBinding()]
    param(
        [int] $Width = 1280,
        [int] $Height = 720,
        [string] $Title = "DirectPort Cell Presenter"
    )

    if ($null -eq $global:NativeInteropState) {
        throw "DirectPort runtime not initialized."
    }

    $hostState = New-WindowsHost -Width $Width -Height $Height -Title $Title
    $hwnd = $hostState.Hwnd
    if ($hwnd -eq [IntPtr]::Zero) { throw 'CreateWindowExW failed for the cell presenter.' }

    $user32 = Open-NativeLibrary "user32.dll"
    $d3d12  = Open-NativeLibrary "d3d12.dll"
    $dxgi   = Open-NativeLibrary "dxgi.dll"

    # Win32 exported functions
    $peek_msg      = Get-NativeCall (Get-NativeExport $user32 'PeekMessageW') ([int32]) @([IntPtr], [IntPtr], [uint32], [uint32], [uint32])
    $translate_msg = Get-NativeCall (Get-NativeExport $user32 'TranslateMessage') ([int32]) @([IntPtr])
    $dispatch_msg  = Get-NativeCall (Get-NativeExport $user32 'DispatchMessageW') ([IntPtr]) @([IntPtr])
    $show_window   = Get-NativeCall (Get-NativeExport $user32 'ShowWindow') ([bool]) @([IntPtr], [int32])
    $destroy_window = Get-NativeCall (Get-NativeExport $user32 'DestroyWindow') ([bool]) @([IntPtr])
    $screen_to_client = Get-NativeCall (Get-NativeExport $user32 'ScreenToClient') ([bool]) @([IntPtr], [IntPtr])
    $msg_wait = Get-NativeCall (Get-NativeExport $user32 'MsgWaitForMultipleObjectsEx') ([uint32]) @([uint32], [IntPtr], [uint32], [uint32], [uint32])

    # D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, IID_ID3D12Device, &device)
    $fnD3D12CreateDevice = Get-NativeCall (Get-NativeExport $d3d12 'D3D12CreateDevice') ([int32]) @([IntPtr], [int32], [IntPtr], [IntPtr])
    $pIidDevice = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse("189819f1-1db6-4b57-be54-1821339b85f7").ToByteArray(), 0, $pIidDevice, 16)
    $pDeviceOut = New-NativeBlock ([IntPtr]::Size)
    $hr = [int32]$fnD3D12CreateDevice.DynamicInvoke([IntPtr]::Zero, [int32]0xB000, $pIidDevice, $pDeviceOut)
    $devicePtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pDeviceOut)
    Remove-NativeBlock $pIidDevice
    Remove-NativeBlock $pDeviceOut
    if ($hr -ne 0 -or $devicePtr -eq [IntPtr]::Zero) { throw ("D3D12CreateDevice failed: 0x{0:X8}" -f [uint32]$hr) }

    # CreateDXGIFactory2(0, IID_IDXGIFactory2, &factory)
    $fnCreateDXGIFactory2 = Get-NativeCall (Get-NativeExport $dxgi 'CreateDXGIFactory2') ([int32]) @([uint32], [IntPtr], [IntPtr])
    $pIidFactory2 = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse("50c83a1c-e072-4c48-87b0-3630fa36a6d0").ToByteArray(), 0, $pIidFactory2, 16)
    $pFactoryOut = New-NativeBlock ([IntPtr]::Size)
    $hr = [int32]$fnCreateDXGIFactory2.DynamicInvoke([uint32]0, $pIidFactory2, $pFactoryOut)
    $factoryPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pFactoryOut)
    Remove-NativeBlock $pIidFactory2
    Remove-NativeBlock $pFactoryOut
    if ($hr -ne 0 -or $factoryPtr -eq [IntPtr]::Zero) {
        [void](Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        throw ("CreateDXGIFactory2 failed: 0x{0:X8}" -f [uint32]$hr)
    }

    # Command queue via ID3D12Device::CreateCommandQueue (slot 8)
    $queueDesc = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::WriteInt32($queueDesc, 0, 0)   # DIRECT
    [System.Runtime.InteropServices.Marshal]::WriteInt32($queueDesc, 4, 0)   # NORMAL priority
    [System.Runtime.InteropServices.Marshal]::WriteInt32($queueDesc, 8, 0)   # no flags
    [System.Runtime.InteropServices.Marshal]::WriteInt32($queueDesc, 12, 0)  # node 0

    $pIidQueue = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse("0ec870a6-5d7e-4c22-8cfc-5baae07616ed").ToByteArray(), 0, $pIidQueue, 16)
    $pQueueOut = New-NativeBlock ([IntPtr]::Size)

    $hr = Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.CreateCommandQueue `
        -ParamTypes @([IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) `
        -Args @($queueDesc, $pIidQueue, $pQueueOut)

    $queuePtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pQueueOut)
    Remove-NativeBlock $queueDesc
    Remove-NativeBlock $pIidQueue
    Remove-NativeBlock $pQueueOut
    if ($hr -ne 0 -or $queuePtr -eq [IntPtr]::Zero) {
        [void](Invoke-ComVtableMethod -ComObject $factoryPtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        throw ("CreateCommandQueue failed: 0x{0:X8}" -f [uint32]$hr)
    }

    # Connect the command queue to the existing HWND through IDXGIFactory2.
    $swapDesc = New-NativeBlock 48
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 0, $Width)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 4, $Height)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 8, 87)  # DXGI_FORMAT_B8G8R8A8_UNORM
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 16, 1) # SampleDesc.Count
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 24, 0x20) # DXGI_USAGE_RENDER_TARGET_OUTPUT
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 28, 2)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 32, 0) # DXGI_SCALING_STRETCH
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 36, 4) # DXGI_SWAP_EFFECT_FLIP_DISCARD
    [System.Runtime.InteropServices.Marshal]::WriteInt32($swapDesc, 40, 0) # DXGI_ALPHA_MODE_UNSPECIFIED
    $pSwapChainOut = New-NativeBlock ([IntPtr]::Size)
    $hr = Invoke-ComVtableMethod -ComObject $factoryPtr -SlotIndex $script:DXGI_FACTORY_SLOTS.CreateSwapChainForHwnd `
        -ParamTypes @([IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) `
        -Args @($queuePtr, $hwnd, $swapDesc, [IntPtr]::Zero, [IntPtr]::Zero, $pSwapChainOut)
    $swapChainPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pSwapChainOut)
    Remove-NativeBlock $swapDesc
    Remove-NativeBlock $pSwapChainOut
    if ($hr -ne 0 -or $swapChainPtr -eq [IntPtr]::Zero) {
        [void](Invoke-ComVtableMethod -ComObject $queuePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $factoryPtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void]$destroy_window.DynamicInvoke($hwnd)
        throw ("CreateSwapChainForHwnd failed: 0x{0:X8}" -f [uint32]$hr)
    }
    [void](Invoke-ComVtableMethod -ComObject $factoryPtr -SlotIndex $script:DXGI_FACTORY_SLOTS.MakeWindowAssociation `
        -ParamTypes @([IntPtr], [uint32]) -ReturnType ([int32]) -Args @($hwnd, [uint32]2))

    # Promote the factory result to IDXGISwapChain3 so DXGI selects the active
    # presentation back buffer. The two DXGI buffers are presentation slots,
    # not a limit on producer/consumer node arenas.
    $pIidSwapChain3 = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('94d99bdb-f1f8-4ab0-b236-7da0170edab1').ToByteArray(), 0, $pIidSwapChain3, 16)
    $pSwapChain3Out = New-NativeBlock ([IntPtr]::Size)
    $hr = Invoke-ComVtableMethod -ComObject $swapChainPtr -SlotIndex $script:DXGI_SWAPCHAIN_SLOTS.QueryInterface -ParamTypes @([IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($pIidSwapChain3, $pSwapChain3Out)
    $swapChain3Ptr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pSwapChain3Out)
    Remove-NativeBlock $pIidSwapChain3
    Remove-NativeBlock $pSwapChain3Out
    if ($hr -ne 0 -or $swapChain3Ptr -eq [IntPtr]::Zero) {
        [void](Invoke-ComVtableMethod -ComObject $swapChainPtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $queuePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $factoryPtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void](Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
        [void]$destroy_window.DynamicInvoke($hwnd)
        throw ("QueryInterface(IDXGISwapChain3) failed: 0x{0:X8}" -f [uint32]$hr)
    }
    [void](Invoke-ComVtableMethod -ComObject $swapChainPtr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
    $swapChainPtr = $swapChain3Ptr
    $frameIndex = [uint32](Invoke-ComVtableMethod -ComObject $swapChainPtr -SlotIndex $script:DXGI_SWAPCHAIN_SLOTS.GetCurrentBackBufferIndex -ParamTypes @() -ReturnType ([uint32]))

    $presentationBufferCount = 2
    $rtvHeapDesc = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::WriteInt32($rtvHeapDesc, 0, 2) # D3D12_DESCRIPTOR_HEAP_TYPE_RTV
    [System.Runtime.InteropServices.Marshal]::WriteInt32($rtvHeapDesc, 4, $presentationBufferCount)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($rtvHeapDesc, 8, 0)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($rtvHeapDesc, 12, 0)
    $pIidDescriptorHeap = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('8efb471d-616c-4f49-90f7-127bb763fa51').ToByteArray(), 0, $pIidDescriptorHeap, 16)
    $pRtvHeapOut = New-NativeBlock ([IntPtr]::Size)
    $hr = Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.CreateDescriptorHeap -ParamTypes @([IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($rtvHeapDesc, $pIidDescriptorHeap, $pRtvHeapOut)
    $rtvHeapPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pRtvHeapOut)
    Remove-NativeBlock $rtvHeapDesc
    Remove-NativeBlock $pIidDescriptorHeap
    Remove-NativeBlock $pRtvHeapOut
    if ($hr -ne 0 -or $rtvHeapPtr -eq [IntPtr]::Zero) { throw ("CreateDescriptorHeap(RTV) failed: 0x{0:X8}" -f [uint32]$hr) }

    $rtvStride = [uint32](Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.GetDescriptorHandleIncrementSize -ParamTypes @([int32]) -ReturnType ([uint32]) -Args @([int32]2))
    $pRtvStart = New-NativeBlock 8
    [void](Invoke-ComVtableMethod -ComObject $rtvHeapPtr -SlotIndex $script:D3D12_DESCRIPTOR_HEAP_SLOTS.GetCPUDescriptorHandleStart -ParamTypes @([IntPtr]) -ReturnType ([IntPtr]) -Args @($pRtvStart))
    $rtvStart = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($pRtvStart)
    Remove-NativeBlock $pRtvStart
    $pIidResource = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('696442be-a72e-4059-bc79-5b5c98040fad').ToByteArray(), 0, $pIidResource, 16)
    $presentationBuffers = [IntPtr[]]::new($presentationBufferCount)
    for ($i = 0; $i -lt $presentationBufferCount; $i++) {
        $pBufferOut = New-NativeBlock ([IntPtr]::Size)
        $hr = Invoke-ComVtableMethod -ComObject $swapChainPtr -SlotIndex $script:DXGI_SWAPCHAIN_SLOTS.GetBuffer -ParamTypes @([uint32], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @([uint32]$i, $pIidResource, $pBufferOut)
        $presentationBuffers[$i] = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pBufferOut)
        Remove-NativeBlock $pBufferOut
        if ($hr -ne 0 -or $presentationBuffers[$i] -eq [IntPtr]::Zero) { Remove-NativeBlock $pIidResource; throw ("IDXGISwapChain::GetBuffer({0}) failed: 0x{1:X8}" -f $i, [uint32]$hr) }
        [void](Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.CreateRenderTargetView -ParamTypes @([IntPtr], [IntPtr], [uint64]) -ReturnType ([void]) -Args @($presentationBuffers[$i], [IntPtr]::Zero, [uint64]($rtvStart + ([uint64]$i * $rtvStride))))
    }
    Remove-NativeBlock $pIidResource

    $pIidAllocator = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('6102dee4-af59-4b09-b999-b44d73f09b24').ToByteArray(), 0, $pIidAllocator, 16)
    $presentationAllocators = [IntPtr[]]::new($presentationBufferCount)
    for ($i = 0; $i -lt $presentationBufferCount; $i++) {
        $pAllocatorOut = New-NativeBlock ([IntPtr]::Size)
        $hr = Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.CreateCommandAllocator -ParamTypes @([int32], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @([int32]0, $pIidAllocator, $pAllocatorOut)
        $presentationAllocators[$i] = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pAllocatorOut)
        Remove-NativeBlock $pAllocatorOut
        if ($hr -ne 0 -or $presentationAllocators[$i] -eq [IntPtr]::Zero) { Remove-NativeBlock $pIidAllocator; throw ("CreateCommandAllocator({0}) failed: 0x{1:X8}" -f $i, [uint32]$hr) }
    }
    Remove-NativeBlock $pIidAllocator

    $pIidCommandList = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('5b160d0f-ac1b-4185-8ba8-b3ae42a5a455').ToByteArray(), 0, $pIidCommandList, 16)
    $pCommandListOut = New-NativeBlock ([IntPtr]::Size)
    $hr = Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.CreateCommandList -ParamTypes @([uint32], [int32], [IntPtr], [IntPtr], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @([uint32]0, [int32]0, $presentationAllocators[$frameIndex], [IntPtr]::Zero, $pIidCommandList, $pCommandListOut)
    $commandListPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pCommandListOut)
    Remove-NativeBlock $pIidCommandList
    Remove-NativeBlock $pCommandListOut
    if ($hr -ne 0 -or $commandListPtr -eq [IntPtr]::Zero) { throw ("CreateCommandList failed: 0x{0:X8}" -f [uint32]$hr) }
    $hr = Invoke-ComVtableMethod -ComObject $commandListPtr -SlotIndex $script:D3D12_COMMAND_LIST_SLOTS.Close -ParamTypes @() -ReturnType ([int32])
    if ($hr -ne 0) { throw ("ID3D12GraphicsCommandList::Close failed: 0x{0:X8}" -f [uint32]$hr) }

    $pIidFence = New-NativeBlock 16
    [System.Runtime.InteropServices.Marshal]::Copy([Guid]::Parse('0a753dcf-c4d8-4b91-adf6-be5a60d95a76').ToByteArray(), 0, $pIidFence, 16)
    $pFenceOut = New-NativeBlock ([IntPtr]::Size)
    $hr = Invoke-ComVtableMethod -ComObject $devicePtr -SlotIndex $script:D3D12_DEVICE_SLOTS.CreateFence -ParamTypes @([uint64], [uint32], [IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @([uint64]0, [uint32]0, $pIidFence, $pFenceOut)
    $fencePtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pFenceOut)
    Remove-NativeBlock $pIidFence
    Remove-NativeBlock $pFenceOut
    if ($hr -ne 0 -or $fencePtr -eq [IntPtr]::Zero) { throw ("CreateFence failed: 0x{0:X8}" -f [uint32]$hr) }

    $kernel32 = Open-NativeLibrary 'kernel32.dll'
    $create_event = Get-NativeCall (Get-NativeExport $kernel32 'CreateEventW') ([IntPtr]) @([IntPtr], [bool], [bool], [IntPtr])
    $wait_single = Get-NativeCall (Get-NativeExport $kernel32 'WaitForSingleObject') ([uint32]) @([IntPtr], [uint32])
    $close_handle = Get-NativeCall (Get-NativeExport $kernel32 'CloseHandle') ([bool]) @([IntPtr])
    $fenceEvent = [IntPtr]$create_event.DynamicInvoke([IntPtr]::Zero, $false, $false, [IntPtr]::Zero)
    if ($fenceEvent -eq [IntPtr]::Zero) { throw 'CreateEventW failed for the presentation fence.' }

    $msgBlock = New-NativeBlock 48
    $pointBlock = New-NativeBlock 8
    $stateObj = [Windows.Graphics.CanvasWindowState]::new()
    $stateObj.Alive = $true
    $stateObj.Width = $Width
    $stateObj.Height = $Height

    $presenter = [PSCustomObject]@{
        PSTypeName    = 'QuickPS.CellPresenter'
        Width         = $Width
        Height        = $Height
        Title         = $Title
        MessageLoop   = $true
        DroppedFrames = [uint64]0
        MouseX        = 0
        MouseY        = 0
        KeyCode       = 0
        LeftDown      = $false
        WheelDelta    = 0
        ResizeSerial  = [uint64]0
        FrameIndex    = [uint32]$frameIndex
        LastPresentHResult = [int32]0
        PresentSlot   = [int]$script:DXGI_SWAPCHAIN_SLOTS.Present
        SwapIndexSlot = [int]$script:DXGI_SWAPCHAIN_SLOTS.GetCurrentBackBufferIndex
        QueueSignalSlot = [int]$script:D3D12_CMDQUEUE_SLOTS.Signal
        FenceCompletedSlot = [int]$script:D3D12_FENCE_SLOTS.GetCompletedValue
        FenceEventSlot = [int]$script:D3D12_FENCE_SLOTS.SetEventOnCompletion
        AllocatorResetSlot = [int]$script:D3D12_COMMAND_ALLOCATOR_SLOTS.Reset
        CommandListResetSlot = [int]$script:D3D12_COMMAND_LIST_SLOTS.Reset
        CommandListCloseSlot = [int]$script:D3D12_COMMAND_LIST_SLOTS.Close
        ResourceBarrierSlot = [int]$script:D3D12_COMMAND_LIST_SLOTS.ResourceBarrier
        ClearRenderTargetSlot = [int]$script:D3D12_COMMAND_LIST_SLOTS.ClearRenderTargetView
        ExecuteCommandListsSlot = [int]$script:D3D12_CMDQUEUE_SLOTS.ExecuteCommandLists
        Hwnd          = $hwnd
        DevicePtr     = $devicePtr
        FactoryPtr    = $factoryPtr
        QueuePtr      = $queuePtr
        SwapChainPtr  = $swapChainPtr
        PresentationBufferCount = [int]$presentationBufferCount
        PresentationBuffers = $presentationBuffers
        RtvHeapPtr    = $rtvHeapPtr
        RtvStride     = $rtvStride
        RtvStart      = $rtvStart
        PresentationAllocators = $presentationAllocators
        CommandListPtr = $commandListPtr
        FencePtr      = $fencePtr
        FenceEvent    = $fenceEvent
        FenceValues   = [uint64[]]@(0, 0)
        NextFenceValue = [uint64]1
    }

    [void]$show_window.DynamicInvoke($hwnd, [int32]1)

    # Pump: message loop via Win32 ABI (PeekMessageW, non-blocking)
    $presenter | Add-Member -MemberType ScriptMethod -Name Pump -Value ({
        param([int] $WaitMs = 1)

        $stateObj.KeyCode = 0
        $stateObj.CharCode = [char]0
        $stateObj.WheelDelta = 0
        $stateObj.IsDoubleClick = $false
        $pumpPaintActive = $false
        if ($WaitMs -gt 0) {
            [void]$msg_wait.DynamicInvoke([uint32]0, [IntPtr]::Zero, [uint32]$WaitMs, [uint32]0x04FF, [uint32]4)
        }
        while ([int32]$peek_msg.DynamicInvoke($msgBlock, [IntPtr]::Zero, [uint32]0, [uint32]0, [uint32]1)) {
            $continue = Decode-WindowsInputMessage -State $stateObj -Hwnd $this.Hwnd -ScratchMsg $msgBlock `
                -ScratchPoint $pointBlock -ScratchPaint ([IntPtr]::Zero) -FnBeginPaint $null `
                -FnScreenToClient $screen_to_client -PaintActive ([ref]$pumpPaintActive)
            if (-not $continue) { $this.MessageLoop = $false; break }
            [void]$translate_msg.DynamicInvoke($msgBlock)
            [void]$dispatch_msg.DynamicInvoke($msgBlock)
        }
        $this.Width = $stateObj.Width
        $this.Height = $stateObj.Height
        $this.MouseX = $stateObj.MouseX
        $this.MouseY = $stateObj.MouseY
        $this.KeyCode = $stateObj.KeyCode
        $this.LeftDown = $stateObj.LeftDown
        $this.WheelDelta = $stateObj.WheelDelta
        $this.ResizeSerial = $stateObj.ResizeSerial

        [PSCustomObject]@{
            Alive        = $this.MessageLoop
            Width        = $this.Width
            Height       = $this.Height
            MouseX       = $this.MouseX
            MouseY       = $this.MouseY
            KeyCode      = $this.KeyCode
            LeftDown     = $this.LeftDown
            WheelDelta   = $this.WheelDelta
            ResizeSerial = $this.ResizeSerial
        }
    }.GetNewClosure())

    # Present reaches the real IDXGISwapChain. Frame drawing is bound separately.
    $presenter | Add-Member -MemberType ScriptMethod -Name Present -Value ({
        param([uint32[]] $Cells, [int] $Columns, [int] $Rows, [single] $Elapsed, [uint64] $Frame)
        if ($Cells.Length -ne ($Columns * $Rows)) { throw 'cells.Length must equal columns * rows.' }
        if ($null -ne $this.TextTargets) {
            $builder = [System.Text.StringBuilder]::new(($Columns + 2) * $Rows)
            for ($row = 0; $row -lt $Rows; $row++) {
                $rowStart = $row * $Columns
                for ($column = 0; $column -lt $Columns; $column++) {
                    $codeUnit = [int]($Cells[$rowStart + $column] -band 0xFFFF)
                    [void]$builder.Append($(if ($codeUnit -eq 0) { [char]32 } else { [char]$codeUnit }))
                }
                if ($row -lt ($Rows - 1)) { [void]$builder.Append("`r`n") }
            }
            return [bool]$this.TextTargets.DrawTextFrame($this, $this.TextBridge, $this.TextDevice, $builder.ToString(), $Cells, $Columns, $Rows)
        }
        $activeIndex = [int]$this.FrameIndex
        $hr = [int32](Invoke-ComVtableMethod -ComObject $this.PresentationAllocators[$activeIndex] -SlotIndex $this.AllocatorResetSlot -ParamTypes @() -ReturnType ([int32]))
        if ($hr -lt 0) { $this.LastPresentHResult = $hr; $this.DroppedFrames++; return $false }
        $hr = [int32](Invoke-ComVtableMethod -ComObject $this.CommandListPtr -SlotIndex $this.CommandListResetSlot -ParamTypes @([IntPtr], [IntPtr]) -ReturnType ([int32]) -Args @($this.PresentationAllocators[$activeIndex], [IntPtr]::Zero))
        if ($hr -lt 0) { $this.LastPresentHResult = $hr; $this.DroppedFrames++; return $false }

        $barrier = New-NativeBlock 32
        [System.Runtime.InteropServices.Marshal]::WriteInt32($barrier, 0, 0)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($barrier, 4, 0)
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($barrier, 8, $this.PresentationBuffers[$activeIndex])
        for ($byteOffset = 16; $byteOffset -lt 20; $byteOffset++) {
            [System.Runtime.InteropServices.Marshal]::WriteByte($barrier, $byteOffset, [byte]0xFF)
        }
        [System.Runtime.InteropServices.Marshal]::WriteInt32($barrier, 20, 0)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($barrier, 24, 4)
        [void](Invoke-ComVtableMethod -ComObject $this.CommandListPtr -SlotIndex $this.ResourceBarrierSlot -ParamTypes @([uint32], [IntPtr]) -ReturnType ([void]) -Args @([uint32]1, $barrier))

        $clear = New-NativeBlock 16
        $clearValues = [single[]]@(0.035, 0.055, 0.085, 1.0)
        [System.Runtime.InteropServices.Marshal]::Copy($clearValues, 0, $clear, 4)
        $rtv = [uint64]($this.RtvStart + ([uint64]$activeIndex * $this.RtvStride))
        [void](Invoke-ComVtableMethod -ComObject $this.CommandListPtr -SlotIndex $this.ClearRenderTargetSlot -ParamTypes @([uint64], [IntPtr], [uint32], [IntPtr]) -ReturnType ([void]) -Args @($rtv, $clear, [uint32]0, [IntPtr]::Zero))
        Remove-NativeBlock $clear

        [System.Runtime.InteropServices.Marshal]::WriteInt32($barrier, 20, 4)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($barrier, 24, 0)
        [void](Invoke-ComVtableMethod -ComObject $this.CommandListPtr -SlotIndex $this.ResourceBarrierSlot -ParamTypes @([uint32], [IntPtr]) -ReturnType ([void]) -Args @([uint32]1, $barrier))
        Remove-NativeBlock $barrier
        $hr = [int32](Invoke-ComVtableMethod -ComObject $this.CommandListPtr -SlotIndex $this.CommandListCloseSlot -ParamTypes @() -ReturnType ([int32]))
        if ($hr -lt 0) { $this.LastPresentHResult = $hr; $this.DroppedFrames++; return $false }
        $listArray = New-NativeBlock ([IntPtr]::Size)
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($listArray, 0, $this.CommandListPtr)
        [void](Invoke-ComVtableMethod -ComObject $this.QueuePtr -SlotIndex $this.ExecuteCommandListsSlot -ParamTypes @([uint32], [IntPtr]) -ReturnType ([void]) -Args @([uint32]1, $listArray))
        Remove-NativeBlock $listArray
        $hr = [int32](Invoke-ComVtableMethod -ComObject $this.SwapChainPtr -SlotIndex $this.PresentSlot `
            -ParamTypes @([uint32], [uint32]) -ReturnType ([int32]) -Args @([uint32]0, [uint32]0))
        $this.LastPresentHResult = $hr
        if ($hr -lt 0) { $this.DroppedFrames++; return $false }
        $submittedIndex = [int]$this.FrameIndex
        $signalValue = [uint64]$this.NextFenceValue
        $this.NextFenceValue = [uint64]($signalValue + 1)
        $signalHr = [int32](Invoke-ComVtableMethod -ComObject $this.QueuePtr -SlotIndex $this.QueueSignalSlot -ParamTypes @([IntPtr], [uint64]) -ReturnType ([int32]) -Args @($this.FencePtr, $signalValue))
        if ($signalHr -lt 0) { $this.DroppedFrames++; return $false }
        $this.FenceValues[$submittedIndex] = $signalValue
        $nextIndex = [uint32](Invoke-ComVtableMethod -ComObject $this.SwapChainPtr -SlotIndex $this.SwapIndexSlot -ParamTypes @() -ReturnType ([uint32]))
        $reuseValue = [uint64]$this.FenceValues[$nextIndex]
        if ($reuseValue -ne 0) {
            $completed = [uint64](Invoke-ComVtableMethod -ComObject $this.FencePtr -SlotIndex $this.FenceCompletedSlot -ParamTypes @() -ReturnType ([uint64]))
            if ($completed -lt $reuseValue) {
                $waitHr = [int32](Invoke-ComVtableMethod -ComObject $this.FencePtr -SlotIndex $this.FenceEventSlot -ParamTypes @([uint64], [IntPtr]) -ReturnType ([int32]) -Args @($reuseValue, $this.FenceEvent))
                if ($waitHr -lt 0) { $this.DroppedFrames++; return $false }
                [void]$wait_single.DynamicInvoke($this.FenceEvent, [uint32]::MaxValue)
            }
        }
        $this.FrameIndex = $nextIndex
        $true
    }.GetNewClosure())

    # Dispose: release real COM pointers via their vtable Release (slot 2)
    $presenter | Add-Member -MemberType ScriptMethod -Name Dispose -Value ({
        $this.MessageLoop = $false
        if ($null -ne $this.TextTargets) { $this.TextTargets.Dispose(); $this.TextTargets = $null }
        if ($null -ne $this.TextDevice) { $this.TextDevice.Dispose(); $this.TextDevice = $null }
        if ($null -ne $this.TextBridge) { $this.TextBridge.Dispose(); $this.TextBridge = $null }
        if ($this.QueuePtr -ne [IntPtr]::Zero -and $this.FencePtr -ne [IntPtr]::Zero) {
            $idleValue = [uint64]$this.NextFenceValue
            $idleHr = [int32](Invoke-ComVtableMethod -ComObject $this.QueuePtr -SlotIndex $this.QueueSignalSlot -ParamTypes @([IntPtr], [uint64]) -ReturnType ([int32]) -Args @($this.FencePtr, $idleValue))
            if ($idleHr -ge 0) {
                $completed = [uint64](Invoke-ComVtableMethod -ComObject $this.FencePtr -SlotIndex $this.FenceCompletedSlot -ParamTypes @() -ReturnType ([uint64]))
                if ($completed -lt $idleValue) {
                    $waitHr = [int32](Invoke-ComVtableMethod -ComObject $this.FencePtr -SlotIndex $this.FenceEventSlot -ParamTypes @([uint64], [IntPtr]) -ReturnType ([int32]) -Args @($idleValue, $this.FenceEvent))
                    if ($waitHr -ge 0) { [void]$wait_single.DynamicInvoke($this.FenceEvent, [uint32]::MaxValue) }
                }
            }
        }
        foreach ($ptr in @($this.CommandListPtr) + @($this.PresentationAllocators) + @($this.PresentationBuffers) + @($this.RtvHeapPtr, $this.FencePtr, $this.SwapChainPtr, $this.QueuePtr, $this.FactoryPtr, $this.DevicePtr)) {
            if ($ptr -and $ptr -ne [System.IntPtr]::Zero) {
                [void](Invoke-ComVtableMethod -ComObject $ptr -SlotIndex 2 -ParamTypes @() -ReturnType ([uint32]))
            }
        }
        if ($this.FenceEvent -ne [IntPtr]::Zero) { [void]$close_handle.DynamicInvoke($this.FenceEvent) }
        if ($this.Hwnd -ne [IntPtr]::Zero) { [void]$destroy_window.DynamicInvoke($this.Hwnd) }
        Remove-NativeBlock $msgBlock
        Remove-NativeBlock $pointBlock
        $this.Hwnd = [IntPtr]::Zero
        $this.SwapChainPtr = [System.IntPtr]::Zero
        $this.RtvHeapPtr = [System.IntPtr]::Zero
        $this.CommandListPtr = [System.IntPtr]::Zero
        $this.FencePtr = [System.IntPtr]::Zero
        $this.FenceEvent = [System.IntPtr]::Zero
        $this.QueuePtr = [System.IntPtr]::Zero
        $this.FactoryPtr = [System.IntPtr]::Zero
        $this.DevicePtr = [System.IntPtr]::Zero
    }.GetNewClosure())

    $presenter | Add-Member -MemberType NoteProperty -Name TextBridge -Value $null
    $presenter | Add-Member -MemberType NoteProperty -Name TextDevice -Value $null
    $presenter | Add-Member -MemberType NoteProperty -Name TextTargets -Value $null
    try {
        $presenter.TextBridge = New-D3D11On12Bridge -D3D12Device $presenter.DevicePtr -D3D12Queue $presenter.QueuePtr
        $presenter.TextDevice = New-WindowsTextDevice -Bridge $presenter.TextBridge
        $presenter.TextTargets = New-WindowsTextTargets -Presenter $presenter -Bridge $presenter.TextBridge -TextDevice $presenter.TextDevice
    }
    catch {
        $presenter.Dispose()
        throw
    }

    $presenter
}

$global:QuickPS.NewCellPresenter = ${function:New-CellPresenter}
$global:QuickPS.InvokeVtableMethod = ${function:Invoke-ComVtableMethod}
$global:QuickPS | Add-Member -MemberType NoteProperty -Name NewCompositionPipe -Value $script:Composition.NewPipe -Force
$global:QuickPS | Add-Member -MemberType NoteProperty -Name NewWicPipe -Value $script:Wic.NewPipe -Force
$global:QuickPS | Add-Member -MemberType NoteProperty -Name NewWasapiPipe -Value $script:Wasapi.NewPipe -Force

# Export-ScriptBundle is declared after the retained root is assembled.
$global:QuickPS.Linker = ${function:Export-ScriptBundle}

# ==============================================================================

# Backward-Compatibility Aliases
Set-Alias -Name Invoke-DirectPortVtableMethod -Value Invoke-ComVtableMethod -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name New-DirectPortCanvas -Value New-Canvas -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name New-DirectPortNode -Value New-CapabilityScope -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name New-DirectPortRunspace -Value New-ConstrainedRunspace -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name Add-DirectPortApplication -Value Start-HostedScript -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name Detach-DirectPortApplication -Value Stop-HostedScript -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name Export-DirectPortBundle -Value Export-ScriptBundle -Scope Global -ErrorAction SilentlyContinue
$global:DirectPort = $global:QuickPS
$global:Quips = $global:QuickPS
# SECTION 160: DIRECT EXECUTION GUARD & CLI BUNDLE DISPATCH
////////////////////////////////////////////////////////////////////////////////
//////////////////////////////// SCRIPT BLOCK: CAPABILITY_ROUTER ///////////////
////////////////////////////////////////////////////////////////////////////////

function global:QuickPS {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Canvas', 'Host', 'Input', 'Runspace', 'Telemetry', 'Composition', 'Wic', 'Wasapi', 'GetCarrier')]
        [string] $Action = 'Canvas',

        [Parameter(ValueFromRemainingArguments)]
        [object[]] $Args
    )

    switch ($Action) {
        'Canvas'    {
            $canvasArguments = @($Args | Where-Object { $null -ne $_ })
            if ($canvasArguments.Count -ge 3) {
                return (& $script:Canvas @canvasArguments)
            }
            $dependencies = Resolve-DirectPortCanvasDependencies
            return (& $script:Canvas `
                -AssemblyPath $dependencies.AssemblyPath `
                -AtlasPng $dependencies.AtlasPng `
                -MetricsJson $dependencies.MetricsJson)
        }
        'Host'      { return (New-WindowsHost @Args) }
        'Input'     { return (Decode-WindowsInputMessage @Args) }
        'Runspace'  { return (New-ConstrainedRunspace @Args) }
        'Telemetry' { return (script:Write-TelemetryPanel @Args) }
        'Composition' { return (& $script:Composition.NewPipe @Args) }
        'Wic'         { return (& $script:Wic.NewPipe) }
        'Wasapi'      { return (& $script:Wasapi.NewPipe) }
        'GetCarrier'{ return $global:QuickPS }
    }
}

if ($Bundle) {
    $out = Export-ScriptBundle -ScriptPath $Bundle -OutputPath $OutFile
    if ($out) { "Bundle written to $out" }
    exit 0
}

$isDirectExecution = [string]::IsNullOrEmpty($MyInvocation.ScriptName) -and
                     ($MyInvocation.InvocationName -ne '.')

if ($isDirectExecution -or $Interactive) {
    if ($Headless) { exit 0 }
    if (-not $EnableCanvas) {
        exit 0
    }

    $dependencies = Resolve-DirectPortCanvasDependencies `
        -AssemblyPath $AssemblyPath `
        -AtlasPng $AtlasPng `
        -MetricsJson $MetricsJson
    & $script:Canvas `
        -AssemblyPath $dependencies.AssemblyPath `
        -AtlasPng $dependencies.AtlasPng `
        -MetricsJson $dependencies.MetricsJson
}
