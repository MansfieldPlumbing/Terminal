export const smokeTestConfig = `
; ---------------------------------------
; OOBE Fallback Configuration (Algebraic INI)
; ---------------------------------------

[Variables]
$default_blur = 12px
$primary_accent = #3b82f6

[Profile.Default]
mica.blur = $default_blur
accent.color = $primary_accent

; --- Views ---

[Settings.Root]
type = View
title = Settings

[Settings.Personalization]
type = View
title = Personalization

; --- Controls View ---

[Settings.Controls]
type = View
title = Controls & Interactivity

[Settings.Controls.InputSurface]
type = Surface
title = System Input
parent = Settings.Controls

[Settings.Controls.InputSurface.CommandPalette]
type = Toggle
label = Enable Command Palette
caption = Quick actions using Ctrl+Shift+P or Cmd+Shift+P.
value = true
storeKey = commandPaletteVisible
parent = Settings.Controls.InputSurface

[Settings.Controls.InputSurface.VirtualJoystick]
type = Toggle
label = Virtual Joystick
caption = Enable on-screen analog touch controls.
value = false
storeKey = thumbstickVisible
parent = Settings.Controls.InputSurface

; --- Root Navigation ---

[Settings.Root.Nav.Personalization]
type = ActionRow
label = Personalization
caption = Themes, UI scaling, transparency effects
icon = Palette
target = Settings.Personalization
parent = Settings.Root

[Settings.Root.Nav.Controls]
type = ActionRow
label = Controls
caption = Command palette, virtual joystick
icon = Gamepad2
target = Settings.Controls
parent = Settings.Root

[Settings.Root.Nav.CanvasHost]
type = ActionRow
label = Canvas Host
caption = Hardware-accelerated rendering and diagnostics
icon = Activity
target = Settings.CanvasHost
parent = Settings.Root

[Settings.Root.Nav.About]
type = ActionRow
label = About
caption = Device integration, source code and documentation
icon = Info
target = Settings.About
parent = Settings.Root

; --- Personalization Surfaces ---

[Settings.Personalization.Appearance]
type = Surface
title = System Appearance
parent = Settings.Personalization

; --- Appearance Controls ---

[Settings.Personalization.Appearance.Scale]
type = Slider
label = UI Scale & Font Size
caption = Adjusts the overall density, font sizes, and context menu sizing globally.
min = 0.5
max = 1.5
value = 1
multiplier = 100
unit = %
storeKey = uiScale
parent = Settings.Personalization.Appearance

[Settings.Personalization.Appearance.BgOpacity]
type = Slider
label = Background Opacity
caption = Controls transparency of the desktop background and windows
min = 0
max = 1
value = 0.5
multiplier = 100
unit = %
storeKey = bgOpacity
parent = Settings.Personalization.Appearance

[Settings.Personalization.Appearance.Opacity]
type = Slider
label = Panel Opacity
caption = Controls transparency of menus, dialogs, and popups
min = 0
max = 1
value = 0.85
multiplier = 100
unit = %
storeKey = micaOpacity
parent = Settings.Personalization.Appearance

[Settings.Personalization.Appearance.Blur]
type = Slider
label = Mica Blur Radius
min = 0
max = 64
value = 6
unit = px
storeKey = micaBlur
parent = Settings.Personalization.Appearance

[Settings.Personalization.Appearance.MicaTabBar]
type = Toggle
label = Mica Tab Bar
caption = Enable translucent tab bar with animated clouds
value = false
storeKey = autoHideTabs
parent = Settings.Personalization.Appearance

[Settings.Personalization.Themes]
type = Custom
component = NativeColorSchemeEditor
parent = Settings.Personalization

; --- Canvas Host View ---

[Settings.CanvasHost]
type = View
title = Canvas Host

[Settings.CanvasHost.Tunables]
type = Surface
title = Canvas Host Tunables
parent = Settings.CanvasHost

[Settings.CanvasHost.Tunables.Dpi]
type = Slider
label = DPI Scale
min = 1
max = 5
value = 1
unit = 
storeKey = canvasDpi
parent = Settings.CanvasHost.Tunables

[Settings.CanvasHost.Tunables.BlockScale]
type = Slider
label = Block Scale
min = 1
max = 8
value = 2
unit = x
storeKey = canvasBlockScale
parent = Settings.CanvasHost.Tunables

[Settings.CanvasHost.Diagnostics]
type = Surface
title = Diagnostics
parent = Settings.CanvasHost

[Settings.CanvasHost.Diagnostics.Launch]
type = Button
label = Launch Canvas Host
caption = Hardware-accelerated in-app PowerShell SDK testing suite.
icon = Activity
action = LaunchCanvasHost
parent = Settings.CanvasHost.Diagnostics

; --- About View ---

[Settings.About]
type = View
title = About Android Terminal

[Settings.About.AppHeader]
type = Header
title = Android Terminal
subtitle = Version 0.2.0 • MIT License
copyright = © 2026 MansfieldPlumbing. All rights reserved.
parent = Settings.About

[Settings.About.Info]
type = Surface
title = Device Information
parent = Settings.About

[Settings.About.Info.Environment]
type = KeyValue
label = Environment
value = pwsh (PowerShell)
parent = Settings.About.Info

[Settings.About.Info.Version]
type = KeyValue
label = PowerShell Version
value = 7.6.1
parent = Settings.About.Info

[Settings.About.Info.Runtime]
type = KeyValue
label = .NET Runtime
value = 11.0.100-preview.4.26230.115
parent = Settings.About.Info

[Settings.About.Info.Build]
type = KeyValue
label = Build Date
value = 2026-05-16
parent = Settings.About.Info

[Settings.About.Links]
type = Surface
title = Links
parent = Settings.About

[Settings.About.Links.GitHub]
type = Button
label = View Source on GitHub
caption = github.com/MansfieldPlumbing/android-terminal
icon = Terminal
action = OpenGitHub
parent = Settings.About.Links
`;
