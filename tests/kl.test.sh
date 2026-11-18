#!/bin/sh
# Key layout editing: src/klpatch.awk (generator) and src/kllint.awk (on-device grammar check),
# judged by the unmodified AOSP KeyLayoutMap parser built on the host (kltool).
. "$ROOT/tests/lib.sh"
: "${KLTOOL:?run tests through tests/run.sh}"
KL="$FIXTURES/key2-base.kl"
KEYCODES="$ROOT/src/keycodes.txt"

kllint() { LC_ALL=C run_awk "$1" -f "$ROOT/src/kllint.awk" "$KEYCODES" "$2"; }
klpatch() { run_awk "$1" -f "$ROOT/src/klpatch.awk" "$2" "$3"; }
dump() { "$KLTOOL" dump "$1"; }

check 'AOSP parser accepts the device key layout' "$KLTOOL" check "$KL"
for impl in busybox gawk mawk; do
    check "$impl kllint accepts the device key layout" kllint "$impl" "$KL"
done
# Generic.kl also has axis and led lines, which kllint deliberately rejects; its key lines are
# a larger real-world corpus.
grep -E '^[[:space:]]*(#|key[[:space:]]|$)' "$AOSP_KEYBOARDS/Generic.kl" > "$WORK/generic-keys.kl"
check 'AOSP parser accepts the key lines of Generic.kl' "$KLTOOL" check "$WORK/generic-keys.kl"
check 'kllint accepts the key lines of Generic.kl' kllint busybox "$WORK/generic-keys.kl"

# VERDICT|text: what AOSP does, or "stricter" where kllint deliberately rejects what AOSP accepts.
cat > "$WORK/cases" <<'CASES'
accept|key 42 SHIFT_LEFT\n
accept|# c\n\n  key 42   SHIFT_LEFT   # c\n\tkey 0x38 ALT_LEFT\n
accept|key 42 SHIFT_LEFT WAKE\nkey 43 A VIRTUAL FUNCTION\n
accept|key usage 0x070004 A\nkey 30 A\n
accept|key 42 SHIFT_LEFT\r\n
accept|
reject|key 42 NOPE\n
reject|key 42\n
reject|key\n
reject|key 42 SHIFT_LEFT NOPE\n
reject|key 42 SHIFT_LEFT WAKE WAKE\n
reject|key 42 SHIFT_LEFT\nkey 42 A\n
reject|key 052 SHIFT_LEFT\nkey 42 A\n
reject|key usage 7 A\nkey usage 7 B\n
reject|key 42 SHIFT_LEFT#c\n
reject|kee 42 A\n
reject|key A 42\n
stricter|key 42abc SHIFT_LEFT\n
stricter|key -5 A\n
stricter|axis 0x00 X\n
stricter|led 0x00 NUM_LOCK\n
CASES
n=0
while IFS='|' read -r verdict text; do
    n=$((n + 1))
    printf '%b' "$text" > "$WORK/case$n.kl"
    case_matches() {
        if "$KLTOOL" check "$WORK/case$n.kl" >/dev/null 2>&1; then aosp=accept; else aosp=reject; fi
        for impl in busybox gawk mawk; do
            if kllint "$impl" "$WORK/case$n.kl" 2>/dev/null; then l=accept; else l=reject; fi
            case "$verdict:$aosp:$l" in
                accept:accept:accept|reject:reject:reject|stricter:accept:reject) ;;
                *) echo "expected $verdict, AOSP $aosp, $impl kllint $l"; return 1;;
            esac
        done
    }
    check "kl edge case $n ($verdict): $(printf '%s' "$text" | cut -c1-50)" case_matches
done < "$WORK/cases"

