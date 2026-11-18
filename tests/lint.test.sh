#!/bin/sh
# src/lint.awk, the on-device KCM grammar check, judged against the real AOSP parser (kcmtool).
# The safety property: whatever lint accepts, AOSP accepts. lint may reject more than AOSP.
. "$ROOT/tests/lib.sh"
LINT="$ROOT/src/lint.awk"
KEYCODES="$ROOT/src/keycodes.txt"

lint() { # IMPL FILE
    LC_ALL=C run_awk "$1" -f "$LINT" "$KEYCODES" "$2"
}

check 'src/keycodes.txt equals the AOSP key code label table' \
    cmp "$KEYCODES" "$(dirname "$AOSP_KEYBOARDS")/keycodes.txt"

for f in "$FIXTURES/key2-base.kcm" "$FIXTURES/key2-v03-live.kcm" "$FIXTURES/synthetic-key2.kcm" \
    "$AOSP_KEYBOARDS"/*.kcm; do
    for impl in busybox gawk mawk; do
        check "$impl lint accepts ${f##*/}" lint "$impl" "$f"
    done
done

# Hand-written edge cases: VERDICT|KCM text with \n escapes. VERDICT is what AOSP does
# (accept/reject) or "stricter" where lint deliberately rejects what AOSP accepts.
cat > "$WORK/cases" <<'EOF'
accept|type ALPHA\nkey A {\n    base: 'a'\n}\n
accept|type ALPHA\n# comment\n\n  key A { # c\n\tbase,shift:'a' # c\n} # c\n
accept|type ALPHA\nkey A {\n    shift+lshift: 'A'\n}\n
accept|type ALPHA\nkey A {\n    base: 'a' fallback TAB\n    sym: replace DPAD_LEFT\n    alt: none\n}\n
accept|type ALPHA\nkey A {\n    base: '\\u00e9'\n    shift: '\\''\n    alt: '\\\\'\n    sym: '\\"'\n    fn: '\\n'\n}\n
accept|type ALPHA\nmap key 0x1e A\nmap key 31 S\nmap key usage 0x07001e A\nkey A {\n    base: 'a'\n}\n
accept|type ALPHA\nkey A {\n    base: 'a'\n}\r\n
accept|type SPECIAL_FUNCTION\n
accept|type FULL\nkey UNKNOWN {\n    base: 'x'\n}\n
reject|key A {\n    base: 'a'\n}\n
reject|type ALPHA\ntype FULL\n
reject|type OVERLAY\n
reject|type ALPHA\nkey A {\n    base: 'a'\n
reject|type ALPHA\nkey A{\n    base: 'a'\n}\n
reject|type ALPHA\nkey A {#\n    base: 'a'\n}\n
reject|type ALPHA\nkey A\n{\n    base: 'a'\n}\n
reject|type ALPHA\nkey NOPE {\n    base: 'a'\n}\n
reject|type ALPHA\nkey A {\n    base: 'a'\n}\nkey A {\n    base: 'a'\n}\n
reject|type ALPHA\nkey A {\n    base: 'a'#c\n}\n
reject|type ALPHA\nkey A {\n    base: 'a'\n}#c\n
reject|type ALPHA\nkey A {\n    base: 'ab'\n}\n
reject|type ALPHA\nkey A {\n    base: '\\u0000'\n}\n
reject|type ALPHA\nkey A {\n    base: '\\x'\n}\n
reject|type ALPHA\nkey A {\n    base: '\\u12g4'\n}\n
reject|type ALPHA\nkey A {\n    base:\n}\n
reject|type ALPHA\nkey A {\n    base, base: 'a'\n}\n
reject|type ALPHA\nkey A {\n    base: 'a'\n    base: 'b'\n}\n
reject|type ALPHA\nkey A {\n    shift+shift: 'a'\n}\n
reject|type ALPHA\nkey A {\n    shift+: 'a'\n}\n
reject|type ALPHA\nkey A {\n    , base: 'a'\n}\n
reject|type ALPHA\nkey A {\n    base 'a'\n}\n
reject|type ALPHA\nkey A {\n    base: 'a' replace TAB\n}\n
reject|type ALPHA\nkey A {\n    base: none replace TAB\n}\n
reject|type ALPHA\nkey A {\n    base: fallback TAB replace TAB\n}\n
reject|type ALPHA\nkey A {\n    base: 'a' 'b'\n}\n
reject|type ALPHA\nkey A {\n    base: replace NOPE\n}\n
reject|type ALPHA\nkey A {\n    base: 'a'\n    key B {\n}\n
reject|type ALPHA\nmap key 08 A\n
reject|type ALPHA\nmap key 010 A\nmap key 8 S\n
reject|type ALPHA\nmap key 0x1e NOPE\n
reject|type ALPHA\nmap A\n
reject|type ALPHA\nbogus\n
stricter|type ALPHA\nkey A {\n    label: 'A' fallback TAB\n}\n
stricter|type ALPHA\nmap key +5 A\n
EOF
n=0
while IFS='|' read -r verdict text; do
    n=$((n + 1))
    printf '%b' "$text" > "$WORK/case$n.kcm"
    case_matches() {
        if "$KCMTOOL" check "$WORK/case$n.kcm" >/dev/null 2>&1; then aosp=accept; else aosp=reject; fi
        for impl in busybox gawk mawk; do
            if lint "$impl" "$WORK/case$n.kcm" 2>/dev/null; then l=accept; else l=reject; fi
            case "$verdict:$aosp:$l" in
                accept:accept:accept|reject:reject:reject|stricter:accept:reject) ;;
                *) echo "expected $verdict, AOSP $aosp, $impl lint $l"; return 1;;
            esac
        done
    }
    check "edge case $n ($verdict): $(printf '%s' "$text" | cut -c1-60)" case_matches
done < "$WORK/cases"

generator_codes_are_valid() {
    bad='' used=0
    while read -r code; do
        write_config "$WORK/code" "sym:A=R_$code"
        run_awk busybox -f "$ROOT/src/patch.awk" "$WORK/code" "$FIXTURES/key2-base.kcm" > "$WORK/code.kcm" 2>/dev/null || continue
        used=$((used + 1))
        "$KCMTOOL" check "$WORK/code.kcm" >/dev/null 2>&1 || bad="$bad $code"
    done < "$KEYCODES"
    [ "$used" -gt 0 ] || { echo 'generator accepted no key code'; return 1; }
    [ -z "$bad" ] || { echo "AOSP rejects:$bad"; return 1; }
}
check 'every key code the generator accepts as a replacement is accepted by AOSP' generator_codes_are_valid

# Random single edits of real maps. Fails on any mutant lint accepts but AOSP rejects.
mutants_never_falsely_accepted() {
    python3 -I - "$WORK/mut" "$FIXTURES/key2-base.kcm" "$AOSP_KEYBOARDS/Generic.kcm" <<'PY'
import os, random, sys
out, sources = sys.argv[1], sys.argv[2:]
os.makedirs(out)
rng = random.Random(20261118)
alphabet = [" ", "\t", "\r", "#", ":", ",", "{", "}", "'", "\\", "+", "x", "0", "u", "\n"]
n = 0
for src in sources:
    lines = open(src, encoding="ascii").read().split("\n")
    for _ in range(400):
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
        open(os.path.join(out, "%04d.kcm" % n), "w", encoding="ascii").write("\n".join(m))
PY
    accepted=0 stricter=0 false_accept=''
    for f in "$WORK"/mut/*.kcm; do
        if lint busybox "$f" 2>/dev/null; then l=1; else l=0; fi
        if "$KCMTOOL" check "$f" >/dev/null 2>&1; then a=1; else a=0; fi
        [ "$l$a" = 10 ] && false_accept="$false_accept ${f##*/}"
        [ "$l$a" = 11 ] && accepted=$((accepted + 1))
        [ "$l$a" = 01 ] && stricter=$((stricter + 1))
    done
    echo "mutants accepted by both: $accepted, rejected only by lint: $stricter" > "$WORK/mut-summary"
    [ -z "$false_accept" ] || { echo "lint accepted but AOSP rejected:$false_accept"; return 1; }
}
check 'lint never accepts a mutated map that AOSP rejects (800 mutants)' mutants_never_falsely_accepted
sed 's/^/      /' "$WORK/mut-summary"

finish
