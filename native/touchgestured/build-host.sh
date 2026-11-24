#!/bin/sh
# Build gesturetool, the host-side driver of the touchgestured recogniser used by the tests.
# The key names it reads in getevent logs are taken from the host's linux/input-event-codes.h.
#   native/touchgestured/build-host.sh [OUTPUT]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/gesturetool}
CC=${CC:-cc}
GEN=$(mktemp -d)
trap 'rm -rf "$GEN"' EXIT
echo '#include <linux/input-event-codes.h>' | $CC -E -dM - |
    awk '$2 ~ /^KEY_/ && $3 ~ /^(0x[0-9a-fA-F]+|[0-9]+)$/ { printf "{ \"%s\", %s },\n", $2, $3 }' > "$GEN/keynames.inc"
[ -s "$GEN/keynames.inc" ] || { echo 'no KEY_ names in linux/input-event-codes.h' >&2; exit 1; }
$CC -std=c11 -D_POSIX_C_SOURCE=200809L -O1 -Wall -Wextra -Werror -I"$GEN" \
    -o "$OUT" "$HERE/gesturetool.c" "$HERE/config.c" "$HERE/gesture.c" -lm
