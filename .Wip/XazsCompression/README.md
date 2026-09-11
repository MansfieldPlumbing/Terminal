# Experiment: Pure PowerShell .NET for Android XAZS Assembly Compression

## Executive Summary
This experiment isolates, decodes, and bit-identically reproduces the managed assembly compression transform in .NET for Android (`net11.0-android`, Preview 7).

We have established that .NET for Android in this toolchain uses **Zstandard (Zstd)** compression at **compression level 3**, encapsulated in a 12-byte `XAZS` header.

When the uncompressed assembly bytes from oracle `AndroidSMA.dll` are compressed using this recipe, the output is **BYTE-FOR-BYTE IDENTICAL** to the oracle payload `payload_336_AndroidSMA.dll.bin`:
- Length: 6,829 bytes
- SHA-256: `A37B47E8309141136916DCC79CF00617892CB4DA31311D48655769EC3C66DE84`

## 1. XAZS Binary Header Specification (12 bytes)
All multi-byte fields are little-endian.

- **Offset 0x00..0x03**: Magic ASCII `'XAZS'` (`0x58, 0x41, 0x5A, 0x53`)
- **Offset 0x04..0x07**: uint32 `descriptorIndex`
  - Assigned by the build task `Microsoft.Android.Tasks.CompressAssemblies`
  - For `AndroidSMA.dll` in generation `E85A25C3`, `descriptorIndex = 150` (0x00000096)
- **Offset 0x08..0x0B**: uint32 `uncompressedSize`
  - Exact uncompressed byte length of the PE assembly (13,312 bytes for `AndroidSMA.dll`)
  - Enforced strictly by `libmonodroid.so` at runtime (`assembly-store.cc:605`): if actual decompressed bytes exceed this value, the runtime aborts immediately.
- **Offset 0x0C..end**: Standard Zstandard compressed frame
  - Magic bytes: `0x28, 0xB5, 0x2F, 0xFD` (`0xFD2FB528`)
  - Compression Level: 3 (default for `ZstandardEncoder` and `libzstd`)

## 2. Experimental Proof Receipts

### Oracle Specimen: `payload_336_AndroidSMA.dll.bin`
- **Source**: Extracted from oracle XABA store `3EC2CEF338CD39D5A8B9410052A73EF3E8C924C537DCA4BC2BAF0B95BF2BE741`
- **Compressed Length**: 6,829 bytes
- **SHA-256**: `A37B47E8309141136916DCC79CF00617892CB4DA31311D48655769EC3C66DE84`
- **Decompressed Length**: 13,312 bytes
- **Decompressed Assembly**: `AndroidSMA, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null`
- **Decompressed MVID**: `08a99875-bc00-402d-942e-d24278335806`

### Shadow Reconstruction at Compression Level 3
- **Input**: Decompressed oracle assembly bytes (13,312 bytes)
- **Transform**: Encapsulate with XAZS header (magic + index 150 + size 13312) + `ZSTD_compress(..., level 3)`
- **Output Length**: 6,829 bytes
- **Output SHA-256**: `A37B47E8309141136916DCC79CF00617892CB4DA31311D48655769EC3C66DE84`
- **Identity**: **100% BIT-FOR-BIT IDENTICAL TO ORACLE PAYLOAD**