kl_mutants_never_falsely_accepted() {
    python3 -I - "$WORK/klmut" "$KL" "$WORK/generic-keys.kl" <<'PY'
import os, random, sys
out, sources = sys.argv[1], sys.argv[2:]
os.makedirs(out)
rng = random.Random(20261118)
alphabet = [" ", "\t", "\r", "#", "0", "x", "1", "A", "_", "-", "\n", "W"]
n = 0
for src in sources:
    lines = open(src, encoding="ascii").read().split("\n")
    for _ in range(300):
        m = list(lines)
        op = rng.randrange(5)
        i = rng.randrange(len(m))
        if op == 0:
            del m[i]
        elif op == 1:
            m.insert(i, m[i])
        else:
            s = m[i]
            p = rng.randrange(len(s) + 1)
            if op == 2:
                s = s[:p] + rng.choice(alphabet) + s[p:]
            elif op == 3 and s:
                s = s[:p] + s[p + 1:]
            else:
                s = s[:p] + rng.choice(alphabet) + s[p + 1:]
            m[i] = s
        n += 1
        open(os.path.join(out, "%04d.kl" % n), "w", encoding="ascii").write("\n".join(m))
PY
    both=0 stricter=0 false_accept=''
    for f in "$WORK"/klmut/*.kl; do
        if kllint busybox "$f" 2>/dev/null; then l=1; else l=0; fi
        if "$KLTOOL" check "$f" >/dev/null 2>&1; then a=1; else a=0; fi
        [ "$l$a" = 10 ] && false_accept="$false_accept ${f##*/}"
        [ "$l$a" = 11 ] && both=$((both + 1))
        [ "$l$a" = 01 ] && stricter=$((stricter + 1))
    done
    echo "mutants accepted by both: $both, rejected only by kllint: $stricter" > "$WORK/klmut-summary"
    [ -z "$false_accept" ] || { echo "kllint accepted but AOSP rejected:$false_accept"; return 1; }
}
check 'kllint never accepts a mutated layout that AOSP rejects (600 mutants)' kl_mutants_never_falsely_accepted
sed 's/^/      /' "$WORK/klmut-summary"

# awk ends its last output line with a newline; the device layout has none at the end.
empty_config_reproduces_layout() {
    { cat "$KL"; [ -z "$(tail -c 1 "$KL")" ] || echo; } > "$WORK/expected.kl"
    write_config "$WORK/empty" && for impl in busybox gawk mawk; do
        klpatch "$impl" "$WORK/empty" "$KL" > "$WORK/out.kl" && cmp "$WORK/expected.kl" "$WORK/out.kl" || return 1
    done
}
check 'empty config reproduces the key layout, only ending the last line (3 awks)' empty_config_reproduces_layout

# roles_become SCAN=KEYCODE...: after klpatch, exactly those scan codes change, AOSP and kllint
# accept the result, and the flags stay.
roles_become() {
    cfg=''
    for a in "$@"; do cfg="$cfg kl:$a"; done
    # shellcheck disable=SC2086
    write_config "$WORK/roles" $cfg &&
        klpatch busybox "$WORK/roles" "$WORK/base.kl" > "$WORK/new.kl" &&
        "$KLTOOL" check "$WORK/new.kl" >/dev/null && kllint busybox "$WORK/new.kl" &&
        dump "$WORK/base.kl" > "$WORK/before" && dump "$WORK/new.kl" > "$WORK/after" || return 1
    expected=$(for a in "$@"; do echo "${a%%=*} ${a#*=}"; done | sort)
    actual=$(diff "$WORK/before" "$WORK/after" | sed -n 's/^> \([0-9]*\) \([A-Z0-9_]*\) .*/\1 \2/p' | sort)
    [ "$expected" = "$actual" ] || { echo "expected: $expected"; echo "changed: $actual"; return 1; }
    [ "$(diff "$WORK/before" "$WORK/after" | grep -c '^<')" -eq "$#" ]
}
cp "$KL" "$WORK/base.kl"
check 'Speed key can become Escape' roles_become 110=ESCAPE
check 'SYM can become left Ctrl while Speed becomes SYM' roles_become 100=CTRL_LEFT 110=SYM
check 'all four modifier keys can change at once' roles_become 42=ALT_LEFT 56=SHIFT_LEFT 100=META_LEFT 110=TAB
sed 's/^key 42 .*/key 42    SHIFT_LEFT WAKE # left shift/' "$KL" > "$WORK/base.kl"
check 'a changed line keeps its flags and comment' sh -c '
    printf "# config\nkl:42=CAPS_LOCK\n" > "$1/c" && busybox awk -f "$2" "$1/c" "$1/base.kl" | grep -qx "key 42    CAPS_LOCK WAKE # left shift"' _ "$WORK" "$ROOT/src/klpatch.awk"
