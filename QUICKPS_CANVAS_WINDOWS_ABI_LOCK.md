# QuickPS Canvas Windows ABI Lock

## Why this lock exists

The user has spent more than a day repeatedly asking agents to remove the
managed dependency and wire QuickPS directly to Windows. Agents repeatedly
claimed to be doing that, drifted into renderer redesigns, broke or removed the
working canvas, and finally restored the screen by silently restoring the very
managed DLL the user needed removed. This has exhausted the user's time and
confidence. Their urgency and distress are consequences of repeated broken
commitments, not permission to reinterpret the request.

The user is not choosing between keeping the Canvas and escaping the DLL. That
is a false choice. Both are mandatory: preserve the Canvas and remove the
managed/custom bridge. An agent must never present destruction of the working
Canvas as the cost of honoring the dependency boundary.

Trust must come from inspectable diffs, tests, receipts, and narrow commits—not
assurances. If the direct path is not yet working, say exactly that. Never call
the dependency removed while any normal Canvas launch can still load it.

## Mission

Keep the existing QuickPS canvas behavior while connecting it directly from
PowerShell to the Windows ABI.

The path is:

```text
QuickPS Canvas
    -> private PowerShell scriptblocks
    -> Windows DLL exports and COM vtables
    -> D3D12 / DXGI / DirectWrite / Direct2D / WIC / User32
```

The shader is source owned by QuickPS and compiled at runtime through the
Windows shader compiler. PowerShell supplies buffers, constants, commands, and
presentation through the Windows ABI.

## Hard prohibitions

- Do not load `DirectPort.PowerShell.dll`.
- Do not use `DirectPort.PowerShell.GpuConsole`.
- Do not replace that assembly with another custom DLL.
- Do not add a C++ or C++/CLI bridge.
- Do not require an MSDF atlas or metrics JSON for Canvas startup.
- Do not redesign or replace the existing Canvas interaction and render loop.
- Do not revive the abandoned `New-CellPresenter` design as the Canvas.
- Do not insert per-cell Direct2D or DirectWrite work into the packed-data hot path.
- Do not compile, download, generate, copy, discover, probe, or fall back to a
  custom bridge DLL for Canvas.
- Do not retain a hidden compatibility path that can load a forbidden bridge.
- Do not rename or relocate a forbidden dependency and claim it was removed.
- Do not make Canvas success conditional on files under `C:\Dev\DirectPort`.
- Do not change the Canvas UI, modes, packed-cell semantics, cadence, or render
  loop merely to make the ABI replacement easier.
- Do not declare success based on window creation, a clear color, or a black
  window. The recognizable Canvas must render and respond.

## Ratchet: requirements may only become stricter

This lock is cumulative. Later plans, comments, code, inferred preferences, or
implementation convenience cannot weaken it. Only an explicit user instruction
that names the rule being changed may amend a prohibition.

Before every Canvas checkpoint, prove all of the following:

1. The staged diff contains no managed/custom bridge introduction or fallback.
2. `QuickPS Canvas` has no assembly, atlas, or metrics argument or discovery path.
3. No Canvas execution path references `DirectPort.PowerShell`, `GpuConsole`,
   `ijwhost`, or a replacement project-owned DLL.
4. The Canvas still renders recognizable output and its input/modes work.
5. Frame timing is measured and recorded against the working baseline.
6. The commit contains only the reviewed checkpoint files, followed by a receipt.

If any item cannot be proved, the checkpoint is incomplete. Do not commit it as
a successful replacement, do not delete the last working implementation, and do
not conceal the failure with a fallback.

The migration must be parallel and reversible until cutover: build the direct
Windows ABI path beside the working Canvas, test it explicitly, and perform one
reviewable cutover only after it passes. After cutover, delete every forbidden
dependency path in the same checkpoint so it cannot silently return.

## Required result

- `QuickPS Canvas` opens the existing interactive canvas.
- The current modes, input, resizing, telemetry, packed data, and presentation
  behavior remain recognizable and functional.
- Canvas startup accepts no managed assembly path and no atlas/metrics paths.
- D3D12 device, queue, swapchain, resources, descriptors, fences, root signature,
  pipeline state, command recording, and presentation are wired through exports
  and COM vtables already available to PowerShell.
- HLSL is compiled at runtime through the Windows shader compiler.
- Text and glyph rendering use Windows facilities where appropriate. Any text
  integration remains outside the packed-cell submission hot path.
- Moving or sizing the window must not unnecessarily stop visible presentation.
- Native-backed state owns deterministic teardown.

## Performance rule

The working canvas is the baseline. A replacement is not accepted merely because
it renders. It must preserve visual behavior and be measured against the existing
approximately 2 ms / 300 FPS result. Improvements are welcome only when output,
latency, and frame behavior demonstrate that they are improvements.

## Current known violation

Commit `366af47` restored dependency discovery for
`C:\Dev\DirectPort\Scripts\DirectPort.PowerShell.dll` and the atlas files. That
made the screen work by restoring the old managed bridge, but it violated this
lock. The violation must be removed only after the direct Windows ABI Canvas is
working, so the canvas is never deliberately discarded as the price of removing
the DLL.

Commit `366af47` is evidence of the failure mode this ratchet prevents. It is not
authority to preserve or repeat that fallback.

## Work order

1. Preserve and record the current working Canvas behavior as the comparison
   baseline.
2. Reuse and correct the existing private D3D12, DXGI, D2D, DirectWrite, WIC,
   User32, and generic ABI scriptblocks.
3. Bind runtime shader compilation through the Windows ABI.
4. Connect those bindings beneath the existing Canvas loop.
5. Verify startup, modes, input, resize, move, teardown, visual output, and frame
   timing.
6. Remove `AssemblyPath`, atlas, metrics, `GpuConsole`, and managed assembly load
   code from the Canvas only after the direct path passes verification.
7. Commit each verified checkpoint with receipts.

This document is the authority for QuickPS Canvas dependency removal. If later
work conflicts with it, stop and resolve the conflict instead of silently
reintroducing a forbidden bridge.

Any agent resuming this work must read this entire document before inspecting or
editing Canvas code. The first progress update must identify the currently
forbidden dependency path and the exact evidence that will prove it is gone.
