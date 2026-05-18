# Android Terminal - User Profile
# Loaded at startup. Edit to customize your environment.

# --- Navigation shortcuts (CMD / bash-style) ---
function cd..  { Set-Location ..      }
function cd\   { Set-Location /       }
function cd-   { Set-Location -       }
function ..    { Set-Location ..      }
function ...   { Set-Location ../..   }
function ....  { Set-Location ../../..}

# --- Directory helpers ---
function mkdir {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path
}
function md {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path
}
function rmdir {
    param([Parameter(Mandatory)][string]$Path, [switch]$s, [switch]$Recurse)
    Remove-Item -Path $Path -Recurse:($s -or $Recurse) -Force
}

# --- Aliases ---
Set-Alias -Name cls     -Value Clear-Host        -Force -Option AllScope
Set-Alias -Name cp      -Value Copy-Item         -Force -Option AllScope
Set-Alias -Name mv      -Value Move-Item         -Force -Option AllScope
Set-Alias -Name del     -Value Remove-Item       -Force -Option AllScope
Set-Alias -Name rd      -Value Remove-Item       -Force -Option AllScope
Set-Alias -Name ren     -Value Rename-Item       -Force -Option AllScope
Set-Alias -Name copy    -Value Copy-Item         -Force -Option AllScope
Set-Alias -Name move    -Value Move-Item         -Force -Option AllScope
Set-Alias -Name chdir   -Value Set-Location      -Force -Option AllScope
Set-Alias -Name type    -Value Get-Content       -Force -Option AllScope
Set-Alias -Name h       -Value Get-History       -Force -Option AllScope
Set-Alias -Name history -Value Get-History       -Force -Option AllScope
Set-Alias -Name man     -Value Get-Help          -Force -Option AllScope
Set-Alias -Name help    -Value Get-Help          -Force -Option AllScope
Set-Alias -Name ps      -Value Get-Process       -Force -Option AllScope
Set-Alias -Name kill    -Value Stop-Process      -Force -Option AllScope
Set-Alias -Name grep    -Value Select-String     -Force -Option AllScope
Set-Alias -Name which   -Value Get-Command       -Force -Option AllScope
Set-Alias -Name curl    -Value Invoke-WebRequest -Force -Option AllScope
Set-Alias -Name wget    -Value Invoke-WebRequest -Force -Option AllScope
Set-Alias -Name sort    -Value Sort-Object       -Force -Option AllScope
Set-Alias -Name tee     -Value Tee-Object        -Force -Option AllScope

# --- Prompt (white, shows full path) ---
function prompt {
    "PS $($PWD.Path)> "
}