cp "$KL" "$WORK/base.kl"

markers_record_roles() {
    write_config "$WORK/m" kl:110=ESCAPE kl:56=CTRL_LEFT &&
        klpatch busybox "$WORK/m" "$KL" | tail -n 2 | tr '\n' ' ' | grep -qx '# KEY2_KL 110=ESCAPE # KEY2_KL 56=CTRL_LEFT '
}
check 'saved roles are recorded as KEY2_KL comments' markers_record_roles

# refuses CONTENT ASSIGNMENT...: klpatch exits 1 for every awk.
refuses() {
    printf '%b' "$1" > "$WORK/odd.kl"; shift
    write_config "$WORK/r" "$@"
    for impl in busybox gawk mawk; do
        klpatch "$impl" "$WORK/r" "$WORK/odd.kl" >/dev/null 2>&1
        status=$?
        [ "$status" -eq 1 ] || { echo "$impl exit $status"; return 1; }
    done
}
check 'klpatch refuses a scan code that is not a KEY2 modifier key' refuses 'key 30 A\n' kl:30=CTRL_LEFT
check 'klpatch refuses a target key code outside the allowed set' refuses 'key 110 CTRL_LEFT\n' kl:110=POWER
check 'klpatch refuses a configured scan code missing from the layout' refuses 'key 42 SHIFT_LEFT\n' kl:110=SYM
check 'klpatch refuses a configured scan code that appears twice' refuses 'key 110 CTRL_LEFT\nkey 110 SYM\n' kl:110=SYM
check 'klpatch refuses a configured line it does not understand' refuses 'key 110 CTRL_LEFT  extra#x\n' kl:110=SYM
check 'klpatch refuses a carriage return inside a line' refuses 'key 110\rCTRL_LEFT\n' kl:110=SYM
check 'klpatch refuses a duplicate assignment' refuses 'key 110 CTRL_LEFT\n' kl:110=SYM kl:110=TAB
check 'klpatch refuses a malformed assignment' refuses 'key 110 CTRL_LEFT\n' 'kl:110:SYM'
crlf_layout_is_handled() {
    sed 's/$/\r/' "$KL" > "$WORK/crlf.kl" && write_config "$WORK/c" kl:110=TAB &&
        klpatch busybox "$WORK/c" "$WORK/crlf.kl" > "$WORK/crlf.out.kl" && ! grep -q "$(printf '\r')" "$WORK/crlf.out.kl" &&
        "$KLTOOL" dump "$WORK/crlf.out.kl" | grep -qx '110 TAB 0x0'
}
check 'klpatch handles a CRLF layout and writes LF' crlf_layout_is_handled

targets_match_generator() {
    kl='' kcm=''
    while read -r code; do
        write_config "$WORK/t" "kl:110=$code"
        klpatch busybox "$WORK/t" "$KL" >/dev/null 2>&1 && kl="$kl $code"
        write_config "$WORK/t" "sym:A=R_$code"
        run_awk busybox -f "$ROOT/src/patch.awk" "$WORK/t" "$FIXTURES/key2-base.kcm" >/dev/null 2>&1 && kcm="$kcm $code"
    done < "$KEYCODES"
    modifiers=' SHIFT_LEFT SHIFT_RIGHT ALT_LEFT ALT_RIGHT CTRL_LEFT CTRL_RIGHT META_LEFT META_RIGHT SYM FUNCTION CAPS_LOCK'
    want=$(printf '%s\n' $kcm $modifiers | sort -u | tr '\n' ' ')
    got=$(printf '%s\n' $kl | sort -u | tr '\n' ' ')
    [ "$want" = "$got" ] || { echo "want: $want"; echo "got:  $got"; return 1; }
}
check 'modifier keys accept exactly the replace targets plus the modifier key codes' targets_match_generator

finish
