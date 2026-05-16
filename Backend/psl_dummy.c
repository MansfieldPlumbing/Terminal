#ifdef __cplusplus
extern "C" {
#endif

// Legacy names
void SysLogProvider_OpenSysLog(const char* identity, int facility) {}
void SysLogProvider_CloseSysLog() {}
void SysLogProvider_LogSysLog(int priority, const char* message) {}

// PowerShell 7.6+ names
void Native_OpenLog(const char* identity, int facility) {}
void Native_CloseLog() {}
void Native_LogSysLog(int priority, const char* message) {}
void Native_SysLog(int priority, const char* message) {} // <-- Added this one!

#ifdef __cplusplus
}
#endif
