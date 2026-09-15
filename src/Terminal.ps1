#requires -Version 7.0
using namespace System
using namespace System.Diagnostics

param(
    [Android.App.Activity] $Activity = $global:Activity
)

# Terminal shell. The application remains PowerShell; Android owns
# only input admission and presentation through the packed-cell canvas edge.
enum TerminalPage { Terminal; Editor; Settings }

# Keep the donor state alive when an Activity is replaced or this script is
# reloaded. Android objects live separately in $script:AndroidCanvasEdge.
if ($null -eq $script:Cells) {
    $script:Cells = [uint32[]]::new(1)
    $script:Columns = 1
    $script:Rows = 1
    $script:Mode = [TerminalPage]::Terminal
    $global:CanvasSelectedModeIndex = 0
    $script:Frame = 0
    # Android physical pixels are denser than the donor's 1000 x 650 desktop
    # window. Scale 2 yields a comparable approximately 4,000-cell workload.
    $script:Scale = 2
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
    $script:CursorPhase = -1
    $global:TerminalInput = ''
    $global:TerminalInputCursor = 0
    $global:TerminalHistory = [Collections.Generic.List[string]]::new()
    $global:TerminalHistoryIndex = -1
    $global:TerminalTranscript = [Collections.Generic.List[object]]::new()
    $global:TerminalTranscriptVersion = 0
    $global:TerminalReflowWidth = 0
    $global:TerminalReflowVersion = -1
    $global:TerminalReflowRows = @()
    $global:TerminalSyntaxCache = @{}
    $global:TerminalTranscript.Add([pscustomobject]@{ Text = 'PowerShell 7 on Android CoreCLR'; Foreground = 10 })
    $global:TerminalTranscript.Add([pscustomobject]@{ Text = 'Terminal ready.'; Foreground = 7 })
    $global:TerminalTranscript.Add([pscustomobject]@{ Text = ''; Foreground = 7 })
    $global:TerminalCommand = $null
    $global:TerminalAsync = $null
    $global:TerminalOutput = $null
    $global:TerminalScroll = 0
    $global:TerminalSettingsIndex = 0
    $global:TerminalEditorText = "# PowerShell editor`nGet-Process | Sort-Object CPU -Descending | Select-Object -First 10"
    $global:TerminalQuickIndex = 0
    $global:TerminalQuickCommands = @(
        '$PSVersionTable',
        '$global:TerminalCount = 1 + $global:TerminalCount; $global:TerminalCount',
        '[Environment]::ProcessorCount',
        'Get-Process | Select-Object -First 8',
        '[DateTime]::Now'
    )
    $initialState = [Management.Automation.Runspaces.InitialSessionState]::Create()
    $initialState.LanguageMode = [Management.Automation.PSLanguageMode]::FullLanguage
    $initialState.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $global:TerminalRunspace = [RunspaceFactory]::CreateRunspace($initialState)
    $global:TerminalRunspace.Open()
}

$global:labels = @(
    @{ Text = ' TERMINAL '; Mode = [TerminalPage]::Terminal },
    @{ Text = ' EDITOR '; Mode = [TerminalPage]::Editor },
    @{ Text = ' SETTINGS '; Mode = [TerminalPage]::Settings }
)

function global:Set-Mode([TerminalPage] $Mode) {
    $script:Mode = $Mode
    $script:Dirty = $true
    $script:EmitSample = $true
}

function global:Request-TerminalRefresh { $script:Dirty = $true }

function global:Cycle-TerminalTextScale {
    $script:Scale = if ($script:Scale -ge 4) { 1 } else { $script:Scale + 1 }
    $script:Dirty = $true
}

function global:Add-TerminalLine([string] $Text, [int] $Foreground = 7) {
    foreach ($line in ([string]$Text -split "`r?`n", -1)) {
        $global:TerminalTranscript.Add([pscustomobject]@{ Text = $line; Foreground = $Foreground })
    }
    while ($global:TerminalTranscript.Count -gt 4000) { $global:TerminalTranscript.RemoveAt(0) }
    $global:TerminalTranscriptVersion++
    $global:TerminalScroll = 0
    $script:Dirty = $true
}

function global:Exit-Terminal {
    if ($null -ne $script:AndroidCanvasEdge) {
        $script:AndroidCanvasEdge.Active = $false
        if ($null -ne $script:AndroidCanvasEdge.HintSession) {
            $script:AndroidCanvasEdge.HintSession.Close()
        }
    }
    if ($null -ne $global:TerminalRunspace) {
        $global:TerminalRunspace.Dispose()
        $global:TerminalRunspace = $null
    }
    # A later launch creates a new terminal model and a new child runspace.
    $script:Cells = $null
    $startPath = [System.IO.Path]::Combine(
        [string]$global:Terminal.Home, 'Profile.ps1')
    if (-not [System.IO.File]::Exists($startPath)) {
        throw "Profile.ps1 was not found: $startPath"
    }
    [System.Environment]::SetEnvironmentVariable(
        'TERMINAL_SESSION', 'launcher', [System.EnvironmentVariableTarget]::Process)
    $global:Terminal.Session = 'launcher'
    [scriptblock] $startSource = [scriptblock]::Create(
        [System.IO.File]::ReadAllText($startPath))
    & $startSource
}

function global:Start-TerminalCommand {
    [Android.Util.Log]::Info('PowerShell', "Terminal submit entered input='$global:TerminalInput' async=$($null -ne $global:TerminalAsync)")
    if ($null -ne $global:TerminalAsync) { return }
    $commandText = $global:TerminalInput
    if ([string]::IsNullOrWhiteSpace($commandText)) { return }
    if ($commandText.Trim().Equals('exit', [StringComparison]::OrdinalIgnoreCase)) {
        $global:TerminalInput = ''
        $global:TerminalInputCursor = 0
        Exit-Terminal
        return
    }
    Add-TerminalLine "PS> $commandText" 11
    $global:TerminalHistory.Add($commandText)
    $global:TerminalHistoryIndex = $global:TerminalHistory.Count
    $global:TerminalInput = ''
    $global:TerminalInputCursor = 0
    $powerShell = [PowerShell]::Create()
    $powerShell.Runspace = $global:TerminalRunspace
    $null = $powerShell.AddScript($commandText)
    $output = [Management.Automation.PSDataCollection[psobject]]::new()
    $global:TerminalCommand = $powerShell
    $global:TerminalOutput = $output
    $global:TerminalAsync = $powerShell.BeginInvoke[psobject, psobject]($null, $output)
    [Android.Util.Log]::Info('PowerShell', 'Terminal command BeginInvoke accepted')
    $script:Dirty = $true
}

