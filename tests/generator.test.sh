#!/bin/sh
# Behaviour of the KCM generator (src/patch.awk), judged by the AOSP parser built on the host.
. "$ROOT/tests/lib.sh"
GEN="$ROOT/src/patch.awk"
AWKS='busybox gawk mawk'
ORIGINAL="$FIXTURES/key2-base.kcm"

# One assignment of every behaviour kind, new and existing rules, a key absent from the original,
# a rule split out of a combined "a, b:" line, and a rule overriding a narrower existing one.
SAMPLE='sym:H=R_DPAD_LEFT shift+sym:H=R_DPAD_LEFT sym:Z=F_F6 sym:A=NONE lshift+lalt:4=U_20AC
shift+ctrl:A=R_MOVE_HOME lalt:SPACE=R_LANGUAGE_SWITCH sym:DEL=R_FORWARD_DEL'

generate() { # IMPL CONFIG ORIGINAL OUT
    run_awk "$1" -f "$GEN" "$2" "$3" > "$4"
}

empty_config_reproduces_original() { # IMPL ORIGINAL
    write_config "$WORK/empty" && generate "$1" "$WORK/empty" "$2" "$WORK/out" && cmp "$2" "$WORK/out"
}

for original in "$ORIGINAL" "$FIXTURES/synthetic-key2.kcm" "$AOSP_KEYBOARDS"/*.kcm; do
    check "AOSP parser accepts the input fixture ${original##*/}" "$KCMTOOL" check "$original"
done
for impl in $AWKS; do
    for original in "$ORIGINAL" "$FIXTURES/synthetic-key2.kcm" "$AOSP_KEYBOARDS"/*.kcm; do
        check "$impl: empty config reproduces ${original##*/} byte for byte" \
            empty_config_reproduces_original "$impl" "$original"
    done
done

# shellcheck disable=SC2086 # SAMPLE is a whitespace-separated list by design.
write_config "$WORK/sample" $SAMPLE
generate busybox "$WORK/sample" "$ORIGINAL" "$WORK/sample.kcm"

awk_implementations_agree() {
    for impl in gawk mawk; do
        generate "$impl" "$WORK/sample" "$ORIGINAL" "$WORK/sample.$impl.kcm" &&
            cmp "$WORK/sample.kcm" "$WORK/sample.$impl.kcm" || return 1
    done
}
check 'busybox awk, gawk and mawk generate identical maps' awk_implementations_agree
check 'AOSP parser accepts the generated map' "$KCMTOOL" check "$WORK/sample.kcm"

only_configured_keys_change() {
    expected=$(printf '%s\n' $SAMPLE | sed 's/^[^:]*:\([^=]*\)=.*/\1/' | sort -u)
    actual=$(changed_keys "$ORIGINAL" "$WORK/sample.kcm") || return 1
    [ "$expected" = "$actual" ] || { echo "expected: $expected"; echo "actual: $actual"; return 1; }
}
check 'keys without assignments behave exactly as in the original' only_configured_keys_change

# changes_require KEY MASK: every modifier state whose result changed for KEY contains a bit of MASK.
changes_require() {
    compare_maps "$ORIGINAL" "$WORK/sample.kcm" "$WORK/changes" || return 1
    awk -v k="$1" '$1 == k {print $2}' "$WORK/changes" > "$WORK/states"
    while read -r meta; do
        [ $((meta & $2)) -ne 0 ] || { echo "$1 changed at $meta"; return 1; }
    done < "$WORK/states"
}
check 'H changes only in states with SYM' changes_require H 0x4
check 'A changes only in states with SYM or Ctrl' changes_require A 0x1004
check 'SPACE changes only in states with left Alt' changes_require SPACE 0x10

