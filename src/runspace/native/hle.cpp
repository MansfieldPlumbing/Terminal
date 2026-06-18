#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <pthread.h>
#include <setjmp.h>
#include <string.h>
#include <wchar.h>
#include <malloc.h>
#include <time.h>
#include <android/log.h>
#include <mutex>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "FET:Native", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "FET:Native", __VA_ARGS__)

// Rename shims to avoid symbol clashes with host libraries (like libcoreclr.so)
#define VirtualAlloc HleVirtualAlloc
#define VirtualFree HleVirtualFree
#define GetCurrentProcessId HleGetCurrentProcessId
#define CreateFileW HleCreateFileW
#define ReadFile HleReadFile
#define WriteFile HleWriteFile
#define CloseHandle HleCloseHandle
#define GetStdHandle HleGetStdHandle
#define GetCommandLineW HleGetCommandLineW
#define GetCommandLineA HleGetCommandLineA
#define MessageBoxW HleMessageBoxW
#define ExitProcess HleExitProcess
#define GetLastError HleGetLastError
#define SetLastError HleSetLastError
#define LocalAlloc HleLocalAlloc
#define LocalFree HleLocalFree
#define GetModuleHandleW HleGetModuleHandleW
#define GetModuleHandleA HleGetModuleHandleA
#define GetFileSizeEx HleGetFileSizeEx
#define SetFilePointerEx HleSetFilePointerEx
#define SetConsoleMode HleSetConsoleMode
#define GetNumberOfConsoleInputEvents HleGetNumberOfConsoleInputEvents
#define ReadConsoleInputW HleReadConsoleInputW
#define PeekConsoleInputA HlePeekConsoleInputA
#define ReadConsoleW HleReadConsoleW
#define GetStringTypeW HleGetStringTypeW
#define RegOpenKeyExW HleRegOpenKeyExW
#define RegOpenKeyExA HleRegOpenKeyExA
#define RegOpenKeyA HleRegOpenKeyA
#define RegCreateKeyA HleRegCreateKeyA
#define RegQueryValueExW HleRegQueryValueExW
#define RegQueryValueExA HleRegQueryValueExA
#define RegSetValueExA HleRegSetValueExA
#define RegCloseKey HleRegCloseKey
#define LoadCursorA HleLoadCursorA
#define InflateRect HleInflateRect
#define GetSysColorBrush HleGetSysColorBrush
#define SetCursor HleSetCursor
#define SetWindowTextA HleSetWindowTextA
#define GetDlgItem HleGetDlgItem
#define EndDialog HleEndDialog
#define DialogBoxIndirectParamA HleDialogBoxIndirectParamA
#define SendMessageA HleSendMessageA
#define StartPage HleStartPage
#define EndDoc HleEndDoc
#define StartDocA HleStartDocA
#define SetMapMode HleSetMapMode
#define GetDeviceCaps HleGetDeviceCaps
#define EndPage HleEndPage
#define PrintDlgA HlePrintDlgA
#define InitializeCriticalSection HleInitializeCriticalSection
#define InitializeCriticalSectionAndSpinCount HleInitializeCriticalSectionAndSpinCount
#define InitializeCriticalSectionEx HleInitializeCriticalSectionEx
#define EnterCriticalSection HleEnterCriticalSection
#define LeaveCriticalSection HleLeaveCriticalSection
#define DeleteCriticalSection HleDeleteCriticalSection
#define GetProcessHeap HleGetProcessHeap
#define HeapAlloc HleHeapAlloc
#define HeapFree HleHeapFree
#define HeapReAlloc HleHeapReAlloc
#define HeapSize HleHeapSize
#define IsProcessorFeaturePresent HleIsProcessorFeaturePresent
#define TlsAlloc HleTlsAlloc
#define TlsGetValue HleTlsGetValue
#define TlsSetValue HleTlsSetValue
#define TlsFree HleTlsFree
#define FlsAlloc HleFlsAlloc
#define FlsGetValue HleFlsGetValue
#define FlsSetValue HleFlsSetValue
#define FlsFree HleFlsFree
#define InitializeSListHead HleInitializeSListHead
#define InterlockedPushEntrySList HleInterlockedPushEntrySList
#define InterlockedPopEntrySList HleInterlockedPopEntrySList
#define InterlockedFlushSList HleInterlockedFlushSList
#define EncodePointer HleEncodePointer
#define DecodePointer HleDecodePointer
#define RaiseException HleRaiseException
#define RtlRaiseException HleRtlRaiseException
#define RtlLookupFunctionEntry HleRtlLookupFunctionEntry
#define RtlPcToFileHeader HleRtlPcToFileHeader
#define RtlUnwindEx HleRtlUnwindEx
#define RtlUnwind HleRtlUnwind
#define QueryPerformanceCounter HleQueryPerformanceCounter
#define GetSystemTimeAsFileTime HleGetSystemTimeAsFileTime
#define GetCurrentThreadId HleGetCurrentThreadId
#define GetEnvironmentStringsW HleGetEnvironmentStringsW
#define FreeEnvironmentStringsW HleFreeEnvironmentStringsW
#define GetStartupInfoW HleGetStartupInfoW
#define SetStdHandle HleSetStdHandle
#define TerminateProcess HleTerminateProcess
#define FreeLibrary HleFreeLibrary
#define GetModuleHandleExW HleGetModuleHandleExW
#define GetFileType HleGetFileType
#define GetConsoleCP HleGetConsoleCP
#define GetConsoleOutputCP HleGetConsoleOutputCP
#define GetConsoleMode HleGetConsoleMode
#define FlushFileBuffers HleFlushFileBuffers
#define WideCharToMultiByte HleWideCharToMultiByte
#define MultiByteToWideChar HleMultiByteToWideChar
#define WriteConsoleW HleWriteConsoleW
#define GetCurrentProcess HleGetCurrentProcess
#define SetUnhandledExceptionFilter HleSetUnhandledExceptionFilter
#define OutputDebugStringW HleOutputDebugStringW
#define IsDebuggerPresent HleIsDebuggerPresent
#define GetProcAddress HleGetProcAddress
#define GetModuleFileNameW HleGetModuleFileNameW
#define GetModuleFileNameA HleGetModuleFileNameA
#define SetEnvironmentVariableW HleSetEnvironmentVariableW
#define SetConsoleCtrlHandler HleSetConsoleCtrlHandler
#define FindClose HleFindClose
#define CompareStringW HleCompareStringW
#define LCMapStringW HleLCMapStringW
#define GetLocaleInfoW HleGetLocaleInfoW
#define IsValidLocale HleIsValidLocale
#define GetUserDefaultLCID HleGetUserDefaultLCID
#define EnumSystemLocalesW HleEnumSystemLocalesW
#define GetCurrentThread HleGetCurrentThread
#define GetCPInfo HleGetCPInfo
#define GetOEMCP HleGetOEMCP
#define GetACP HleGetACP
#define IsValidCodePage HleIsValidCodePage
#define FormatMessageA HleFormatMessageA
#define FindFirstFileA HleFindFirstFileA
#define FindNextFileA HleFindNextFileA
#define FindFirstFileExW HleFindFirstFileExW
#define FindNextFileW HleFindNextFileW
#define GetFullPathNameA HleGetFullPathNameA
#define SetFilePointer HleSetFilePointer
#define GetFileVersionInfoSizeW HleGetFileVersionInfoSizeW
#define GetFileVersionInfoSizeA HleGetFileVersionInfoSizeA
#define GetFileVersionInfoW HleGetFileVersionInfoW
#define GetFileVersionInfoA HleGetFileVersionInfoA
#define VerQueryValueW HleVerQueryValueW
#define VerQueryValueA HleVerQueryValueA
#define GetVersionExA HleGetVersionExA
#define LoadLibraryExW HleLoadLibraryExW
#define LoadLibraryExA HleLoadLibraryExA
#define GetCurrentDirectoryA HleGetCurrentDirectoryA
#define CreateFileA HleCreateFileA
#define GetDateFormatW HleGetDateFormatW
#define GetTimeFormatW HleGetTimeFormatW

