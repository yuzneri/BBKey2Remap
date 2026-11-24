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

DEFAULTS='start_mm 2\nstep_mm 3\nflick_mm_s 60\ntap_ms 200\nhold_ms 0\ngather_ms 150\nafter_key_ms 300\n'

check 'an empty settings file gives the default thresholds and no gestures' accepts '' "$DEFAULTS"
check 'comments, blank lines and tabs are ignored' accepts '# c\n\n\tstart_mm\t2.5  \n' \
    'start_mm 2.5\nstep_mm 3\nflick_mm_s 60\ntap_ms 200\nhold_ms 0\ngather_ms 150\nafter_key_ms 300\n'
check 'every kind of line is read' accepts \
    'step_mm 4\nflick_mm_s 300\ntap_ms 150\nhold_ms 40\ngather_ms 120\nafter_key_ms 500\nbind 1 swipe left key 0x100 ctrl+shift\nbind 2 flick down-right key 261\nbind 2 tap key 0x102 meta\npass 3\nmod 42 shift\nmod 0x1d ctrl\n' \
    'start_mm 2\nstep_mm 4\nflick_mm_s 300\ntap_ms 150\nhold_ms 40\ngather_ms 120\nafter_key_ms 500\nbind 1 swipe left key 0x100 ctrl+shift\nbind 2 flick down-right key 0x105\nbind 2 tap key 0x102 meta\npass 3\nmod 42 shift\nmod 29 ctrl\n'
check 'modifiers may be listed in any order' accepts 'bind 1 tap key 1 meta+alt+shift+ctrl\n' \
    "${DEFAULTS}bind 1 tap key 0x1 ctrl+shift+alt+meta\n"
check 'a file without a final newline is read' accepts 'tap_ms 100' \
    'start_mm 2\nstep_mm 3\nflick_mm_s 60\ntap_ms 100\nhold_ms 0\ngather_ms 150\nafter_key_ms 300\n'

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
check 'passthrough and gestures for the same finger count are rejected at the bind line' rejects 'pass 1\nbind 1 tap key 1\n' \
    '2: 1-finger gestures are both passed through and bound'
check 'a comment may have any number of words' accepts '# a b c d e f g h i j\n  # indented comment\n' "$DEFAULTS"
check 'passthrough after gestures of the same count is rejected at the pass line' rejects 'bind 1 tap key 1\npass 1\n' \
    '2: 1-finger gestures are both passed through and bound'
check 'pass set twice is rejected' rejects 'pass 2\npass 2\n' 'pass 2 is set twice'
check 'a physical modifier key takes a single modifier' rejects 'mod 42 ctrl+shift\n' 'modifier must be'
check 'a gesture may be bound in a modifier layer' accepts 'bind shift 1 swipe left key 0x100 ctrl\nbind sym 2 tap key 3\nmod 100 sym\n' \
    "${DEFAULTS}bind shift 1 swipe left key 0x100 ctrl\nbind sym 2 tap key 0x3\nmod 100 sym\n"
check 'a gesture bound twice in one layer is rejected' rejects 'bind alt 1 tap key 1\nbind alt 1 tap key 2\n' 'alt 1-finger tap is bound twice'
check 'the same gesture may be bound in different layers' accepts 'bind 1 tap key 1\nbind ctrl 1 tap key 2\n' \
    "${DEFAULTS}bind 1 tap key 0x1\nbind ctrl 1 tap key 0x2\n"
check 'SYM cannot be sent with a key' rejects 'bind 1 tap key 1 sym\n' 'modifiers must be'
check 'a layer binding conflicts with passthrough of its finger count' rejects 'pass 1\nbind alt 1 tap key 1\n' \
    '1-finger gestures are both passed through and bound'
check 'an unknown layer is rejected' rejects 'bind meta 1 tap key 1\n' 'finger count must be 1-3'
check 'a physical key with two modifiers is rejected' rejects 'mod 42 shift\nmod 42 ctrl\n' 'scancode 42 has two modifiers'
long=$(printf '%0300d' 0)
check 'overlong lines are rejected' rejects "# $long\n" 'longer than 256'

# Every threshold the table lists is accepted at its default and its ends, and refused just outside
# them and, for whole-number ones, with a fraction.
thresholds_match_parser() {
    "$GESTURETOOL" thresholds > "$WORK/thresholds" && [ "$(wc -l < "$WORK/thresholds")" -eq 7 ] || return 1
    while read -r name def min max kind; do
        for v in "$def" "$min" "$max"; do accepts "$name $v\n" "$(printf "$DEFAULTS" | sed "s/^$name .*/$name $v/")\n" || return 1; done
        rejects "$name $(awk -v x="$max" 'BEGIN { print x + 1 }')\n" "$name must be" || return 1
        if [ "$min" != 0 ]; then rejects "$name $(awk -v x="$min" 'BEGIN { print x - 0.1 }')\n" "$name must be" || return 1; fi
        case "$kind" in
            int) rejects "$name $min.5\n" 'whole number' || return 1 ;;
            real) v=$(awk -v x="$min" 'BEGIN { print x + 0.25 }')
                  accepts "$name $v\n" "$(printf "$DEFAULTS" | sed "s/^$name .*/$name $v/")\n" || return 1 ;;
            *) echo "kind $kind"; return 1 ;;
        esac
    done < "$WORK/thresholds"
    printf "$DEFAULTS" | awk '{ print $1, $2 }' > "$WORK/defaults"
    awk '{ print $1, $2 }' "$WORK/thresholds" | cmp - "$WORK/defaults"
}
check 'the thresholds table gives the defaults and ranges the settings file accepts' thresholds_match_parser

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

