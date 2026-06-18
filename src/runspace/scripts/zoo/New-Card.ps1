# New-Card — mint a card object (\Capability\Card\<id>, REGISTRY-SPEC §3 kind:"card") at RUNTIME.
# The Surface renders it; the agent's make_card tool calls this; the card maker presenter will too.
# A card = an Adaptive Card TEMPLATE (+ optional ${} bindings) fed by a PowerShell -Command whose JSON
# result is the template's data. Validation here is the FIRST line of the safety contract (a malformed
# LLM-authored card must never reach the registry); the Surface's per-card try/catch is the last.
# Returns the registered record, or a structured @{ error = ... } the model can read and self-correct.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Id,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Template,      # Adaptive Card JSON (the presentation, ${} bindings allowed)
    [string]$Command = '',                         # PowerShell that produces the card's data (JSON object)
    [int]$RefreshSeconds = 0,                      # 0 = manual only; clamped to >=15 by the renderer anyway
    [string]$Icon = '·',
    [int]$Width = 260,
    [int]$Height = 200,
    [switch]$Place                                 # also drop an instance onto the Surface layout
)

if ($Id -cnotmatch '^[a-z][a-z0-9-]{1,31}$') {
    return @{ error = "invalid card id '$Id' — must match ^[a-z][a-z0-9-]{1,31}$ (lowercase, digits, dashes)" }
}
try { $tpl = $Template | ConvertFrom-Json } catch {
    return @{ error = "template is not valid JSON: $($_.Exception.Message)" }
}
if ($tpl.type -ne 'AdaptiveCard') {
    return @{ error = "template.type must be 'AdaptiveCard' (got '$($tpl.type)')" }
}

$manifest = [ordered]@{
    version      = 1
    kind         = 'card'
    id           = $Id
    name         = $Name
    icon         = $Icon
    presentation = $tpl
    consumers    = @('canvas')
    size         = @{ w = $Width; h = $Height }
    ext          = @{}
}
if ($Command) {
    $data = [ordered]@{ binding = 'script'; command = $Command }
    if ($RefreshSeconds -gt 0) { $data.refresh = [Math]::Max(15, $RefreshSeconds) }
    $manifest.data    = $data
    $manifest.actions = @{ refresh = @{ command = $Command } }
}

$json = $manifest | ConvertTo-Json -Depth 24 -Compress
Register-Capability -Path "\Capability\Card\$Id" -Name $Name -Type Card -Manifest $json -Enabled | Out-Null

if ($Place) {
    # Append an instance to the Surface layout blob (\Shell\Config\ss-surface). Last-writer-wins is
    # fine on a single-user device; the Surface resyncs on focus/visibility.
    $rec = Get-Capability "\Shell\Config\ss-surface"
    $layout = $null
    if ($rec -and $rec.ManifestJson) { try { $layout = $rec.ManifestJson | ConvertFrom-Json } catch { } }
    if (-not $layout -or -not $layout.cards) { $layout = [pscustomobject]@{ version = 2; cards = @() } }
    $inst = [pscustomobject]@{
        id = 'w' + ([guid]::NewGuid().ToString('n').Substring(0, 7))
        card = $Id; x = 60; y = 60; w = $Width; h = $Height
    }
    $layout.cards = @($layout.cards) + $inst
    $blob = $layout | ConvertTo-Json -Depth 12 -Compress
    Register-Capability -Path "\Shell\Config\ss-surface" -Name 'ss-surface' -Type Config -Manifest $blob -Enabled | Out-Null
}

Get-Capability "\Capability\Card\$Id"
