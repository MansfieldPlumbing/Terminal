<#
.SYNOPSIS
    "The General" Safe Edition (LLM Optimized).
    Generates a token-efficient XML context report.
#>

# --- 1. USER CONFIGURATION (FLATTENED) ---

# [CATEGORY A] DIRECTORIES TO IGNORE FOR MAPPING (The Tree View)
# These will appear as "[Excluded]" in your directory structure and won't be scanned.
$IgnoreDirsMapping = @(
    ".git", ".svn", ".vs", ".vscode", ".idea", "node_modules", "venv", ".venv", "env", "__pycache__", "python"
)

# [CATEGORY B] DIRECTORIES TO IGNORE FOR TRANSCRIPTION (The Source Code)
# These files will show up in the Tree View, but their CONTENT will not be added to the report.
$IgnoreDirsContent = @(
    "dist", "build", "out", "target", "vendor", "pkg", "coverage", "weights", "checkpoints", "python", "site-packages"
)

# [CATEGORY C] ALLOWED TEXT EXTENSIONS
# Only files with these extensions will have their content transcribed.
$AllowedExtensions = @(
    ".ps1", ".psm1", ".psd1", ".txt", ".md", ".json", ".xml", ".html", ".css", 
    ".js", ".ts", ".py", ".c", ".cpp", ".h", ".cs", ".java", ".go", ".rs", 
    ".php", ".rb", ".bat", ".cmd", ".sh", ".yaml", ".yml", ".sql"
)

# [GENERAL LIMITS]
$MaxFileSize = 512000 # Skip files larger than 500KB
$IgnoreFilesGlobal = @("package-lock.json", "yarn.lock", "*.log", "*.tmp", ".DS_Store")

# --- 2. SETUP ---
$CurrentDir = Get-Location
$ProjectName = Split-Path $CurrentDir -Leaf
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$OutputFile = "$ProjectName $Timestamp.txt"
$OutputPath = Join-Path $CurrentDir $OutputFile
$sw = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.Encoding]::UTF8)

# --- 3. HELPER FUNCTIONS ---
function Test-IsTextFile {
    param($Item)
    if ($Item.Length -gt $MaxFileSize) { return $false }
    if ($AllowedExtensions -contains $Item.Extension) { return $true }
    
    try {
        $stream = [System.IO.File]::OpenRead($Item.FullName)
        $buffer = New-Object byte[] 512
        $count = $stream.Read($buffer, 0, 512)
        $stream.Close()
        if ($count -eq 0) { return $true }
        return (-not ($buffer[0..($count-1)] -contains 0))
    } catch { return $false } 
}

function Get-RelativePath {
    param($Path)
    $rel = $Path.Substring($CurrentDir.Path.Length).TrimStart("\").TrimStart("/")
    return $rel.Replace("\", "/")
}

# --- 4. REPORT GENERATION ---
$sw.WriteLine("<context_report project=""$ProjectName"" generated=""$Timestamp"">")

# SECTION A: The Tree (Mapping)
$sw.WriteLine("<directory_structure>")
function Write-CompactTree {
    param($Dir, $Level)
    $indent = "  " * $Level
    $items = Get-ChildItem -LiteralPath $Dir -Force | Sort-Object Name
    foreach ($item in $items) {
        if ($item.Name -eq $OutputFile) { continue }
        if ($item.PSIsContainer) {
            if ($IgnoreDirsMapping -contains $item.Name) { 
                $sw.WriteLine("$indent+ $($item.Name)/ [Excluded from Mapping]")
                continue 
            }
            $sw.WriteLine("$indent+ $($item.Name)/")
            Write-CompactTree -Dir $item.FullName -Level ($Level + 1)
        } else {
            $sw.WriteLine("$indent- $($item.Name)")
        }
    }
}

Write-Host "Mapping Structure..." -ForegroundColor Cyan
Write-CompactTree -Dir $CurrentDir.Path -Level 0
$sw.WriteLine("</directory_structure>`n")

# SECTION B: The Content (Transcription)
$sw.WriteLine("<source_code>")
function Write-Content {
    param($Dir)
    $items = Get-ChildItem -LiteralPath $Dir -Force | Sort-Object Name
    foreach ($item in $items) {
        if ($item.Name -eq $OutputFile) { continue }
        if ($item.PSIsContainer) {
            # Skip if in Mapping Ignore OR Content Ignore
            if ($IgnoreDirsMapping -contains $item.Name -or $IgnoreDirsContent -contains $item.Name) { continue }
            Write-Content -Dir $item.FullName
        } else {
            $shouldSkip = $false
            foreach ($pattern in $IgnoreFilesGlobal) { if ($item.Name -like $pattern) { $shouldSkip = $true; break } }
            if ($shouldSkip -or (-not (Test-IsTextFile $item))) { continue }

            $relPath = Get-RelativePath $item.FullName
            Write-Host "Transcribing: $relPath" -ForegroundColor DarkGray
            $sw.WriteLine("<file path=""$relPath"">")
            try {
                $content = [System.IO.File]::ReadAllText($item.FullName).Trim()
                $content = $content -replace '(\r?\n){3,}', "`n`n"
                $sw.WriteLine($content)
            } catch { $sw.WriteLine("!! ERROR READING FILE !!") }
            $sw.WriteLine("</file>")
        }
    }
}

Write-Host "Ingesting Code..." -ForegroundColor Cyan
Write-Content -Dir $CurrentDir.Path
$sw.WriteLine("</source_code>")
$sw.WriteLine("</context_report>")
$sw.Close()

Write-Host "Report Generated: $OutputFile" -ForegroundColor Green