typedef void* HANDLE;
typedef uint32_t DWORD;
typedef uint32_t UINT;

// Win32 Thread Environment Block (TEB) fake structure
struct FakeTeb {
    void* ExceptionList;             // 0x00
    void* StackBase;                 // 0x08
    void* StackLimit;                // 0x10
    void* SubSystemTib;              // 0x18
    void* FiberData;                 // 0x20
    void* ArbitraryUserPointer;      // 0x28
    FakeTeb* Self;                   // 0x30
    void* EnvironmentPointer;        // 0x38
    uint64_t UniqueProcess;          // 0x40
    uint64_t UniqueThread;           // 0x48
    void* ActiveRpcHandle;           // 0x50
    void* ThreadLocalStoragePointer; // 0x58
    
    uint8_t Padding[0x1480 - 0x60];
    void* TlsSlots[64];              // 0x1480
    
    // Static TLS simulation
    void* StaticTlsArray[64];
    void* StaticTlsBlocks[64];
};

jmp_buf g_ExitBuf;
int g_ExitCode = 0;

static wchar_t* g_CommandLineW = nullptr;
static char* g_CommandLineA = nullptr;

class ScopedBionicContext {
private:
    uintptr_t saved_teb;
    bool swapped;
public:
    ScopedBionicContext() : saved_teb(0), swapped(false) {
        uintptr_t current_x18;
        asm volatile("mov %0, x18" : "=r"(current_x18));
        if (current_x18 > 0x1000) {
            FakeTeb* teb = (FakeTeb*)current_x18;
            if (teb->Self == teb) {
                saved_teb = current_x18;
                uintptr_t scs = (uintptr_t)teb->ArbitraryUserPointer;
                asm volatile("mov x18, %0" : : "r"(scs));
                swapped = true;
            }
        }
    }
    ~ScopedBionicContext() {
        if (swapped) {
            asm volatile("mov x18, %0" : : "r"(saved_teb));
        }
    }
};

__attribute__((constructor)) void InitializeFidelity() {
    LOGI("Ghost Environment Initialized.");
}

