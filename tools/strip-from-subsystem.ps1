<#
  strip-from-subsystem.ps1 — vendor Subsystem's shared core into the focused "Terminal" head.

  Terminal is a CURATED HEAD of Subsystem, not a blind fork: the shell + runspace core come
  FROM Subsystem; this script removes the on-device-AI surface and the Windows head so the
  result is "Subsystem minus the agent, Android only." Re-running it re-pulls the core.

  WHAT THIS SCRIPT DOES (the deterministic part):
    1. Copies the KEEP set (src/runspace, src/shell, src/analyzers, src/tools, build files,
       content/html-applets) from -Source into -Dest\... , EXCLUDING the wholesale REMOVE set.
    2. Leaves the SURGICAL seams (files that weave AI into otherwise-core code) for the caller
       to edit; those edits are the fork's committed divergence (listed at the bottom).

  WHAT IT DELIBERATELY DOES NOT DO:
    - It does not touch -Source (Subsystem is read-only ground truth).
    - It does not git-commit; the caller owns history.

  Usage:
    pwsh tools/strip-from-subsystem.ps1 -Source S:\subsystem-project\subsystem-main -Dest S:\terminal-project
#>
[CmdletBinding()]
param(
  [string]$Source = 'S:\subsystem-project\subsystem-main',
  [string]$Dest   = 'S:\terminal-project'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Source)) { throw "Source not found: $Source" }
Write-Host "Stripping  $Source  ->  $Dest" -ForegroundColor Cyan

# --- the REMOVE set -----------------------------------------------------------------------------
# Directories removed wholesale (matched by NAME at any depth). These are self-contained: the
# Windows head (excluded from the Android build), the AI broker, native GPU surface, AI vendor libs.
$xd = @(
  'windows',          # the Windows head (SubsystemWin.csproj) — Android product doesn't ship it
  'directport',       # DirectPort D3D12 (Windows GPU surface)
  'ort',              # ONNX Runtime JS (model inference)
  'kokoro',           # Kokoro TTS JS (agent voice)
  'monaco',           # Monaco editor (12 MB / a TypeScript language service) — replaced by lib/codeedit.js
  'shaders',          # the WebGL fragment-shader wallpaper catalog — a continuous-GPU resource hog
  # build artifacts / vcs — never vendor these
  'bin','obj','build','.git','.vs','node_modules'
)
# KEEP THE BROKER, REMOVE THE AI (owner call). The RuntimeBroker is a runtime-broker-behind-a-contract
# (LiteRT/ONNX/GGML) — reusable plumbing worth keeping, and keeping it means the host layer that
# references it (SubsystemApi/ProjectionServer/MainActivity/Dg/WrapperCmdlets) compiles UNTOUCHED — no
# surgical deletions, no dangling references. The AI is removed at the reachable PRODUCT SURFACE, not by
# gutting the plumbing: we drop only the AI's UI presenters here, then the seam edits below remove the
# Broker charm + the Settings→Models picker. The broker ships dormant — nothing in the UI can reach it.
# (The 38 MB libLiteRtLm.so still bundles; drop it from Subsystem.csproj if you want the lean APK.)
$xf = @(
  'agent.obp','webnn.obp','quickassist.obp',          # the AI's reachable UI presenters
  # the shader-background live wallpaper (continuous-GPU hog): the native WallpaperService, its
  # cmdlets + service metadata, and the in-WebView WebGL backdrop renderer.
  'WpService.cs','SystemWallpaperCmdlets.cs','wallpaper.xml','shader-bg.js'
)

function Copy-Subtree($rel) {
  $src = Join-Path $Source $rel
  if (-not (Test-Path $src)) { Write-Host "  skip (absent): $rel" -ForegroundColor DarkYellow; return }
  $dst = Join-Path $Dest $rel
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  $args = @($src, $dst, '/E', '/NFL','/NDL','/NJH','/NJS','/NP','/R:1','/W:1')
  if ($xd.Count) { $args += '/XD'; $args += $xd }
  if ($xf.Count) { $args += '/XF'; $args += $xf }
  & robocopy @args | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) for $rel" }
  Write-Host "  copied: $rel" -ForegroundColor Green
}

# --- the KEEP set -------------------------------------------------------------------------------
Copy-Subtree 'src\runspace'
Copy-Subtree 'src\shell'
Copy-Subtree 'src\analyzers'
Copy-Subtree 'src\tools'
Copy-Subtree 'content\html-applets'

# Root build/config files (drive the Android build + analyzer gate). README/CLAUDE/logs are NOT
# copied — Terminal writes its own.
foreach ($f in 'Directory.Build.props','nuget.config','.editorconfig','.gitignore','LICENSE') {
  $s = Join-Path $Source $f
  if (Test-Path $s) { Copy-Item $s (Join-Path $Dest $f) -Force; Write-Host "  copied: $f" -ForegroundColor Green }
}

Write-Host "`nWholesale strip complete." -ForegroundColor Cyan
Write-Host @"

SEAM EDITS — the fork's committed divergence (applied ON TOP of this strip; re-apply after a re-sync):
  src\shell\objects\Charms\Charms.js     Broker charm removed (no agent launcher in the charm bar)
  src\shell\presenters\settings.obp      Models + System-Wallpaper nav/view/dispatch removed
  src\shell\presenters\edit.obp          Monaco -> lib/codeedit.js (vanilla editor; Monaco vendor dropped)
  src\shell\shell\Shell.js               shader-backdrop import removed (static gradient floor only)

KEPT DORMANT — "keep the broker, remove the AI": the RuntimeBroker + its C# satellites COMPILE but
nothing in the UI can reach them (no agent presenter, no Broker charm, no model picker):
  src\runspace\RuntimeBroker\*, Host\ModelsApi.cs, Pwsh\Cmdlets\AgentCmdlets.cs,
  Diagnostics\AgentSettings.cs, Services\* (voice), shell\{models,prompts,agent-tools}.json,
  and libLiteRtLm.so (~38 MB). To shed the AI PAYLOAD later: drop the .so from Subsystem.csproj.

VERIFY: the kept tree = Subsystem minus the Windows head + the AI's reachable surface; nothing
references a removed type, so it compiles as-is (confirm with an on-device build).
"@ -ForegroundColor DarkGray
