[CmdletBinding()]
param()
$raw = Invoke-AdbShell 'service list'
$lines = $raw -split "`r?`n"
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($line in $lines) {
    if ($line -match '^\s*(\d+)\s+([^:]+?)\s*:\s*\[(.*)\]\s*$') {
        [void]$results.Add([pscustomobject]@{
            Index = [int]$Matches[1]
            Name = $Matches[2].Trim()
            Interface = $Matches[3].Trim()
        })
    } elseif ($line -match '^\s*(\d+)\s+([^:]+?)\s*:\s*\[\s*\]\s*$') {
        [void]$results.Add([pscustomobject]@{
            Index = [int]$Matches[1]
            Name = $Matches[2].Trim()
            Interface = ""
        })
    }
}
$results
