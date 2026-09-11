# QuickPS Architecture Lock

This document constrains all continuing work on `QuickPS.ps1`.

## Public surface

- `QuickPS <Argument> [values...]` is the single public shape.
- `QuickPS` is the only global function introduced by QuickPS.
- The first argument selects one private named script block; remaining values are passed explicitly to it.
- Do not add global per-argument constructor or helper functions.
- Do not add a global carrier, registry, pipe object, authorization layer, or alternate callable API.

## Direct script launch

- Top-level script parameters may provide shortcut-friendly launch choices such as `-Canvas`, `-Desktop`, or `-StartMenu`.
- A launch choice invokes the same private argument block used by `QuickPS`; it is not a second public API.
- Top-level tunables are permitted when useful, but they are immutable invocation inputs rather than a global configuration system.
- Do not duplicate argument implementation logic in the direct-execution guard.

## Argument implementation shape

- Each first-argument choice is implemented inside one explicitly named private script block.
- The block owns its constants, GUIDs, ABI slots, native activation, object construction, operations, and teardown.
- Internal functions remain local to the argument block and must not leak into global scope.
- `QuickPS` invokes the selected block directly. Another private block may invoke it only with explicitly received values.
- Each returned instance owns and releases its native pointers, handles, buffers, events, and COM initialization responsibility.

## Discovery and organization

- Script-block variable names and parameter declarations are the discovery mechanism.
- PowerShell AST inspection must be sufficient to find argument blocks and their accepted values.
- Do not introduce numbered or lettered section taxonomies.
- Keep each block internally ordered: inputs, immutable ABI declarations, activation, returned instance, operations, teardown, exported entrypoints.
- Prefer readable statements over compressed one-line implementations.

## Boundaries

- The restored 300-FPS canvas is frozen. Windows argument work must not modify its producer, render loop, packed-cell contract, presenter, or dependencies.
- DirectComposition, WIC, WASAPI, Media Foundation, Direct2D, DirectWrite, D3D, and IPC remain independent argument implementations unless the caller explicitly composes them.
- Construction must not silently attach itself to the canvas or another hot path.
- Presentation slots are not a global producer/consumer node policy.

## Ownership

- There is no grant, authorization, revocation, generation, capability layer, or engine abstraction.
- The managed heap supplies object lifetime.
- Calls execute in the current scope unless the caller explicitly requests a runspace.
- A real runspace is the only additional scope boundary.
- A runspace receives only the values and script blocks explicitly supplied when it is created.
- Closing or disposing the runspace ends that scope; no parallel scope model is maintained.
- A returned instance owns its native resources while it holds them.
- `Dispose()` releases the instance's seat and its owned resources.
- Resource transfer between argument blocks is explicit through passed or returned values.

## Checkpoint gate

Before committing an argument checkpoint:

- Parse `QuickPS.ps1` with the PowerShell AST parser.
- Confirm private constructors do not appear as global commands.
- Exercise the implementation through `QuickPS` arguments.
- Verify native HRESULTs and nonzero pointers/handles appropriate to the checkpoint.
- Run `git diff --check`.
- Record the runtime receipt and commit the checkpoint.
