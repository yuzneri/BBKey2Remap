#!/system/bin/sh
# Magisk runs this at late_start: start the gesture daemon when gesture mode is in effect.
sh "${0%/*}/remap.sh" touch-start
