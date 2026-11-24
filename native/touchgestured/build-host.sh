#!/bin/sh
# Build gesturetool, the host-side driver of the touchgestured recogniser used by the tests.
#   native/touchgestured/build-host.sh [OUTPUT]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/gesturetool}
${CC:-cc} -std=c11 -D_POSIX_C_SOURCE=200809L -O1 -Wall -Wextra -Werror \
    -o "$OUT" "$HERE/gesturetool.c" "$HERE/config.c" -lm