# stroke FROM TO X0,Y0 X1,Y1 [SLOT]: script lines moving a finger (slot 0 by default) in a straight
# line, a frame every 10 ms.
stroke() {
    awk -v a="$1" -v b="$2" -v p="$3" -v q="$4" -v slot="${5:-0}" 'BEGIN {
        split(p, s, ","); split(q, e, ",")
        for (t = a; t <= b; t += 10) {
            f = b > a ? (t - a) / (b - a) : 1
            printf "%d %d=%d,%d\\n", t, slot, s[1] + (e[1] - s[1]) * f, s[2] + (e[2] - s[2]) * f
        }
    }'
}

SWIPES='bind 1 swipe up key 1\nbind 1 swipe down key 2\nbind 1 swipe left key 3\nbind 1 swipe right key 4\n'
# 10 mm right in 500 ms: start_mm (2 mm, 42 units) is reached at 100 ms, then 5 mm at 250, 8 mm at 400.
check 'a swipe sends its first key at start_mm and one more every step_mm' replays "$SWIPES" \
    "$(stroke 0 500 100,200 310,200)500 -0\n" '100 1-finger swipe right key 0x4\n250 1-finger swipe right key 0x4\n400 1-finger swipe right key 0x4\n'
check 'upward movement (falling Y) is a swipe up' replays "$SWIPES" \
    "$(stroke 0 100 500,300 500,237)100 -0\n" '70 1-finger swipe up key 0x1\n'
check 'going back along the axis sends the opposite direction' replays "$SWIPES" \
    "$(stroke 0 400 100,200 268,200)$(stroke 410 690 266,200 142,200)690 -0\n" \
    '100 1-finger swipe right key 0x4\n250 1-finger swipe right key 0x4\n400 1-finger swipe right key 0x4\n550 1-finger swipe left key 0x3\n690 1-finger swipe left key 0x3\n'
check 'the first axis that reaches start_mm is kept for the whole swipe' replays "$SWIPES" \
    "$(stroke 0 100 100,200 163,200)$(stroke 110 500 163,190 163,0)500 -0\n" '70 1-finger swipe right key 0x4\n'
check 'an axis without bindings is not chosen' replays 'bind 1 swipe down key 2\n' \
    "$(stroke 0 500 100,200 310,263)500 -0\n" '340 1-finger swipe down key 0x2\n'
check 'a fast finger moving several steps in one frame sends a key per step' replays "$SWIPES" \
    '0 0=100,200\n10 0=310,200\n500 -0\n' '10 1-finger swipe right key 0x4\n10 1-finger swipe right key 0x4\n10 1-finger swipe right key 0x4\n'
check 'no swipe key is sent before hold_ms' replays "hold_ms 300\n$SWIPES" \
    "$(stroke 0 500 100,200 310,200)500 -0\n" '300 1-finger swipe right key 0x4\n300 1-finger swipe right key 0x4\n400 1-finger swipe right key 0x4\n'
check 'a finger that moved and stopped starts its swipe when hold_ms passes' replays "hold_ms 300\n$SWIPES" \
    "$(stroke 0 100 100,200 205,200)600 -0\n" '300 1-finger swipe right key 0x4\n300 1-finger swipe right key 0x4\n'

FLICKS='bind 1 flick up key 0x11\nbind 1 flick down key 0x12\nbind 1 flick left key 0x13\nbind 1 flick right key 0x14\nbind 1 flick up-left key 0x15\nbind 1 flick up-right key 0x16\nbind 1 flick down-left key 0x17\nbind 1 flick down-right key 0x18\n'
# 10 mm in 40 ms is 250 mm/s, over flick_mm_s (150); 10 mm in 500 ms is 20 mm/s.
check 'a fast movement ending in a lift is a flick' replays "$FLICKS" "$(stroke 0 40 100,200 310,200)40 -0\n" '40 1-finger flick right key 0x14\n'
check 'a slow movement is not a flick' replays "$FLICKS" "$(stroke 0 500 100,200 310,200)500 -0\n" ''
# 1.4 mm in 4 ms is 357 mm/s: fast enough, but short of start_mm.
check 'a flick must cover start_mm' replays "$FLICKS" '0 0=500,200\n2 0=530,200\n4 -0\n' ''
check 'a finger that stopped before lifting is not a flick' replays "$FLICKS" "$(stroke 0 40 100,200 310,200)200 -0\n" ''
# NAME:CODE:FROM:TO. The last two lie 4 and 6 degrees inside a sector border (22.5 and 67.5 degrees).
for dir in up:11:500,200:500,0 down:12:500,0:500,200 left:13:500,200:290,200 up-left:15:500,200:350,50 \
    up-right:16:500,200:650,50 down-left:17:500,50:350,200 down-right:18:500,50:650,200 \
    up-right:16:500,200:700,100 up:11:500,200:560,0; do
    IFS=: read -r name code from to <<EOF
