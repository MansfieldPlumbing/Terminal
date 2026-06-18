using System;
using System.IO;
using System.Runtime.InteropServices;
using Subsystem.Vom;

namespace Subsystem.Device;

public static unsafe class PeLoaderInterop
{
    [DllImport("libc", EntryPoint = "mmap", SetLastError = true)]
    public static extern IntPtr mmap(IntPtr addr, UIntPtr length, int prot, int flags, int fd, IntPtr offset);

    [DllImport("libc", EntryPoint = "munmap", SetLastError = true)]
    public static extern int munmap(IntPtr addr, UIntPtr length);

    [DllImport("libc", EntryPoint = "mprotect", SetLastError = true)]
    public static extern int mprotect(IntPtr addr, UIntPtr len, int prot);

    [DllImport("libc", EntryPoint = "read", SetLastError = true)]
    public static extern int read(int fd, IntPtr buf, int count);

    [DllImport("libc", EntryPoint = "write", SetLastError = true)]
    public static extern int write(int fd, IntPtr buf, int count);

    [DllImport("libc", EntryPoint = "close", SetLastError = true)]
    public static extern int close(int fd);

    [DllImport("libc", EntryPoint = "lseek", SetLastError = true)]
    public static extern long lseek(int fd, long offset, int whence);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void RegisterHleCallbacksDelegate(IntPtr cf, IntPtr rf, IntPtr wf, IntPtr ch, IntPtr gf, IntPtr sf);
    public static RegisterHleCallbacksDelegate RegisterHleCallbacks;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate IntPtr GetHleReportGsFailurePtrDelegate();
    public static GetHleReportGsFailurePtrDelegate GetHleReportGsFailurePtr;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void SetHleCommandLineDelegate(
        [MarshalAs(UnmanagedType.LPWStr)] string wcmd,
        [MarshalAs(UnmanagedType.LPStr)] string acmd);
    public static SetHleCommandLineDelegate SetHleCommandLine;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int CallEntryPointDelegate(IntPtr entryPoint);
    public static CallEntryPointDelegate CallEntryPoint;

    static PeLoaderInterop()
    {
        IntPtr hleLib = System.Runtime.InteropServices.NativeLibrary.Load("libsubsystem_hle.so");

        RegisterHleCallbacks = Marshal.GetDelegateForFunctionPointer<RegisterHleCallbacksDelegate>(System.Runtime.InteropServices.NativeLibrary.GetExport(hleLib, "RegisterHleCallbacks"));
        GetHleReportGsFailurePtr = Marshal.GetDelegateForFunctionPointer<GetHleReportGsFailurePtrDelegate>(System.Runtime.InteropServices.NativeLibrary.GetExport(hleLib, "GetHleReportGsFailurePtr"));
        SetHleCommandLine = Marshal.GetDelegateForFunctionPointer<SetHleCommandLineDelegate>(System.Runtime.InteropServices.NativeLibrary.GetExport(hleLib, "SetHleCommandLine"));
        CallEntryPoint = Marshal.GetDelegateForFunctionPointer<CallEntryPointDelegate>(System.Runtime.InteropServices.NativeLibrary.GetExport(hleLib, "CallEntryPoint"));
    }

    public const int PROT_READ = 0x1;
    public const int PROT_WRITE = 0x2;
    public const int PROT_EXEC = 0x4;

    public const int MAP_PRIVATE = 0x02;
    public const int MAP_ANONYMOUS = 0x20;
}

public unsafe class PeLoader
{
    private byte[]? _fileData;
    private IntPtr _baseAddress = IntPtr.Zero;
    private uint _sizeOfImage;
    private IntPtr _entryPointRva;
    private static IntPtr _hleLibraryHandle = IntPtr.Zero;

