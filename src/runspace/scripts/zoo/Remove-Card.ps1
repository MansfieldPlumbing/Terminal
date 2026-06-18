# Remove-Card — unregister a card object and strip its instances from the Surface layout.
# The mirror of New-Card; the agent's remove_card tool calls this.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Id
)

if ($Id -cnotmatch '^[a-z][a-z0-9-]{1,31}$') {
    return @{ error = "invalid card id '$Id'" }
}

$removed = Unregister-Capability -Path "\Capability\Card\$Id"

# Strip any placed instances of this card from the layout blob.
$rec = Get-Capability "\Shell\Config\ss-surface"
if ($rec -and $rec.ManifestJson) {
    try {
        $layout = $rec.ManifestJson | ConvertFrom-Json
        if ($layout.cards) {
            $kept = @($layout.cards | Where-Object { $_.card -ne $Id })
            if ($kept.Count -ne @($layout.cards).Count) {
                $layout.cards = $kept
                $blob = $layout | ConvertTo-Json -Depth 12 -Compress
                Register-Capability -Path "\Shell\Config\ss-surface" -Name 'ss-surface' -Type Config -Manifest $blob -Enabled | Out-Null
            }
        }
    } catch { }
}

@{ removed = $Id; ok = [bool]$removed }
