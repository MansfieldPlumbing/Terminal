#include <stdarg.h>
#include <stdio.h>
#include <android/log.h>

extern "C" {

void openlog(const char *ident, int option, int facility) {
    // Android doesn't need explicit openlog, but we could store ident if we wanted
}

void syslog(int priority, const char *format, ...) {
    va_list args;
    va_start(args, format);

    // Map Linux syslog priorities to Android priorities
    // LOG_EMERG=0, LOG_ALERT=1, LOG_CRIT=2, LOG_ERR=3
    // LOG_WARNING=4, LOG_NOTICE=5, LOG_INFO=6, LOG_DEBUG=7
    android_LogPriority android_priority = ANDROID_LOG_INFO;
    switch (priority) {
        case 0:
        case 1:
        case 2: android_priority = ANDROID_LOG_FATAL; break;
        case 3: android_priority = ANDROID_LOG_ERROR; break;
        case 4: android_priority = ANDROID_LOG_WARN; break;
        case 5:
        case 6: android_priority = ANDROID_LOG_INFO; break;
        case 7: android_priority = ANDROID_LOG_DEBUG; break;
        default: android_priority = ANDROID_LOG_INFO; break;
    }

    __android_log_vprint(android_priority, "PowerShellNative", format, args);
    va_end(args);
}

void closelog(void) {
}

}