for case in \
    'H 0x4 key=21 meta=0x0 ' \
    'H 0x45 key=21 meta=0x0 ' \
    'H 0x0 key=36 meta=0x0 char=0x0068' \
    'H 0x12 key=36 meta=0x12 char=0x002f' \
    'Z 0x4 key=54 meta=0x4 char=0x0000 fallback=136/' \
    'A 0x4 key=29 meta=0x4 char=0x0000 fallback=0/' \
    'A 0x3041 key=122 meta=0x0 ' \
    '4 0x52 key=11 meta=0x52 char=0x20ac' \
    '4 0x41 key=11 meta=0x41 char=0x00a3' \
    'SPACE 0x12 key=204 meta=0x0 ' \
    'SPACE 0x2 key=62 meta=0x2 char=0x0020' \
    'A 0x100000 key=29 meta=0x100000 char=0x0041' \
    'SPACE 0x0 key=62 meta=0x0 char=0x0020' \
    'DEL 0x4 key=112 meta=0x0 ' \
    'DEL 0x0 key=67 meta=0x0 '; do
    # shellcheck disable=SC2086
    set -- $case
    key=$1 meta=$2
    shift 2
    check "$key with meta $meta gives $*" expect_eval "$WORK/sample.kcm" "$key" "$meta" "$*"
done

v03_settings_migrate_to_same_behaviour() {
    # Same conversion as customize.sh applies to a v0.3 module's generated map.
    cfg=$(sed -n 's/^# KEY2_GUI \([^=]*\)=\(.*\)$/sym:\1=R_\2/p' "$FIXTURES/key2-v03-live.kcm")
    # shellcheck disable=SC2086
    write_config "$WORK/v03" $cfg &&
        generate busybox "$WORK/v03" "$ORIGINAL" "$WORK/v03.kcm" &&
        compare_maps "$FIXTURES/key2-v03-live.kcm" "$WORK/v03.kcm" "$WORK/v03.diff" &&
        [ ! -s "$WORK/v03.diff" ]
}
check 'v0.3 settings migrate to a map that behaves like the v0.3 map on the device' \
    v03_settings_migrate_to_same_behaviour

crlf_original_is_handled() {
    sed 's/$/\r/' "$ORIGINAL" > "$WORK/crlf.kcm" &&
        write_config "$WORK/one" sym:H=R_DPAD_LEFT &&
        generate busybox "$WORK/one" "$WORK/crlf.kcm" "$WORK/crlf.out.kcm" &&
        "$KCMTOOL" check "$WORK/crlf.out.kcm" &&
        expect_eval "$WORK/crlf.out.kcm" H 0x4 'key=21 '
}
check 'CRLF original: edits an existing key without duplicating its block' crlf_original_is_handled

# rejects_original CONTENT: the generator must refuse (exit 1) an original it does not
# understand, for every awk, rather than copy the unknown text through.
rejects_original() {
    printf '%s' "$1" > "$WORK/odd.kcm"
    write_config "$WORK/one" sym:H=R_DPAD_LEFT
    for impl in $AWKS; do
        generate "$impl" "$WORK/one" "$WORK/odd.kcm" "$WORK/odd.out" 2>/dev/null
        status=$?
        [ "$status" -eq 1 ] || { echo "$impl exit $status"; return 1; }
    done
}
check 'generator refuses an unknown top-level line' rejects_original "$(printf 'type ALPHA\nbogus line\nkey H {\n    base: %s\n}\n' "'h'")"
check 'generator refuses a key line without an opening brace' rejects_original "$(printf 'type ALPHA\nkey H\n    base: %s\n}\n' "'h'")"
check 'generator refuses a key line with the brace glued to the label' rejects_original "$(printf 'type ALPHA\nkey H{\n    base: %s\n}\n' "'h'")"
check 'generator refuses a carriage return inside a line' rejects_original "$(printf 'type ALPHA\nkey H {\n    base:\r%s\n}\n' "'h'")"
check 'generator refuses an unclosed key block' rejects_original "$(printf 'type ALPHA\nkey H {\n    base: %s\n' "'h'")"

finish
