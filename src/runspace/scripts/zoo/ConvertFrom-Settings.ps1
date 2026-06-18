[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
    [string[]]$InputObject
)

begin {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($line in $InputObject) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -gt 0) {
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            $results.Add([pscustomobject]@{ Key = $key; Value = $val })
        }
    }
}

end {
    $results
}
