# Build dependencies and APK signing

This document records what the build scripts actually execute. It is based on
the command expressions in `Build-AndroidSMA.ps1` and every PowerShell script
directly under `Scripts/`, rather than on inferred requirements from the
README.

## External executables

The following list is complete for that scope as of this revision.

| Executable | Invocation | Purpose |
| --- | --- | --- |
| `llvm-mc` | `Build-AndroidSMA.ps1:462`, `Build-AndroidSMA.ps1:467` | Assembles the generated assembly-store source into an Android ARM64 or ARM32 object file. |
| `ld` | `Build-AndroidSMA.ps1:464`, `Build-AndroidSMA.ps1:469` | Links that object into `libassembly-store.so` and exports `_assembly_store`. |
| `javac` | `Build-AndroidSMA.ps1:922` | Compiles the generated Android activity and resource Java sources. |
| `d8` | `Build-AndroidSMA.ps1:935` | Lowers the compiled Java classes and required runtime JARs into `classes.dex`. |
| `dotnet` | `Scripts/Install-AndroidWorkload.ps1:99` | Queries the NuGet global-packages location with `dotnet nuget locals global-packages --list`. |

`Build-AndroidSMA.ps1:96` also invokes `Scripts/Emit-AndroidSMA.ps1`, but that is
a repository script executed by the current PowerShell process, not an
external executable.

The main build accepts explicit paths for `llvm-mc`, `ld`, `javac`, and `d8`.
It otherwise discovers them through `PATH` and the configured .NET, Java, and
Android SDK roots. The Android SDK root can be supplied with
`-AndroidSdkRoot` or through `ANDROID_SDK_ROOT`/`ANDROID_HOME`; the .NET root
can be supplied with `-DotnetRoot` or through `DOTNET_ROOT`/the active
`dotnet` command. Missing tools or roots stop the build with an actionable
error. No developer-specific SDK path is an implicit fallback.

The build also consumes SDK and runtime files rather than executing them:
`android.jar`, `mono.android.jar`, `java_runtime_clr.jar`, the Android
cryptography runtime JAR, and `libzstd.dll`. The Zstandard library can be
provided with `-ZstdLibraryPath`, through `ZSTD_LIBRARY`, or through `PATH`.

## APK signing status

The produced APK is signed. The build first writes an explicitly named
`*-Unsigned.apk` intermediate at `Build-AndroidSMA.ps1:1303-1305`, then creates
`*-Signed.apk` and adds an APK Signature Scheme v2 signing block.

The signing implementation:

- loads the Xamarin Android debug keystore as an X.509 certificate at line
  1321;
- obtains its RSA private key at line 1322;
- uses SHA-256 with RSA (`0x0103`) at line 1365;
- writes the APK v2 block identifier `0x7109871a` at line 1389; and
- writes the `APK Sig Block 42` footer at line 1395.

No code in the audited scripts writes or references `META-INF/MANIFEST.MF` or
`CERT.SF`. Consequently, the build implements APK Signature Scheme v2, not a
v1/JAR signature. It does not implement v3 or v4 signing. This pass documents
the existing signing behavior and does not add or replace any signing code.
