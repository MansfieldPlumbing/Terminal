#requires -Version 7.0
param(
    [Android.App.Activity] $Activity = $global:Activity
)

# Mechanical PowerShell port of the small TypeScript Tetris donor.
# Application semantics stay here; Android is only input + presentation.
# No fixed window size or fixed pixel cell size: layout derives from the live SurfaceView.

if ($null -eq $Activity) { throw 'Tetris.ps1 requires AndroidSMA to provide $Activity.' }

$script:TetrisPresentation = [ordered]@{
    Orientation = 'Portrait'
    Reflow      = $true
}

function New-TetrisMatrix([string[]] $Rows) {
    [object[]] $matrix = [object[]]::new($Rows.Count)
    for ($y = 0; $y -lt $Rows.Count; $y++) {
        [byte[]] $row = [byte[]]::new($Rows[$y].Length)
        for ($x = 0; $x -lt $Rows[$y].Length; $x++) {
            if ($Rows[$y][$x] -eq '1') { $row[$x] = 1 }
        }
        $matrix[$y] = $row
    }
    return ,$matrix
}

function New-TetrisGrid {
    [object[]] $grid = [object[]]::new(20)
    for ($r = 0; $r -lt 20; $r++) { $grid[$r] = [byte[]]::new(10) }
    return ,$grid
}

$script:TetrisShapes = @{
    1 = (New-TetrisMatrix @('0000','1111','0000','0000')) # I
    2 = (New-TetrisMatrix @('100','111','000'))           # J
    3 = (New-TetrisMatrix @('001','111','000'))           # L
    4 = (New-TetrisMatrix @('11','11'))                   # O
    5 = (New-TetrisMatrix @('011','110','000'))           # S
    6 = (New-TetrisMatrix @('010','111','000'))           # T
    7 = (New-TetrisMatrix @('110','011','000'))           # Z
}

$script:TetrisColors = @{
    1 = [Android.Graphics.Color]::Rgb(0, 220, 235)
    2 = [Android.Graphics.Color]::Rgb(50, 90, 245)
    3 = [Android.Graphics.Color]::Rgb(255, 157, 45)
    4 = [Android.Graphics.Color]::Rgb(247, 219, 54)
    5 = [Android.Graphics.Color]::Rgb(68, 205, 88)
    6 = [Android.Graphics.Color]::Rgb(165, 86, 220)
    7 = [Android.Graphics.Color]::Rgb(238, 68, 73)
}

function Reset-TetrisGame {
    $script:Tetris = [pscustomobject]@{
        Grid          = (New-TetrisGrid)
        PieceType     = 0
        Matrix        = $null
        X             = 0
        Y             = 0
        Score         = 0
        Lines         = 0
        Level         = 1
        GameOver      = $false
        Paused        = $false
        DropAt        = [Environment]::TickCount64 + 1000
        DropInterval  = 1000
        Dirty         = $true
        TouchDownX    = [single]0
        TouchDownY    = [single]0
        TouchTracking = $false
    }
    Spawn-TetrisPiece
}

function Test-TetrisPosition([object[]] $Matrix, [int] $PX, [int] $PY) {
    for ($y = 0; $y -lt $Matrix.Count; $y++) {
        [byte[]] $row = $Matrix[$y]
        for ($x = 0; $x -lt $row.Length; $x++) {
            if ($row[$x] -eq 0) { continue }
            $r = $PY + $y
            $c = $PX + $x
            if ($c -lt 0 -or $c -ge 10 -or $r -ge 20) { return $false }
            if ($r -ge 0 -and $script:Tetris.Grid[$r][$c] -ne 0) { return $false }
        }
    }
    return $true
}

function Move-Tetris([int] $DX, [int] $DY) {
    if (Test-TetrisPosition $script:Tetris.Matrix ($script:Tetris.X + $DX) ($script:Tetris.Y + $DY)) {
        $script:Tetris.X += $DX
        $script:Tetris.Y += $DY
        $script:Tetris.Dirty = $true
        return $true
    }
    return $false
}