$dir
EOF
    check "flicks are told apart in 8 directions: $name from $from to $to" replays "$FLICKS" \
        "$(stroke 0 40 "$from" "$to")40 -0\n" "40 1-finger flick $name key 0x$code\n"
done

BOTH="$SWIPES$FLICKS"
check 'with swipes and flicks bound, a fast flick sends only the flick' replays "$BOTH" \
    "$(stroke 0 40 100,200 310,200)40 -0\n" '40 1-finger flick right key 0x14\n'
check 'with swipes and flicks bound, a slow swipe sends only swipe keys' replays "$BOTH" \
    "$(stroke 0 500 100,200 310,200)500 -0\n" '100 1-finger swipe right key 0x4\n250 1-finger swipe right key 0x4\n400 1-finger swipe right key 0x4\n'
# 10 mm since it started moving falls below 60 mm/s at 167 ms (and the finger is silent by then).
check 'held-back swipe keys are sent once a fast finger stops' replays "$BOTH" \
    "$(stroke 0 40 100,200 310,200)300 -0\n" '166 1-finger swipe right key 0x4\n166 1-finger swipe right key 0x4\n166 1-finger swipe right key 0x4\n'
check 'a fast finger between two frames is not taken for a still one' replays "$BOTH" \
    '0 0=100,200\n30 0=100,222\n36 0=100,255\n47 0=100,297\n53 0=100,345\n64 0=100,378\n90 -0\n' '90 1-finger flick down key 0x12\n'
check 'after its first swipe key a touch is no longer a flick' replays "$BOTH" \
    "$(stroke 0 500 100,200 310,200)$(stroke 510 540 310,200 520,200)540 -0\n" \
    '100 1-finger swipe right key 0x4\n250 1-finger swipe right key 0x4\n400 1-finger swipe right key 0x4\n520 1-finger swipe right key 0x4\n530 1-finger swipe right key 0x4\n540 1-finger swipe right key 0x4\n540 1-finger swipe right key 0x4\n'
check 'a fast lift in a direction without a flick binding sends the held-back swipe keys' replays \
    "${SWIPES}bind 1 flick up key 0x11\n" "$(stroke 0 40 100,200 310,200)40 -0\n" \
    '40 1-finger swipe right key 0x4\n40 1-finger swipe right key 0x4\n40 1-finger swipe right key 0x4\n'

check 'with more fingers bound, a swipe waits for gather_ms before its first key' replays "${SWIPES}bind 2 tap key 2\n" \
    "$(stroke 0 500 100,200 310,200)500 -0\n" '150 1-finger swipe right key 0x4\n250 1-finger swipe right key 0x4\n400 1-finger swipe right key 0x4\n'

check 'a finger that moved and stopped during gather_ms starts its swipe when the fingers are counted' replays \
    "${SWIPES}bind 2 tap key 2\n" "$(stroke 0 100 100,200 205,200)600 -0\n" \
    '150 1-finger swipe right key 0x4\n150 1-finger swipe right key 0x4\n'
check 'a slow swipe lifted within gather_ms still sends its keys' replays "${SWIPES}bind 2 tap key 2\n" \
    "$(stroke 0 140 100,200 226,200)140 -0\n" '140 1-finger swipe right key 0x4\n140 1-finger swipe right key 0x4\n'
check 'a swipe in a direction without a key does not stop a later flick' replays \
    'bind 1 swipe right key 4\nbind 1 flick left key 0x13\n' "$(stroke 0 200 400,200 330,200)$(stroke 210 230 320,200 100,200)230 -0\n" \
    '230 1-finger flick left key 0x13\n'
check 'a finger landing after gather_ms does not move the gesture' replays "${SWIPES}bind 2 tap key 2\n" \
    "0 0=900,300\n$(stroke 200 300 300,200 600,200 1)400 -1\n500 -0\n" ''

# gestures CONFIG LOG EXPECTED: the gesture names replaying a device recording gives, one per line.
gestures() {
    conf "$1"
    got=$("$GESTURETOOL" replay "$WORK/g.conf" "$2" | cut -d' ' -f2-4) || return 1
    [ "$got" = "$(printf "$3")" ] || { printf 'got:\n%s\n' "$got"; return 1; }
}
# With the default thresholds: an up-and-down swipe, a 7 mm swipe left, and 15 mm right in 163 ms,
# as fast as the recorded flicks below.
check 'device recording: one-finger swipes with the default thresholds' gestures "$BOTH" \
    "$FIXTURES/touch-swipes-1finger.getevent" \
    "$(printf '1-finger swipe up\n%.0s' 1 2)\n$(printf '1-finger swipe down\n%.0s' 1 2)\n$(printf '1-finger swipe left\n%.0s' 1 2)\n1-finger flick right\n"