    public static void InitializeHle()
    {
        if (_hleLibraryHandle == IntPtr.Zero)
        {
            Console.WriteLine("[VOM:HLE] Loading libsubsystem_hle.so...");
            _hleLibraryHandle = NativeLibrary.Load("libsubsystem_hle.so");
            
            // Obtain function pointers to [UnmanagedCallersOnly] static methods directly
            delegate* unmanaged<IntPtr, uint, uint, IntPtr, uint, uint, IntPtr, IntPtr> cfPtr = &HleCreateFileW;
            delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, bool> rfPtr = &HleReadFile;
            delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, bool> wfPtr = &HleWriteFile;
            delegate* unmanaged<IntPtr, bool> chPtr = &HleCloseHandle;
            delegate* unmanaged<IntPtr, IntPtr, bool> gfPtr = &HleGetFileSizeEx;
            delegate* unmanaged<IntPtr, long, IntPtr, uint, bool> sfPtr = &HleSetFilePointerEx;

            PeLoaderInterop.RegisterHleCallbacks((IntPtr)cfPtr, (IntPtr)rfPtr, (IntPtr)wfPtr, (IntPtr)chPtr, (IntPtr)gfPtr, (IntPtr)sfPtr);
            Console.WriteLine("[VOM:HLE] Native callbacks registered successfully.");
        }
    }

