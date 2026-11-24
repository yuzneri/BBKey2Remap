# Helpers for tests/*.test.sh (POSIX sh). Expects ROOT and KCMTOOL from tests/run.sh.
: "${ROOT:?run tests through tests/run.sh}" "${KCMTOOL:?run tests through tests/run.sh}"
FIXTURES="$ROOT/tests/fixtures"
WORK=$(mktemp -d)
# Stub daemons (module_files) run from under $WORK; a failed test may leave one behind, possibly
# stopped (SIGSTOP), which only SIGKILL ends.
trap 'pkill -KILL -f "$WORK/" 2>/dev/null; rm -rf "$WORK"' EXIT
passed=0 failed=0 known=0

# check NAME COMMAND...: passes when COMMAND exits 0; its output is shown on failure.
check() {
    name=$1; shift
    if out=$("$@" 2>&1); then
        passed=$((passed + 1)); printf 'ok    %s\n' "$name"
    else
        failed=$((failed + 1)); printf 'FAIL  %s\n' "$name"; printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

# known_bug NAME COMMAND...: records a known defect, so COMMAND is expected to fail with exit 1.
# Once the defect is fixed this reports a failure, forcing the test to become a check. Any other
# status (127 for a missing tool, 2 for a usage error) is a broken test, not the known defect.
known_bug() {
    name=$1; shift
    "$@" >/dev/null 2>&1
    case $? in
        0) failed=$((failed + 1)); printf 'FAIL  %s (known bug now passes: turn it into check)\n' "$name";;
        1) known=$((known + 1)); printf 'xfail %s\n' "$name";;
        *) failed=$((failed + 1)); printf 'FAIL  %s (failed for an unexpected reason)\n' "$name";;
    esac
}

finish() {
    printf '%s: %d passed, %d failed, %d known bugs\n' "${0##*/}" "$passed" "$failed" "$known"
    [ "$failed" -eq 0 ]
}

# Helpers below take positional parameters only, so they never overwrite a caller's variables.

# write_config FILE ASSIGNMENT...: writes a generator config in the format remap.sh produces.
write_config() {
    exec 3> "$1"; shift
    echo '# config' >&3
    for a in "$@"; do echo "$a" >&3; done
    exec 3>&-
}

# run_awk IMPL ARGS...: IMPL is busybox, gawk or mawk.
run_awk() {
    if [ "$1" = busybox ]; then shift; busybox awk "$@"; else "$@"; fi
}

# compare_maps A B OUT: writes kcmtool's per-state differences to OUT (empty when the maps
# behave the same); fails, exit 1, if the AOSP parser rejects either map.
compare_maps() { "$KCMTOOL" compare "$1" "$2" > "$3"; }

# changed_keys A B: key labels whose result differs for any modifier state, one per line.
changed_keys() { compare_maps "$1" "$2" "$WORK/changed_keys" && awk '{print $1}' "$WORK/changed_keys" | sort -u; }

# expect_eval FILE KEY META EXPECTED: kcmtool's result line for that key event must start with EXPECTED.
expect_eval() {
    got=$("$KCMTOOL" eval "$1" "$2" "$3") || return 1
    case "$got" in "$4"*) return 0;; esac
    echo "expected '$4' got '$got'"; return 1
}

# fake_device DIR: a fake device root for the module scripts (KEY2REMAP_ROOT=DIR). It holds the
# stock keymaps, Magisk's busybox (host busybox), and stub commands in DIR/bin to put first in
# PATH: dumpsys prints DIR/dumpsys-input.txt, getprop answers as the KEY2 on Android 16,
# ls -Z prints the label in DIR/label, chcon logs to DIR/chcon.log and exits with DIR/chcon.status.
fake_device() {
    mkdir -p "$1/vendor/usr/keychars" "$1/vendor/usr/keylayout" "$1/data/adb/magisk" \
        "$1/data/adb/modules" "$1/bin"
    cp "$FIXTURES/key2-base.kcm" "$1/vendor/usr/keychars/stmpe.kcm"
    cp "$FIXTURES/key2-base.kl" "$1/vendor/usr/keylayout/stmpe.kl"
    ln -s "$(command -v busybox)" "$1/data/adb/magisk/busybox"
    printf 'u:object_r:vendor_keychars_file:s0\n' > "$1/label"
    echo 0 > "$1/chcon.status"
    cat > "$1/dumpsys-input.txt" <<'TXT'
      KeyLayoutFile: /system/usr/keylayout/Generic.kl
      KeyCharacterMapFile: /system/usr/keychars/Generic.kcm
      KeyLayoutFile: /vendor/usr/keylayout/stmpe.kl
      KeyCharacterMapFile: /vendor/usr/keychars/stmpe.kcm
TXT
    cat > "$1/bin/dumpsys" <<'SH'
#!/bin/sh
[ "$1" = input ] && cat "$KEY2REMAP_ROOT/dumpsys-input.txt"
SH
    cat > "$1/bin/getprop" <<'SH'
#!/bin/sh
case "$1" in ro.product.model) echo 'BlackBerry KEY2';; ro.build.version.release) echo 16;; esac
SH
    cat > "$1/bin/ls" <<'SH'
#!/bin/sh
if [ "$1" = -Z ]; then label=$(cat "$KEY2REMAP_ROOT/label"); [ -n "$label" ] || exit 1; echo "$label $2"; exit 0; fi
exec /bin/ls "$@"
SH
    cat > "$1/bin/svc" <<'SH'
#!/bin/sh
echo "$*" >> "$KEY2REMAP_ROOT/svc.log"
exit "$(cat "$KEY2REMAP_ROOT/svc.status" 2>/dev/null || echo 0)"
SH
    cat > "$1/bin/chcon" <<'SH'
#!/bin/sh
echo "$*" >> "$KEY2REMAP_ROOT/chcon.log"
exit "$(cat "$KEY2REMAP_ROOT/chcon.status")"
SH
    chmod +x "$1/bin/"*
}

# module_files DIR: the module as Magisk extracts it from the ZIP (src/ without generated data).
# bin/touchgestured, an arm64 binary in the ZIP, is stood in for by a script: "check" runs
# gesturetool's check of the same settings file, "thresholds" its table, and starting the daemon records its pid and
# arguments in DIR/daemon.calls and waits for SIGTERM (as a shell, so its command line still
# names bin/touchgestured).
module_files() {
    mkdir -p "$1/bin" && cp -R "$ROOT/src/." "$1/" || return 1
    cat > "$1/bin/touchgestured" <<STUB
#!/bin/sh
if [ "\$1" = check ]; then exec "${GESTURETOOL:?run tests through tests/run.sh}" check "\$2" > /dev/null; fi
if [ "\$1" = thresholds ]; then exec "$GESTURETOOL" thresholds; fi
echo "\$\$ \$*" >> "$1/daemon.calls"
echo "touchgestured: stub running" >&2
trap 'echo "touchgestured: stub stopped" >&2; exit 0' TERM
while :; do sleep 1; done
STUB
    chmod 0755 "$1/bin/touchgestured"
}
