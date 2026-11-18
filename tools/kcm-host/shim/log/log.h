#pragma once
#include <cstring>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#define ALOGE(...) (fprintf(stderr, "E " LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGW(...) (fprintf(stderr, "W " LOG_TAG ": " __VA_ARGS__), fputc('\n', stderr))
#define ALOGD(...) ((void)0)
#define ALOGD_IF(c, ...) ((void)0)
#define ALOGV(...) ((void)0)
#define LOG_ALWAYS_FATAL_IF(c, ...) ((void)0)
#define ALOGI(...) ((void)0)
enum { ANDROID_LOG_DEBUG = 3, ANDROID_LOG_INFO = 4 };
inline int __android_log_is_loggable(int, const char*, int) { return 0; }