function New-RotatedTetrisMatrix([object[]] $Matrix, [int] $Direction) {
    $n = $Matrix.Count
    [object[]] $rotated = [object[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $rotated[$i] = [byte[]]::new($n) }

    for ($y = 0; $y -lt $n; $y++) {
        [byte[]] $row = $Matrix[$y]
        for ($x = 0; $x -lt $n; $x++) {
            if ($Direction -gt 0) { $rotated[$x][$n - 1 - $y] = $row[$x] }
            else { $rotated[$n - 1 - $x][$y] = $row[$x] }
        }
    }
    return ,$rotated
}

function Rotate-Tetris([int] $Direction = 1) {
    [object[]] $rotated = New-RotatedTetrisMatrix $script:Tetris.Matrix $Direction
    foreach ($kick in @(0, -1, 1, -2, 2)) {
        if (Test-TetrisPosition $rotated ($script:Tetris.X + $kick) $script:Tetris.Y) {
            $script:Tetris.Matrix = $rotated
            $script:Tetris.X += $kick
            $script:Tetris.Dirty = $true
            return
        }
    }
}

function Lock-TetrisPiece {
    for ($y = 0; $y -lt $script:Tetris.Matrix.Count; $y++) {
        [byte[]] $row = $script:Tetris.Matrix[$y]
        for ($x = 0; $x -lt $row.Length; $x++) {
            if ($row[$x] -eq 0) { continue }
            $r = $script:Tetris.Y + $y
            $c = $script:Tetris.X + $x
            if ($r -ge 0 -and $r -lt 20 -and $c -ge 0 -and $c -lt 10) {
                $script:Tetris.Grid[$r][$c] = [byte]$script:Tetris.PieceType
            }
        }
    }
}

function Clear-TetrisLines {
    $write = 19
    $cleared = 0
    for ($read = 19; $read -ge 0; $read--) {
        $full = $true
        for ($c = 0; $c -lt 10; $c++) {
            if ($script:Tetris.Grid[$read][$c] -eq 0) { $full = $false; break }
        }
        if ($full) { $cleared++; continue }
        if ($write -ne $read) { $script:Tetris.Grid[$write] = $script:Tetris.Grid[$read] }
        $write--
    }
    while ($write -ge 0) {
        $script:Tetris.Grid[$write] = [byte[]]::new(10)
        $write--
    }

    if ($cleared -gt 0) {
        $scores = @(0, 40, 100, 300, 1200)
        $script:Tetris.Lines += $cleared
        $script:Tetris.Score += $scores[$cleared] * $script:Tetris.Level
        $script:Tetris.Level = [Math]::Floor($script:Tetris.Lines / 10) + 1
        $script:Tetris.DropInterval = [Math]::Max(100, 1000 - (($script:Tetris.Level - 1) * 100))
    }
}

function Spawn-TetrisPiece {
    $type = $script:TetrisRng.Next(1, 8)
    $script:Tetris.PieceType = $type
    $script:Tetris.Matrix = $script:TetrisShapes[$type]
    $width = ([byte[]]$script:Tetris.Matrix[0]).Length
    $script:Tetris.X = [Math]::Floor(10 / 2) - [Math]::Floor($width / 2)
    $script:Tetris.Y = 0
    $script:Tetris.DropAt = [Environment]::TickCount64 + $script:Tetris.DropInterval
    if (-not (Test-TetrisPosition $script:Tetris.Matrix $script:Tetris.X $script:Tetris.Y)) {
        $script:Tetris.GameOver = $true
    }
    $script:Tetris.Dirty = $true
}

function Step-TetrisDown {
    if (-not (Move-Tetris 0 1)) {
        Lock-TetrisPiece
        Clear-TetrisLines
        Spawn-TetrisPiece
    }
    $script:Tetris.DropAt = [Environment]::TickCount64 + $script:Tetris.DropInterval
}

function Drop-TetrisHard {
    while (Move-Tetris 0 1) { }
    Step-TetrisDown
}

function Invoke-TetrisCommand([string] $Command) {
    if ($Command -eq 'Restart') { Reset-TetrisGame; Request-TetrisFrame; return }
    if ($Command -eq 'Pause') {
        $script:Tetris.Paused = -not $script:Tetris.Paused
        $script:Tetris.DropAt = [Environment]::TickCount64 + $script:Tetris.DropInterval
        $script:Tetris.Dirty = $true
        Request-TetrisFrame
        return
    }
    if ($script:Tetris.GameOver -or $script:Tetris.Paused) { return }

    switch ($Command) {
        'Left'   { [void](Move-Tetris -1 0) }
        'Right'  { [void](Move-Tetris 1 0) }
        'Down'   { Step-TetrisDown }
        'Rotate' { Rotate-Tetris 1 }
        'Drop'   { Drop-TetrisHard }
    }
    Request-TetrisFrame
}

function Set-TetrisPaint([Android.Graphics.Color] $Color, [single] $TextSize = 0,
                         [Android.Graphics.Paint+Align] $Align = [Android.Graphics.Paint+Align]::Left) {
    $script:TetrisPaint.Color = $Color
    $script:TetrisPaint.SetStyle([Android.Graphics.Paint+Style]::Fill)
    $script:TetrisPaint.TextAlign = $Align
    if ($TextSize -gt 0) { $script:TetrisPaint.TextSize = $TextSize }
}

function Draw-TetrisText([Android.Graphics.Canvas] $Canvas, [string] $Text,
                         [single] $X, [single] $Y, [single] $Size,
                         [Android.Graphics.Color] $Color,
                         [Android.Graphics.Paint+Align] $Align = [Android.Graphics.Paint+Align]::Left) {
    Set-TetrisPaint $Color $Size $Align
    $Canvas.DrawText($Text, $X, $Y, $script:TetrisPaint)
}

function Draw-TetrisBlock([Android.Graphics.Canvas] $Canvas,
                          [single] $X, [single] $Y, [single] $Cell,
                          [Android.Graphics.Color] $Color) {
    $gap = [single][Math]::Max(1.0, $Cell * 0.055)
    Set-TetrisPaint $Color
    $Canvas.DrawRoundRect(
        [single]($X + $gap), [single]($Y + $gap),
        [single]($X + $Cell - $gap), [single]($Y + $Cell - $gap),
        [single]($Cell * 0.10), [single]($Cell * 0.10), $script:TetrisPaint)
}

function Get-TetrisLayout([single] $Width, [single] $Height) {
    # Only the logical board is fixed (10x20). Everything physical derives from the surface.
    $short = [single][Math]::Min($Width, $Height)
    $pad = [single]($short * 0.035)
    $hudH = [single][Math]::Max($short * 0.12, $Height * 0.075)
    $availableW = [single][Math]::Max(1.0, $Width - (2 * $pad))
    $availableH = [single][Math]::Max(1.0, $Height - $hudH - (2 * $pad))
    $cell = [single][Math]::Min($availableW / 10.0, $availableH / 20.0)
    $boardW = [single](10 * $cell)
    $boardH = [single](20 * $cell)
    $left = [single](($Width - $boardW) / 2.0)
    $top = [single]($hudH + $pad + (($availableH - $boardH) / 2.0))
    return [pscustomobject]@{
        Cell = $cell; BoardW = $boardW; BoardH = $boardH
        Left = $left; Top = $top; HudH = $hudH; Pad = $pad
    }
}

function Draw-TetrisFrame {
    $edge = $script:TetrisEdge
    if (-not $script:Tetris.Dirty -or $null -eq $edge.Surface -or -not $edge.Surface.Holder.Surface.IsValid) { return }

    [Android.Graphics.Canvas] $canvas = $null
    try {
        $canvas = $edge.Surface.Holder.LockHardwareCanvas()
        if ($null -eq $canvas) { return }
        $w = [single]$edge.Surface.Width
        $h = [single]$edge.Surface.Height
        $layout = Get-TetrisLayout $w $h
        $cell = [single]$layout.Cell
        $left = [single]$layout.Left
        $top = [single]$layout.Top

        $canvas.DrawColor([Android.Graphics.Color]::Rgb(11, 13, 18))

        # Compact HUD across the top: same layout model at every aspect ratio.
        $hudY = [single]($layout.Pad + ($layout.HudH * 0.52))
        $valueY = [single]($layout.Pad + ($layout.HudH * 0.86))
        $fontSmall = [single][Math]::Max(11.0, $cell * 0.42)
        $fontValue = [single][Math]::Max(15.0, $cell * 0.64)
        foreach ($hud in @(
            @('SCORE', [string]$script:Tetris.Score, 0.18),
            @('LEVEL', [string]$script:Tetris.Level, 0.50),
            @('LINES', [string]$script:Tetris.Lines, 0.82)
        )) {
            $hx = [single]($w * [double]$hud[2])
            Draw-TetrisText $canvas ([string]$hud[0]) $hx $hudY $fontSmall `
                ([Android.Graphics.Color]::Rgb(126, 132, 145)) ([Android.Graphics.Paint+Align]::Center)
            Draw-TetrisText $canvas ([string]$hud[1]) $hx $valueY $fontValue `
                ([Android.Graphics.Color]::White) ([Android.Graphics.Paint+Align]::Center)
        }

        Set-TetrisPaint ([Android.Graphics.Color]::Rgb(26, 29, 36))
        $canvas.DrawRoundRect($left, $top, [single]($left + $layout.BoardW),
            [single]($top + $layout.BoardH), [single]($cell * 0.18), [single]($cell * 0.18), $script:TetrisPaint)

        # Grid lines scale with cell size; they are intentionally subtle.
        $script:TetrisPaint.SetStyle([Android.Graphics.Paint+Style]::Stroke)
        $script:TetrisPaint.StrokeWidth = [single][Math]::Max(1.0, $cell * 0.018)
        $script:TetrisPaint.Color = [Android.Graphics.Color]::Rgb(43, 47, 56)
        for ($r = 1; $r -lt 20; $r++) {
            $y = [single]($top + ($r * $cell))
            $canvas.DrawLine($left, $y, [single]($left + $layout.BoardW), $y, $script:TetrisPaint)
        }
        for ($c = 1; $c -lt 10; $c++) {
            $x = [single]($left + ($c * $cell))
            $canvas.DrawLine($x, $top, $x, [single]($top + $layout.BoardH), $script:TetrisPaint)
        }

        for ($r = 0; $r -lt 20; $r++) {
            for ($c = 0; $c -lt 10; $c++) {
                $type = [int]$script:Tetris.Grid[$r][$c]
                if ($type -ne 0) {
                    Draw-TetrisBlock $canvas ([single]($left + $c * $cell)) `
                        ([single]($top + $r * $cell)) $cell $script:TetrisColors[$type]
                }
            }
        }

        if (-not $script:Tetris.GameOver) {
            $ghostY = $script:Tetris.Y
            while (Test-TetrisPosition $script:Tetris.Matrix $script:Tetris.X ($ghostY + 1)) { $ghostY++ }
            $ghost = [Android.Graphics.Color]::Argb(50, 255, 255, 255)
            for ($y = 0; $y -lt $script:Tetris.Matrix.Count; $y++) {
                [byte[]] $row = $script:Tetris.Matrix[$y]
                for ($x = 0; $x -lt $row.Length; $x++) {
                    if ($row[$x] -eq 0) { continue }
                    Draw-TetrisBlock $canvas `
                        ([single]($left + ($script:Tetris.X + $x) * $cell)) `
                        ([single]($top + ($ghostY + $y) * $cell)) $cell $ghost
                }
            }

            for ($y = 0; $y -lt $script:Tetris.Matrix.Count; $y++) {
                [byte[]] $row = $script:Tetris.Matrix[$y]
                for ($x = 0; $x -lt $row.Length; $x++) {
                    if ($row[$x] -eq 0) { continue }
                    Draw-TetrisBlock $canvas `
                        ([single]($left + ($script:Tetris.X + $x) * $cell)) `
                        ([single]($top + ($script:Tetris.Y + $y) * $cell)) $cell `
                        $script:TetrisColors[[int]$script:Tetris.PieceType]
                }
            }
        }

        if ($script:Tetris.Paused -or $script:Tetris.GameOver) {
            Set-TetrisPaint ([Android.Graphics.Color]::Argb(215, 8, 10, 14))
            $mid = [single]($top + $layout.BoardH / 2.0)
            $band = [single]($cell * 2.4)
            $canvas.DrawRect($left, [single]($mid - $band / 2.0),
                [single]($left + $layout.BoardW), [single]($mid + $band / 2.0), $script:TetrisPaint)
            $label = if ($script:Tetris.GameOver) { 'GAME OVER' } else { 'PAUSED' }
            $labelColor = if ($script:Tetris.GameOver) {
                [Android.Graphics.Color]::Rgb(255, 92, 92)
            } else { [Android.Graphics.Color]::White }
            Draw-TetrisText $canvas $label ([single]($left + $layout.BoardW / 2.0)) `
                ([single]($mid + $cell * 0.22)) ([single]($cell * 0.82)) $labelColor `
                ([Android.Graphics.Paint+Align]::Center)
        }

        $script:Tetris.Dirty = $false
    }
    catch {
        [Android.Util.Log]::Error('PowerShell', "Tetris draw failed: $_ stack=$($_.ScriptStackTrace)")
    }
    finally {
        if ($null -ne $canvas) { $edge.Surface.Holder.UnlockCanvasAndPost($canvas) }
    }
}

function Request-TetrisFrame {
    $edge = $script:TetrisEdge
    if ($null -eq $edge -or -not $edge.Active -or $edge.FramePending -or $null -eq $edge.Surface) { return }
    $edge.FramePending = $true
    $edge.Surface.PostOnAnimation($edge.Tick)
}

function Exit-Tetris {
    $edge = $script:TetrisEdge
    if ($null -ne $edge) { $edge.Active = $false }
    try { $Activity.RequestedOrientation = $script:TetrisPreviousOrientation } catch { }

    $startPath = [System.IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'Profile.ps1')
    if ([System.IO.File]::Exists($startPath)) {
        [scriptblock] $start = [scriptblock]::Create([System.IO.File]::ReadAllText($startPath))
        & $start
    }
    else { $Activity.Finish() }
}

$script:TetrisRng = [Random]::new()
Reset-TetrisGame

[Android.Graphics.Paint] $script:TetrisPaint = [Android.Graphics.Paint]::new()
$script:TetrisPaint.AntiAlias = $true
[void]$script:TetrisPaint.SetTypeface([Android.Graphics.Typeface]::Create('sans-serif', [Android.Graphics.TypefaceStyle]::Bold))

$script:TetrisPreviousOrientation = $Activity.RequestedOrientation
$generation = [Guid]::NewGuid()
$edge = [pscustomobject]@{
    Activity = $Activity
    Surface = $null
    Tick = $null
    Touch = $null
    KeyPress = $null
    Active = $true
    FramePending = $false
    Generation = $generation
}
$script:TetrisEdge = $edge

[scriptblock] $keyPress = {
    param($sender, $eventArgs)
    try {
        if ($eventArgs.Event.Action -ne [Android.Views.KeyEventActions]::Down) { return }
        $key = $eventArgs.KeyCode
        if ($key -eq [Android.Views.Keycode]::DpadLeft)        { Invoke-TetrisCommand 'Left';    $eventArgs.Handled = $true }
        elseif ($key -eq [Android.Views.Keycode]::DpadRight)   { Invoke-TetrisCommand 'Right';   $eventArgs.Handled = $true }
        elseif ($key -eq [Android.Views.Keycode]::DpadDown)    { Invoke-TetrisCommand 'Down';    $eventArgs.Handled = $true }
        elseif ($key -eq [Android.Views.Keycode]::DpadUp)      { Invoke-TetrisCommand 'Rotate';  $eventArgs.Handled = $true }
        elseif ($key -in @([Android.Views.Keycode]::DpadCenter, [Android.Views.Keycode]::Enter, [Android.Views.Keycode]::Space)) {
            Invoke-TetrisCommand 'Drop'; $eventArgs.Handled = $true
        }
        elseif ($key -eq [Android.Views.Keycode]::P)           { Invoke-TetrisCommand 'Pause';   $eventArgs.Handled = $true }
        elseif ($key -eq [Android.Views.Keycode]::R)           { Invoke-TetrisCommand 'Restart'; $eventArgs.Handled = $true }
        elseif ($key -eq [Android.Views.Keycode]::Back)        { $eventArgs.Handled = $true; Exit-Tetris }
    }
    catch { [Android.Util.Log]::Error('PowerShell', "Tetris key failed: $_") }
}.GetNewClosure()
$edge.KeyPress = $keyPress

[scriptblock] $touch = {
    param($sender, $eventArgs)
    try {
        [Android.Views.MotionEvent] $e = $eventArgs.Event
        if ($e.ActionMasked -eq [Android.Views.MotionEventActions]::Down) {
            $script:Tetris.TouchDownX = [single]$e.GetX()
            $script:Tetris.TouchDownY = [single]$e.GetY()
            $script:Tetris.TouchTracking = $true
            $eventArgs.Handled = $true
            return
        }
        if ($e.ActionMasked -eq [Android.Views.MotionEventActions]::Up -and $script:Tetris.TouchTracking) {
            $script:Tetris.TouchTracking = $false
            $dx = [single]($e.GetX() - $script:Tetris.TouchDownX)
            $dy = [single]($e.GetY() - $script:Tetris.TouchDownY)
            $threshold = [single]([Math]::Min($edge.Surface.Width, $edge.Surface.Height) * 0.08)
            if ([Math]::Abs($dx) -gt [Math]::Abs($dy) -and [Math]::Abs($dx) -gt $threshold) {
                Invoke-TetrisCommand $(if ($dx -lt 0) { 'Left' } else { 'Right' })
            }
            elseif ([Math]::Abs($dy) -gt $threshold) {
                Invoke-TetrisCommand $(if ($dy -gt 0) { 'Drop' } else { 'Rotate' })
            }
            else { Invoke-TetrisCommand 'Rotate' }
            $eventArgs.Handled = $true
        }
    }
    catch { [Android.Util.Log]::Error('PowerShell', "Tetris touch failed: $_") }
}.GetNewClosure()
$edge.Touch = $touch

[Action] $onAnimation = [Action]{
    try {
        $edge.FramePending = $false
        if (-not $edge.Active -or $null -eq $edge.Surface -or -not $edge.Surface.IsAttachedToWindow) { return }

        $now = [Environment]::TickCount64
        if (-not $script:Tetris.Paused -and -not $script:Tetris.GameOver -and $now -ge $script:Tetris.DropAt) {
            Step-TetrisDown
        }
        Draw-TetrisFrame

        # Active play schedules toward the next gravity deadline. Paused/game-over is event-driven.
        if (-not $script:Tetris.Paused -and -not $script:Tetris.GameOver) {
            $remaining = [Math]::Max(1, $script:Tetris.DropAt - [Environment]::TickCount64)
            $delay = [int][Math]::Min(50, $remaining)
            $edge.FramePending = $true
            $edge.Surface.PostDelayed($edge.Tick, [long]$delay)
        }
    }
    catch { [Android.Util.Log]::Error('PowerShell', "Tetris tick failed: $_ stack=$($_.ScriptStackTrace)") }
}.GetNewClosure()
[AndroidSMA.RecoveryProgram]::SetAnimationCallback($onAnimation)
$callbackMethod = [AndroidSMA.RecoveryProgram].GetMethod('RunAnimationCallback', [Reflection.BindingFlags]'Public,Static')
[Action] $animationCallback = $callbackMethod.CreateDelegate([Action])
$edge.Tick = [Java.Lang.Runnable]::new($animationCallback)

[Action] $attach = [Action]{
    try {
        # Per-script policy on the shared Activity. Restore it in Exit-Tetris so the next app is free again.
        $Activity.RequestedOrientation = [Android.Content.PM.ScreenOrientation]::Portrait

        [Android.Views.SurfaceView] $surface = [Android.Views.SurfaceView]::new($Activity)
        $surface.KeepScreenOn = $true
        $surface.Focusable = $true
        $surface.FocusableInTouchMode = $true
        $surface.add_Touch($touch)
        $surface.add_KeyPress($keyPress)
        $edge.Surface = $surface
        $Activity.SetContentView($surface)
        [void]$surface.RequestFocus()
        $script:Tetris.Dirty = $true
        Request-TetrisFrame
        [Android.Util.Log]::Info('PowerShell', "Tetris READY generation=$generation orientation=portrait")
    }
    catch { [Android.Util.Log]::Error('PowerShell', "Tetris attach failed: $_ stack=$($_.ScriptStackTrace)") }
}.GetNewClosure()

$Activity.RunOnUiThread($attach)
