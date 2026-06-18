# Native Android Terminal Profile
#
# Dot-sourced at runspace init AFTER MainActivity's initScript, so the two definitions below override
# the desktop-shaped defaults baked there. Both are phone-first views; they are friendly shims, not
# canon cmdlets (Get-ChildItem itself is untouched — 'dir' is just the readable listing).

# Short, phone-friendly prompt. A full path eats the narrow line; show only the leaf (HOME as '~').
function global:prompt {
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    if ($loc -eq $env:HOME) {
        $leaf = '~'
    } elseif ($env:HOME -and $loc.StartsWith($env:HOME)) {
        $leaf = '~/' + (Split-Path $loc -Leaf)
    } else {
        $leaf = Split-Path $loc -Leaf
        if (-not $leaf) { $leaf = $loc }   # drive/filesystem root has no leaf
    }
    "PS $leaf > "
}

# Phone-sane directory listing: Mode, short date, ONE scoped-unit size column, Name. Dirs read <DIR>
# in the size column. Get-ChildItem stays canonical; this is the friendly view bound to 'dir' (and ls).
function global:dir {
    Get-ChildItem @args | Format-Table -AutoSize `
        Mode, `
        @{ N = 'Date'; E = { $_.LastWriteTime.ToString('MM/dd/yy') } }, `
        @{ N = 'Size'; A = 'Right'; E = {
            if ($_.PSIsContainer) { '<DIR>' }
            else {
                $b = $_.Length
                if     ($b -lt 1KB) { "$b B" }
                elseif ($b -lt 1MB) { '{0:0.#} KB' -f ($b / 1KB) }
                elseif ($b -lt 1GB) { '{0:0.#} MB' -f ($b / 1MB) }
                else                { '{0:0.#} GB' -f ($b / 1GB) }
            }
        } }, `
        Name
}
Set-Alias ls dir -Scope Global -Force

function Install-LocalAdb {
    $adbPath = "$HOME/adb"
    if (-not (Test-Path $adbPath)) {
        Write-Host "Downloading official ARM64 ADB binary to phone..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri "https://github.com/Magisk-Modules-Repo/adb-ndk/raw/master/bin/adb" -OutFile $adbPath
        Start-Sleep -Seconds 1
        
        # Make the binary executable using .NET Core 7+ UnixFileMode
        [System.IO.File]::SetUnixFileMode($adbPath, [System.IO.UnixFileMode]::UserExecute -bor [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
    }
    return $adbPath
}

function Pair-LocalAdb {
    param([int]$Port, [string]$Code)
    $adb = Install-LocalAdb
    & $adb pair "127.0.0.1:$Port" $Code
}

function Connect-LocalAdb {
    param([int]$Port)
    $adb = Install-LocalAdb
    & $adb connect "127.0.0.1:$Port"
}

function Enter-AdbShell {
    $adb = Install-LocalAdb
    Write-Host "Dropping into elevated ADB shell. Type 'exit' to return to PWSH." -ForegroundColor Yellow
    & $adb shell
}

Write-Host "Welcome to PWSH on Android!" -ForegroundColor Cyan
Write-Host "To kill Shizuku, use Pair-LocalAdb, Connect-LocalAdb, and Enter-AdbShell." -ForegroundColor Yellow