function global:Complete-TerminalCommand {
    if ($null -eq $global:TerminalAsync -or -not $global:TerminalAsync.IsCompleted) { return }
    try {
        $null = $global:TerminalCommand.EndInvoke($global:TerminalAsync)
        if ($global:TerminalOutput.Count) {
            foreach ($resultObject in $global:TerminalOutput) {
                $baseObject = $resultObject.PSObject.BaseObject
                if ($baseObject -is [Collections.IDictionary]) {
                    foreach ($key in $baseObject.Keys) {
                        Add-TerminalLine ('{0,-28} {1}' -f $key, $baseObject[$key]) 7
                    }
                }
                elseif ($baseObject -is [Diagnostics.Process]) {
                    Add-TerminalLine ('{0,6}  {1}' -f $baseObject.Id, $baseObject.ProcessName) 7
                }
                else { Add-TerminalLine ([string]$baseObject) 7 }
            }
        }
        foreach ($errorRecord in $global:TerminalCommand.Streams.Error) {
            Add-TerminalLine ([string]$errorRecord) 9
        }
    }
    catch { Add-TerminalLine ([string]$_) 9 }
    finally {
        $global:TerminalCommand.Dispose()
        $global:TerminalCommand = $null
        $global:TerminalAsync = $null
        $global:TerminalOutput = $null
        $script:Dirty = $true
    }
}

function global:Get-PowerShellTokenSpans([string] $Text) {
    if ($global:TerminalSyntaxCache.ContainsKey($Text)) { return $global:TerminalSyntaxCache[$Text] }
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    $spans = [Collections.Generic.List[object]]::new()
    foreach ($token in $tokens) {
        $foreground = if (($token.TokenFlags -band [Management.Automation.Language.TokenFlags]::Keyword) -ne 0) { 13 }
            elseif ($token.Kind -in @([Management.Automation.Language.TokenKind]::StringLiteral,[Management.Automation.Language.TokenKind]::StringExpandable)) { 10 }
            elseif ($token.Kind -eq [Management.Automation.Language.TokenKind]::Variable) { 14 }
            elseif ($token.Kind -eq [Management.Automation.Language.TokenKind]::Number) { 11 }
            elseif ($token.Kind -eq [Management.Automation.Language.TokenKind]::Comment) { 8 }
            elseif (($token.TokenFlags -band [Management.Automation.Language.TokenFlags]::CommandName) -ne 0) { 12 }
            else { 15 }
        $spans.Add([pscustomobject]@{ Start = $token.Extent.StartOffset; End = $token.Extent.EndOffset; Foreground = $foreground })
    }
    $result = $spans.ToArray()
    if ($global:TerminalSyntaxCache.Count -gt 128) { $global:TerminalSyntaxCache.Clear() }
    $global:TerminalSyntaxCache[$Text] = $result
    return $result
}

function global:Add-TouchCell([int] $X, [int] $Y) {
    if ($X -lt 0 -or $X -ge $script:Columns -or $Y -lt 1 -or $Y -ge $script:Rows) { return }
    $cell = $Y * $script:Columns + $X
    if ($cell -eq $script:LastTouchCell) { return }
    $script:LastTouchCell = $cell
    $script:TouchX.Add($X)
    $script:TouchY.Add($Y)
    $script:TouchAt.Add([Environment]::TickCount64)
    $script:Dirty = $true
}

function global:Put-Text([uint32[]] $Cells, [int] $Columns, [int] $Rows, [int] $X, [int] $Y,
                  [string] $Text, [int] $Foreground, [int] $Background) {
    if ($Y -lt 0 -or $Y -ge $Rows) { return }
    for ($i = 0; $i -lt $Text.Length -and ($X + $i) -lt $Columns; $i++) {
        if (($X + $i) -ge 0) {
            $Cells[$Y * $Columns + $X + $i] = [uint32](($Background -shl 24) -bor ($Foreground -shl 16) -bor [int]$Text[$i])
        }
    }
}

function global:Get-ReflowedTerminalRows([int] $Width) {
    if ($global:TerminalReflowWidth -eq $Width -and
        $global:TerminalReflowVersion -eq $global:TerminalTranscriptVersion) {
        return $global:TerminalReflowRows
    }
    $result = [Collections.Generic.List[object]]::new()
    $usable = [Math]::Max(1, $Width)
    foreach ($entry in $global:TerminalTranscript) {
        $text = [string]$entry.Text
        if ($text.Length -eq 0) {
            $result.Add([pscustomobject]@{ Text = ''; Foreground = $entry.Foreground })
            continue
        }
        for ($at = 0; $at -lt $text.Length; $at += $usable) {
            $take = [Math]::Min($usable, $text.Length - $at)
            $result.Add([pscustomobject]@{ Text = $text.Substring($at, $take); Foreground = $entry.Foreground })
        }
    }
    $global:TerminalReflowWidth = $Width
    $global:TerminalReflowVersion = $global:TerminalTranscriptVersion
    $global:TerminalReflowRows = $result.ToArray()
    return $global:TerminalReflowRows
}

function global:Put-PowerShellText([uint32[]] $Cells, [int] $Columns, [int] $Rows,
                                   [int] $X, [int] $Y, [string] $Text) {
    $spans = @(Get-PowerShellTokenSpans $Text)
    for ($i = 0; $i -lt $Text.Length -and ($X + $i) -lt $Columns; $i++) {
        $foreground = 15
        foreach ($span in $spans) {
            if ($i -ge $span.Start -and $i -lt $span.End) {
                $foreground = $span.Foreground
                break
            }
        }
        Put-Text $Cells $Columns $Rows ($X + $i) $Y ([string]$Text[$i]) $foreground 0
    }
}

