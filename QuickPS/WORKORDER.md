# QuickPS Work Order

QuickPS is a collection of binders and instruction sets.

```text
QuickPS <argument> [values...]
```

That is the public shape. Build functionality.

## Rules

- Put each coherent binder or instruction set in its own plainly named `.ps1` file.
- Binder files reject dot-sourcing. Invoke them with `&` so their private helpers and state cannot leak into the caller.
- `Verify.ps1` must pass before every binder commit. Do not waive, suppress, or weaken a failed check to make a checkpoint pass.
- Bind Windows and Android platform APIs directly.
- Use existing working code as the implementation reference.
- Test the real operation before calling a binder working.
- Preserve useful scripts and behavior while moving code.
- Commit each working checkpoint with its test result.
- Keep Android and Windows as equal targets.
- Return useful values and native-backed objects naturally.
- Let callers compose them with ordinary PowerShell arguments, variables,
  scriptblocks, closures, objects, processes, and runspaces.

Do not build an engine, manager, authority, capability system, registry, carrier,
grant domain, ownership framework, universal scheduler, or documentation system.
Do not invent time, cadence, formats, or policy for callers.

## Binder files to assemble

```text
QuickPS.ps1
Native.ps1
Window.Windows.ps1
Input.Windows.ps1
D3D12.Windows.ps1
DXGI.Windows.ps1
Shader.Windows.ps1
Direct2D.Windows.ps1
DirectWrite.Windows.ps1
D3D11On12.Windows.ps1
Wic.Windows.ps1
Composition.Windows.ps1
Wasapi.Windows.ps1
MediaFoundation.Windows.ps1
Camera.Windows.ps1
Sharing.Windows.ps1
Activity.Android.ps1
Window.Android.ps1
Input.Android.ps1
Shader.Android.ps1
Text.Android.ps1
Images.Android.ps1
Audio.Android.ps1
Media.Android.ps1
Camera.Android.ps1
Sharing.Android.ps1
Canvas.Windows.ps1
Canvas.Android.ps1
Cells.ps1
Cells.Windows.ps1
Cells.Android.ps1
Pixels.ps1
Pixels.Windows.ps1
Pixels.Android.ps1
PSNES.ps1
Camera.ps1
TerminalDemo.ps1
Desktop.ps1
Tiles.ps1
```

Cells describe cell-oriented work without imposing a platform format. Pixels
describe pixel-oriented work without imposing a renderer. Camera and PSNES pass
their output to Pixels. Canvas is general drawing and is not synonymous with
Cells or Pixels.

## Sources to mine

- `C:\Dev\Terminal\QuickPS.ps1` — existing Windows binders and working behavior.
- `C:\Dev\Terminal\Src\CanvasDemo.ps1` — Android Canvas, RuntimeShader, input,
  SurfaceView, and TV behavior.
- `C:\Dev\DirectPort\Src` — VirtuaCam Media Foundation/WASAPI and other Windows
  implementation references.
- `C:\Subsystem` — Android bindings and implementation references.
- `C:\Dev\QuickPS\scripts` — applications and working PowerShell donors.

## Immediate work

1. Inventory reusable Media Foundation and WASAPI calls from VirtuaCam.
2. Inventory reusable Android bindings from `C:\Subsystem`.
3. Extract the shared native-call substrate.
4. Assemble and test binder files one at a time.
5. Wire a Windows Canvas without the old managed DLL or external atlas.
6. Verify the Android Canvas on the connected Google TV box.
7. Connect PSNES and camera frames through platform Pixels binders.
