#pragma once
// Only what KeyLayoutMap.h/.cpp use: the sensor type enum (values from android/sensor.h).
#include <cstdint>
#include <input/Input.h>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>
namespace android {
enum class InputDeviceSensorType : int32_t {
    ACCELEROMETER = 1, MAGNETIC_FIELD = 2, ORIENTATION = 3, GYROSCOPE = 4, LIGHT = 5, PRESSURE = 6,
    TEMPERATURE = 7, PROXIMITY = 8, GRAVITY = 9, LINEAR_ACCELERATION = 10, ROTATION_VECTOR = 11,
    RELATIVE_HUMIDITY = 12, AMBIENT_TEMPERATURE = 13, MAGNETIC_FIELD_UNCALIBRATED = 14,
    GAME_ROTATION_VECTOR = 15, GYROSCOPE_UNCALIBRATED = 16, SIGNIFICANT_MOTION = 17,
};
}
