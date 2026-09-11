#requires -Version 7.0

$terminal = [IO.Path]::Combine($PSScriptRoot, 'Terminal.ps1')
if (-not [IO.File]::Exists($terminal)) {
    throw "Terminal.ps1 was not found beside PROFILE.PS1: $terminal"
}

[scriptblock] $terminalSource = [scriptblock]::Create([IO.File]::ReadAllText($terminal))
& $terminalSource -Activity $Activity