function global:Build-Cells([int] $ViewWidth, [int] $ViewHeight) {
    Complete-TerminalCommand
    $cellWidth = 9 * $script:Scale
    $cellHeight = 18 * $script:Scale
    $columns = [Math]::Clamp([int][Math]::Floor($ViewWidth / $cellWidth), 20, 512)
    $rows = [Math]::Clamp([int][Math]::Floor($ViewHeight / $cellHeight), 8, 512)
    while (($columns * $rows) -gt 262144) { $rows-- }
    $shape = $columns -ne $script:Columns -or $rows -ne $script:Rows
    if ($shape) {
        $script:Columns = $columns
        $script:Rows = $rows
        $script:Cells = [uint32[]]::new($columns * $rows)
    }
    else { [Array]::Clear($script:Cells, 0, $script:Cells.Length) }

    $cells = $script:Cells

    # Fluent-style tab strip. Blue is both selection and remote-focus state.
    $toolbarX = 0
    for ($buttonIndex = 0; $buttonIndex -lt $labels.Count; $buttonIndex++) {
        $button = $labels[$buttonIndex]
        $focused = $buttonIndex -eq $global:CanvasSelectedModeIndex
        Put-Text $cells $columns $rows $toolbarX 0 $button.Text 15 $(if ($focused) { 4 } else { 8 })
        $toolbarX += $button.Text.Length
    }
    if ($toolbarX -lt $columns) {
        Put-Text $cells $columns $rows $toolbarX 0 (' ' * ($columns - $toolbarX)) 7 8
    }

    if ($script:Mode -eq [TerminalPage]::Terminal) {
        $contentTop = 2
        $contentBottom = $rows - 4
        $visibleCount = [Math]::Max(1, $contentBottom - $contentTop + 1)
        $reflowed = @(Get-ReflowedTerminalRows $columns)
        $end = [Math]::Max(0, $reflowed.Count - $global:TerminalScroll)
        $begin = [Math]::Max(0, $end - $visibleCount)
        $screenY = $contentTop
        for ($lineIndex = $begin; $lineIndex -lt $end -and $screenY -le $contentBottom; $lineIndex++) {
            $line = $reflowed[$lineIndex]
            Put-Text $cells $columns $rows 0 $screenY $line.Text $line.Foreground 0
            $screenY++
        }

        $busy = if ($null -ne $global:TerminalAsync) { ' RUNNING ' } else { ' READY ' }
        $quick = $global:TerminalQuickCommands[$global:TerminalQuickIndex]
        $statusText = $busy + ' D-pad up/down: command   OK: run '
        $statusColor = if ($null -ne $global:TerminalAsync) { 11 } else { 10 }
        Put-Text $cells $columns $rows 0 ($rows - 3) $statusText $statusColor 8
        Put-Text $cells $columns $rows 0 ($rows - 2) ('> ' + $quick) 12 0

        Put-Text $cells $columns $rows 0 ($rows - 1) 'PS> ' 14 0
        Put-PowerShellText $cells $columns $rows 4 ($rows - 1) $global:TerminalInput
        $cursorX = [Math]::Min($columns - 1, 4 + $global:TerminalInputCursor)
        if (([Environment]::TickCount64 % 1000) -lt 500) {
            $cursorChar = if ($global:TerminalInputCursor -lt $global:TerminalInput.Length) {
                [string]$global:TerminalInput[$global:TerminalInputCursor]
            } else { ' ' }
            Put-Text $cells $columns $rows $cursorX ($rows - 1) $cursorChar 15 4
        }
    }
    elseif ($script:Mode -eq [TerminalPage]::Editor) {
        Put-Text $cells $columns $rows 0 2 'UNTITLED.PS1  -  shared terminal/editor cell surface' 15 8
        $editorLines = [regex]::Split($global:TerminalEditorText, '\r?\n')
        for ($lineIndex = 0; $lineIndex -lt $editorLines.Count -and ($lineIndex + 4) -lt $rows; $lineIndex++) {
            $lineNumber = '{0,4} ' -f ($lineIndex + 1)
            Put-Text $cells $columns $rows 0 ($lineIndex + 4) $lineNumber 8 0
            Put-PowerShellText $cells $columns $rows 5 ($lineIndex + 4) $editorLines[$lineIndex]
        }
        Put-Text $cells $columns $rows 0 ($rows - 1) 'SMA parser highlighting | shared cells, selection, IME and themes' 10 0
    }
    else {
        Put-Text $cells $columns $rows 2 2 'Settings' 15 0
        Put-Text $cells $columns $rows 2 3 'Appearance and interaction' 8 0
        $settings = @(
            @{ Name = 'Text scale'; Value = ('{0}x' -f $script:Scale) },
            @{ Name = 'Color scheme'; Value = 'Campbell / Fluent dark' },
            @{ Name = 'Cursor'; Value = 'Blinking block' },
            @{ Name = 'Reflow on resize'; Value = 'On' },
            @{ Name = 'PowerShell syntax highlighting'; Value = 'On' },
            @{ Name = 'Remote navigation'; Value = 'Left/right tabs, up/down rows, OK activate' }
        )
        for ($settingIndex = 0; $settingIndex -lt $settings.Count; $settingIndex++) {
            $selected = $settingIndex -eq $global:TerminalSettingsIndex
            $line = '  {0,-36} {1}' -f $settings[$settingIndex].Name, $settings[$settingIndex].Value
            if ($line.Length -lt $columns - 4) { $line += ' ' * ($columns - 4 - $line.Length) }
            Put-Text $cells $columns $rows 2 (5 + 2 * $settingIndex) $line 15 $(if ($selected) { 4 } else { 8 })
        }
        Put-Text $cells $columns $rows 2 ($rows - 2) 'Built in PowerShell. Presented by Android GPU canvas. No WebView.' 10 0
    }

    if ($script:LastFps -gt 0 -and $columns -gt 42) {
        $telemetry = '{0}x{1} {2:0}fps {3:0.0}ms ' -f $columns, $rows, $script:LastFps, $script:LastBuild
        Put-Text $cells $columns $rows ([Math]::Max(0, $columns - $telemetry.Length)) 0 $telemetry 7 8
    }
    return $shape
}

$script:CanvasPalette = [int[]]@(
    [Android.Graphics.Color]::Rgb(9, 12, 18).ToArgb(),
    [Android.Graphics.Color]::Rgb(205, 49, 49).ToArgb(),
    [Android.Graphics.Color]::Rgb(13, 188, 121).ToArgb(),
    [Android.Graphics.Color]::Rgb(229, 229, 16).ToArgb(),
    [Android.Graphics.Color]::Rgb(36, 114, 200).ToArgb(),
    [Android.Graphics.Color]::Rgb(188, 63, 188).ToArgb(),
    [Android.Graphics.Color]::Rgb(17, 168, 205).ToArgb(),
    [Android.Graphics.Color]::Rgb(229, 229, 229).ToArgb(),
    [Android.Graphics.Color]::Rgb(102, 102, 102).ToArgb(),
    [Android.Graphics.Color]::Rgb(241, 76, 76).ToArgb(),
    [Android.Graphics.Color]::Rgb(35, 209, 139).ToArgb(),
    [Android.Graphics.Color]::Rgb(245, 245, 67).ToArgb(),
    [Android.Graphics.Color]::Rgb(59, 142, 234).ToArgb(),
    [Android.Graphics.Color]::Rgb(214, 112, 214).ToArgb(),
    [Android.Graphics.Color]::Rgb(41, 184, 219).ToArgb(),
    [Android.Graphics.Color]::Rgb(255, 255, 255).ToArgb()
)

