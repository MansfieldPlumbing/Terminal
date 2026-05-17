# DeployReact.ps1
# Run from the project root: .\DeployReact.ps1
#
# Modes:
#   .\DeployReact.ps1              → build + serve locally for browser testing
#   .\DeployReact.ps1 -Deploy      → build + copy to Backend assets (no APK compile)
#   .\DeployReact.ps1 -Deploy -Apk → build + copy + compile & push APK (full deploy.ps1 equivalent)
#   .\DeployReact.ps1 -SkipBuild   → skip npm build, just serve/deploy existing dist/

param(
    [switch]$Deploy,    # Copy dist to Backend/Assets/wwwroot
    [switch]$Apk,       # Also compile and push the APK (requires -Deploy)
    [switch]$SkipBuild  # Skip npm install + build (use existing dist/)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root     = $PSScriptRoot
$Frontend = Join-Path $Root "Frontend"
$Dist     = Join-Path $Frontend "dist"
$Assets   = Join-Path $Root "Backend\Assets\wwwroot"

function Write-Step($msg)    { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)      { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg)    { Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Fail($msg)    { Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Banner($msg)  { 
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════" -ForegroundColor White
    Write-Host "  $msg" -ForegroundColor White
    Write-Host "════════════════════════════════════════════════════" -ForegroundColor White
}

# ─── Step 1: Build ────────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Step "Installing npm dependencies..."
    Push-Location $Frontend
    try {
        npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
        Write-OK "Dependencies installed"

        Write-Step "Running prebuild (update.cjs — SVG wallpaper injection)..."
        if (Test-Path "update.cjs") {
            node update.cjs
            if ($LASTEXITCODE -ne 0) { throw "update.cjs failed" }
            Write-OK "CSS wallpaper layers injected"
        } else {
            Write-Warn "update.cjs not found — skipping wallpaper injection"
        }

        Write-Step "Building production bundle (vite build)..."
        npm run build -- 2>&1 | Tee-Object -Variable buildOutput
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Vite build failed. Output:"
            $buildOutput | Write-Host
            exit 1
        }
        Write-OK "Build complete → $Dist"
    } finally {
        Pop-Location
    }
} else {
    Write-Warn "Skipping build (-SkipBuild). Using existing dist at: $Dist"
    if (-not (Test-Path $Dist)) {
        Write-Fail "No dist/ folder found at $Dist. Run without -SkipBuild first."
        exit 1
    }
}

# ─── Step 2: Validation checks on the dist output ─────────────────────────────
Write-Step "Validating dist output..."

$indexPath = Join-Path $Dist "index.html"
if (-not (Test-Path $indexPath)) {
    Write-Fail "index.html missing from dist/. Build may have failed silently."
    exit 1
}
Write-OK "index.html present"

# Check that asset paths are relative (not absolute /assets/...)
$indexContent = Get-Content $indexPath -Raw
if ($indexContent -match 'src="/assets/' -or $indexContent -match 'href="/assets/') {
    Write-Warn "Absolute asset paths detected in index.html (/assets/...)."
    Write-Warn "Ensure vite.config.ts has base: './' — run Fix-ProjectIssues.ps1 first."
} else {
    Write-OK "Asset paths are relative (base: './' confirmed)"
}

# Check config.json was copied from public/
$configInDist = Join-Path $Dist "config.json"
if (-not (Test-Path $configInDist)) {
    Write-Warn "config.json missing from dist/. Check Frontend/public/config.json exists."
} else {
    Write-OK "config.json present in dist/"
}

# Check CSS has the wallpaper classes injected
$cssFiles = Get-ChildItem (Join-Path $Dist "assets") -Filter "*.css" -ErrorAction SilentlyContinue
$wallpaperFound = $false
foreach ($css in $cssFiles) {
    if ((Get-Content $css.FullName -Raw) -match 'bliss-clouds') {
        $wallpaperFound = $true; break
    }
}
if (-not $wallpaperFound) {
    Write-Warn "bliss-clouds CSS class not found in any dist CSS file."
    Write-Warn "update.cjs may not have run. Check prebuild script."
} else {
    Write-OK "Wallpaper CSS classes present (bliss-clouds / bliss-hill)"
}

# ─── Step 3: Local browser test OR deploy ─────────────────────────────────────
if (-not $Deploy) {
    Write-Banner "LOCAL TEST MODE"
    Write-Host ""
    Write-Host "  Serving production build locally so you can test in a browser" -ForegroundColor White
    Write-Host "  before pushing to the device." -ForegroundColor White
    Write-Host ""
    Write-Host "  NOTE: Some AndroidBridge features won't work in a browser —" -ForegroundColor Yellow
    Write-Host "  that's expected. Check for visual correctness, asset loading," -ForegroundColor Yellow
    Write-Host "  and console errors instead." -ForegroundColor Yellow
    Write-Host ""

    # Check for a local static server — try npx serve, then python, then warn
    $serverFound = $false

    # Option A: npx serve (most reliable, uses the project's node_modules)
    $serveAvailable = $null
    try { $serveAvailable = Get-Command npx -ErrorAction Stop } catch {}

    if ($serveAvailable) {
        Write-Step "Starting local server at http://localhost:4173 (Ctrl+C to stop)..."
        Write-Host ""
        Push-Location $Frontend
        try {
            # Use vite preview which respects the vite config (base, etc.)
            npx vite preview --port 4173 --host
        } finally {
            Pop-Location
        }
        $serverFound = $true
    }

    if (-not $serverFound) {
        # Fallback: Python HTTP server
        $python = $null
        try { $python = Get-Command python -ErrorAction Stop } catch {}
        try { $python = Get-Command python3 -ErrorAction Stop } catch {}

        if ($python) {
            Write-Step "Starting Python HTTP server at http://localhost:4173 (Ctrl+C to stop)..."
            Push-Location $Dist
            try {
                & $python.Source -m http.server 4173
            } finally {
                Pop-Location
            }
        } else {
            Write-Warn "No static server found (npx/python). Install serve: npm i -g serve"
            Write-Warn "Or open dist/index.html directly in Chrome and check DevTools."
        }
    }

} else {
    # ─── Deploy mode: copy to Backend assets ──────────────────────────────────
    Write-Step "Deploying to Backend/Assets/wwwroot..."

    if (Test-Path $Assets) { 
        Remove-Item -Recurse -Force $Assets
        Write-OK "Cleared old wwwroot"
    }
    New-Item -ItemType Directory -Force $Assets | Out-Null
    Copy-Item -Path (Join-Path $Dist "*") -Destination $Assets -Recurse -Force
    Write-OK "Copied dist → $Assets"

    # Verify the copy
    $deployedIndex = Join-Path $Assets "index.html"
    if (Test-Path $deployedIndex) {
        Write-OK "index.html confirmed in wwwroot"
    } else {
        Write-Fail "index.html missing from wwwroot after copy. Something went wrong."
        exit 1
    }

    if ($Apk) {
        Write-Step "Compiling APK and pushing to device via ADB..."
        Push-Location (Join-Path $Root "Backend")
        try {
            dotnet build -c Release -t:Run -f net11.0-android
            if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }
            Write-OK "APK compiled and pushed"
        } finally {
            Pop-Location
        }
        Write-Banner "FULL DEPLOY COMPLETE"
    } else {
        Write-Banner "FRONTEND DEPLOYED TO ASSETS"
        Write-Host ""
        Write-Host "  Assets are in Backend\Assets\wwwroot\" -ForegroundColor White
        Write-Host "  Run with -Apk to also compile and push the APK:" -ForegroundColor White
        Write-Host "  .\DeployReact.ps1 -Deploy -Apk" -ForegroundColor Cyan
    }
}

Write-Host ""