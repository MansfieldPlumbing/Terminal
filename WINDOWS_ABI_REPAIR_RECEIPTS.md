# QuickPS Windows ABI Repair Receipts

This ledger records committed, runtime-verified Windows ABI repair checkpoints.
It does not grant scope beyond `WINDOWS_ABI_REPAIR_HEADER.md`.

## Baseline

- `ff789ef` — checkpoint before canvas repair.
- Existing `$script:Canvas`, `Build-Cells`, packed-cell format, modes, and render loop are preserved.

## Verified checkpoints

- `ca002cb` — corrected the D3D12 device vtable and connected the existing HWND, message pump, command queue, and real DXGI swap chain.
- `ea6ca4a` — promoted the swap chain to `IDXGISwapChain3` and read DXGI's active presentation-buffer index.
- `a92b259` — acquired both DXGI presentation buffers and created their RTV descriptors.
- `114b8b3` — created the two presentation command allocators and reusable graphics command list.
- `49bf7f0` — created the presentation fence/event, full 64-bit per-buffer completion values, reuse waits, and teardown wait.
- `accfcbe` — mapped the Canvas2D command-list ABI from the installed Windows SDK.
- `3b2f1a9` — executed real `PRESENT -> RENDER_TARGET -> PRESENT` commands, clears, queue submission, presentation, and fencing.
- `1f58baf` — created D3D11On12 over the existing D3D12 device and queue; queried `ID3D11On12Device` and `IDXGIDevice`.
- `c5d7ea0` — created the Direct2D device/context and shared DirectWrite factory.
- `593daa9` — wrapped both D3D12 presentation buffers as D3D11 resources, queried DXGI surfaces, and created premultiplied Direct2D bitmap targets.
- `8865cc1` — completed acquire/draw/release/flush/present/fence DirectWrite submission.
- `cec482c` — connected the unchanged packed-cell `Present(cells, columns, rows, elapsed, frame)` contract to OS text presentation.
- `e7445bc` — restored all 16 packed-cell foreground/background colors through Direct2D brushes while retaining DirectWrite glyph rendering.
- `c0a997c` — moved resource-pointer, rectangle, clear-color, and UTF-16 run scratch storage into the long-lived Windows text target yard.
- `eac9072` — added an independent DirectComposition device/target/visual transaction pipe over the existing `IDXGIDevice`.
- `e1cb8b7` — added an independent WIC bitmap, file-decoder/frame, and pixel-format conversion pipe.
- `b939205` — added independent WASAPI default endpoints, audio clients, mix formats, shared/event initialization, capture/render services, start/stop, and teardown.
- `a4ae4e2` — completed WASAPI render-buffer and capture-packet acquire/release operations inside the private `$Wasapi` argument block.
- `f390bf9` — cordoned DirectComposition, WIC, and WASAPI into independent capability script blocks with private constructors and narrow public routers.
- `d0254c9` — reduced the new capability surface to the single global `QuickPS` router and added the durable capability contract.

## Runtime receipts

- Initial D3D12 device, DXGI factory, command queue, HWND, and swap chain pointers were nonzero.
- Real swap-chain `Present` returned `S_OK`.
- Both acquired presentation-buffer pointers, RTV heap, RTV start, and descriptor stride were nonzero/valid.
- Both command allocator pointers and the reusable command-list pointer were nonzero.
- Ten consecutive fenced presentations completed with the latest 64-bit fence value observed.
- Thirty-two consecutive render-target command submissions completed with `GetDeviceRemovedReason == S_OK`.
- D3D11 device/context, `ID3D11On12Device`, and `IDXGIDevice` pointers were nonzero.
- Direct2D device/context and DirectWrite factory pointers were nonzero.
- Both wrapped resources, DXGI surfaces, and Direct2D bitmap targets were nonzero.
- Sixteen consecutive Unicode DirectWrite presentations completed with `GetDeviceRemovedReason == S_OK`.
- Sixteen packed-cell presentations through the unchanged caller contract completed with `GetDeviceRemovedReason == S_OK`.
- Sixteen 40x12 packed-cell palette presentations completed in 8996.61 ms with `GetDeviceRemovedReason == S_OK`; this validates compatibility and device health, not hot-path performance.
- The same hostile 16-frame palette test, including a non-ASCII UTF-16 code unit, completed in 4940.78 ms after scratch reuse (45.08% lower elapsed time), with `GetDeviceRemovedReason == S_OK`.
- DirectComposition device, HWND target, and root visual pointers were nonzero; `Commit` and `WaitForCommitCompletion` returned `S_OK`.
- WIC created a 64x64 PBGRA bitmap, converted it to BGRA with dimensions intact, and decoded the existing 512x512 Cascadia atlas frame; all calls returned `S_OK`.
- Default render and capture endpoints each activated stereo 48 kHz audio clients. Event-driven microphone capture and render-loopback capture both acquired services and completed start/stop with `S_OK`.
- WASAPI reported a 48000-frame render capacity, acquired/released a 128-frame render buffer, and acquired/released a live 480-frame capture packet with valid native pointers; all calls returned `S_OK`.
- Capability isolation audit found zero leaked internal constructors; all three public routers and private script-block entrypoints remained live, and all three capabilities passed post-refactor native activation.
- Single-router audit found zero global pipe constructors; WIC and WASAPI instantiated successfully through `QuickPS` arguments.
- PowerShell AST parsing and `git diff --check` passed before each committed code checkpoint.

