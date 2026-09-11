#requires -Version 7.0
using namespace System
using namespace System.Collections

param([Android.App.Activity] $Activity = $global:Activity)

# PowerShell authors retained Android objects once. Android owns focus, input,
# animation, composition, and every intermediate frame after this script returns.
if ($null -eq $Activity) { throw 'Profile.ps1 requires AndroidSMA to provide $Activity.' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Dp([single]$Value) {
    [int][Math]::Round($Value * [single]$Activity.Resources.DisplayMetrics.Density)
}

function New-TileBackground([Android.Graphics.Color]$Color) {
    $normal = [Android.Graphics.Drawables.GradientDrawable]::new()
    $normal.SetColor($Color)
    $normal.SetCornerRadius([single](ConvertTo-Dp 2))
    $focused = [Android.Graphics.Drawables.GradientDrawable]::new()
    $focused.SetColor($Color)
    $focused.SetCornerRadius([single](ConvertTo-Dp 2))
    $focused.SetStroke((ConvertTo-Dp 4), [Android.Graphics.Color]::White)
    $selector = [Android.Graphics.Drawables.StateListDrawable]::new()
    $selector.AddState([int[]]@([Android.Resource+Attribute]::StateFocused), $focused)
    $selector.AddState([int[]]@(), $normal)
    $selector
}

function Get-StableDelay([string]$Id) {
    [int]$hash = 17
    foreach ($character in $Id.ToCharArray()) {
        $hash = (($hash * 31) + [int]$character) -band 0x7fffffff
    }
    [long](1200 + ($hash % 6800))
}

function New-Face(
    [string]$Text,
    [single]$TextSize,
    [Android.Views.GravityFlags]$Gravity
) {
    $face = [Android.Widget.TextView]::new($Activity)
    $face.Text = $Text
    $face.SetTextColor([Android.Graphics.Color]::White)
    $face.SetTextSize([Android.Util.ComplexUnitType]::Sp, $TextSize)
    $face.Gravity = $Gravity
    $face.SetPadding((ConvertTo-Dp 12), (ConvertTo-Dp 10), (ConvertTo-Dp 12), (ConvertTo-Dp 10))
    $face.SetIncludeFontPadding($false)
    $face
}

function Start-NativeFlip(
    [Android.Views.View]$Card,
    [Android.Views.View]$Front,
    [Android.Views.View]$Back,
    [string]$Id
) {
    $duration = [long]850
    $delay = Get-StableDelay $Id
    $interpolator = [Android.Views.Animations.AccelerateDecelerateInterpolator]::new()
    $animators = @(
        [Android.Animation.ObjectAnimator]::OfFloat($Card, 'rotationY', [single[]]@(0.0, 180.0)),
        [Android.Animation.ObjectAnimator]::OfFloat($Front, 'alpha', [single[]]@(1.0, 1.0, 0.0, 0.0)),
        [Android.Animation.ObjectAnimator]::OfFloat($Back, 'alpha', [single[]]@(0.0, 0.0, 1.0, 1.0))
    )
    foreach ($animator in $animators) {
        [void]$animator.SetDuration($duration)
        $animator.StartDelay = $delay
        $animator.RepeatCount = [Android.Animation.ValueAnimator]::Infinite
        $animator.RepeatMode = [Android.Animation.ValueAnimatorRepeatMode]::Reverse
        $animator.SetInterpolator($interpolator)
        $animator.Start()
        [void]$script:StartNativeState.Animators.Add($animator)
    }
}

function New-RetainedTile($Descriptor, [int]$Cell, [int]$Gap) {
    $width = ($Cell * [int]$Descriptor.W) + ($Gap * ([int]$Descriptor.W - 1))
    $height = ($Cell * [int]$Descriptor.H) + ($Gap * ([int]$Descriptor.H - 1))
    $card = [Android.Widget.FrameLayout]::new($Activity)
    $card.Id = [Android.Views.View]::GenerateViewId()
    $card.Tag = $Descriptor.Id
    $card.Focusable = $true
    $card.FocusableInTouchMode = $false
    $card.Clickable = $true
    $card.Elevation = [single](ConvertTo-Dp 2)
    $card.Background = New-TileBackground $Descriptor.Color

    $frontText = if ([string]::IsNullOrWhiteSpace([string]$Descriptor.Glyph)) {
        [string]$Descriptor.Title
    } else { "$($Descriptor.Glyph)`n$($Descriptor.Title)" }
    $backText = if ([string]::IsNullOrWhiteSpace([string]$Descriptor.Back)) {
        [string]$Descriptor.Title
    } else { [string]$Descriptor.Back }
    $front = New-Face $frontText 18.0 ([Android.Views.GravityFlags]::Center -bor [Android.Views.GravityFlags]::Bottom)
    $back = New-Face $backText 16.0 ([Android.Views.GravityFlags]::Center)
    $back.Alpha = [single]0.0
    # The rear face is mounted backward. Rotating the containing card through
    # 180 degrees makes this face arrive upright instead of mirroring its text.
    $back.RotationY = [single]180.0
    $card.AddView($front, [Android.Widget.FrameLayout+LayoutParams]::new(-1, -1))
    $card.AddView($back, [Android.Widget.FrameLayout+LayoutParams]::new(-1, -1))

    $layout = [Android.Widget.FrameLayout+LayoutParams]::new($width, $height)
    $layout.LeftMargin = ([int]$Descriptor.Col * ($Cell + $Gap))
    $layout.TopMargin = ([int]$Descriptor.Row * ($Cell + $Gap))
    $card.LayoutParameters = $layout

    $actionId = [string]$Descriptor.Action
    $title = [string]$Descriptor.Title
    [EventHandler]$click = {
        param($sender, $eventArgs)
        try {
            [Android.Util.Log]::Info('PowerShell', "START_ACTION=$actionId")
            $script:StartNativeState.ActionCount++
            [Android.Widget.Toast]::MakeText($Activity, "$title  •  $actionId", [Android.Widget.ToastLength]::Short).Show()
        } catch {
            [Android.Util.Log]::Error('PowerShell', "Start action failed: $_")
        }
    }.GetNewClosure()
    $card.add_Click($click)
    [void]$script:StartNativeState.Handlers.Add($click)
    [void]$script:StartNativeState.Views.Add($card)
    [void]$script:StartNativeState.Board.AddView($card)
    if ($Descriptor.Flip) {
        $card.CameraDistance = [single](ConvertTo-Dp 8000)
        Start-NativeFlip $card $front $back ([string]$Descriptor.Id)
    }
}

# Application-owned semantic content. None of this is represented in AndroidSMA.dll.
$tiles = @(
    [pscustomobject]@{ Id='phone';     Title='Phone';             Glyph='☎';  Back='2 missed calls';             Action='phone.open';      W=2; H=2; Col=0; Row=0;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,120,215) },
    [pscustomobject]@{ Id='messaging'; Title='Messaging';         Glyph='✉';  Back='Alex: See you at 7pm';       Action='messages.open';   W=2; H=2; Col=2; Row=0;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,153,188) },
    [pscustomobject]@{ Id='camera';    Title='Camera';            Glyph='●';  Back='Camera';                     Action='camera.open';     W=1; H=1; Col=4; Row=0;  Flip=$false; Color=[Android.Graphics.Color]::Rgb(96,96,96) },
    [pscustomobject]@{ Id='store';     Title='Store';             Glyph='▣';  Back='3 updates';                  Action='store.open';      W=1; H=1; Col=5; Row=0;  Flip=$false; Color=[Android.Graphics.Color]::Rgb(104,33,122) },
    [pscustomobject]@{ Id='settings';  Title='Settings';          Glyph='⚙';  Back='Start + theme';              Action='settings.open';   W=1; H=1; Col=4; Row=1;  Flip=$false; Color=[Android.Graphics.Color]::Rgb(72,72,72) },
    [pscustomobject]@{ Id='gpu';       Title='GPU';               Glyph='◇';  Back='Native retained animation';  Action='gpu.toggle';      W=1; H=1; Col=5; Row=1;  Flip=$false; Color=[Android.Graphics.Color]::Rgb(0,99,177) },
    [pscustomobject]@{ Id='cortana';   Title='Cortana';           Glyph='◯';  Back='Good evening';               Action='cortana.open';    W=4; H=2; Col=0; Row=2;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,120,215) },
    [pscustomobject]@{ Id='people';    Title='People';            Glyph='●●'; Back='David shared 3 photos';      Action='people.open';     W=2; H=2; Col=4; Row=2;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(232,17,35) },
    [pscustomobject]@{ Id='photos';    Title='Photos';            Glyph='▧';  Back='124 memories this week';     Action='photos.open';     W=4; H=2; Col=0; Row=4;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(16,124,16) },
    [pscustomobject]@{ Id='mail';      Title='Outlook';           Glyph='✉';  Back='14 • Team Sync';             Action='mail.open';       W=2; H=2; Col=4; Row=4;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,99,177) },
    [pscustomobject]@{ Id='calendar';  Title='Calendar';          Glyph='4';  Back='Tomorrow • 10:00 AM';        Action='calendar.open';   W=4; H=2; Col=0; Row=6;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(232,17,35) },
    [pscustomobject]@{ Id='music';     Title='Music';             Glyph='♫';  Back='Solar Fields • Sol';         Action='music.open';      W=2; H=2; Col=4; Row=6;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(191,0,119) },
    [pscustomobject]@{ Id='weather';   Title='Weather';           Glyph='☀';  Back='74° • Sunny';                Action='weather.open';    W=2; H=2; Col=0; Row=8;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,120,215) },
    [pscustomobject]@{ Id='browser';   Title='Internet Explorer'; Glyph='e';  Back='4 open tabs';                Action='browser.open';    W=2; H=2; Col=2; Row=8;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,153,188) },
    [pscustomobject]@{ Id='games';     Title='Games';             Glyph='✚';  Back='1,420 Gamerscore';           Action='games.open';      W=2; H=2; Col=4; Row=8;  Flip=$true;  Color=[Android.Graphics.Color]::Rgb(16,124,16) },
    [pscustomobject]@{ Id='maps';      Title='HERE Maps';         Glyph='⌖';  Back='Turn right on Market St';    Action='maps.open';       W=4; H=2; Col=0; Row=10; Flip=$true;  Color=[Android.Graphics.Color]::Rgb(0,99,177) },
    [pscustomobject]@{ Id='calc';      Title='Calculator';        Glyph='±';  Back='0';                          Action='calculator.open'; W=2; H=2; Col=4; Row=10; Flip=$true;  Color=[Android.Graphics.Color]::Rgb(96,96,96) }
)