function global:Get-AndroidCanvasBounds {
    [Android.Views.SurfaceView] $surface = $script:AndroidCanvasEdge.Surface
    if ($null -eq $surface -or $surface.Width -le 0 -or $surface.Height -le 0) { return $null }

    $left = 0; $top = 0; $right = 0; $bottom = 0
    [Android.Views.WindowInsets] $windowInsets = $surface.RootWindowInsets
    if ($null -ne $windowInsets) {
        [Android.Graphics.Insets] $bars = $windowInsets.GetInsets([Android.Views.WindowInsets+Type]::SystemBars())
        $left = $bars.Left; $top = $bars.Top; $right = $bars.Right; $bottom = $bars.Bottom
        [Android.Views.DisplayCutout] $cutout = $windowInsets.DisplayCutout
        if ($null -ne $cutout) {
            $left = [Math]::Max($left, $cutout.SafeInsetLeft)
            $top = [Math]::Max($top, $cutout.SafeInsetTop)
            $right = [Math]::Max($right, $cutout.SafeInsetRight)
            $bottom = [Math]::Max($bottom, $cutout.SafeInsetBottom)
        }
    }

    [pscustomobject]@{
        Left = $left
        Top = $top
        Right = $right
        Bottom = $bottom
        Width = [Math]::Max(1, $surface.Width - $left - $right)
        Height = [Math]::Max(1, $surface.Height - $top - $bottom)
        SurfaceWidth = $surface.Width
        SurfaceHeight = $surface.Height
    }
}

function global:Present-CellsWithCanvasCalls {
    param([Parameter(Mandatory)] $Bounds)

    [Android.Views.SurfaceView] $surface = $script:AndroidCanvasEdge.Surface
    if ($null -eq $surface -or -not $surface.Holder.Surface.IsValid) { return $false }
    [Android.Graphics.Canvas] $canvas = $null
    try {
        $canvas = $surface.Holder.LockHardwareCanvas()
        if ($null -eq $canvas) { return $false }
        [Android.Graphics.Paint] $paint = $script:AndroidCanvasEdge.Paint
        $canvas.DrawColor([Android.Graphics.Color]::Rgb(9, 12, 18))

        [double] $cellWidth = $Bounds.Width / [double]$script:Columns
        [double] $cellHeight = $Bounds.Height / [double]$script:Rows
        $paint.TextSize = [single]($cellHeight * 0.78)
        [Android.Graphics.Paint+FontMetrics] $font = $paint.FontMetrics
        [single] $baselineOffset = [single](($cellHeight - ($font.Descent - $font.Ascent)) / 2.0 - $font.Ascent)

        for ($y = 0; $y -lt $script:Rows; $y++) {
            $x = 0
            while ($x -lt $script:Columns) {
                [uint32] $packed = $script:Cells[$y * $script:Columns + $x]
                $foreground = ($packed -shr 16) -band 0xff
                $background = ($packed -shr 24) -band 0xff
                $start = $x
                [Text.StringBuilder] $text = [Text.StringBuilder]::new()
                while ($x -lt $script:Columns) {
                    $packed = $script:Cells[$y * $script:Columns + $x]
                    if ((($packed -shr 16) -band 0xff) -ne $foreground -or
                        (($packed -shr 24) -band 0xff) -ne $background) { break }
                    $codepoint = $packed -band 0xffff
                    [void]$text.Append($(if ($codepoint) { [char]$codepoint } else { ' ' }))
                    $x++
                }

                [single] $left = [single]($Bounds.Left + $start * $cellWidth)
                [single] $top = [single]($Bounds.Top + $y * $cellHeight)
                if ($background -ne 0) {
                    $paint.Color = [Android.Graphics.Color]::new($script:CanvasPalette[$background -band 15])
                    $canvas.DrawRect($left, $top,
                        [single]($left + $text.Length * $cellWidth), [single]($top + $cellHeight), $paint)
                }
                if ($text.ToString().Trim().Length) {
                    $paint.Color = [Android.Graphics.Color]::new($script:CanvasPalette[$foreground -band 15])
                    $canvas.DrawText($text.ToString(), $left, [single]($top + $baselineOffset), $paint)
                }
            }
        }
        return $canvas.IsHardwareAccelerated
    }
    catch {
        [Android.Util.Log]::Error('PowerShell', "Canvas presentation failed: $_")
        return $false
    }
    finally {
        if ($null -ne $canvas) { $surface.Holder.UnlockCanvasAndPost($canvas) }
    }
}