typedef HANDLE (*CreateFileW_t)(const wchar_t* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
typedef bool (*ReadFile_t)(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
typedef bool (*WriteFile_t)(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
typedef bool (*CloseHandle_t)(HANDLE hObject);
typedef bool (*GetFileSizeEx_t)(HANDLE hFile, int64_t* lpFileSize);
typedef bool (*SetFilePointerEx_t)(HANDLE hFile, int64_t liDistanceToMove, int64_t* lpNewFilePointer, DWORD dwMoveMethod);

// Win32 Critical Section mapping structure
struct HleCriticalSection {
    pthread_mutex_t mutex;
};

// Win32 Singly-Linked List structures
// We treat SLIST_HEADER as a 128-bit integer for lock-free atomic operations.
// SLIST_ENTRY has a single pointer.
struct HleSListEntry {
    HleSListEntry* Next;
};

extern "C" {
    __attribute__((visibility("default"))) void* HleDummyReturnZero() {
        LOGE("HleDummyReturnZero called! Returning 0 to prevent SIGSEGV at PC=0.");
        return nullptr;
    }

    __attribute__((visibility("default"))) bool HleIsProcessorFeaturePresent(DWORD ProcessorFeature) {
        LOGI("IsProcessorFeaturePresent called: %u", ProcessorFeature);
        return false;
    }

    static CreateFileW_t g_CreateFileW = nullptr;
    static ReadFile_t g_ReadFile = nullptr;
    static WriteFile_t g_WriteFile = nullptr;
    static CloseHandle_t g_CloseHandle = nullptr;
    static GetFileSizeEx_t g_GetFileSizeEx = nullptr;
    static SetFilePointerEx_t g_SetFilePointerEx = nullptr;

    __attribute__((visibility("default"))) void RegisterHleCallbacks(
        CreateFileW_t cf, ReadFile_t rf, WriteFile_t wf, CloseHandle_t ch,
        GetFileSizeEx_t gf, SetFilePointerEx_t sf) {
        g_CreateFileW = cf;
        g_ReadFile = rf;
        g_WriteFile = wf;
        g_CloseHandle = ch;
        g_GetFileSizeEx = gf;
        g_SetFilePointerEx = sf;
    }

    __attribute__((visibility("default"))) void SetHleCommandLine(const wchar_t* wcmd, const char* acmd) {
        if (g_CommandLineW) free((void*)g_CommandLineW);
        if (g_CommandLineA) free((void*)g_CommandLineA);
        g_CommandLineW = wcmd ? wcsdup(wcmd) : nullptr;
        g_CommandLineA = acmd ? strdup(acmd) : nullptr;
    }

    __attribute__((visibility("default"))) int CallEntryPoint(void (*ep)()) {
        FakeTeb* teb = (FakeTeb*)calloc(1, sizeof(FakeTeb));
        teb->Self = teb;
        teb->ThreadLocalStoragePointer = teb->StaticTlsArray;
        
        for (int i = 0; i < 64; i++) {
            teb->StaticTlsArray[i] = &teb->StaticTlsBlocks[i];
        }
        
        uintptr_t saved_scs;
        asm volatile("mov %0, x18" : "=r"(saved_scs));
        teb->ArbitraryUserPointer = (void*)saved_scs;
        asm volatile("mov x18, %0" : : "r"((uintptr_t)teb));
        
        int ret = 0;
        if (setjmp(g_ExitBuf) == 0) {
            LOGI("CallEntryPoint: calling ep()...");
            ep();
            LOGI("CallEntryPoint: ep() returned successfully!");
            ret = 0;
        } else {
            LOGI("CallEntryPoint: setjmp returned non-zero (ExitCode: %d)", g_ExitCode);
            ret = g_ExitCode;
        }
        
        asm volatile("mov x18, %0" : : "r"(saved_scs));
        free(teb);
        return ret;
    }

    __attribute__((visibility("default"))) void* VirtualAlloc(void* lpAddress, size_t dwSize, DWORD flAllocationType, DWORD flProtect) {
        ScopedBionicContext ctx;
        long pageSize = sysconf(_SC_PAGESIZE);
        size_t alignedSize = (dwSize + pageSize - 1) & ~(pageSize - 1);
        
        LOGI("Intercepted VirtualAlloc! Requested: %zu bytes, Padded to: %zu bytes", dwSize, alignedSize);

        int prot = PROT_READ | PROT_WRITE; 
        int flags = MAP_PRIVATE | MAP_ANONYMOUS;
        
        void* result = mmap(lpAddress, alignedSize, prot, flags, -1, 0);
        return (result == MAP_FAILED) ? nullptr : result;
    }

    __attribute__((visibility("default"))) bool VirtualFree(void* lpAddress, size_t dwSize, DWORD dwFreeType) {
        ScopedBionicContext ctx;
        LOGI("Intercepted VirtualFree!");
        return munmap(lpAddress, dwSize) == 0;
    }

    __attribute__((visibility("default"))) DWORD GetCurrentProcessId() { 
        ScopedBionicContext ctx;
        DWORD pid = (DWORD)getpid();
        LOGI("GetCurrentProcessId called -> %u", pid);
        return pid;
    }

    __attribute__((visibility("default"))) HANDLE CreateFileW(const wchar_t* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile) {
        ScopedBionicContext ctx;
        LOGI("CreateFileW called! File: %ls", lpFileName);
        if (g_CreateFileW) {
            return g_CreateFileW(lpFileName, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
        }
        return (HANDLE)(intptr_t)-1;
    }

    __attribute__((visibility("default"))) bool ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped) {
        ScopedBionicContext ctx;
        LOGI("ReadFile called! hFile: %p, bytes: %u", hFile, nNumberOfBytesToRead);
        if (g_ReadFile) {
            return g_ReadFile(hFile, lpBuffer, nNumberOfBytesToRead, lpNumberOfBytesRead, lpOverlapped);
        }
        return false;
    }

    __attribute__((visibility("default"))) bool WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped) {
        ScopedBionicContext ctx;
        LOGI("WriteFile called! hFile: %p, bytes: %u", hFile, nNumberOfBytesToWrite);
        if (g_WriteFile) {
            return g_WriteFile(hFile, lpBuffer, nNumberOfBytesToWrite, lpNumberOfBytesWritten, lpOverlapped);
        }
        return false;
    }

    __attribute__((visibility("default"))) bool CloseHandle(HANDLE hObject) {
        ScopedBionicContext ctx;
        LOGI("CloseHandle called! hObject: %p", hObject);
        if (g_CloseHandle) {
            return g_CloseHandle(hObject);
        }
        return false;
    }

    __attribute__((visibility("default"))) HANDLE GetStdHandle(DWORD nStdHandle) {
        ScopedBionicContext ctx;
        LOGI("GetStdHandle called! nStdHandle: %u", nStdHandle);
        return (HANDLE)(intptr_t)nStdHandle;
    }

    __attribute__((visibility("default"))) const wchar_t* GetCommandLineW() {
        ScopedBionicContext ctx;
        LOGI("GetCommandLineW called! Command line: %ls", g_CommandLineW ? g_CommandLineW : L"strings.exe");
        return g_CommandLineW ? g_CommandLineW : L"strings.exe";
    }

    __attribute__((visibility("default"))) const char* GetCommandLineA() {
        ScopedBionicContext ctx;
        LOGI("GetCommandLineA called! Command line: %s", g_CommandLineA ? g_CommandLineA : "strings.exe");
        return g_CommandLineA ? g_CommandLineA : "strings.exe";
    }

    __attribute__((visibility("default"))) int MessageBoxW(HANDLE hWnd, const wchar_t* lpText, const wchar_t* lpCaption, UINT uType) {
        ScopedBionicContext ctx;
        LOGI("Intercepted MessageBoxW! Text: %ls", lpText);
        return 1; // IDOK
    }

    __attribute__((visibility("default"))) void ExitProcess(UINT uExitCode) {
        ScopedBionicContext ctx;
        LOGI("Intercepted ExitProcess! Exit code: %u", uExitCode);
        g_ExitCode = uExitCode;
        longjmp(g_ExitBuf, 1);
    }

    __attribute__((visibility("default"))) void HleReportGsFailure(uint64_t badCookie, uint64_t lr, uint64_t fp) {
        LOGE("==========================================================");
        LOGE("CRITICAL: __report_gsfailure HOOKED!");
        LOGE("Bad cookie (x0): 0x%llX", badCookie);
        LOGE("Return address (lr): 0x%llX", lr);
        LOGE("Frame pointer (fp): 0x%llX", fp);
        LOGE("Global cookie value: 0x123456789ABCDEF0");
        LOGE("==========================================================");
        
        // Return to prevent infinite loop or unhandled brk
        ExitProcess(2);
    }

    __attribute__((visibility("default"))) void* GetHleReportGsFailurePtr() {
        return (void*)&HleReportGsFailure;
    }

    __attribute__((visibility("default"))) DWORD GetLastError() {
        ScopedBionicContext ctx;
        LOGI("GetLastError called");
        return 0;
    }

    __attribute__((visibility("default"))) void SetLastError(DWORD dwErrCode) {
        ScopedBionicContext ctx;
        LOGI("SetLastError called! Code: %u", dwErrCode);
    }

    __attribute__((visibility("default"))) void* LocalAlloc(UINT uFlags, size_t uBytes) {
        ScopedBionicContext ctx;
        LOGI("LocalAlloc called! Bytes: %zu", uBytes);
        void* ptr = malloc(uBytes);
        LOGI("LocalAlloc returned: %p", ptr);
        return ptr;
    }

    __attribute__((visibility("default"))) void* LocalFree(void* hMem) {
        ScopedBionicContext ctx;
        LOGI("LocalFree called! Ptr: %p", hMem);
        free(hMem);
        return nullptr;
    }

    __attribute__((visibility("default"))) HANDLE GetModuleHandleW(const wchar_t* lpModuleName) {
        ScopedBionicContext ctx;
        LOGI("GetModuleHandleW called! Name: %ls", lpModuleName ? lpModuleName : L"null");
        return nullptr;
    }

    __attribute__((visibility("default"))) HANDLE GetModuleHandleA(const char* lpModuleName) {
        ScopedBionicContext ctx;
        LOGI("GetModuleHandleA called! Name: %s", lpModuleName ? lpModuleName : "null");
        return nullptr;
    }

    __attribute__((visibility("default"))) bool GetFileSizeEx(HANDLE hFile, int64_t* lpFileSize) {
        ScopedBionicContext ctx;
        if (g_GetFileSizeEx) {
            return g_GetFileSizeEx(hFile, lpFileSize);
        }
        return false;
    }

    __attribute__((visibility("default"))) bool SetFilePointerEx(HANDLE hFile, int64_t liDistanceToMove, int64_t* lpNewFilePointer, DWORD dwMoveMethod) {
        ScopedBionicContext ctx;
        if (g_SetFilePointerEx) {
            return g_SetFilePointerEx(hFile, liDistanceToMove, lpNewFilePointer, dwMoveMethod);
        }
        return false;
    }

    __attribute__((visibility("default"))) bool SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode) {
        ScopedBionicContext ctx;
        return true;
    }

    __attribute__((visibility("default"))) bool GetNumberOfConsoleInputEvents(HANDLE hConsoleInput, DWORD* lpNumberOfEvents) {
        ScopedBionicContext ctx;
        if (lpNumberOfEvents) *lpNumberOfEvents = 0;
        return true;
    }

    __attribute__((visibility("default"))) bool ReadConsoleInputW(HANDLE hConsoleInput, void* lpBuffer, DWORD nLength, DWORD* lpNumberOfEventsRead) {
        ScopedBionicContext ctx;
        return false;
    }

    __attribute__((visibility("default"))) bool PeekConsoleInputA(HANDLE hConsoleInput, void* lpBuffer, DWORD nLength, DWORD* lpNumberOfEventsRead) {
        ScopedBionicContext ctx;
        return false;
    }

    __attribute__((visibility("default"))) bool ReadConsoleW(HANDLE hConsoleInput, void* lpBuffer, DWORD nNumberOfCharsToRead, DWORD* lpNumberOfCharsRead, void* pInputControl) {
        ScopedBionicContext ctx;
        return false;
    }

    __attribute__((visibility("default"))) bool GetStringTypeW(DWORD dwInfoType, const wchar_t* lpSrcStr, int cchSrc, uint16_t* lpCharType) {
        ScopedBionicContext ctx;
        return true;
    }

    // ADVAPI32 stubs
    typedef long LSTATUS;
    #define ERROR_SUCCESS 0

    __attribute__((visibility("default"))) LSTATUS RegOpenKeyExW(HANDLE hKey, const wchar_t* lpSubKey, DWORD ulOptions, DWORD samDesired, HANDLE* phkResult) {
        ScopedBionicContext ctx;
        LOGI("RegOpenKeyExW called! SubKey: %ls", lpSubKey);
        if (phkResult) *phkResult = (HANDLE)0x1234;
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegOpenKeyExA(HANDLE hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, HANDLE* phkResult) {
        ScopedBionicContext ctx;
        LOGI("RegOpenKeyExA called! SubKey: %s", lpSubKey);
        if (phkResult) *phkResult = (HANDLE)0x1234;
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegOpenKeyA(HANDLE hKey, const char* lpSubKey, HANDLE* phkResult) {
        ScopedBionicContext ctx;
        LOGI("RegOpenKeyA called! SubKey: %s", lpSubKey);
        if (phkResult) *phkResult = (HANDLE)0x1234;
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegCreateKeyA(HANDLE hKey, const char* lpSubKey, HANDLE* phkResult) {
        ScopedBionicContext ctx;
        LOGI("RegCreateKeyA called! SubKey: %s", lpSubKey);
        if (phkResult) *phkResult = (HANDLE)0x1234;
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegQueryValueExW(HANDLE hKey, const wchar_t* lpValueName, DWORD* lpReserved, DWORD* lpType, uint8_t* lpData, DWORD* lpcbData) {
        ScopedBionicContext ctx;
        LOGI("RegQueryValueExW called! ValueName: %ls", lpValueName);
        if (lpType) *lpType = 4; // REG_DWORD
        if (lpData && lpcbData && *lpcbData >= 4) {
            *(DWORD*)lpData = 1; // EulaAccepted = 1
            *lpcbData = 4;
        } else if (lpcbData) {
            *lpcbData = 4;
        }
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegQueryValueExA(HANDLE hKey, const char* lpValueName, DWORD* lpReserved, DWORD* lpType, uint8_t* lpData, DWORD* lpcbData) {
        ScopedBionicContext ctx;
        LOGI("RegQueryValueExA called! ValueName: %s", lpValueName);
        if (lpType) *lpType = 4; // REG_DWORD
        if (lpData && lpcbData && *lpcbData >= 4) {
            *(DWORD*)lpData = 1; // EulaAccepted = 1
            *lpcbData = 4;
        } else if (lpcbData) {
            *lpcbData = 4;
        }
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegSetValueExA(HANDLE hKey, const char* lpValueName, DWORD Reserved, DWORD dwType, const uint8_t* lpData, DWORD cbData) {
        ScopedBionicContext ctx;
        LOGI("RegSetValueExA called! ValueName: %s", lpValueName);
        return ERROR_SUCCESS;
    }
    __attribute__((visibility("default"))) LSTATUS RegCloseKey(HANDLE hKey) {
        ScopedBionicContext ctx;
        LOGI("RegCloseKey called! Key: %p", hKey);
        return ERROR_SUCCESS;
    }

    // USER32 stubs
    __attribute__((visibility("default"))) HANDLE LoadCursorA(HANDLE hInstance, const char* lpCursorName) {
        ScopedBionicContext ctx;
        return (HANDLE)0x2000;
    }
    __attribute__((visibility("default"))) bool InflateRect(void* lprc, int dx, int dy) {
        ScopedBionicContext ctx;
        return true;
    }
    __attribute__((visibility("default"))) HANDLE GetSysColorBrush(int nIndex) {
        ScopedBionicContext ctx;
        return (HANDLE)0x3000;
    }
    __attribute__((visibility("default"))) HANDLE SetCursor(HANDLE hCursor) {
        ScopedBionicContext ctx;
        return hCursor;
    }
    __attribute__((visibility("default"))) bool SetWindowTextA(HANDLE hWnd, const char* lpString) {
        ScopedBionicContext ctx;
        LOGI("SetWindowTextA called: %s", lpString);
        return true;
    }
    __attribute__((visibility("default"))) HANDLE GetDlgItem(HANDLE hDlg, int nIDDlgItem) {
        ScopedBionicContext ctx;
        return (HANDLE)0x5000;
    }
    __attribute__((visibility("default"))) bool EndDialog(HANDLE hDlg, intptr_t nResult) {
        ScopedBionicContext ctx;
        LOGI("EndDialog called! Result: %ld", (long)nResult);
        return true;
    }
    __attribute__((visibility("default"))) intptr_t DialogBoxIndirectParamA(HANDLE hInstance, void* hDialogTemplate, HANDLE hWndParent, void* lpDialogFunc, intptr_t dwInitParam) {
        ScopedBionicContext ctx;
        LOGI("DialogBoxIndirectParamA called!");
        return 1;
    }
    __attribute__((visibility("default"))) intptr_t SendMessageA(HANDLE hWnd, UINT Msg, uintptr_t wParam, intptr_t lParam) {
        ScopedBionicContext ctx;
        return 0;
    }

    // GDI32 stubs
    __attribute__((visibility("default"))) int StartPage(HANDLE hdc) {
        ScopedBionicContext ctx;
        return 1;
    }
    __attribute__((visibility("default"))) int EndDoc(HANDLE hdc) {
        ScopedBionicContext ctx;
        return 1;
    }
    __attribute__((visibility("default"))) int StartDocA(HANDLE hdc, void* lpdi) {
        ScopedBionicContext ctx;
        return 1;
    }
    __attribute__((visibility("default"))) int SetMapMode(HANDLE hdc, int iMode) {
        ScopedBionicContext ctx;
        return 1;
    }
    __attribute__((visibility("default"))) int GetDeviceCaps(HANDLE hdc, int nIndex) {
        ScopedBionicContext ctx;
        return 1;
    }
    __attribute__((visibility("default"))) int EndPage(HANDLE hdc) {
        ScopedBionicContext ctx;
        return 1;
    }

    // COMDLG32 stubs
    __attribute__((visibility("default"))) bool PrintDlgA(void* lppd) {
        ScopedBionicContext ctx;
        return true;
    }

    // --- CRT & Synchronization Shims ---

    __attribute__((visibility("default"))) void InitializeCriticalSection(void* lpCriticalSection) {
        ScopedBionicContext ctx;
        LOGI("InitializeCriticalSection called on section %p", lpCriticalSection);
        HleCriticalSection* hcs = (HleCriticalSection*)malloc(sizeof(HleCriticalSection));
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&hcs->mutex, &attr);
        pthread_mutexattr_destroy(&attr);
        *(void**)lpCriticalSection = hcs;
    }

    __attribute__((visibility("default"))) bool InitializeCriticalSectionAndSpinCount(void* lpCriticalSection, DWORD dwSpinCount) {
        InitializeCriticalSection(lpCriticalSection);
        return true;
    }

    __attribute__((visibility("default"))) bool InitializeCriticalSectionEx(void* lpCriticalSection, DWORD dwSpinCount, DWORD Flags) {
        InitializeCriticalSection(lpCriticalSection);
        return true;
    }

    __attribute__((visibility("default"))) void EnterCriticalSection(void* lpCriticalSection) {
        ScopedBionicContext ctx;
        HleCriticalSection* hcs = *(HleCriticalSection**)lpCriticalSection;
        if (hcs) {
            pthread_mutex_lock(&hcs->mutex);
        }
    }

    __attribute__((visibility("default"))) void LeaveCriticalSection(void* lpCriticalSection) {
        ScopedBionicContext ctx;
        HleCriticalSection* hcs = *(HleCriticalSection**)lpCriticalSection;
        if (hcs) {
            pthread_mutex_unlock(&hcs->mutex);
        }
    }

    __attribute__((visibility("default"))) void DeleteCriticalSection(void* lpCriticalSection) {
        ScopedBionicContext ctx;
        HleCriticalSection* hcs = *(HleCriticalSection**)lpCriticalSection;
        if (hcs) {
            pthread_mutex_destroy(&hcs->mutex);
            free(hcs);
            *(void**)lpCriticalSection = nullptr;
        }
    }

    __attribute__((visibility("default"))) HANDLE GetProcessHeap() {
        LOGI("GetProcessHeap called");
        return (HANDLE)0x77777777;
    }

    __attribute__((visibility("default"))) void* HeapAlloc(HANDLE hHeap, DWORD dwFlags, size_t dwBytes) {
        ScopedBionicContext ctx;
        LOGI("HeapAlloc called! Bytes: %zu", dwBytes);
        void* ptr = malloc(dwBytes);
        if (ptr && (dwFlags & 8)) {
            memset(ptr, 0, dwBytes);
        }
        LOGI("HeapAlloc returned: %p", ptr);
        return ptr;
    }

    __attribute__((visibility("default"))) bool HeapFree(HANDLE hHeap, DWORD dwFlags, void* lpMem) {
        ScopedBionicContext ctx;
        if (lpMem) {
            free(lpMem);
        }
        return true;
    }

    __attribute__((visibility("default"))) void* HeapReAlloc(HANDLE hHeap, DWORD dwFlags, void* lpMem, size_t dwBytes) {
        ScopedBionicContext ctx;
        if (!lpMem) {
            return HeapAlloc(hHeap, dwFlags, dwBytes);
        }
        void* ptr = realloc(lpMem, dwBytes);
        return ptr;
    }

    __attribute__((visibility("default"))) size_t HeapSize(HANDLE hHeap, DWORD dwFlags, void* lpMem) {
        ScopedBionicContext ctx;
        return malloc_usable_size(lpMem);
    }

    __attribute__((visibility("default"))) DWORD TlsAlloc() {
        static int nextTlsIndex = 0;
        if (nextTlsIndex < 64) {
            int idx = nextTlsIndex++;
            LOGI("TlsAlloc called -> index %d", idx);
            return (DWORD)(idx);
        }
        LOGI("TlsAlloc FAILED (out of slots)");
        return 0xFFFFFFFF;
    }

    __attribute__((visibility("default"))) void* TlsGetValue(DWORD dwTlsIndex) {
        LOGI("TlsGetValue called. Index: %u", dwTlsIndex);
        uintptr_t current_x18;
        asm volatile("mov %0, x18" : "=r"(current_x18));
        if (current_x18 > 0x1000) {
            FakeTeb* teb = (FakeTeb*)current_x18;
            if (teb->Self == teb && dwTlsIndex < 64) {
                return teb->TlsSlots[dwTlsIndex];
            }
        }
        return nullptr;
    }

    __attribute__((visibility("default"))) bool TlsSetValue(DWORD dwTlsIndex, void* lpTlsValue) {
        LOGI("TlsSetValue called. Index: %u, Value: %p", dwTlsIndex, lpTlsValue);
        uintptr_t current_x18;
        asm volatile("mov %0, x18" : "=r"(current_x18));
        if (current_x18 > 0x1000) {
            FakeTeb* teb = (FakeTeb*)current_x18;
            if (teb->Self == teb && dwTlsIndex < 64) {
                teb->TlsSlots[dwTlsIndex] = lpTlsValue;
                return true;
            }
        }
        return false;
    }

    __attribute__((visibility("default"))) bool TlsFree(DWORD dwTlsIndex) {
        LOGI("TlsFree called. Index: %u", dwTlsIndex);
        uintptr_t current_x18;
        asm volatile("mov %0, x18" : "=r"(current_x18));
        if (current_x18 > 0x1000) {
            FakeTeb* teb = (FakeTeb*)current_x18;
            if (teb->Self == teb && dwTlsIndex < 64) {
                teb->TlsSlots[dwTlsIndex] = nullptr;
                return true;
            }
        }
        return false;
    }

    __attribute__((visibility("default"))) DWORD FlsAlloc(void* lpCallback) {
        LOGI("FlsAlloc called");
        return TlsAlloc();
    }

    __attribute__((visibility("default"))) void* FlsGetValue(DWORD dwFlsIndex) {
        LOGI("FlsGetValue called. Index: %u", dwFlsIndex);
        return TlsGetValue(dwFlsIndex);
    }

    __attribute__((visibility("default"))) bool FlsSetValue(DWORD dwFlsIndex, void* lpFlsValue) {
        LOGI("FlsSetValue called. Index: %u, Value: %p", dwFlsIndex, lpFlsValue);
        return TlsSetValue(dwFlsIndex, lpFlsValue);
    }

    __attribute__((visibility("default"))) bool FlsFree(DWORD dwFlsIndex) {
        return TlsFree(dwFlsIndex);
    }

    __attribute__((visibility("default"))) void InitializeSListHead(void* ListHead) {
        LOGI("InitializeSListHead called");
        ScopedBionicContext ctx;
        __atomic_store_n((__int128*)ListHead, 0, __ATOMIC_RELEASE);
    }

    __attribute__((visibility("default"))) void* InterlockedPushEntrySList(void* ListHead, void* ListEntry) {
        LOGI("InterlockedPushEntrySList called");
        ScopedBionicContext ctx;
        __int128* head = (__int128*)ListHead;
        __int128 oldVal = __atomic_load_n(head, __ATOMIC_ACQUIRE);
        __int128 newVal;
        uint64_t oldNext;
        do {
            oldNext = (uint64_t)oldVal;
            uint32_t oldDepth = (uint32_t)(oldVal >> 64);
            uint32_t oldSequence = (uint32_t)(oldVal >> 96);
            
            *(uint64_t*)ListEntry = oldNext; // entry->Next = oldFirst
            
            uint64_t newNext = (uint64_t)ListEntry;
            uint32_t newDepth = oldDepth + 1;
            uint32_t newSequence = oldSequence + 1;
            
            newVal = ((__int128)newSequence << 96) | ((__int128)newDepth << 64) | newNext;
        } while (!__atomic_compare_exchange_n(head, &oldVal, newVal, false, __ATOMIC_RELEASE, __ATOMIC_ACQUIRE));
        
        return (void*)oldNext;
    }

    __attribute__((visibility("default"))) void* InterlockedPopEntrySList(void* ListHead) {
        LOGI("InterlockedPopEntrySList called");
        ScopedBionicContext ctx;
        __int128* head = (__int128*)ListHead;
        __int128 oldVal = __atomic_load_n(head, __ATOMIC_ACQUIRE);
        __int128 newVal;
        uint64_t oldNext;
        do {
            oldNext = (uint64_t)oldVal;
            if (!oldNext) {
                return nullptr;
            }
            uint32_t oldDepth = (uint32_t)(oldVal >> 64);
            uint32_t oldSequence = (uint32_t)(oldVal >> 96);
            
            uint64_t nextOfFirst = *(uint64_t*)oldNext;
            
            uint64_t newNext = nextOfFirst;
            uint32_t newDepth = oldDepth - 1;
            uint32_t newSequence = oldSequence; // Keep sequence same
            
            newVal = ((__int128)newSequence << 96) | ((__int128)newDepth << 64) | newNext;
        } while (!__atomic_compare_exchange_n(head, &oldVal, newVal, false, __ATOMIC_RELEASE, __ATOMIC_ACQUIRE));
        
        return (void*)oldNext;
    }

    __attribute__((visibility("default"))) void* InterlockedFlushSList(void* ListHead) {
        LOGI("InterlockedFlushSList called");
        ScopedBionicContext ctx;
        __int128* head = (__int128*)ListHead;
        __int128 oldVal = __atomic_load_n(head, __ATOMIC_ACQUIRE);
        __int128 newVal;
        uint64_t oldNext;
        do {
            oldNext = (uint64_t)oldVal;
            if (!oldNext) {
                return nullptr;
            }
            uint32_t oldSequence = (uint32_t)(oldVal >> 96);
            newVal = ((__int128)oldSequence << 96); // Depth 0, Next 0
        } while (!__atomic_compare_exchange_n(head, &oldVal, newVal, false, __ATOMIC_RELEASE, __ATOMIC_ACQUIRE));
        
        return (void*)oldNext;
    }

    __attribute__((visibility("default"))) void* EncodePointer(void* Ptr) {
        LOGI("EncodePointer called: %p", Ptr);
        return Ptr;
    }

    __attribute__((visibility("default"))) void* DecodePointer(void* Ptr) {
        LOGI("DecodePointer called: %p", Ptr);
        return Ptr;
    }

    __attribute__((visibility("default"))) void RaiseException(DWORD dwExceptionCode, DWORD dwExceptionFlags, DWORD nNumberOfArguments, const uintptr_t* lpArguments) {
        LOGI("RaiseException called! ExceptionCode: 0x%x", dwExceptionCode);
    }

    __attribute__((visibility("default"))) void RtlRaiseException(void* ExceptionRecord) {
        uint32_t exceptionCode = ExceptionRecord ? *(uint32_t*)ExceptionRecord : 0;
        LOGE("RtlRaiseException called! Exception Code: 0x%X", exceptionCode);
    }

    __attribute__((visibility("default"))) void* RtlLookupFunctionEntry(uintptr_t ControlPc, uintptr_t* ImageBase, void* HistoryTable) {
        LOGI("RtlLookupFunctionEntry called for PC: 0x%llX", (unsigned long long)ControlPc);
        return nullptr;
    }

    __attribute__((visibility("default"))) void* RtlPcToFileHeader(void* PcValue, void** BaseOfImage) {
        LOGI("RtlPcToFileHeader called for PC: %p", PcValue);
        return nullptr;
    }

    __attribute__((visibility("default"))) void* RtlUnwindEx(void* TargetFrame, void* TargetIp, void* ExceptionRecord, void* ReturnValue, void* ContextRecord, void* HistoryTable) {
        LOGI("RtlUnwindEx called");
        return nullptr;
    }

    __attribute__((visibility("default"))) void RtlUnwind(void* TargetFrame, void* TargetIp, void* ExceptionRecord, void* ReturnValue) {
        LOGI("RtlUnwind called");
    }

    __attribute__((visibility("default"))) bool QueryPerformanceCounter(int64_t* lpPerformanceCount) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        if (lpPerformanceCount) {
            *lpPerformanceCount = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
        }
        return true;
    }

    __attribute__((visibility("default"))) void GetSystemTimeAsFileTime(uint64_t* lpSystemTimeAsFileTime) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        if (lpSystemTimeAsFileTime) {
            uint64_t ns = (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
            *lpSystemTimeAsFileTime = (ns / 100) + 116444736000000000ULL;
        }
    }

    __attribute__((visibility("default"))) DWORD GetCurrentThreadId() {
        LOGI("GetCurrentThreadId called");
        return (DWORD)pthread_self();
    }

    __attribute__((visibility("default"))) wchar_t* GetEnvironmentStringsW() {
        ScopedBionicContext ctx;
        LOGI("GetEnvironmentStringsW called");
        static wchar_t emptyEnv[] = L"\0";
        return emptyEnv;
    }

    __attribute__((visibility("default"))) bool FreeEnvironmentStringsW(wchar_t* env) {
        return true;
    }

    __attribute__((visibility("default"))) void GetStartupInfoW(void* lpStartupInfo) {
        ScopedBionicContext ctx;
        LOGI("GetStartupInfoW called");
        memset(lpStartupInfo, 0, 104);
    }

    __attribute__((visibility("default"))) bool SetStdHandle(DWORD nStdHandle, HANDLE hHandle) {
        return true;
    }

    __attribute__((visibility("default"))) bool TerminateProcess(HANDLE hProcess, DWORD uExitCode) {
        ExitProcess(uExitCode);
        return true;
    }

    __attribute__((visibility("default"))) bool FreeLibrary(HANDLE hLibModule) {
        return true;
    }

    __attribute__((visibility("default"))) HANDLE GetModuleHandleExW(DWORD dwFlags, const wchar_t* lpModuleName, HANDLE* phModule) {
        if (phModule) *phModule = nullptr;
        return nullptr;
    }

    __attribute__((visibility("default"))) DWORD GetFileType(HANDLE hFile) {
        ScopedBionicContext ctx;
        uintptr_t val = (uintptr_t)hFile;
        LOGI("GetFileType called! hFile: 0x%lx", (unsigned long)val);
        if (val == 1 || val == 2 || (int)val == -11 || (int)val == -12) {
            return 2; // FILE_TYPE_CHAR
        }
        return 1; // FILE_TYPE_DISK
    }

    __attribute__((visibility("default"))) DWORD GetConsoleCP() {
        return 65001; // UTF-8
    }

    __attribute__((visibility("default"))) DWORD GetConsoleOutputCP() {
        return 65001; // UTF-8
    }

    __attribute__((visibility("default"))) bool GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode) {
        if (lpMode) *lpMode = 0;
        return true;
    }

    __attribute__((visibility("default"))) bool FlushFileBuffers(HANDLE hFile) {
        return true;
    }

    __attribute__((visibility("default"))) int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, bool* lpUsedDefaultChar) {
        if (cchWideChar == -1) {
            cchWideChar = wcslen(lpWideCharStr);
        }
        int len = 0;
        for (int i = 0; i < cchWideChar; i++) {
            wchar_t wc = lpWideCharStr[i];
            if (wc < 0x80) {
                if (lpMultiByteStr && len < cbMultiByte) {
                    lpMultiByteStr[len] = (char)wc;
                }
                len++;
            } else if (wc < 0x800) {
                if (lpMultiByteStr && len + 1 < cbMultiByte) {
                    lpMultiByteStr[len] = (char)(0xC0 | (wc >> 6));
                    lpMultiByteStr[len+1] = (char)(0x80 | (wc & 0x3F));
                }
                len += 2;
            } else {
                if (lpMultiByteStr && len + 2 < cbMultiByte) {
                    lpMultiByteStr[len] = (char)(0xE0 | (wc >> 12));
                    lpMultiByteStr[len+1] = (char)(0x80 | ((wc >> 6) & 0x3F));
                    lpMultiByteStr[len+2] = (char)(0x80 | (wc & 0x3F));
                }
                len += 3;
            }
        }
        if (lpMultiByteStr && len < cbMultiByte) {
            lpMultiByteStr[len] = '\0';
        }
        return len;
    }

    __attribute__((visibility("default"))) int MultiByteToWideChar(UINT CodePage, DWORD dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar) {
        if (cbMultiByte == -1) {
            cbMultiByte = strlen(lpMultiByteStr);
        }
        int len = 0;
        for (int i = 0; i < cbMultiByte; ) {
            uint8_t b = lpMultiByteStr[i];
            wchar_t wc;
            if (b < 0x80) {
                wc = b;
                i++;
            } else if ((b & 0xE0) == 0xC0) {
                wc = ((b & 0x1F) << 6) | (lpMultiByteStr[i+1] & 0x3F);
                i += 2;
            } else {
                wc = ((b & 0x0F) << 12) | ((lpMultiByteStr[i+1] & 0x3F) << 6) | (lpMultiByteStr[i+2] & 0x3F);
                i += 3;
            }
            if (lpWideCharStr && len < cchWideChar) {
                lpWideCharStr[len] = wc;
            }
            len++;
        }
        if (lpWideCharStr && len < cchWideChar) {
            lpWideCharStr[len] = L'\0';
        }
        return len;
    }

    __attribute__((visibility("default"))) bool WriteConsoleW(HANDLE hConsoleOutput, const void* lpBuffer, DWORD nNumberOfCharsToWrite, DWORD* lpNumberOfCharsWritten, void* lpReserved) {
        return WriteFile(hConsoleOutput, lpBuffer, nNumberOfCharsToWrite * sizeof(wchar_t), lpNumberOfCharsWritten, nullptr);
    }

    __attribute__((visibility("default"))) HANDLE GetCurrentProcess() {
        return (HANDLE)(intptr_t)-1;
    }

    __attribute__((visibility("default"))) bool SetUnhandledExceptionFilter(void* lpTopLevelExceptionFilter) {
        return true;
    }

    __attribute__((visibility("default"))) void OutputDebugStringW(const wchar_t* lpOutputString) {
        LOGI("[OutputDebugString] %ls", lpOutputString);
    }

    __attribute__((visibility("default"))) bool IsDebuggerPresent() {
        return false;
    }

    __attribute__((visibility("default"))) void* GetProcAddress(HANDLE hModule, const char* lpProcName) {
    ScopedBionicContext ctx;
    if (!lpProcName) return nullptr;
    
    LOGI("GetProcAddress called for %s", lpProcName);
    
    // Search our own HLE library
    void* sym = dlsym(RTLD_DEFAULT, lpProcName);
    if (sym) return sym;
    
    // Try with Hle prefix
    char hleName[256];
    snprintf(hleName, sizeof(hleName), "Hle%s", lpProcName);
    sym = dlsym(RTLD_DEFAULT, hleName);
    if (sym) return sym;
    
    LOGE("GetProcAddress UNRESOLVED: %s - returning DummyReturnZero to prevent crash", lpProcName);
    return (void*)HleDummyReturnZero;
}

    __attribute__((visibility("default"))) DWORD GetModuleFileNameW(HANDLE hModule, wchar_t* lpFilename, DWORD nSize) {
        static const wchar_t* dummyName = L"strings.exe";
        wcsncpy(lpFilename, dummyName, nSize);
        return wcslen(lpFilename);
    }

    __attribute__((visibility("default"))) DWORD GetModuleFileNameA(HANDLE hModule, char* lpFilename, DWORD nSize) {
        static const char* dummyName = "strings.exe";
        strncpy(lpFilename, dummyName, nSize);
        return strlen(lpFilename);
    }

    __attribute__((visibility("default"))) bool SetEnvironmentVariableW(const wchar_t* lpName, const wchar_t* lpValue) {
        return true;
    }

    __attribute__((visibility("default"))) bool SetConsoleCtrlHandler(void* HandlerRoutine, bool Add) {
        return true;
    }

    __attribute__((visibility("default"))) bool FindClose(HANDLE hFindFile) {
        return true;
    }

    __attribute__((visibility("default"))) int CompareStringW(uint32_t Locale, DWORD dwCmpFlags, const wchar_t* lpString1, int cchCount1, const wchar_t* lpString2, int cchCount2) {
        return wcscmp(lpString1, lpString2) == 0 ? 2 : 1; // 2 = CSTR_EQUAL, 1 = CSTR_LESS_THAN
    }

    __attribute__((visibility("default"))) int LCMapStringW(uint32_t Locale, DWORD dwMapFlags, const wchar_t* lpSrcStr, int cchSrc, wchar_t* lpDestStr, int cchDest) {
        return 0;
    }

    __attribute__((visibility("default"))) int GetLocaleInfoW(uint32_t Locale, DWORD LCType, wchar_t* lpLCData, int cchData) {
        return 0;
    }

    __attribute__((visibility("default"))) bool IsValidLocale(uint32_t Locale, DWORD dwFlags) {
        return true;
    }

    __attribute__((visibility("default"))) uint32_t GetUserDefaultLCID() {
        return 1033;
    }

    __attribute__((visibility("default"))) bool EnumSystemLocalesW(void* lpLocaleEnumProc, DWORD dwFlags) {
        return true;
    }

    __attribute__((visibility("default"))) HANDLE GetCurrentThread() {
        return (HANDLE)(intptr_t)-2;
    }

    __attribute__((visibility("default"))) bool GetCPInfo(UINT CodePage, void* lpCPInfo) {
        return false;
    }

    __attribute__((visibility("default"))) UINT GetOEMCP() {
        return 65001;
    }

    __attribute__((visibility("default"))) UINT GetACP() {
        return 65001;
    }

    __attribute__((visibility("default"))) bool IsValidCodePage(UINT CodePage) {
        return CodePage == 65001;
    }

    __attribute__((visibility("default"))) int FormatMessageA(DWORD dwFlags, const void* lpSource, DWORD dwMessageId, DWORD dwLanguageId, char* lpBuffer, DWORD nSize, void* Arguments) {
        return 0;
    }

    __attribute__((visibility("default"))) HANDLE FindFirstFileA(const char* lpFileName, void* lpFindFileData) {
        return (HANDLE)(intptr_t)-1;
    }

    __attribute__((visibility("default"))) bool FindNextFileA(HANDLE hFindFile, void* lpFindFileData) {
        return false;
    }

    __attribute__((visibility("default"))) HANDLE FindFirstFileExW(const wchar_t* lpFileName, int fInfoLevelId, void* lpFindFileData, int fSearchOp, void* lpSearchFilter, DWORD dwAdditionalFlags) {
        return (HANDLE)(intptr_t)-1;
    }

    __attribute__((visibility("default"))) bool FindNextFileW(HANDLE hFindFile, void* lpFindFileData) {
        return false;
    }

    __attribute__((visibility("default"))) DWORD GetFullPathNameA(const char* lpFileName, DWORD nBufferLength, char* lpBuffer, char** lpFilePart) {
        if (lpBuffer && nBufferLength > strlen(lpFileName)) {
            strcpy(lpBuffer, lpFileName);
            return strlen(lpFileName);
        }
        return 0;
    }

    __attribute__((visibility("default"))) DWORD SetFilePointer(HANDLE hFile, long lDistanceToMove, long* lpDistanceToMoveHigh, DWORD dwMoveMethod) {
        int64_t dist = lDistanceToMove;
        if (lpDistanceToMoveHigh) {
            dist |= ((int64_t)*lpDistanceToMoveHigh) << 32;
        }
        int64_t newOffset = 0;
        bool ok = SetFilePointerEx(hFile, dist, &newOffset, dwMoveMethod);
        if (ok) {
            if (lpDistanceToMoveHigh) {
                *lpDistanceToMoveHigh = (long)(newOffset >> 32);
            }
            return (DWORD)(newOffset & 0xFFFFFFFF);
        }
        return 0xFFFFFFFF;
    }

    // --- VERSION.dll stubs ---

    __attribute__((visibility("default"))) DWORD GetFileVersionInfoSizeW(const wchar_t* lptstrFilename, DWORD* lpdwHandle) {
        if (lpdwHandle) *lpdwHandle = 0;
        return 0;
    }

    __attribute__((visibility("default"))) DWORD GetFileVersionInfoSizeA(const char* lptstrFilename, DWORD* lpdwHandle) {
        if (lpdwHandle) *lpdwHandle = 0;
        return 0;
    }

    __attribute__((visibility("default"))) bool GetFileVersionInfoW(const wchar_t* lptstrFilename, DWORD dwHandle, DWORD dwLen, void* lpData) {
        return false;
    }

    __attribute__((visibility("default"))) bool GetFileVersionInfoA(const char* lptstrFilename, DWORD dwHandle, DWORD dwLen, void* lpData) {
        return false;
    }

    __attribute__((visibility("default"))) bool VerQueryValueW(const void* pBlock, const wchar_t* lpSubBlock, void** lplpBuffer, UINT* puLen) {
        return false;
    }

    __attribute__((visibility("default"))) bool VerQueryValueA(const void* pBlock, const char* lpSubBlock, void** lplpBuffer, UINT* puLen) {
        return false;
    }

    // --- KERNEL32 dynamic loading & version stubs ---

    __attribute__((visibility("default"))) bool GetVersionExA(void* lpVersionInformation) {
        DWORD* pSize = (DWORD*)lpVersionInformation;
        if (pSize && *pSize >= 148) { // sizeof(OSVERSIONINFOA) is 148
            memset((char*)lpVersionInformation + 4, 0, *pSize - 4);
            DWORD* pMajor = (DWORD*)((char*)lpVersionInformation + 4);
            DWORD* pMinor = (DWORD*)((char*)lpVersionInformation + 8);
            DWORD* pBuild = (DWORD*)((char*)lpVersionInformation + 12);
            DWORD* pPlatform = (DWORD*)((char*)lpVersionInformation + 16);
            *pMajor = 10; // Windows 10
            *pMinor = 0;
            *pBuild = 19041;
            *pPlatform = 2; // VER_PLATFORM_WIN32_NT
            return true;
        }
        return false;
    }

    __attribute__((visibility("default"))) HANDLE LoadLibraryExW(const wchar_t* lpLibFileName, HANDLE hFile, DWORD dwFlags) {
        LOGI("Intercepted LoadLibraryExW! Lib: %ls", lpLibFileName);
        return nullptr;
    }

    __attribute__((visibility("default"))) HANDLE LoadLibraryExA(const char* lpLibFileName, HANDLE hFile, DWORD dwFlags) {
        LOGI("Intercepted LoadLibraryExA! Lib: %s", lpLibFileName);
        return nullptr;
    }

    __attribute__((visibility("default"))) DWORD GetCurrentDirectoryA(DWORD nBufferLength, char* lpBuffer) {
        static const char* dummyDir = "C:\\";
        if (lpBuffer && nBufferLength > strlen(dummyDir)) {
            strcpy(lpBuffer, dummyDir);
            return strlen(dummyDir);
        }
        return strlen(dummyDir);
    }

    __attribute__((visibility("default"))) HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile) {
        wchar_t wPath[512];
        MultiByteToWideChar(65001, 0, lpFileName, -1, wPath, 512);
        return CreateFileW(wPath, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
    }

    __attribute__((visibility("default"))) int GetDateFormatW(uint32_t Locale, DWORD dwFlags, const void* lpDate, const wchar_t* lpFormat, wchar_t* lpDateStr, int cchDate) {
        return 0;
    }

    __attribute__((visibility("default"))) int GetTimeFormatW(uint32_t Locale, DWORD dwFlags, const void* lpTime, const wchar_t* lpFormat, wchar_t* lpTimeStr, int cchTime) {
        return 0;
    }
}