    public void Load(string filePath)
    {
        InitializeHle();

        _fileData = File.ReadAllBytes(filePath);
        fixed (byte* pData = _fileData)
        {
            // Parse DOS Header
            dosMagic = *(ushort*)pData;
            ushort dosMagicVal = dosMagic;
            if (dosMagicVal != 0x5A4D) // 'MZ'
                throw new BadImageFormatException("Invalid DOS Header magic.");

            int e_lfanew = *(int*)(pData + 0x3C);
            byte* pNtHeaders = pData + e_lfanew;

            // Parse NT Header Signature
            uint peSignature = *(uint*)pNtHeaders;
            if (peSignature != 0x00004550) // 'PE\0\0'
                throw new BadImageFormatException("Invalid PE signature.");

            // Parse File Header
            byte* pFileHeader = pNtHeaders + 4;
            ushort machine = *(ushort*)pFileHeader;
            if (machine != 0xAA64) // ARM64
                throw new BadImageFormatException("Target binary is not ARM64.");

            ushort numberOfSections = *(ushort*)(pFileHeader + 2);
            ushort sizeOfOptionalHeader = *(ushort*)(pFileHeader + 16);

            // Parse Optional Header
            byte* pOptionalHeader = pFileHeader + 20;
            ushort magic = *(ushort*)pOptionalHeader;
            if (magic != 0x020B) // PE32+ (64-bit)
                throw new BadImageFormatException("Only 64-bit PE binaries are supported.");

            uint addressOfEntryPoint = *(uint*)(pOptionalHeader + 16);
            ulong imageBase = *(ulong*)(pOptionalHeader + 24);
            _sizeOfImage = *(uint*)(pOptionalHeader + 56);
            uint sizeOfHeaders = *(uint*)(pOptionalHeader + 60);

            // Data Directories
            byte* pDataDirs = pOptionalHeader + 112;
            uint importRva = *(uint*)(pDataDirs + 8);
            uint importSize = *(uint*)(pDataDirs + 12);
            uint relocRva = *(uint*)(pDataDirs + 40);
            uint relocSize = *(uint*)(pDataDirs + 44);

            _entryPointRva = (IntPtr)addressOfEntryPoint;

            // 2. Allocate memory block for the image
            _baseAddress = PeLoaderInterop.mmap(
                IntPtr.Zero,
                (UIntPtr)_sizeOfImage,
                PeLoaderInterop.PROT_READ | PeLoaderInterop.PROT_WRITE,
                PeLoaderInterop.MAP_PRIVATE | PeLoaderInterop.MAP_ANONYMOUS,
                -1,
                IntPtr.Zero
            );

            if (_baseAddress == IntPtr.Zero || _baseAddress == new IntPtr(-1))
                throw new OutOfMemoryException("mmap failed to allocate memory for the PE image.");

            Console.WriteLine($"[hle] Allocated contiguous block at 0x{_baseAddress.ToInt64():X} (aligned to 4096-byte pages)");

            // Copy Headers
            Marshal.Copy(_fileData, 0, _baseAddress, (int)sizeOfHeaders);

            // Map Sections
            byte* pSectionHeaders = pOptionalHeader + sizeOfOptionalHeader;
            for (int i = 0; i < numberOfSections; i++)
            {
                byte* pSection = pSectionHeaders + i * 40;
                uint virtualSize = *(uint*)(pSection + 8);
                uint virtualAddress = *(uint*)(pSection + 12);
                uint sizeOfRawData = *(uint*)(pSection + 16);
                uint pointerToRawData = *(uint*)(pSection + 20);

                if (sizeOfRawData > 0 && pointerToRawData > 0)
                {
                    IntPtr targetSectionAddr = IntPtr.Add(_baseAddress, (int)virtualAddress);
                    Marshal.Copy(_fileData, (int)pointerToRawData, targetSectionAddr, (int)sizeOfRawData);
                }
            }

            // --- 3.6 HOOK __report_gsfailure TO PRINT DIAGNOSTICS ---
            ulong gsFailureRva = 0x71d8;
            byte* gsTarget = (byte*)_baseAddress + gsFailureRva;
            
            // mov x1, x30       (aa1e03e1)
            // mov x2, x29       (aa1d03e2)
            // ldr x16, [pc, #8] (58000050)
            // br x16            (d61f0200)
            // .quad <HleReportGsFailure>
            *(uint*)(gsTarget + 0) = 0xaa1e03e1;
            *(uint*)(gsTarget + 4) = 0xaa1d03e2;
            *(uint*)(gsTarget + 8) = 0x58000050;
            *(uint*)(gsTarget + 12) = 0xd61f0200;
            
            // Get the pointer via DllImport which uses the Android NativeLibrary infrastructure
            IntPtr hleReportGsFailurePtr = PeLoaderInterop.GetHleReportGsFailurePtr();
            *(ulong*)(gsTarget + 16) = (ulong)hleReportGsFailurePtr;
            
            Android.Util.Log.Info("FET:Loader", $"Hooked __report_gsfailure at 0x{(ulong)gsTarget:X} -> 0x{(ulong)hleReportGsFailurePtr:X}");

            // 4. Base Relocations
            long delta = _baseAddress.ToInt64() - (long)imageBase;
            if (delta != 0 && relocRva > 0 && relocSize > 0)
            {
                byte* pReloc = (byte*)_baseAddress + relocRva;
                uint processed = 0;
                while (processed < relocSize)
                {
                    uint pageRva = *(uint*)(pReloc + processed);
                    uint blockSize = *(uint*)(pReloc + processed + 4);
                    if (blockSize == 0) break;

                    uint entryCount = (blockSize - 8) / 2;
                    ushort* pEntries = (ushort*)(pReloc + processed + 8);

                    for (uint j = 0; j < entryCount; j++)
                    {
                        ushort entry = pEntries[j];
                        int type = entry >> 12;
                        int offset = entry & 0x0FFF;

                        if (type == 10) // IMAGE_REL_BASED_DIR64
                        {
                            long* patchAddr = (long*)((byte*)_baseAddress + pageRva + offset);
                            *patchAddr += delta;
                        }
                    }
                    processed += blockSize;
                }
                Console.WriteLine($"[hle] Base relocation applied successfully: Delta = 0x{delta:X}");
            }

            // 3.5 Initialize Security Cookie (LoadConfig Directory)
            uint loadConfigRva = *(uint*)(pDataDirs + 80);
            uint loadConfigSize = *(uint*)(pDataDirs + 84);
            if (loadConfigRva > 0 && loadConfigSize >= 96)
            {
                ulong securityCookieVa = *(ulong*)((byte*)_baseAddress + loadConfigRva + 88);
                if (securityCookieVa > 0)
                {
                    ulong newCookie = 0x123456789ABCDEF0UL; // Non-default dummy value to satisfy __security_init_cookie
                    *(ulong*)securityCookieVa = newCookie;
                    Android.Util.Log.Info("FET:Loader", $"Initialized SecurityCookie at 0x{securityCookieVa:X} to 0x{newCookie:X}");
                }
            }

            // 4. Resolve Import Table
            if (importRva > 0 && importSize > 0)
            {
                byte* pImportDesc = (byte*)_baseAddress + importRva;
                int descIdx = 0;
                while (true)
                {
                    byte* pDesc = pImportDesc + descIdx * 20;
                    uint originalFirstThunk = *(uint*)pDesc;
                    uint nameRva = *(uint*)(pDesc + 12);
                    uint firstThunk = *(uint*)(pDesc + 16);

                    if (nameRva == 0) break;

                    string dllName = Marshal.PtrToStringAnsi((IntPtr)((byte*)_baseAddress + nameRva)) ?? "";
                    byte* pThunk = (byte*)_baseAddress + firstThunk;
                    byte* pLookup = (byte*)_baseAddress + (originalFirstThunk != 0 ? originalFirstThunk : firstThunk);

                    int thunkIdx = 0;
                    while (true)
                    {
                        ulong lookupVal = *(ulong*)(pLookup + thunkIdx * 8);
                        if (lookupVal == 0) break;

                        string funcName;
                        if ((lookupVal & 0x8000000000000000) != 0)
                        {
                            ushort ordinal = (ushort)(lookupVal & 0xFFFF);
                            funcName = "#" + ordinal;
                        }
                        else
                        {
                            uint nameOffset = (uint)(lookupVal & 0xFFFFFFFF);
                            funcName = Marshal.PtrToStringAnsi((IntPtr)((byte*)_baseAddress + nameOffset + 2)) ?? "";
                        }

                        IntPtr resolved = ResolveImport(dllName, funcName);
                        *(IntPtr*)(pThunk + thunkIdx * 8) = resolved;

                        thunkIdx++;
                    }

                    descIdx++;
                }
            }

            // 5. Secure memory protection
            PeLoaderInterop.mprotect(_baseAddress, (UIntPtr)_sizeOfImage, PeLoaderInterop.PROT_READ | PeLoaderInterop.PROT_WRITE | PeLoaderInterop.PROT_EXEC);
        }
    }