function global:Initialize-AndroidPackedPresenter {
    param([Parameter(Mandatory)] $Bounds)

    $edge = $script:AndroidCanvasEdge
    $cellWidth = [int][Math]::Ceiling($Bounds.Width / [double]$script:Columns)
    $cellHeight = [int][Math]::Ceiling($Bounds.Height / [double]$script:Rows)
    $shape = "$($script:Columns)x$($script:Rows):${cellWidth}x${cellHeight}"
    if ($edge.PackedShape -eq $shape -and $null -ne $edge.PackedShader) { return }

    if ($null -ne $edge.PackedBitmap) { $edge.PackedBitmap.Dispose() }
    if ($null -ne $edge.GlyphBitmap) { $edge.GlyphBitmap.Dispose() }
    if ($null -ne $edge.PaletteBitmap) { $edge.PaletteBitmap.Dispose() }
    if ($null -ne $edge.PackedPaint) { $edge.PackedPaint.Dispose() }

    $packedBytes = [byte[]]::new($script:Columns * $script:Rows * 4)
    [Java.Nio.ByteBuffer] $packedBuffer = [Java.Nio.ByteBuffer]::AllocateDirect($packedBytes.Length)
    [Android.Graphics.Bitmap] $packedBitmap = [Android.Graphics.Bitmap]::CreateBitmap(
        $script:Columns, $script:Rows, [Android.Graphics.Bitmap+Config]::Argb8888)
    [Android.Graphics.BitmapShader] $packedInput = [Android.Graphics.BitmapShader]::new(
        $packedBitmap,
        [Android.Graphics.Shader+TileMode]::Clamp,
        [Android.Graphics.Shader+TileMode]::Clamp)
    $packedInput.FilterMode = [int][Android.Graphics.BitmapShaderFilterMode]::Nearest

    [Android.Graphics.Bitmap] $glyphBitmap = [Android.Graphics.Bitmap]::CreateBitmap(
        16 * $cellWidth, 8 * $cellHeight, [Android.Graphics.Bitmap+Config]::Argb8888)
    [Android.Graphics.Canvas] $glyphCanvas = [Android.Graphics.Canvas]::new($glyphBitmap)
    [Android.Graphics.Paint] $glyphPaint = [Android.Graphics.Paint]::new()
    $glyphPaint.AntiAlias = $true
    $glyphPaint.Color = [Android.Graphics.Color]::White
    $glyphPaint.TextSize = [single]($cellHeight * 0.78)
    [void]$glyphPaint.SetTypeface([Android.Graphics.Typeface]::Monospace)
    [Android.Graphics.Rect] $glyphBounds = [Android.Graphics.Rect]::new()
    for ($codepoint = 33; $codepoint -lt 127; $codepoint++) {
        $tileX = $codepoint % 16
        $tileY = [int][Math]::Floor($codepoint / 16)
        $glyphText = [string][char]$codepoint
        $glyphBounds.SetEmpty()
        $glyphPaint.GetTextBounds($glyphText, 0, 1, $glyphBounds)
        [single] $glyphX = [single](
            $tileX * $cellWidth + ($cellWidth - $glyphBounds.Width()) / 2.0 - $glyphBounds.Left)
        [single] $glyphY = [single](
            $tileY * $cellHeight + ($cellHeight - $glyphBounds.Height()) / 2.0 - $glyphBounds.Top)
        $glyphCanvas.DrawText(
            $glyphText,
            $glyphX,
            $glyphY,
            $glyphPaint)
    }
    $glyphCanvas.Dispose()
    $glyphPaint.Dispose()

    [Android.Graphics.BitmapShader] $glyphInput = [Android.Graphics.BitmapShader]::new(
        $glyphBitmap,
        [Android.Graphics.Shader+TileMode]::Clamp,
        [Android.Graphics.Shader+TileMode]::Clamp)
    $glyphInput.FilterMode = [int][Android.Graphics.BitmapShaderFilterMode]::Nearest

    [Android.Graphics.Bitmap] $paletteBitmap = [Android.Graphics.Bitmap]::CreateBitmap(
        16, 1, [Android.Graphics.Bitmap+Config]::Argb8888)
    $paletteBitmap.SetPixels($script:CanvasPalette, 0, 16, 0, 0, 16, 1)
    [Android.Graphics.BitmapShader] $paletteInput = [Android.Graphics.BitmapShader]::new(
        $paletteBitmap,
        [Android.Graphics.Shader+TileMode]::Clamp,
        [Android.Graphics.Shader+TileMode]::Clamp)
    $paletteInput.FilterMode = [int][Android.Graphics.BitmapShaderFilterMode]::Nearest

    $program = @'
uniform shader packedCells;
uniform shader glyphAtlas;
uniform shader colors;
uniform float2 origin;
uniform float2 contentSize;
uniform float2 cellSize;
uniform float2 glyphCellSize;
uniform int2 gridSize;

half4 main(float2 p) {
    float2 q = p - origin;
    if (q.x < 0.0 || q.y < 0.0 || q.x >= contentSize.x || q.y >= contentSize.y) {
        return colors.eval(float2(0.5, 0.5));
    }

    int2 cellAt = int2(floor(q / cellSize));
    half4 cellValue = packedCells.eval(float2(cellAt) + float2(0.5));

    int codepointLow = int(floor(float(cellValue.r) * 255.0 + 0.5));
    int codepointHigh = int(floor(float(cellValue.g) * 255.0 + 0.5));
    int foreground = int(floor(float(cellValue.b) * 255.0 + 0.5));
    int background = int(floor(float(cellValue.a) * 255.0 + 0.5));
    int codepoint = codepointLow + codepointHigh * 256;

    half4 backgroundColor = colors.eval(float2(float(background) + 0.5, 0.5));
    if (codepoint <= 32 || codepoint >= 127) {
        return backgroundColor;
    }

    float2 withinCell = q - floor(q / cellSize) * cellSize;
    int tileY = codepoint / 16;
    int tileX = codepoint - tileY * 16;
    float2 tile = float2(float(tileX), float(tileY));
    float2 glyphAt = tile * glyphCellSize + (withinCell / cellSize) * glyphCellSize;
    half glyphCoverage = glyphAtlas.eval(glyphAt).a;
    half4 foregroundColor = colors.eval(float2(float(foreground) + 0.5, 0.5));
    return mix(backgroundColor, foregroundColor, glyphCoverage);
}
'@

    [Android.Graphics.RuntimeShader] $runtimeShader = [Android.Graphics.RuntimeShader]::new($program)
    $runtimeShader.SetInputBuffer('packedCells', $packedInput)
    $runtimeShader.SetInputShader('glyphAtlas', $glyphInput)
    $runtimeShader.SetInputShader('colors', $paletteInput)

    [Android.Graphics.Paint] $packedPaint = [Android.Graphics.Paint]::new()
    $packedPaint.AntiAlias = $false
    [void]$packedPaint.SetShader($runtimeShader)

    $edge.PackedBytes = $packedBytes
    $edge.PackedBuffer = $packedBuffer
    $edge.PackedBitmap = $packedBitmap
    $edge.PackedInput = $packedInput
    $edge.GlyphBitmap = $glyphBitmap
    $edge.GlyphInput = $glyphInput
    $edge.PaletteBitmap = $paletteBitmap
    $edge.PaletteInput = $paletteInput
    $edge.PackedShader = $runtimeShader
    $edge.PackedPaint = $packedPaint
    $edge.GlyphCellWidth = $cellWidth
    $edge.GlyphCellHeight = $cellHeight
    $edge.PackedShape = $shape
    [Android.Util.Log]::Info('PowerShell',
        "Canvas packed presenter READY cells=$($script:Columns)x$($script:Rows) atlas=$($glyphBitmap.Width)x$($glyphBitmap.Height)")
}