# Recorded as 12 flicks (up, down, left, right, three times; one came out as a still touch), 4 slow
# swipes and 4 swipes of hesitant speed. With both bound, each flick must be a flick in its
# direction and nothing else may be one.
flicks_and_swipes() {
    conf "$BOTH"
    # The first key of each touch (touches are over 300 ms apart), as "KIND DIRECTION".
    "$GESTURETOOL" replay "$WORK/g.conf" "$FIXTURES/touch-flicks-and-swipes.getevent" |
        awk 'NR == 1 || $1 - last > 300 { print $3, $4 } { last = $1 }' > "$WORK/kinds"
    [ "$(tr '\n' ' ' < "$WORK/kinds")" = 'flick up flick down flick left flick right flick up flick down flick left flick right flick down flick left flick right swipe up swipe down swipe left swipe right swipe left swipe left swipe up swipe up ' ] ||
        { cat "$WORK/kinds"; return 1; }
}
check 'device recording: recorded flicks and swipes are told apart with the default thresholds' flicks_and_swipes
# Typing: the finger on each key touches the surface 0.3-0.5 s before the key goes down and keeps
# sliding over several keys; then Shift is held (its finger is not on the surface) for a swipe right.
typing_and_shift() {
    conf "mod 42 shift\nmod 54 shift\nmod 29 ctrl\n$SWIPES"
    "$GESTURETOOL" replay "$WORK/g.conf" "$FIXTURES/typing-and-shift-swipe.getevent" | cut -d' ' -f2- | uniq -c > "$WORK/out"
    [ "$(tr -s ' ' < "$WORK/out")" = ' 7 1-finger swipe right key 0x4 shift' ] || { cat "$WORK/out"; return 1; }
    grep /dev/input/event1 "$FIXTURES/typing-and-shift-swipe.getevent" > "$WORK/touch-only.log"
    "$GESTURETOOL" replay "$WORK/g.conf" "$WORK/touch-only.log" | grep -q 'swipe left'
}
check 'device recording: typing sends no gesture keys (it would without the keyboard), Shift+swipe sends shifted keys' typing_and_shift
check 'device recording: a 5.5 mm two-finger swipe up with the default thresholds' gestures \
    'bind 2 swipe up key 1\nbind 2 swipe down key 2\nbind 3 tap key 3\n' "$FIXTURES/touch-2-and-3-fingers.getevent" \
    '2-finger swipe up\n2-finger swipe up\n'

