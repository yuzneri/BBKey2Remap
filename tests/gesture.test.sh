#!/bin/sh
# touchgestured recogniser and settings file (native/touchgestured), driven through gesturetool.
. "$ROOT/tests/lib.sh"
: "${GESTURETOOL:?run tests through tests/run.sh}"

# conf TEXT: writes TEXT (printf format) to $WORK/g.conf.
conf() { printf "$1" > "$WORK/g.conf"; }

# accepts TEXT EXPECTED: check succeeds and prints EXPECTED (the effective settings).
accepts() {
    conf "$1"
    got=$("$GESTURETOOL" check "$WORK/g.conf") || return 1
    [ "$got" = "$(printf "$2")" ] || { printf 'got:\n%s\n' "$got"; return 1; }
}

# rejects TEXT MESSAGE: check fails and its error contains MESSAGE.
rejects() {
    conf "$1"
    if err=$("$GESTURETOOL" check "$WORK/g.conf" 2>&1); then echo "accepted"; return 1; fi
    case $err in *"$2"*) ;; *) printf 'error: %s\n' "$err"; return 1;; esac
}

DEFAULTS='start_mm 2\nstep_mm 3\nflick_mm_s 150\ntap_ms 200\nhold_ms 0\ngather_ms 150\nafter_key_ms 300\n'

check 'an empty settings file gives the default thresholds and no gestures' accepts '' "$DEFAULTS"
check 'comments, blank lines and tabs are ignored' accepts '# c\n\n\tstart_mm\t2.5  \n' \
    'start_mm 2.5\nstep_mm 3\nflick_mm_s 150\ntap_ms 200\nhold_ms 0\ngather_ms 150\nafter_key_ms 300\n'
check 'every kind of line is read' accepts \
    'step_mm 4\nflick_mm_s 300\ntap_ms 150\nhold_ms 40\ngather_ms 120\nafter_key_ms 500\nbind 1 swipe left key 0x100 ctrl+shift\nbind 2 flick down-right key 261\nbind 2 tap key 0x102 meta\npass 3\nmod 42 shift\nmod 0x1d ctrl\n' \
    'start_mm 2\nstep_mm 4\nflick_mm_s 300\ntap_ms 150\nhold_ms 40\ngather_ms 120\nafter_key_ms 500\nbind 1 swipe left key 0x100 ctrl+shift\nbind 2 flick down-right key 0x105\nbind 2 tap key 0x102 meta\npass 3\nmod 42 shift\nmod 29 ctrl\n'
check 'modifiers may be listed in any order' accepts 'bind 1 tap key 1 meta+alt+shift+ctrl\n' \
    "${DEFAULTS}bind 1 tap key 0x1 ctrl+shift+alt+meta\n"
check 'a file without a final newline is read' accepts 'tap_ms 100' \
    'start_mm 2\nstep_mm 3\nflick_mm_s 150\ntap_ms 100\nhold_ms 0\ngather_ms 150\nafter_key_ms 300\n'

check 'unknown settings are rejected with their line number' rejects '# c\nspeed 3\n' '2: unknown setting "speed"'
check 'a threshold set twice is rejected' rejects 'tap_ms 100\ntap_ms 200\n' 'tap_ms is set twice'
check 'a threshold below its range is rejected' rejects 'start_mm 0.4\n' 'start_mm must be'
check 'a threshold above its range is rejected' rejects 'gather_ms 501\n' 'gather_ms must be'
check 'a millisecond threshold must be whole' rejects 'tap_ms 10.5\n' 'whole number'
check 'a threshold value must be a plain number' rejects 'step_mm 3mm\n' 'step_mm must be'
check 'a threshold needs exactly one value' rejects 'step_mm 3 4\n' 'step_mm takes one value'
check 'finger counts other than 1-3 are rejected' rejects 'bind 4 tap key 1\n' 'finger count must be 1-3'
check 'unknown gestures are rejected' rejects 'bind 1 swipe up-left key 1\n' 'unknown gesture "swipe up-left"'
check 'a swipe needs a direction' rejects 'bind 1 swipe\n' 'swipe needs a direction'
check 'a tap takes no direction' rejects 'bind 1 tap up key 1\n' 'bind ends with key'
check 'scancode 0 is rejected' rejects 'bind 1 tap key 0\n' 'scancode must be'
check 'scancodes above KEY_MAX are rejected' rejects 'bind 1 tap key 0x300\n' 'scancode must be'
check 'negative scancodes are rejected' rejects 'bind 1 tap key -1\n' 'scancode must be'
check 'a repeated modifier is rejected' rejects 'bind 1 tap key 1 ctrl+ctrl\n' 'modifiers must be'
check 'a dangling + is rejected' rejects 'bind 1 tap key 1 ctrl+\n' 'modifiers must be'
check 'unknown modifiers are rejected' rejects 'bind 1 tap key 1 super\n' 'modifiers must be'
check 'a gesture bound twice is rejected' rejects 'bind 2 flick up key 1\nbind 2 flick up key 2\n' '2-finger flick up is bound twice'
check 'passthrough and gestures for the same finger count are rejected' rejects 'pass 1\nbind 1 tap key 1\n' \
    '1-finger gestures are both passed through and bound'
check 'pass set twice is rejected' rejects 'pass 2\npass 2\n' 'pass 2 is set twice'
check 'a physical modifier key takes a single modifier' rejects 'mod 42 ctrl+shift\n' 'modifier must be'
check 'a physical key with two modifiers is rejected' rejects 'mod 42 shift\nmod 42 ctrl\n' 'scancode 42 has two modifiers'
long=$(printf '%0300d' 0)
check 'overlong lines are rejected' rejects "# $long\n" 'longer than 256'

# The settings check prints what it read; reading that back must give the same settings.
conf 'step_mm 4\nbind 1 swipe left key 0x100 ctrl+shift\nbind 2 tap key 3\npass 3\nmod 42 shift\n'
"$GESTURETOOL" check "$WORK/g.conf" > "$WORK/dump.conf"
check 'the printed settings read back unchanged' accepts "$(cat "$WORK/dump.conf")\n" "$(cat "$WORK/dump.conf")\n"

finish
