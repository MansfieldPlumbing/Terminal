# QuickPS Windows ABI Repair Header

## Scope Contract

The repair target is exclusively the Windows ABI connection in `QuickPS.ps1`.

Do not modify:

- `$script:Canvas`
- the packed-cell format
- canvas modes, labels, layout, or behavior
- `Build-Cells`
- the canvas render loop
- the existing `Pump()` / `Present(cells, columns, rows, elapsed, frame)` contract expected by that loop

All implementation work must remain behind the existing Windows-ABI presenter boundary and make that boundary fulfill its current contract.

## Confirmed Root Cause

`$script:Canvas` already passes its packed-cell frame to `New-CellPresenter`. The receiving Windows-ABI implementation is incomplete:

1. It creates a real D3D12 device.
2. It creates a real DXGI factory.
3. It creates a real D3D12 command queue.
4. It does not create or connect an HWND.
5. It does not call `CreateSwapChainForHwnd`.
6. It explicitly leaves `SwapChainPtr` at zero.
7. Its `Present()` method ignores the supplied cells and returns `$true` after incrementing a counter.
8. Its `Pump()` method does not populate live mouse, keyboard, resize, or window state.

This produces false readiness: the canvas receives `$true` even though no frame was submitted and no window exists.

## Runtime Evidence

The current implementation was instantiated without modifying the repository. Observed state:

```text
DevicePtr:     nonzero
FactoryPtr:    nonzero
QueuePtr:      nonzero
SwapChainPtr:  0
PresentResult: true
```

## Missing Windows ABI Connections

The Windows-ABI implementation must supply the pieces its comments and contract already claim:

- HWND creation and lifecycle connection
- live Windows message decoding into the existing state fields
- `IDXGIFactory2::CreateSwapChainForHwnd`
- swap-chain back buffers
- render-target descriptor heap and views
- command allocator and graphics command list
- required resource state transitions
- command submission and synchronization
- packed-cell frame upload/rendering through the existing presentation contract
- `IDXGISwapChain::Present`
- resize handling and resource recreation
- complete release of HWND, swap-chain, frame, synchronization, queue, factory, and device resources

## Vtable Defect

The `ID3D12Device` slot table is correct only through slot 25. It omits `GetCustomHeapProperties` at slot 26 and therefore mislabels all subsequent methods.

Known corrections include:

```text
CreateCommittedResource: listed 26, actual 27
CreateHeap:              listed 27, actual 28
CreatePlacedResource:    listed 28, actual 29
CreateReservedResource:  listed 29, actual 30
CreateFence:             listed 30, actual 36
GetDeviceRemovedReason:  listed 31, actual 37
GetCopyableFootprints:   listed 32, actual 38
CreateQueryHeap:         listed 33, actual 39
SetStablePowerState:     listed 34, actual 40
CreateCommandSignature:  listed 35, actual 41
GetResourceTiling:       listed 36, actual 42
GetAdapterLuid:          listed 37, actual 43
```

The existing DXGI factory slot for `CreateSwapChainForHwnd` and swap-chain slot for `Present` are declared but never invoked by `New-CellPresenter`.

## Governing Rule

Do not redesign or replace the canvas. Do not move rendering work into `$script:Canvas`. Complete the Windows ABI connection behind the interface the canvas already uses.