function global:Present-CellsWithPackedShader {
    param([Parameter(Mandatory)] $Bounds)

    [Android.Views.SurfaceView] $surface = $script:AndroidCanvasEdge.Surface
    if ($null -eq $surface -or -not $surface.Holder.Surface.IsValid) { return $false }
    $edge = $script:AndroidCanvasEdge
    [Android.Graphics.Canvas] $canvas = $null

    Initialize-AndroidPackedPresenter $Bounds

    $uploadAt = [Stopwatch]::GetTimestamp()
    [Buffer]::BlockCopy($script:Cells, 0, $edge.PackedBytes, 0, $edge.PackedBytes.Length)
    [void]$edge.PackedBuffer.Clear()
    [void]$edge.PackedBuffer.Put($edge.PackedBytes)
    [void]$edge.PackedBuffer.Rewind()
    $edge.PackedBitmap.CopyPixelsFromBuffer($edge.PackedBuffer)
    $uploadedAt = [Stopwatch]::GetTimestamp()

    if (-not $edge.PackedProbeLogged) {
        [Android.Graphics.Color] $cell0 = $edge.PackedBitmap.GetPixel(0, 0)
        [Android.Graphics.Color] $cell1 = $edge.PackedBitmap.GetPixel(1, 0)
        $atlasInk = 0
        $probeCodepoint = 65
        $probeTileX = $probeCodepoint % 16
        $probeTileY = [int][Math]::Floor($probeCodepoint / 16)
        for ($probeY = 0; $probeY -lt $edge.GlyphCellHeight; $probeY++) {
            for ($probeX = 0; $probeX -lt $edge.GlyphCellWidth; $probeX++) {
                [Android.Graphics.Color] $atlasPixel = $edge.GlyphBitmap.GetPixel(
                    $probeTileX * $edge.GlyphCellWidth + $probeX,
                    $probeTileY * $edge.GlyphCellHeight + $probeY)
                if ($atlasPixel.A -gt 0) { $atlasInk++ }
            }
        }
        [Android.Util.Log]::Info('PowerShell',
            "Canvas packed probe c0=$($cell0.R),$($cell0.G),$($cell0.B),$($cell0.A) c1=$($cell1.R),$($cell1.G),$($cell1.B),$($cell1.A) atlasA=$atlasInk")
        $edge.PackedProbeLogged = $true
    }

    $edge.PackedShader.SetFloatUniform('origin', [single]$Bounds.Left, [single]$Bounds.Top)
    $edge.PackedShader.SetFloatUniform('contentSize', [single]$Bounds.Width, [single]$Bounds.Height)
    $edge.PackedShader.SetFloatUniform(
        'cellSize',
        [single]($Bounds.Width / [double]$script:Columns),
        [single]($Bounds.Height / [double]$script:Rows))
    $edge.PackedShader.SetFloatUniform(
        'glyphCellSize',
        [single]$edge.GlyphCellWidth,
        [single]$edge.GlyphCellHeight)
    $edge.PackedShader.SetIntUniform('gridSize', $script:Columns, $script:Rows)

    $submitAt = [Stopwatch]::GetTimestamp()
    $hardwareAccelerated = $false
    try {
        $canvas = $surface.Holder.LockHardwareCanvas()
        if ($null -eq $canvas) { return $false }
        $canvas.DrawPaint($edge.PackedPaint)
        $hardwareAccelerated = $canvas.IsHardwareAccelerated
    }
    finally {
        if ($null -ne $canvas) { $surface.Holder.UnlockCanvasAndPost($canvas) }
    }
    $submittedAt = [Stopwatch]::GetTimestamp()
    $edge.UploadTotal += 1000.0 * ($uploadedAt - $uploadAt) / $edge.Frequency
    $edge.SubmitTotal += 1000.0 * ($submittedAt - $submitAt) / $edge.Frequency
    return $hardwareAccelerated
}

function global:Present-Cells {
    param([Parameter(Mandatory)] $Bounds)

    if (-not $script:AndroidCanvasEdge.PackedPresenterFailed) {
        try {
            return Present-CellsWithPackedShader $Bounds
        }
        catch {
            $script:AndroidCanvasEdge.PackedPresenterFailed = $true
            [Android.Util.Log]::Error('PowerShell',
                "Canvas packed presenter failed; retaining checkpoint presenter: $_ stack=$($_.ScriptStackTrace)")
        }
    }
    return Present-CellsWithCanvasCalls $Bounds
}

function global:Invoke-AndroidCanvasInput {
    param([Parameter(Mandatory)][Android.Views.MotionEvent] $MotionEvent)

    $bounds = Get-AndroidCanvasBounds
    if ($null -eq $bounds) { return }
    $action = [int]$MotionEvent.ActionMasked
    $pointerCount = $MotionEvent.PointerCount
    $x = [single]$MotionEvent.GetX(0)
    $y = [single]$MotionEvent.GetY(0)

    if ($action -eq [int][Android.Views.MotionEventActions]::Down) {
        $identity = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($MotionEvent)
        [Android.Util.Log]::Info('PowerShell',
            "Canvas input type=$($MotionEvent.GetType().FullName) identity=$identity pointers=$pointerCount")
    }

    if ($pointerCount -ge 2) {
        $dx = $MotionEvent.GetX(1) - $x
        $dy = $MotionEvent.GetY(1) - $y
        $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)
        if ($script:AndroidCanvasEdge.LastPinchDistance -gt 0 -and
            $action -eq [int][Android.Views.MotionEventActions]::Move) {
            $nextScale = [int][Math]::Round($script:Scale * $distance / $script:AndroidCanvasEdge.LastPinchDistance)
            $script:Scale = [Math]::Clamp($nextScale, 1, 8)
            $script:Dirty = $true
        }
        $script:AndroidCanvasEdge.LastPinchDistance = $distance
        return
    }
    $script:AndroidCanvasEdge.LastPinchDistance = 0.0

    $columns = [Math]::Max(1, $script:Columns)
    $rows = [Math]::Max(2, $script:Rows)
    $cellX = [Math]::Clamp([int][Math]::Floor(($x - $bounds.Left) / [Math]::Max(1.0, $bounds.Width / $columns)), 0, $columns - 1)
    $cellY = [Math]::Clamp([int][Math]::Floor(($y - $bounds.Top) / [Math]::Max(1.0, $bounds.Height / $rows)), 0, $rows - 1)
    $leftDown = $action -in @(
        [int][Android.Views.MotionEventActions]::Down,
        [int][Android.Views.MotionEventActions]::Move)

    if ($leftDown -and -not $script:AndroidCanvasEdge.PreviousLeft -and $cellY -eq 0) {
        $hitX = 0
        for ($buttonIndex = 0; $buttonIndex -lt $labels.Count; $buttonIndex++) {
            $button = $labels[$buttonIndex]
            if ($cellX -ge $hitX -and $cellX -lt ($hitX + $button.Text.Length)) {
                $global:CanvasSelectedModeIndex = $buttonIndex
                Set-Mode $button.Mode
                break
            }
            $hitX += $button.Text.Length
        }
    }
    elseif ($leftDown -and -not $script:AndroidCanvasEdge.PreviousLeft -and
            $labels[$global:CanvasSelectedModeIndex].Mode -eq [TerminalPage]::Terminal -and $cellY -eq ($rows - 2)) {
        $global:TerminalInput = $global:TerminalQuickCommands[$global:TerminalQuickIndex]
        $global:TerminalInputCursor = $global:TerminalInput.Length
        $script:Dirty = $true
    }
    if (-not $leftDown) { $script:LastTouchCell = -1 }
    $script:AndroidCanvasEdge.PreviousLeft = $leftDown
    $script:AndroidCanvasEdge.PreviousX = $x
    $script:AndroidCanvasEdge.PreviousY = $y
}

