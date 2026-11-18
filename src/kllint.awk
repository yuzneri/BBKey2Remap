# Checks a key layout (.kl) against the key-line grammar of the Android 16 AOSP parser
# (KeyLayoutMap::Parser, frameworks/native android-16.0.0_r1).
#   awk -f kllint.awk /path/keycodes.txt /path/FILE.kl   -> exit 0 if accepted, else exit 1
# A rejected layout makes Android fall back to Generic.kl, which gives the KEY2's keys other
# meanings (sym becomes right Alt), so this is stricter than AOSP wherever mirroring a quirk
# would be fragile: only key lines are allowed (no axis/led/sensor/requires_kernel_config, which
# the KEY2 layout does not use), and numbers must be whole tokens (AOSP's parseInt ignores
# trailing characters). tests/kl.test.sh checks it against the real parser.
# Same calling rules as lint.awk: paths starting with "/", no NUL in the file, LC_ALL=C.

function fail(msg) { printf "%s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"; failed = 1; exit 1 }
function skip() { while (P <= length(L) && index(" \t\r", substr(L, P, 1))) P++ }
function token(   start) {
    start = P
    while (P <= length(L) && !index(" \t\r", substr(L, P, 1))) P++
    return substr(L, start, P - start)
}
function eol() { return P > length(L) }
function peek() { return substr(L, P, 1) }

# strtol(token, &end, 0) restricted to whole, unsigned tokens that fit in int32_t.
function number(t,   digits, base, v, i) {
    if (t ~ /^0[xX][0-9A-Fa-f]+$/) { digits = substr(t, 3); base = 16 }
    else if (t ~ /^0[0-7]*$/) { digits = t; base = 8 }
    else if (t ~ /^[1-9][0-9]*$/) { digits = t; base = 10 }
    else fail("expected key code number, got '" t "'")
    if (length(digits) > (base == 16 ? 7 : 9)) fail("key code number too long: " t)
    v = 0
    for (i = 1; i <= length(digits); i++) v = v * base + index("0123456789abcdef", tolower(substr(digits, i, 1))) - 1
    return v
}

BEGIN { split("VIRTUAL FUNCTION GESTURE WAKE FALLBACK_USAGE_MAPPING", f, " "); for (i in f) FLAG[f[i]] = 1 }
FILENAME == ARGV[1] { KEYCODE[$0] = 1; nkeycodes++; next }
{
    L = $0; P = 1
    skip()
    if (eol() || peek() == "#") next
    kw = token()
    if (kw != "key") fail("unsupported keyword '" kw "' (only key lines are allowed)")
    skip(); t = token(); kind = "scan"
    if (t == "usage") { kind = "usage"; skip(); t = token() }
    n = number(t)
    if ((kind SUBSEP n) in mapped) fail("duplicate entry for key " kind " code '" t "'")
    mapped[kind, n] = 1
    skip(); label = token()
    if (!(label in KEYCODE)) fail("unknown key code label '" label "'")
    delete used
    for (;;) {
        skip()
        if (eol() || peek() == "#") break
        flag = token()
        if (!(flag in FLAG)) fail("unknown key flag '" flag "'")
        if (flag in used) fail("duplicate key flag '" flag "'")
        used[flag] = 1
    }
}
END {
    if (failed) exit 1
    if (!nkeycodes) { print "kllint.awk: key code list is empty" > "/dev/stderr"; exit 1 }
}
