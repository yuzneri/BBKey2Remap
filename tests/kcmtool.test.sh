#!/bin/sh
# The host AOSP parser tool and the comparison helpers the other suites rely on.
. "$ROOT/tests/lib.sh"

printf 'type ALPHA\nkey A {\n    base: bogus\n}\n' > "$WORK/rejected.kcm"
ORIGINAL="$FIXTURES/key2-base.kcm"

check 'check rejects a map the AOSP parser rejects' fails "$KCMTOOL" check "$WORK/rejected.kcm"
check 'compare_maps fails when the second map is rejected' \
    fails compare_maps "$ORIGINAL" "$WORK/rejected.kcm" "$WORK/out"
check 'compare_maps fails when the first map is rejected' \
    fails compare_maps "$WORK/rejected.kcm" "$ORIGINAL" "$WORK/out"
check 'changed_keys fails when a map is rejected' fails changed_keys "$ORIGINAL" "$WORK/rejected.kcm"

identical_maps_have_no_differences() {
    compare_maps "$ORIGINAL" "$ORIGINAL" "$WORK/same" && [ ! -s "$WORK/same" ]
}
check 'compare reports no differences between identical maps' identical_maps_have_no_differences

sym_edit_differs_only_in_sym_states() {
    sed 's/^\(    sym:[ ]*\)'"'"'#'"'"'$/\1replace DPAD_LEFT/' "$ORIGINAL" > "$WORK/edited.kcm" &&
        compare_maps "$ORIGINAL" "$WORK/edited.kcm" "$WORK/diff" &&
        [ "$(awk '{print $1}' "$WORK/diff" | sort -u)" = H ] &&
        # SYM, no Alt/Ctrl/Meta, Shift none/general/left/right/both, any of Fn and 3 locks: 5*2*8.
        [ "$(wc -l < "$WORK/diff")" -eq 80 ]
}
check 'compare reports a SYM rule change in exactly the 80 states it can match' \
    sym_edit_differs_only_in_sym_states

sticky_alt_state_is_compared() {
    # A tapped (sticky) Alt reaches the KCM as the general Alt bit alone, without the left bit.
    # Give Q a different general-Alt value while held left Alt keeps its own lalt rule.
    sed "s/^    alt, lalt:\( *\)'1'\$/    alt: '~'\\
    lalt:\1'1'/" "$ORIGINAL" > "$WORK/split.kcm" &&
        compare_maps "$ORIGINAL" "$WORK/split.kcm" "$WORK/diff" &&
        grep -q '^Q 0x2 ' "$WORK/diff" && ! grep -q '^Q 0x12 ' "$WORK/diff"
}
check 'compare covers the general-only Alt state of a tapped Alt' sticky_alt_state_is_compared

keyboard_type_is_compared() {
    sed 's/^type ALPHA$/type FULL/' "$ORIGINAL" > "$WORK/full.kcm" &&
        compare_maps "$ORIGINAL" "$WORK/full.kcm" "$WORK/diff" && grep -q '^- type ' "$WORK/diff"
}
check 'compare reports a changed keyboard type' keyboard_type_is_compared

finish
