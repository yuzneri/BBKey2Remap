#pragma once
#include <string>
#include <cstdarg>
#include <cstdio>
namespace android {
class String8 {
public:
    String8() = default;
    String8(const char* s) : s_(s) {}
    String8(const char* s, size_t n) : s_(s, n) {}
    const char* c_str() const { return s_.c_str(); }
    bool empty() const { return s_.empty(); }
    size_t length() const { return s_.size(); }
    bool operator==(const char* o) const { return s_ == o; }
    bool operator!=(const char* o) const { return s_ != o; }
    operator std::string() const { return s_; }
    void appendFormat(const char* fmt, ...) { char b[1024]; va_list a; va_start(a, fmt); vsnprintf(b, sizeof b, fmt, a); va_end(a); s_ += b; }
private:
    std::string s_;
};
}
