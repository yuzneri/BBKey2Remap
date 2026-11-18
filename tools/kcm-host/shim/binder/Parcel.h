#pragma once
#include <utils/String8.h>
#include <cstdint>
namespace android {
class Parcel { public:
  String8 readString8() const { return String8(""); } int32_t readInt32() const { return 0; }
  bool readBool() const { return false; } int errorCheck() const { return -1; }
  void writeString8(const String8&) {} void writeInt32(int32_t) {} void writeBool(bool) {} };
}