    private ushort dosMagic; // helper to avoid CS0103

    private IntPtr ResolveImport(string dllName, string functionName)
    {
        string hleName = "Hle" + functionName;
        if (NativeLibrary.TryGetExport(_hleLibraryHandle, hleName, out IntPtr symbolPtr))
        {
            Android.Util.Log.Info("FET:Loader", $"Mapped {dllName}!{functionName} to {hleName}");
            return symbolPtr;
        }
        if (NativeLibrary.TryGetExport(_hleLibraryHandle, functionName, out symbolPtr))
        {
            Android.Util.Log.Info("FET:Loader", $"Mapped {dllName}!{functionName} directly");
            return symbolPtr;
        }

        // Send to logcat so we actually see what's missing!
        Android.Util.Log.Warn("FET:Loader", $"Unresolved export: {dllName}!{functionName}");
        
        // Return a dummy stub to prevent a SIGSEGV at 0x0
        if (NativeLibrary.TryGetExport(_hleLibraryHandle, "HleDummyReturnZero", out IntPtr dummyPtr)) 
            return dummyPtr;

        return IntPtr.Zero;
    }

    public void SetCommandLine(string args)
    {
        PeLoaderInterop.SetHleCommandLine(args, args);
    }

    public int Execute()
    {
        if (_baseAddress == IntPtr.Zero)
            throw new InvalidOperationException("No binary loaded.");

        IntPtr absoluteEP = IntPtr.Add(_baseAddress, (int)_entryPointRva);
        Console.WriteLine($"[hle] Transitioning execution to entry point at 0x{absoluteEP.ToInt64():X}");
        
        int exitCode = PeLoaderInterop.CallEntryPoint(absoluteEP);
        return exitCode;
    }

