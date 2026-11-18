#pragma once
#include <sys/types.h>
namespace android {
class FileMap { public: enum { SEQUENTIAL };
  bool create(const char*, int, off_t, size_t, bool) { return false; }
  void advise(int) {} void* getDataPtr() { return nullptr; } };
}
