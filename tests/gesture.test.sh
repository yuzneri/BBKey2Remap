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

# touches SCRIPT: converts a touch script to `getevent -lt` lines on stdout. One script line is
# one frame: "MS SLOT=X,Y ... -SLOT ...". SLOT=X,Y lands or moves a finger, -SLOT lifts it.
# 21 units are 1 mm, as on the device.
touches() {
    printf "$1" | awk '
        function ev(type, code, v) { printf "[%6d.%06d] %s %s %08x\n", 1000 + int(t / 1000), (t % 1000) * 1000, type, code, v }
        {
            t = $1
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^-/) {
                    s = substr($i, 2)
                    ev("EV_ABS", "ABS_MT_SLOT", s); ev("EV_ABS", "ABS_MT_TRACKING_ID", 4294967295); down[s] = 0
                    continue
                }
                split($i, a, /[=,]/); s = a[1]
                ev("EV_ABS", "ABS_MT_SLOT", s)
                if (!down[s]) { ev("EV_ABS", "ABS_MT_TRACKING_ID", ++id); down[s] = 1 }
                ev("EV_ABS", "ABS_MT_POSITION_X", a[2]); ev("EV_ABS", "ABS_MT_POSITION_Y", a[3])
            }
            ev("EV_SYN", "SYN_REPORT", 0)
        }'
}

# replays CONFIG SCRIPT EXPECTED: replaying the touch script with the settings prints EXPECTED.
replays() {
    conf "$1"
    touches "$2" > "$WORK/touch.log"
    got=$("$GESTURETOOL" replay "$WORK/g.conf" "$WORK/touch.log") || return 1
    [ "$got" = "$(printf "$3")" ] || { printf 'got:\n%s\n' "$got"; return 1; }
}

TAPS='bind 1 tap key 1\nbind 2 tap key 2\nbind 3 tap key 3\n'
check 'a short touch is a tap, sent when the finger lifts' replays "$TAPS" '0 0=500,200\n50 0=505,200\n120 -0\n' \
    '120 1-finger tap key 0x1\n'
check 'a touch longer than tap_ms is not a tap' replays "$TAPS" '0 0=500,200\n201 -0\n' ''
check 'a touch held exactly tap_ms is still a tap' replays "$TAPS" '0 0=500,200\n200 -0\n' '200 1-finger tap key 0x1\n'
check 'a touch that moved start_mm is not a tap' replays "$TAPS" '0 0=500,200\n40 0=542,200\n60 0=500,200\n80 -0\n' ''
check 'a touch lifted before hold_ms sends nothing' replays "hold_ms 50\n$TAPS" '0 0=500,200\n49 -0\n' ''
check 'a touch held hold_ms can be a tap' replays "hold_ms 50\n$TAPS" '0 0=500,200\n50 -0\n' '50 1-finger tap key 0x1\n'
check 'fingers landing within gather_ms count together' replays "tap_ms 400\n$TAPS" \
    '0 0=300,200\n40 0=300,200 1=700,200\n120 0=300,200 1=700,200 2=900,300\n300 -0 -1 -2\n' '300 3-finger tap key 0x3\n'
check 'a finger landing after gather_ms is ignored' replays "tap_ms 400\n$TAPS" \
    '0 0=300,200\n160 0=300,200 1=700,200\n300 -1\n350 -0\n' '350 1-finger tap key 0x1\n'
check 'lifting a finger within gather_ms ends the gesture at once' replays "$TAPS" \
    '0 0=300,200 1=700,200\n80 -0 -1\n' '80 2-finger tap key 0x2\n'
check 'the gesture ends when the first counted finger lifts' replays "$TAPS" \
    '0 0=300,200 1=700,200\n100 -0\n500 -1\n' '100 2-finger tap key 0x2\n'
check 'four fingers are not a gesture' replays "$TAPS" \
    '0 0=100,200 1=300,200 2=500,200 3=700,200\n100 -0 -1 -2 -3\n' ''
check 'a finger count without bindings sends nothing' replays 'bind 2 tap key 2\n' '0 0=500,200\n100 -0\n' ''
check 'with gather_ms 0 the fingers are counted on the first frame' replays "gather_ms 0\n$TAPS" \
    '0 0=300,200\n10 0=300,200 1=700,200\n100 -0 -1\n' '100 1-finger tap key 0x1\n'
check 'consecutive touches are recognised separately' replays "$TAPS" \
    '0 0=500,200\n100 -0\n300 0=300,200 1=700,200\n400 -0 -1\n' '100 1-finger tap key 0x1\n400 2-finger tap key 0x2\n'

# Device recordings: the finger counts must come out right, including the third finger that
# landed 122 ms after the first. Taps are made easy here so that every touch reports its count.
conf "tap_ms 600\nstart_mm 25\n$TAPS"
check 'device recording: three one-finger touches' sh -c '[ "$("$1" replay "$2" "$3" | cut -d" " -f2)" = "$(printf "1-finger\n1-finger\n1-finger")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$FIXTURES/touch-swipes-1finger.getevent"
check 'device recording: a two-finger and a three-finger touch' sh -c '[ "$("$1" replay "$2" "$3" | cut -d" " -f2)" = "$(printf "2-finger\n3-finger")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$FIXTURES/touch-2-and-3-fingers.getevent"

# replay input handling
conf "$TAPS"
printf 'add device 1: /dev/input/event1\n[    1.000000] /dev/input/event1: EV_ABS ABS_MT_TRACKING_ID 00000001\n[    1.000000] /dev/input/event2: EV_KEY KEY_A DOWN\n[    1.000000] /dev/input/event1: EV_ABS ABS_MT_POSITION_X 00000064\n[    1.000000] /dev/input/event1: EV_SYN SYN_REPORT 00000000\n[    1.050000] /dev/input/event1: EV_ABS ABS_MT_TRACKING_ID ffffffff\n[    1.050000] /dev/input/event1: EV_SYN SYN_REPORT 00000000\n' > "$WORK/prefixed.log"
check 'replay reads device-prefixed lines of the touch device and skips the rest' \
    sh -c '[ "$("$1" replay "$2" "$3")" = "50 1-finger tap key 0x1" ]' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/prefixed.log"
printf '[    1.000000] EV_ABS ABS_MT_POSITION_X\n' > "$WORK/bad.log"
check 'replay rejects a malformed event line with its line number' \
    sh -c '"$1" replay "$2" "$3" >/dev/null 2>"$4" && exit 1; grep -q "bad.log:1: not a getevent" "$4"' \
    - "$GESTURETOOL" "$WORK/g.conf" "$WORK/bad.log" "$WORK/bad.err"

finish