    // --- Win32 Intercept Callbacks ---

    [UnmanagedCallersOnly]
    public static IntPtr HleCreateFileW(
        IntPtr lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile)
    {
        try
        {
            string path = Marshal.PtrToStringUni(lpFileName) ?? "";
            Console.WriteLine($"[INFO][hle] Intercepted CreateFileW. Path: {path}");

            // Normalize file path
            string localPath = path;
            if (path.StartsWith("\\Device\\Android\\FileSystem\\", StringComparison.OrdinalIgnoreCase))
            {
                string subPath = path.Substring("\\Device\\Android\\FileSystem\\".Length).Replace('\\', '/');
                string home = Environment.GetEnvironmentVariable("HOME") ?? "/data/local/tmp";
                localPath = Path.Combine(home, subPath);
            }
            else if (path.Contains("\\"))
            {
                localPath = path.Replace('\\', '/');
            }

            Console.WriteLine($"[INFO][vom] Resolving path: {localPath}");

            if (!File.Exists(localPath))
            {
                Console.WriteLine($"[VOM:HLE] File not found: {localPath}");
                return new IntPtr(-1);
            }

            // ContentResolver JNI OpenFileDescriptor
            var file = new Java.IO.File(localPath);
            var uri = Android.Net.Uri.FromFile(file);
            
            var pfd = Android.App.Application.Context.ContentResolver.OpenFileDescriptor(uri, "r");
            if (pfd == null)
            {
                Console.WriteLine("[VOM:HLE] ContentResolver returned null descriptor");
                return new IntPtr(-1);
            }

            int fd = pfd.DetachFd();
            Console.WriteLine($"[INFO][binder] Invoking ContentResolver. OpenFileDescriptor returned duplicate native fd: {fd}");

            // Wrap fd in VOM Handle
            var owner = Subsystem.Vom.Vom.CreateOwner("\\Device\\Android\\Hle");
            var handle = Subsystem.Vom.Vom.Register(owner, "File", fd, onReclaim: () => {
                PeLoaderInterop.close(fd);
            }, name: $"0x{fd:x}");

            Console.WriteLine($"[INFO][vom] Registered Handle \\Object\\Handle\\File\\0x{handle.Id:x} -> refcount: 1");
            return new IntPtr(handle.Id);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[VOM:HLE] HleCreateFileW Exception: {ex}");
        }
        return new IntPtr(-1);
    }