function global:Invoke-AndroidCanvasFrame {
    $edge = $script:AndroidCanvasEdge
    $nowTicks = [Stopwatch]::GetTimestamp()
    $cursorPhase = [int]([Environment]::TickCount64 / 500) -band 1
    if ($script:CursorPhase -ne $cursorPhase) {
        $script:CursorPhase = $cursorPhase
        if ($script:Mode -eq [TerminalPage]::Terminal) { $script:Dirty = $true }
    }
    $live = $script:Dirty -or ($null -ne $global:TerminalAsync)
    if (-not $live) { return }

    $bounds = Get-AndroidCanvasBounds
    if ($null -eq $bounds) { return }
    $boundsKey = "$($bounds.SurfaceWidth)x$($bounds.SurfaceHeight):$($bounds.Left),$($bounds.Top),$($bounds.Right),$($bounds.Bottom)"
    if ($boundsKey -ne $edge.BoundsKey) {
        $edge.BoundsKey = $boundsKey
        $script:Dirty = $true
        [Android.Util.Log]::Info('PowerShell', "Canvas bounds=$boundsKey content=$($bounds.Width)x$($bounds.Height)")
    }

    if (-not $edge.FrameRateRequested -and $edge.Surface.Holder.Surface.IsValid) {
        $edge.Surface.Holder.Surface.SetFrameRate(
            [single]120.0,
            [int][Android.Views.SurfaceFrameRateCompatibility]::FixedSource,
            [int][Android.Views.SurfaceChangeFrameRate]::Always)
        $edge.FrameRateRequested = $true
        [Android.Util.Log]::Info('PowerShell', 'Canvas surface requested 120fps')
    }

    $buildAt = $nowTicks
    $shape = Build-Cells $bounds.Width $bounds.Height
    $cellsBuiltAt = [Stopwatch]::GetTimestamp()
    $submitted = Present-Cells $bounds
    $builtAt = [Stopwatch]::GetTimestamp()
    if ($submitted) {
        if (-not $script:Ready) {
            [Android.Util.Log]::Info('PowerShell', 'Canvas READY')
            $script:Ready = $true
        }
        if ($shape) {
            [Android.Util.Log]::Info('PowerShell', "Canvas RESIZE $($script:Columns)x$($script:Rows)")
        }
        $script:Frame++
        $script:Dirty = $false
        $edge.SampleFrames++
        $edge.CellBuildTotal += 1000.0 * ($cellsBuiltAt - $buildAt) / $edge.Frequency
        $edge.BuildTotal += 1000.0 * ($builtAt - $buildAt) / $edge.Frequency
        if ($null -ne $edge.HintSession) {
            $actualNanos = [long](1000000000.0 * ($builtAt - $buildAt) / $edge.Frequency)
            $edge.HintSession.ReportActualWorkDuration([Math]::Max([long]1, $actualNanos))
        }
    }
    else { $script:LastDropped++ }

    if (($builtAt - $edge.SampleAt) -ge $edge.Frequency) {
        $elapsed = ($builtAt - $edge.SampleAt) / $edge.Frequency
        $script:LastFps = $edge.SampleFrames / $elapsed
        $script:LastBuild = $edge.BuildTotal / [Math]::Max(1, $edge.SampleFrames)
        if ($script:EmitSample) {
            [Android.Util.Log]::Info('PowerShell',
                ('Canvas FPS={0:0} CELL={1:0.00}ms UP={2:0.00}ms SUBMIT={3:0.00}ms TOTAL={4:0.00}ms D{5}' -f
                    $script:LastFps,
                    ($edge.CellBuildTotal / [Math]::Max(1, $edge.SampleFrames)),
                    ($edge.UploadTotal / [Math]::Max(1, $edge.SampleFrames)),
                    ($edge.SubmitTotal / [Math]::Max(1, $edge.SampleFrames)),
                    $script:LastBuild,
                    $script:LastDropped))
            $script:EmitSample = $false
        }
        $edge.SampleAt = $builtAt
        $edge.SampleFrames = 0
        $edge.CellBuildTotal = 0.0
        $edge.UploadTotal = 0.0
        $edge.SubmitTotal = 0.0
        $edge.BuildTotal = 0.0
    }
}

$activity = $Activity
if ($null -eq $activity) {
    throw 'CanvasDemo.ps1 requires Terminal to provide $Activity, or an Activity passed with -Activity.'
}
$generation = [Guid]::NewGuid()
$frequency = [double][Stopwatch]::Frequency
if ($null -ne $script:AndroidCanvasEdge) {
    $script:AndroidCanvasEdge.Active = $false
    if ($null -ne $script:AndroidCanvasEdge.HintSession) {
        $script:AndroidCanvasEdge.HintSession.Close()
    }
}
[Android.Graphics.Paint] $paint = [Android.Graphics.Paint]::new()
$paint.AntiAlias = $true
[void]$paint.SetTypeface([Android.Graphics.Typeface]::Monospace)
$edge = [pscustomobject]@{
    Activity = $activity
    Surface = $null
    Paint = $paint
    Generation = $generation
    Active = $true
    Tick = $null
    Touch = $null
    KeyPress = $null
    HintManager = $null
    HintSession = $null
    TargetNanos = [long]8333333
    FrameRateRequested = $false
    PackedPresenterFailed = $false
    PackedProbeLogged = $false
    PackedShape = ''
    PackedBytes = $null
    PackedBuffer = $null
    PackedBitmap = $null
    PackedInput = $null
    GlyphBitmap = $null
    GlyphInput = $null
    PaletteBitmap = $null
    PaletteInput = $null
    PackedShader = $null
    PackedPaint = $null
    GlyphCellWidth = 0
    GlyphCellHeight = 0
    Frequency = $frequency
    SampleAt = [Stopwatch]::GetTimestamp()
    SampleFrames = 0
    CellBuildTotal = 0.0
    UploadTotal = 0.0
    SubmitTotal = 0.0
    BuildTotal = 0.0
    BoundsKey = ''
    PreviousLeft = $false
    PreviousX = 0.0
    PreviousY = 0.0
    LastPinchDistance = 0.0
}
$script:AndroidCanvasEdge = $edge
$script:Dirty = $true

[scriptblock] $touch = {
    param($sender, $eventArgs)
    try {
        [Android.Views.MotionEvent] $motionEvent = $eventArgs.Event
        Invoke-AndroidCanvasInput $motionEvent
        $eventArgs.Handled = $true
    }
    catch {
        [Android.Util.Log]::Error('PowerShell',
            "Canvas touch failed: $_ stack=$($_.ScriptStackTrace)")
    }
}.GetNewClosure()
$edge.Touch = $touch

