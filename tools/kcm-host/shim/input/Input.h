#pragma once
#include <input_constants.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <attestation/HmacKeyManager.h>
#include <binder/Parcel.h>
#include <utils/Errors.h>
#include <vector>
#include <string>
#include <cstdint>
namespace android {
typedef int64_t nsecs_t;
template <typename T> class Vector { public: void push() { v.emplace_back(); } T& editTop() { return v.back(); } std::vector<T> v; };
namespace ui { struct LogicalDisplayId { int32_t val; static const LogicalDisplayId INVALID; }; inline const LogicalDisplayId LogicalDisplayId::INVALID{-1}; }
struct InputEvent { static int32_t nextId() { return 0; } };
struct KeyEvent { template <typename... A> void initialize(A&&...) {} };
std::string statusToString(status_t s);
}