# as_passed LOG: the "MS pass TYPE CODE VALUE" lines replay prints for passing LOG through unchanged.
as_passed() {
    awk 'NR == 1 { split($2, o, "."); t0 = o[1] * 1000 + substr(o[2], 1, 3) }
        { sub(/^\[ */, ""); split($1, t, "."); printf "%d pass %s %s %s\n", t[1] * 1000 + substr(t[2], 1, 3) - t0, $2, $3, $4 }' "$1"
}
# passes CONFIG LOG EXPECTED_FILE: replaying LOG prints exactly the lines of EXPECTED_FILE.
passes() {
    conf "$1"
    "$GESTURETOOL" replay "$WORK/g.conf" "$2" > "$WORK/passed" || return 1
    diff "$3" "$WORK/passed"
}

touches '0 0=300,200\n40 0=300,200 1=700,200\n80 0=320,180 1=720,180\n200 0=340,160 1=740,160\n260 -0 -1\n' > "$WORK/two.log"
{ echo '0 pass EV_ABS ABS_MT_SLOT 00000000'; as_passed "$WORK/two.log"; } > "$WORK/two.expected"
check 'a passed-through touch is replayed from its start with the original times' \
    passes 'pass 2\nbind 1 tap key 1\n' "$WORK/two.log" "$WORK/two.expected"
check 'other finger counts are still recognised next to a passthrough' \
    replays 'pass 2\nbind 1 tap key 1\n' '0 0=300,200\n100 -0\n' '100 1-finger tap key 0x1\n'

# The second touch starts without ABS_MT_SLOT because the device is still on slot 1. (The first
# touch selects its slot itself; the slot in effect before it is 0.)
cat > "$WORK/slot.log" <<'EOF'
[  1000.000000] EV_ABS ABS_MT_SLOT 00000001
[  1000.000000] EV_ABS ABS_MT_TRACKING_ID 00000001
[  1000.000000] EV_ABS ABS_MT_POSITION_X 00000064
[  1000.000000] EV_ABS ABS_MT_POSITION_Y 00000064
[  1000.000000] EV_SYN SYN_REPORT 00000000
[  1000.050000] EV_ABS ABS_MT_TRACKING_ID ffffffff
[  1000.050000] EV_SYN SYN_REPORT 00000000
[  1000.500000] EV_ABS ABS_MT_TRACKING_ID 00000002
[  1000.500000] EV_ABS ABS_MT_POSITION_X 000000c8
[  1000.500000] EV_ABS ABS_MT_POSITION_Y 000000c8
[  1000.500000] EV_SYN SYN_REPORT 00000000
[  1000.550000] EV_ABS ABS_MT_TRACKING_ID ffffffff
[  1000.550000] EV_SYN SYN_REPORT 00000000
EOF
{ echo '0 pass EV_ABS ABS_MT_SLOT 00000000'; as_passed "$WORK/slot.log" | sed -n 1,7p
  echo '500 pass EV_ABS ABS_MT_SLOT 00000001'; as_passed "$WORK/slot.log" | sed -n '8,$p'; } > "$WORK/slot.expected"
check 'a passthrough starts by selecting the slot the device is on' passes 'pass 1\n' "$WORK/slot.log" "$WORK/slot.expected"

# 600 frames 1 ms apart while gather_ms (500) waits: 2400 events, more than are kept.
{ touches "$(awk 'BEGIN { for (t = 0; t < 600; t++) printf "%d 0=%d,200\\n", t, 300 + t % 2 }')600 -0\n"
  touches '0 0=300,200\n50 -0\n' | sed 's/^\[  1000/[  1001/'; } > "$WORK/long.log"
{ echo '1000 pass EV_ABS ABS_MT_SLOT 00000000'; as_passed "$WORK/long.log" | tail -n 8; } > "$WORK/long.expected"
check 'a touch with more events than the buffer holds is dropped, and the next one passes' \
    passes 'pass 1\nbind 2 tap key 2\ngather_ms 500\n' "$WORK/long.log" "$WORK/long.expected"

{ touches '0 0=300,200\n10 0=310,200\n' | sed '$d'
  echo '[  1000.010000] EV_SYN SYN_DROPPED 00000000'
  touches '20 0=330,200\n30 0=340,200\n40 -0\n'
  touches '0 0=300,200\n50 -0\n' | sed 's/^\[  1000/[  1001/'; } > "$WORK/dropped.log"
{ echo '0 pass EV_ABS ABS_MT_SLOT 00000000'; as_passed "$WORK/dropped.log" | sed -n 1,8p
  printf '10 pass EV_ABS ABS_MT_SLOT 00000000\n10 pass EV_ABS ABS_MT_TRACKING_ID ffffffff\n'
  for b in BTN_TOUCH BTN_TOOL_FINGER BTN_TOOL_DOUBLETAP BTN_TOOL_TRIPLETAP BTN_TOOL_QUADTAP; do echo "10 pass EV_KEY $b UP"; done
  echo '10 pass EV_SYN SYN_REPORT 00000000'
  echo '1000 pass EV_ABS ABS_MT_SLOT 00000000'; as_passed "$WORK/dropped.log" | tail -n 8; } > "$WORK/dropped.expected"
check 'SYN_DROPPED lifts the passed fingers and ignores the rest of the touch' \
    passes 'pass 1\n' "$WORK/dropped.log" "$WORK/dropped.expected"

# The kernel leaves out an axis whose value did not change, also when a new contact lands.
cat > "$WORK/samex.log" <<'LOG'
[  1000.000000] EV_ABS ABS_MT_TRACKING_ID 00000001
[  1000.000000] EV_ABS ABS_MT_POSITION_X 00000190
[  1000.000000] EV_ABS ABS_MT_POSITION_Y 000000c8
[  1000.000000] EV_SYN SYN_REPORT 00000000
[  1000.080000] EV_ABS ABS_MT_TRACKING_ID ffffffff
[  1000.080000] EV_SYN SYN_REPORT 00000000
[  1000.500000] EV_ABS ABS_MT_TRACKING_ID 00000002
[  1000.500000] EV_ABS ABS_MT_POSITION_Y 000000c9
[  1000.500000] EV_SYN SYN_REPORT 00000000
[  1000.580000] EV_ABS ABS_MT_TRACKING_ID ffffffff
[  1000.580000] EV_SYN SYN_REPORT 00000000
LOG
conf "$TAPS"
check 'a new contact keeps the slot position the kernel did not repeat' \
    sh -c '[ "$("$1" replay "$2" "$3")" = "$(printf "80 1-finger tap key 0x1\n580 1-finger tap key 0x1")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$WORK/samex.log"
{ touches '0 0=500,200\n'; echo '[  1000.030000] EV_SYN SYN_DROPPED 00000000'; echo '[  1000.030000] EV_SYN SYN_REPORT 00000000'
  touches '80 -0\n'; } > "$WORK/drop-tap.log"
check 'SYN_DROPPED abandons a recognised touch too' sh -c '[ -z "$("$1" replay "$2" "$3")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$WORK/drop-tap.log"
{ echo '[  1000.000000] EV_SYN SYN_DROPPED 00000000'; touches '0 0=500,200\n80 -0\n'; } > "$WORK/drop-partial.log"
check 'events after SYN_DROPPED are not used until the next SYN_REPORT' sh -c '[ -z "$("$1" replay "$2" "$3")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$WORK/drop-partial.log"

# What the daemon does after SYN_DROPPED: it discards the queued events and gives the kernel's
# current slots (RESYNC CURRENT_SLOT ID:X:Y per slot, -1 for an empty one).
{ touches '0 0=100,200\n10 0=110,200\n'; echo '[  1000.030000] EV_SYN SYN_DROPPED 00000000'
  echo '[  1000.030000] RESYNC 0 1:300:200 -1 -1 -1'
  touches '40 0=310,200\n100 0=500,200\n300 -0\n400 0=500,200\n450 -0\n' | grep -v 'TRACKING_ID 00000001$'; } > "$WORK/resync-held.log"
conf "$SWIPES$TAPS"
check 'after a drop, a finger held across it is ignored until lifted, and the next touch counts' \
    sh -c '[ "$("$1" replay "$2" "$3")" = "450 1-finger tap key 0x1" ]' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/resync-held.log"
{ touches '0 0=100,200\n'; echo '[  1000.030000] EV_SYN SYN_DROPPED 00000000'
  echo '[  1000.030000] RESYNC 1 -1 7:300:200 -1 -1'
  printf '[  1000.040000] EV_ABS ABS_MT_POSITION_X 00000190\n[  1000.040000] EV_SYN SYN_REPORT 00000000\n'
  printf '[  1000.100000] EV_ABS ABS_MT_TRACKING_ID ffffffff\n[  1000.100000] EV_SYN SYN_REPORT 00000000\n'
  touches '400 0=500,200\n450 -0\n'; } > "$WORK/resync-new.log"
check 'a finger that landed during a drop is ignored until lifted' \
    sh -c '[ "$("$1" replay "$2" "$3")" = "450 1-finger tap key 0x1" ]' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/resync-new.log"
conf "pass 1\n"
{ touches '0 0=100,200\n'; echo '[  1000.000000] RESYNC 0 -1 -1 -1 -1'; } > "$WORK/resync-pass.log"
check 'a resync with no fingers lifts the fingers passed through' \
    sh -c '"$1" replay "$2" "$3" | grep -q "pass EV_ABS ABS_MT_TRACKING_ID ffffffff"' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/resync-pass.log"

conf 'pass 1\n'
check 'device recording: every event of passed-through touches reaches the virtual touchpad' sh -c '
    [ "$("$1" replay "$2" "$3" | grep -vc "ABS_MT_SLOT 00000000$")" = "$(grep -vc "ABS_MT_SLOT *00000000$" "$3")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$FIXTURES/touch-swipes-1finger.getevent"

# keys LINES: "MS KEY_NAME DOWN|UP|REPEAT" lines as getevent lines of the keyboard (/dev/input/event2).
keys() {
    printf "$1" | awk '{ printf "[%6d.%06d] /dev/input/event2: EV_KEY %s %s\n", 1000 + int($1 / 1000), ($1 % 1000) * 1000, $2, $3 }'
}
# replays_keys CONFIG SCRIPT KEYS EXPECTED [HELD_LINE]: like replays, with keyboard events merged in
# by time, and HELD_LINE (a pseudo event of the keyboard) given at 100 ms.
replays_keys() {
    conf "$1"
    { touches "$2"; keys "$3"; [ -z "${5:-}" ] || echo "[  1000.100000] /dev/input/event2: $5"; } |
        sort -s -t']' -k1,1 > "$WORK/touch.log"
    got=$("$GESTURETOOL" replay "$WORK/g.conf" "$WORK/touch.log") || return 1
    [ "$got" = "$(printf "$4")" ] || { printf 'got:\n%s\n' "$got"; return 1; }
}

MODS='mod 42 shift\nmod 54 shift\nmod 29 ctrl\n'
check 'a touch starting within after_key_ms of a key press is ignored' replays_keys "$MODS$TAPS" \
    '100 0=500,200\n150 -0\n400 0=500,200\n450 -0\n' '0 KEY_H DOWN\n50 KEY_H UP\n' '450 1-finger tap key 0x1\n'
check 'autorepeat is not a new key press' replays_keys "$MODS$TAPS" \
    '450 0=500,200\n500 -0\n' '0 KEY_H DOWN\n400 KEY_H REPEAT\n' '500 1-finger tap key 0x1\n'
check 'pressing a modifier key does not make later touches ignored' replays_keys "$MODS$TAPS" \
    '100 0=500,200\n150 -0\n' '0 KEY_LEFTSHIFT DOWN\n20 KEY_LEFTSHIFT UP\n' '150 1-finger tap key 0x1\n'
check 'a key pressed during a touch cancels it' replays_keys "$MODS$TAPS" \
    '0 0=500,200\n100 -0\n' '50 KEY_H DOWN\n70 KEY_H UP\n' ''
check 'holding Shift with one finger and swiping with another sends shifted keys' replays_keys "$MODS$SWIPES" \
    "0 0=900,300\n$(stroke 300 800 100,200 310,200 1)800 -1\n900 -0\n" '30 KEY_LEFTSHIFT DOWN\n850 KEY_LEFTSHIFT UP\n' \
    '400 1-finger swipe right key 0x4 shift\n550 1-finger swipe right key 0x4 shift\n700 1-finger swipe right key 0x4 shift\n'
check 'lifting the finger on a modifier does not end the new gesture' replays_keys "$MODS${SWIPES}bind 2 tap key 2\n" \
    "0 0=900,300\n$(stroke 300 800 100,200 310,200 1 | sed 's/\\n320 /\\n320 -0 /')800 -1\n" '30 KEY_LEFTSHIFT DOWN\n310 KEY_LEFTSHIFT UP\n' \
    '450 1-finger swipe right key 0x4\n550 1-finger swipe right key 0x4\n700 1-finger swipe right key 0x4\n'
check 'a modifier pressed after swipe keys were sent ends that swipe' replays_keys "$MODS$SWIPES" \
    "$(stroke 0 500 100,200 310,200)500 -0\n" '200 KEY_LEFTCTRL DOWN\n' '100 1-finger swipe right key 0x4\n'
# Physical modifiers held on the keyboard are added to the keys sent (PR0: they do not carry over
# from the physical keyboard to the virtual one by themselves).
check 'a physical modifier held during a gesture is added to its key' replays_keys "$MODS$SWIPES" \
    "$(stroke 10 110 100,200 163,200)110 -0\n" '0 KEY_LEFTSHIFT DOWN\n200 KEY_LEFTSHIFT UP\n' '80 1-finger swipe right key 0x4 shift\n'
check 'physical modifiers combine with the modifiers of the binding' replays_keys "${MODS}bind 1 swipe right key 4 ctrl\n" \
    "$(stroke 10 110 100,200 163,200)110 -0\n" '0 KEY_LEFTSHIFT DOWN\n' '80 1-finger swipe right key 0x4 ctrl+shift\n'
check 'a released physical modifier is no longer added' replays_keys "$MODS$SWIPES" \
    "$(stroke 500 600 100,200 163,200)600 -0\n" '0 KEY_LEFTSHIFT DOWN\n100 KEY_LEFTSHIFT UP\n' '570 1-finger swipe right key 0x4\n'
check 'a modifier stays held while another key for it is down' replays_keys "$MODS$SWIPES" \
    "$(stroke 500 600 100,200 163,200)600 -0\n" '0 KEY_LEFTSHIFT DOWN\n10 KEY_RIGHTSHIFT DOWN\n100 KEY_LEFTSHIFT UP\n' \
    '570 1-finger swipe right key 0x4 shift\n'
check 'keys not listed as modifiers add nothing' replays_keys "$MODS$SWIPES" \
    "$(stroke 500 600 100,200 163,200)600 -0\n" '0 KEY_LEFTALT DOWN\n' '570 1-finger swipe right key 0x4\n'

# Layers: while a physical modifier is held, a gesture bound in its layer sends that key.
# Scan codes as on the KEY2: 42 Shift, 56 Alt, 100 SYM (KEY_RIGHTALT), 110 Speed key (KEY_INSERT).
LMODS='mod 42 shift\nmod 56 alt\nmod 100 sym\nmod 110 ctrl\n'
LAYERED="$LMODS${SWIPES}bind shift 1 swipe right key 0x40\nbind alt 1 swipe right key 0x41\nbind sym 1 swipe right key 0x42\n"
RIGHT="$(stroke 10 110 100,200 163,200)110 -0\n"
LEFT="$(stroke 10 110 163,200 100,200)110 -0\n"
check "a gesture bound in the held modifier's layer sends that key, without the modifier" replays_keys "$LAYERED" \
    "$RIGHT" '0 KEY_LEFTSHIFT DOWN\n' '80 1-finger swipe right key 0x40\n'
check 'a gesture the layer does not bind sends the base key with the modifier' replays_keys "$LAYERED" \
    "$LEFT" '0 KEY_LEFTSHIFT DOWN\n' '80 1-finger swipe left key 0x3 shift\n'
check 'with two modifiers held the first layer binding the gesture is used, the other modifier added' replays_keys "$LAYERED" \
    "$RIGHT" '0 KEY_LEFTALT DOWN\n1 KEY_LEFTSHIFT DOWN\n' '80 1-finger swipe right key 0x40 alt\n'
check 'a layer without the gesture leaves it to the next held layer' replays_keys "${LMODS}${SWIPES}bind alt 1 swipe right key 0x41\n" \
    "$RIGHT" '0 KEY_LEFTALT DOWN\n1 KEY_LEFTSHIFT DOWN\n' '80 1-finger swipe right key 0x41 shift\n'
check 'SYM selects its layer and is never sent' replays_keys "$LAYERED" \
    "$RIGHT$(echo)$(stroke 300 400 163,200 100,200 | sed 's/ 0=/ 1=/g')400 -1\n" '0 KEY_RIGHTALT DOWN\n' \
    '80 1-finger swipe right key 0x42\n370 1-finger swipe left key 0x3\n'
check 'pressing SYM does not make later touches ignored' replays_keys "$LMODS$TAPS" \
    '100 0=500,200\n150 -0\n' '0 KEY_RIGHTALT DOWN\n20 KEY_RIGHTALT UP\n' '150 1-finger tap key 0x1\n'
check 'the Speed key as Ctrl selects the ctrl layer' replays_keys "${LMODS}${SWIPES}bind ctrl 1 swipe right key 0x44\n" \
    "$RIGHT" '0 KEY_INSERT DOWN\n' '80 1-finger swipe right key 0x44\n'
check 'a flick bound only in a layer is recognised while its modifier is held' replays_keys \
    "${LMODS}${SWIPES}bind shift 1 flick up key 0x45\n" "$(stroke 10 50 500,250 500,40)50 -0\n" '0 KEY_LEFTSHIFT DOWN\n' \
    '50 1-finger flick up key 0x45\n'
check 'without the modifier the same movement is a swipe' replays_keys \
    "${LMODS}${SWIPES}bind shift 1 flick up key 0x45\n" "$(stroke 10 50 500,250 500,40)50 -0\n" '0 KEY_LEFTSHIFT DOWN\n0 KEY_LEFTSHIFT UP\n' \
    '20 1-finger swipe up key 0x1\n30 1-finger swipe up key 0x1\n50 1-finger swipe up key 0x1\n'

conf "pass 1\n$MODS"
{ touches '0 0=500,200\n20 0=510,200\n60 0=530,200\n100 -0\n'; keys '50 KEY_H DOWN\n'; } | sort -s -t']' -k1,1 > "$WORK/k.log"
{ printf '50 pass EV_ABS ABS_MT_SLOT 00000000\n50 pass EV_ABS ABS_MT_TRACKING_ID ffffffff\n'
  for b in BTN_TOUCH BTN_TOOL_FINGER BTN_TOOL_DOUBLETAP BTN_TOOL_TRIPLETAP BTN_TOOL_QUADTAP; do echo "50 pass EV_KEY $b UP"; done
  echo '50 pass EV_SYN SYN_REPORT 00000000'; } > "$WORK/k.expected"
check 'a key pressed during a passthrough lifts the passed fingers there and then' \
    sh -c '"$1" replay "$2" "$3" | tail -n 8 | diff "$4" -' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/k.log" "$WORK/k.expected"
{ touches '0 0=500,200\n20 0=510,200\n60 0=530,200\n100 -0\n'; keys '50 KEY_LEFTSHIFT DOWN\n'; } | sort -s -t']' -k1,1 > "$WORK/k.log"
check 'a modifier pressed during a passthrough leaves the touch to the ROM' \
    sh -c '[ "$("$1" replay "$2" "$3" | tail -n 1)" = "100 pass EV_SYN SYN_REPORT 00000000" ]' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/k.log"

# The daemon gives the keys held on the keyboard (HELD SCANCODE...) when it opens it, after its
# SYN_DROPPED, and with none when it loses it.
check 'a modifier release lost with the keyboard is cleared by HELD' replays_keys "$MODS$SWIPES" \
    "$(stroke 500 600 100,200 163,200)600 -0\n" '0 KEY_LEFTSHIFT DOWN\n' '570 1-finger swipe right key 0x4\n' HELD
# (The HELD line at 100 ms is the first event, so times count from it.)
check 'a modifier already held when the keyboard is opened is added' replays_keys "$MODS$SWIPES" \
    "$(stroke 500 600 100,200 163,200)600 -0\n" '' '470 1-finger swipe right key 0x4 shift\n' 'HELD 42'

# Device recordings: the finger counts must come out right, including the third finger that
# landed 122 ms after the first. Taps are made easy here so that every touch reports its count.
conf "tap_ms 600\nstart_mm 25\n$TAPS"
check 'device recording: three one-finger touches' sh -c '[ "$("$1" replay "$2" "$3" | cut -d" " -f2)" = "$(printf "1-finger\n1-finger\n1-finger")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$FIXTURES/touch-swipes-1finger.getevent"
check 'device recording: a two-finger and a three-finger touch' sh -c '[ "$("$1" replay "$2" "$3" | cut -d" " -f2)" = "$(printf "2-finger\n3-finger")" ]' \
    - "$GESTURETOOL" "$WORK/g.conf" "$FIXTURES/touch-2-and-3-fingers.getevent"

# replay input handling
conf "$TAPS"
printf 'add device 1: /dev/input/event1\n[    1.000000] /dev/input/event1: EV_ABS ABS_MT_TRACKING_ID 00000001\n[    1.000000] /dev/input/event3: EV_KEY KEY_A DOWN\n[    1.000000] /dev/input/event1: EV_ABS ABS_MT_POSITION_X 00000064\n[    1.000000] /dev/input/event1: EV_SYN SYN_REPORT 00000000\n[    1.050000] /dev/input/event1: EV_ABS ABS_MT_TRACKING_ID ffffffff\n[    1.050000] /dev/input/event1: EV_SYN SYN_REPORT 00000000\n' > "$WORK/prefixed.log"
check 'replay reads device-prefixed lines of the touch device and skips the rest' \
    sh -c '[ "$("$1" replay "$2" "$3")" = "50 1-finger tap key 0x1" ]' - "$GESTURETOOL" "$WORK/g.conf" "$WORK/prefixed.log"
printf '[    1.000000] EV_ABS ABS_MT_POSITION_X\n' > "$WORK/bad.log"
check 'replay rejects a malformed event line with its line number' \
    sh -c '"$1" replay "$2" "$3" >/dev/null 2>"$4" && exit 1; grep -q "bad.log:1: not a getevent" "$4"' \
    - "$GESTURETOOL" "$WORK/g.conf" "$WORK/bad.log" "$WORK/bad.err"

finish
