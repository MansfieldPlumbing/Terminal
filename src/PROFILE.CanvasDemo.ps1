#requires -Version 7.0

$canvasDemo = [IO.Path]::Combine($PSScriptRoot, 'CanvasDemo.ps1')
if (-not [IO.File]::Exists($canvasDemo)) {
    throw "CanvasDemo.ps1 was not found beside PROFILE.PS1: $canvasDemo"
}

[scriptblock] $canvasSource = [scriptblock]::Create([IO.File]::ReadAllText($canvasDemo))
& $canvasSource -Activity $Activity