## Defects caught before commit

- The original D3D12 device table omitted `GetCustomHeapProperties`, shifting every later device method. Correct positions include `CreateCommittedResource = 27`, `CreateFence = 36`, and `GetAdapterLuid = 43`.
- The raw Windows ABI for `GetCPUDescriptorHandleForHeapStart` uses a caller-provided return pointer. Treating it as a direct 64-bit return caused an isolated child-process access violation; the call was corrected and retested before commit.
- Script-method closures could not safely re-resolve script-scoped vtable maps. Required slot indices are now pinned onto the owning presenter objects.
- PowerShell could reinterpret `0xFFFFFFFF` as signed negative one. Infinite waits now use `[uint32]::MaxValue`.
- Failed or rejected patches were never committed.

## Local implementation authorities

- Installed Windows SDK `10.0.26100.0` headers for interface layouts, GUIDs, structures, and exports.
- `C:\Dev\DirectPort\Src\windows-d3d12\source\powershell\DirectPort.Console.Native.cpp`
- `C:\Dev\DirectPort\Src\windows-d3d12\source\powershell\DirectPort.Canvas2D.Native.cpp`
- `C:\Dev\ps2orb-d3d12.cpp`
- `C:\Dev\DirectPort\Src\DirectPort-main\original\src\DirectPortMultiplexerD3D12.cpp`
- `C:\Dev\DirectPort\Src\DirectPort-main\original\src\DirectPortTextureToBufferD3D12.cpp`
- `C:\Dev\DirectPort\Src\DirectPort-main\original\src\DirectPortBufferToTextureD3D12.cpp`
- `C:\Dev\DirectPort\Src\ipc-test`
- `C:\Dev\QuickPS\scripts\recorder.ps1`
- `C:\Dev\virtuacam-project\VirtuaCam\src\VirtuaCam\WASAPI.cpp`
- `C:\Dev\virtuacam-project\VirtuaCam\src\VirtuaCam\MFCamera.cpp`
- `C:\Dev\virtuacam-project\VirtuaCam\src\VirtuaCam\BrokerClient.cpp`
- `C:\Dev\GitCommit\main.cpp`
- `C:\Dev\GitCommit\d3d11micablur-notext.cpp`
- `C:\Dev\GitCommit\ff7.cpp`

## Architectural boundaries retained

- Two DXGI buffers are presentation slots only.
- Producer/consumer nodes independently own their long-lived work/blit resources.
- Cells are one client; raw video, shaders, 3D, Canvas2D, DirectComposition, menu graphs, and audio remain independent clients/nodes.
- DirectWrite owns normal Windows text shaping, fallback, rasterization, and caching.
- D3D11On12 is a compatibility bridge, not the renderer or owner of the device yard.
- Shared publication fences and local presentation fences remain separate.
- `C:\Dev\QuickPS\scripts\tiles.ps1` and `C:\Dev\QuickPS\scripts\desktop.ps1` are tail-end feature-conformance views. Their current implementations, especially the Metro/Windows Phone start menu, are not performance authorities.

## Active next checkpoint

Complete the independent WASAPI endpoint, audio-client, render, and capture pipe without attaching it to the canvas.
# Canvas direct Windows ABI: runtime shader compiler

- Date: 2026-09-13
- Bound `D3DCompile` directly from `d3dcompiler_47.dll` using the private QuickPS ABI substrate.
- Compiled a real `vs_5_0` HLSL entry point successfully.
- Returned bytecode was 492 bytes and began with the expected `DXBC` signature.
- Read and released `ID3DBlob` results through their COM vtables.
- No `DirectPort.PowerShell.dll`, `GpuConsole`, C++, C++/CLI, or custom native DLL participated in this test.

# Canvas direct Windows ABI: packed-cell D3D12 pipeline

- Date: 2026-09-13
- Runtime-compiled `VSMain` and `PSMain` through `d3dcompiler_47.dll`.
- Serialized a two-parameter D3D12 root signature directly through `D3D12SerializeRootSignature`.
- Created live `ID3D12RootSignature` and `ID3D12PipelineState` objects through the corrected device vtable.
- Pixel shader reads the existing packed `uint` cell buffer directly and maps its background byte through the 16-color palette.
- Test result: `PACKED_PIPELINE_OK` with non-null root-signature and pipeline-state pointers.
- No string-grid conversion, atlas, managed renderer, C++ bridge, or custom DLL participated.
