#pragma once
// ftl::enum_name/enum_string for InputDeviceSensorType only (KeyLayoutMap's sensor names).
#include <input/InputDevice.h>
#include <string>
#include <string_view>
namespace android::ftl {
constexpr std::string_view sensorName(InputDeviceSensorType t) {
    switch (t) {
#define N(x) case InputDeviceSensorType::x: return #x;
        N(ACCELEROMETER) N(MAGNETIC_FIELD) N(ORIENTATION) N(GYROSCOPE) N(LIGHT) N(PRESSURE)
        N(TEMPERATURE) N(PROXIMITY) N(GRAVITY) N(LINEAR_ACCELERATION) N(ROTATION_VECTOR)
        N(RELATIVE_HUMIDITY) N(AMBIENT_TEMPERATURE) N(MAGNETIC_FIELD_UNCALIBRATED)
        N(GAME_ROTATION_VECTOR) N(GYROSCOPE_UNCALIBRATED) N(SIGNIFICANT_MOTION)
#undef N
    }
    return "";
}
template <auto V> constexpr std::string_view enum_name() { return sensorName(V); }
inline std::string enum_string(InputDeviceSensorType t) { return std::string(sensorName(t)); }
}
