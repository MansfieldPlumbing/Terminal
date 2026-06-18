[CmdletBinding()]
param()
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$raw = Invoke-AdbShell 'dumpsys cpuinfo'
$lines = $raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$load = $null
if ($lines.Count -gt 0 -and $lines[0] -match 'Load:\s*(.*)') {
    $load = $Matches[1].Trim()
}

$totalCpu = $null
$totalLine = $lines | Where-Object { $_ -match 'TOTAL:' } | Select-Object -First 1
if ($totalLine -and $totalLine -match '^\s*([0-9.]+%)\s*TOTAL:') {
    $totalCpu = $Matches[1]
}

$procLines = [System.Collections.Generic.List[string]]::new()
foreach ($line in $lines) {
    if ($line -match '^\s*([0-9.]+%)\s+(\d+)/([^:]+):\s*(.*)$') {
        $pct = $Matches[1]
        $pid = $Matches[2]
        $name = $Matches[3]
        $details = $Matches[4]
        [void]$procLines.Add("$pct $pid $name $details")
    }
}

$procHeader = @('Usage', 'PID', 'Name', 'Details')
$procObjects = $procLines | & "$PSScriptRoot\ConvertFrom-Table.ps1" -Header $procHeader

[pscustomobject]@{
    Load = $load
    TotalCpu = $totalCpu
    Processes = $procObjects
}