[scriptblock] $keyPress = {
    param($sender, $eventArgs)
    try {
      if ($eventArgs.Event.Action -ne [Android.Views.KeyEventActions]::Down) { return }
      $keyCode = $eventArgs.KeyCode
      $lastIndex = $labels.Count - 1
      if ($keyCode -eq [Android.Views.Keycode]::DpadLeft) {
        $global:CanvasSelectedModeIndex = if ($global:CanvasSelectedModeIndex -le 0) { $lastIndex } else { $global:CanvasSelectedModeIndex - 1 }
        Set-Mode $labels[$global:CanvasSelectedModeIndex].Mode
    }
    elseif ($keyCode -eq [Android.Views.Keycode]::DpadRight) {
        $global:CanvasSelectedModeIndex = if ($global:CanvasSelectedModeIndex -ge $lastIndex) { 0 } else { $global:CanvasSelectedModeIndex + 1 }
        Set-Mode $labels[$global:CanvasSelectedModeIndex].Mode
    }
    elseif ($keyCode -eq [Android.Views.Keycode]::DpadUp) {
        $activeMode = $labels[$global:CanvasSelectedModeIndex].Mode
        if ($activeMode -eq [TerminalPage]::Terminal) {
            $global:TerminalQuickIndex = if ($global:TerminalQuickIndex -le 0) { $global:TerminalQuickCommands.Count - 1 } else { $global:TerminalQuickIndex - 1 }
        }
        elseif ($activeMode -eq [TerminalPage]::Settings) {
            $global:TerminalSettingsIndex = [Math]::Max(0, $global:TerminalSettingsIndex - 1)
        }
    }
    elseif ($keyCode -eq [Android.Views.Keycode]::DpadDown) {
        $activeMode = $labels[$global:CanvasSelectedModeIndex].Mode
        if ($activeMode -eq [TerminalPage]::Terminal) {
            $global:TerminalQuickIndex = ($global:TerminalQuickIndex + 1) % $global:TerminalQuickCommands.Count
        }
        elseif ($activeMode -eq [TerminalPage]::Settings) {
            $global:TerminalSettingsIndex = [Math]::Min(5, $global:TerminalSettingsIndex + 1)
        }
    }
    elseif ($keyCode -in @([Android.Views.Keycode]::DpadCenter, [Android.Views.Keycode]::Enter)) {
        $activeMode = $labels[$global:CanvasSelectedModeIndex].Mode
        [Android.Util.Log]::Info('PowerShell', "Terminal activate page=$activeMode input='$global:TerminalInput'")
        if ($activeMode -eq [TerminalPage]::Terminal) {
            if ([string]::IsNullOrEmpty($global:TerminalInput)) {
                $global:TerminalInput = $global:TerminalQuickCommands[$global:TerminalQuickIndex]
                $global:TerminalInputCursor = $global:TerminalInput.Length
            }
            Start-TerminalCommand
        }
        elseif ($activeMode -eq [TerminalPage]::Settings -and $global:TerminalSettingsIndex -eq 0) {
            Cycle-TerminalTextScale
        }
    }
    elseif ($keyCode -eq [Android.Views.Keycode]::Del -and $global:TerminalInputCursor -gt 0) {
        $global:TerminalInput = $global:TerminalInput.Remove($global:TerminalInputCursor - 1, 1)
        $global:TerminalInputCursor--
    }
    else {
        $unicode = [int]$eventArgs.Event.UnicodeChar
        if ($labels[$global:CanvasSelectedModeIndex].Mode -ne [TerminalPage]::Terminal -or $unicode -lt 32) { return }
        $character = [char]$unicode
        $global:TerminalInput = $global:TerminalInput.Insert($global:TerminalInputCursor, [string]$character)
        $global:TerminalInputCursor++
    }
    Request-TerminalRefresh
    $eventArgs.Handled = $true
      [Android.Util.Log]::Info('PowerShell',
          "Canvas remote key=$keyCode mode=$($labels[$global:CanvasSelectedModeIndex].Text.Trim())")
    }
    catch {
        [Android.Util.Log]::Error('PowerShell', "Terminal key failed: $_ stack=$($_.ScriptStackTrace)")
    }
}.GetNewClosure()
$edge.KeyPress = $keyPress

[Action] $onAnimation = [Action]{
    try {
        if ($edge.Active -and $null -ne $edge.Surface -and $edge.Surface.IsAttachedToWindow) {
            $edge.Surface.PostOnAnimation($edge.Tick)
            Invoke-AndroidCanvasFrame
        }
    }
    catch {
        [Android.Util.Log]::Error('PowerShell',
            "Canvas tick failed: $_ stack=$($_.ScriptStackTrace)")
    }
}.GetNewClosure()
[Dev.MansfieldPlumbing.Terminal.RecoveryProgram]::SetAnimationCallback($onAnimation)
$callbackMethod = [Dev.MansfieldPlumbing.Terminal.RecoveryProgram].GetMethod(
    'RunAnimationCallback',
    [Reflection.BindingFlags]'Public,Static')
[Action] $animationCallback = $callbackMethod.CreateDelegate([Action])
$tick = [Java.Lang.Runnable]::new($animationCallback)
$edge.Tick = $tick

[Action] $attach = [Action]{
    [Android.Views.SurfaceView] $surface = [Android.Views.SurfaceView]::new($activity)
    $surface.KeepScreenOn = $true
    $surface.Focusable = $true
    $surface.FocusableInTouchMode = $true
    [single] $requestedFrameRate = 0
    if ([int][Android.OS.Build+VERSION]::SdkInt -ge 35) {
        $surface.RequestedFrameRate = [single]120.0
        $requestedFrameRate = $surface.RequestedFrameRate
    }
    $surface.add_Touch($touch)
    $surface.add_KeyPress($keyPress)
    $edge.Surface = $surface
    $activity.SetContentView($surface)
    [Android.Util.Log]::Info('PowerShell',
        "Canvas window touchBoost=$($activity.Window.FrameRateBoostOnTouchEnabled) requestedFrameRate=$requestedFrameRate")
    [void]$surface.RequestFocus()

    try {
        [Android.OS.PerformanceHintManager] $hintManager =
            $activity.GetSystemService([Android.Content.Context]::PerformanceHintService)
        if ($null -ne $hintManager) {
            $edge.HintManager = $hintManager
            $edge.HintSession = $hintManager.CreateHintSession(
                [int[]]@([Android.OS.Process]::MyTid()), $edge.TargetNanos)
            [Android.Util.Log]::Info('PowerShell',
                "Canvas performance hint tid=$([Android.OS.Process]::MyTid()) target=$($edge.TargetNanos)ns preferred=$($hintManager.PreferredUpdateRateNanos)ns")
        }
    }
    catch {
        [Android.Util.Log]::Warn('PowerShell',
            "Canvas performance hint unavailable: $_")
    }

    $surface.PostOnAnimation($tick)
    [Android.Util.Log]::Info('PowerShell',
        "Canvas attached view=$($surface.GetType().FullName) generation=$generation scheduler=PostOnAnimation")
}.GetNewClosure()

$activity.RunOnUiThread($attach)