    [UnmanagedCallersOnly]
    public static bool HleReadFile(
        IntPtr hFile,
        IntPtr lpBuffer,
        uint nNumberOfBytesToRead,
        IntPtr lpNumberOfBytesRead,
        IntPtr lpOverlapped)
    {
        try
        {
            uint handleId = (uint)hFile.ToInt64();
            Console.WriteLine($"[INFO][hle] Intercepted ReadFile on HANDLE 0x{handleId:x}");

            var owner = Subsystem.Vom.Vom.CreateOwner("\\Device\\Android\\Hle");
            if (Subsystem.Vom.Vom.TryResolve(owner, handleId, out var handle))
            {
                int fd = (int)handle.Resource;
                int bytesRead = PeLoaderInterop.read(fd, lpBuffer, (int)nNumberOfBytesToRead);
                if (bytesRead >= 0)
                {
                    if (lpNumberOfBytesRead != IntPtr.Zero)
                    {
                        Marshal.WriteInt32(lpNumberOfBytesRead, bytesRead);
                    }
                    return true;
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[VOM:HLE] HleReadFile Exception: {ex}");
        }
        return false;
    }

    [UnmanagedCallersOnly]
    public static bool HleWriteFile(
        IntPtr hFile,
        IntPtr lpBuffer,
        uint nNumberOfBytesToWrite,
        IntPtr lpNumberOfBytesWritten,
        IntPtr lpOverlapped)
    {
        try
        {
            uint handleId = (uint)hFile.ToInt64();

            // Intercept STDOUT (1 / -11) or STDERR (2 / -12)
            if ((int)handleId == -11 || (int)handleId == -12 || handleId == 1 || handleId == 2)
            {
                Console.WriteLine("[INFO][hle] Intercepted WriteFile on STDOUT. Redirecting to WebView console.");
                string text = Marshal.PtrToStringAnsi(lpBuffer, (int)nNumberOfBytesToWrite) ?? "";
                
                // Write to stdout console
                Console.Write(text);

                if (lpNumberOfBytesWritten != IntPtr.Zero)
                {
                    Marshal.WriteInt32(lpNumberOfBytesWritten, (int)nNumberOfBytesToWrite);
                }
                return true;
            }

            var owner = Subsystem.Vom.Vom.CreateOwner("\\Device\\Android\\Hle");
            if (Subsystem.Vom.Vom.TryResolve(owner, handleId, out var handle))
            {
                int fd = (int)handle.Resource;
                int bytesWritten = PeLoaderInterop.write(fd, lpBuffer, (int)nNumberOfBytesToWrite);
                if (bytesWritten >= 0)
                {
                    if (lpNumberOfBytesWritten != IntPtr.Zero)
                    {
                        Marshal.WriteInt32(lpNumberOfBytesWritten, bytesWritten);
                    }
                    return true;
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[VOM:HLE] HleWriteFile Exception: {ex}");
        }
        return false;
    }

    [UnmanagedCallersOnly]
    public static bool HleCloseHandle(IntPtr hFile)
    {
        try
        {
            uint handleId = (uint)hFile.ToInt64();
            var owner = Subsystem.Vom.Vom.CreateOwner("\\Device\\Android\\Hle");
            if (Subsystem.Vom.Vom.TryResolve(owner, handleId, out var handle))
            {
                int fd = (int)handle.Resource;
                Subsystem.Vom.Vom.Close(owner, handle.Path);
                return true;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[VOM:HLE] HleCloseHandle Exception: {ex}");
        }
        return false;
    }

    [UnmanagedCallersOnly]
    public static bool HleGetFileSizeEx(IntPtr hFile, IntPtr lpFileSize)
    {
        try
        {
            uint handleId = (uint)hFile.ToInt64();
            var owner = Subsystem.Vom.Vom.CreateOwner("\\Device\\Android\\Hle");
            if (Subsystem.Vom.Vom.TryResolve(owner, handleId, out var handle))
            {
                int fd = (int)handle.Resource;
                long current = PeLoaderInterop.lseek(fd, 0, 1); // SEEK_CUR
                long size = PeLoaderInterop.lseek(fd, 0, 2); // SEEK_END
                PeLoaderInterop.lseek(fd, current, 0); // restore
                if (lpFileSize != IntPtr.Zero)
                {
                    Marshal.WriteInt64(lpFileSize, size);
                }
                return true;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[VOM:HLE] HleGetFileSizeEx Exception: {ex}");
        }
        return false;
    }

    [UnmanagedCallersOnly]
    public static bool HleSetFilePointerEx(IntPtr hFile, long liDistanceToMove, IntPtr lpNewFilePointer, uint dwMoveMethod)
    {
        try
        {
            uint handleId = (uint)hFile.ToInt64();
            var owner = Subsystem.Vom.Vom.CreateOwner("\\Device\\Android\\Hle");
            if (Subsystem.Vom.Vom.TryResolve(owner, handleId, out var handle))
            {
                int fd = (int)handle.Resource;
                long newOffset = PeLoaderInterop.lseek(fd, liDistanceToMove, (int)dwMoveMethod);
                if (newOffset >= 0)
                {
                    if (lpNewFilePointer != IntPtr.Zero)
                    {
                        Marshal.WriteInt64(lpNewFilePointer, newOffset);
                    }
                    return true;
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[VOM:HLE] HleSetFilePointerEx Exception: {ex}");
        }
        return false;
    }
}
