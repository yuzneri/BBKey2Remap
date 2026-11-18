#pragma once
#include <cstdint>
namespace android { enum { SYSTEM_TIME_MONOTONIC = 1 }; inline int64_t systemTime(int) { return 0; } }