$script:StartNativeState = [pscustomobject]@{
    Activity=$Activity; Root=$null; Board=$null
    Views=[ArrayList]::new(); Animators=[ArrayList]::new(); Handlers=[ArrayList]::new()
    ActionCount=0
}

[Action]$attach = {
    try {
        $screenWidth = [int]$Activity.Resources.DisplayMetrics.WidthPixels
        $screenHeight = [int]$Activity.Resources.DisplayMetrics.HeightPixels
        $landscape = $screenWidth -ge $screenHeight
        $columns = if ($landscape) { 6 } else { 4 }
        $gap = ConvertTo-Dp 6
        $pad = ConvertTo-Dp 18
        $cell = [int][Math]::Floor((($screenWidth - ($pad * 2)) - ($gap * ($columns - 1))) / $columns)

        if (-not $landscape) {
            [int]$row=0; [int]$col=0
            foreach ($tile in $tiles) {
                $tile.W = [Math]::Min([int]$tile.W, $columns)
                if (($col + [int]$tile.W) -gt $columns) { $col=0; $row += 2 }
                $tile.Col=$col; $tile.Row=$row; $col += [int]$tile.W
                if ($col -ge $columns) { $col=0; $row += 2 }
            }
        }

        $root = [Android.Widget.LinearLayout]::new($Activity)
        $root.Orientation = [Android.Widget.Orientation]::Vertical
        $root.SetBackgroundColor([Android.Graphics.Color]::Black)
        $root.SetPadding($pad, (ConvertTo-Dp 12), $pad, 0)
        $heading = [Android.Widget.TextView]::new($Activity)
        $heading.Text='start'; $heading.SetTextColor([Android.Graphics.Color]::White)
        $heading.SetTextSize([Android.Util.ComplexUnitType]::Sp, [single]42.0)
        $heading.SetIncludeFontPadding($false)
        $root.AddView($heading, [Android.Widget.LinearLayout+LayoutParams]::new(-1, (ConvertTo-Dp 58)))

        $scroll = [Android.Widget.ScrollView]::new($Activity)
        $scroll.FillViewport=$true; $scroll.SmoothScrollingEnabled=$true
        $scroll.DescendantFocusability=[Android.Views.DescendantFocusability]::AfterDescendants
        $board=[Android.Widget.FrameLayout]::new($Activity)
        [int]$maxRow = 0
        foreach ($tile in $tiles) {
            if ([int]$tile.Row -gt $maxRow) { $maxRow = [int]$tile.Row }
        }
        $board.LayoutParameters=[Android.Widget.FrameLayout+LayoutParams]::new(-1, (($maxRow+2)*($cell+$gap))+(ConvertTo-Dp 20))
        $script:StartNativeState.Board=$board
        foreach ($tile in $tiles) { New-RetainedTile $tile $cell $gap }
        $scroll.AddView($board)
        $root.AddView($scroll, [Android.Widget.LinearLayout+LayoutParams]::new(-1, 0, [single]1.0))
        $script:StartNativeState.Root=$root
        $Activity.SetContentView($root)
        if ($script:StartNativeState.Views.Count) { [void]$script:StartNativeState.Views[0].RequestFocus() }
        [Android.Util.Log]::Info('PowerShell', "START_RETAINED_READY tiles=$($tiles.Count) animators=$($script:StartNativeState.Animators.Count) orientation=$(if($landscape){'landscape'}else{'portrait'})")
    } catch {
        [Android.Util.Log]::Error('PowerShell', "Start retained attach failed: $_ stack=$($_.ScriptStackTrace)")
        throw
    }
}.GetNewClosure()

$Activity.RunOnUiThread($attach)
