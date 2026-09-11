$ErrorActionPreference = 'Stop'

$profileRoot = $Activity.FilesDir.AbsolutePath
$aoaSource = [IO.File]::ReadAllText(
    [IO.Path]::Combine($profileRoot, 'Aoa-CommandSurface.ps1')
)
. ([scriptblock]::Create($aoaSource))
