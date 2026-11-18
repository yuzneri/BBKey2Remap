#!/bin/sh
# Run every test suite: builds the host AOSP parser, then tests/*.test.sh, then tests/*.test.mjs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT
export KCMTOOL="$ROOT/tools/kcm-host/kcmtool"
export KLTOOL="$ROOT/tools/kcm-host/kltool"
export AOSP_KEYBOARDS="$ROOT/tools/kcm-host/aosp/${AOSP_TAG:-android-16.0.0_r1}/keyboards"
sh "$ROOT/tools/kcm-host/build.sh" "$KCMTOOL" >/dev/null

status=0
for suite in "$ROOT"/tests/*.test.sh; do
    [ -e "$suite" ] || continue
    sh "$suite" || status=1
done
set -- "$ROOT"/tests/*.test.mjs
if [ -e "$1" ]; then
    node --test "$@" || status=1
fi
[ "$status" -eq 0 ] && echo 'ALL TESTS PASSED' || echo 'SOME TESTS FAILED'
exit "$status"
