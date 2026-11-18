# Checks a base-format KCM against the grammar of the Android 16 AOSP parser
# (KeyCharacterMap::Parser, frameworks/native android-16.0.0_r1).
#   awk -f lint.awk /path/keycodes.txt /path/FILE.kcm   -> exit 0 if accepted, else exit 1 with a reason
# Callers must pass paths starting with "/" (awk reads an operand like "a=b" as an assignment) and
# must reject files containing NUL first: busybox awk ends a record at NUL, whereas the AOSP
# tokenizer treats NUL as whitespace, so the two would see different lines.
# Android has no on-device validator (validatekeymaps is a host tool) and silently falls back to
# Generic.kcm when the real parser rejects a map, so this mirrors the parser token by token. Where
# mirroring a quirk exactly would be fragile it is stricter (rejects more), never looser; the
# differential tests in tests/lint.test.sh check that against the real parser.
# Run with LC_ALL=C so that every byte is one character.

function fail(msg) { printf "%s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"; failed = 1; exit 1 }

# Tokenizer over the current line L, cursor P (1-based). Tokens never span lines.
function skip(delims) { while (P <= length(L) && index(delims, substr(L, P, 1))) P++ }
function token(delims,   start) {
    start = P
    while (P <= length(L) && !index(delims, substr(L, P, 1))) P++
    return substr(L, start, P - start)
}
function eol() { return P > length(L) }
function peek() { return substr(L, P, 1) }
function expect_end() { skip(WS); if (!eol() && peek() != "#") fail("expected end of line or comment") }

# strtol(token, &end, 0) with the whole token consumed. Stricter: no sign, and few enough digits
# that the value fits in int32_t, so duplicates compare exactly as AOSP's truncated values do.
function code_number(t,   digits, base, v, i, c) {
    if (t ~ /^0[xX][0-9A-Fa-f]+$/) { digits = substr(t, 3); base = 16 }
    else if (t ~ /^0[0-7]*$/) { digits = t; base = 8 }
    else if (t ~ /^[1-9][0-9]*$/) { digits = t; base = 10 }
    else fail("expected key code number, got '" t "'")
    if (length(digits) > (base == 16 ? 7 : 9)) fail("key code number too long: " t)
    v = 0
    for (i = 1; i <= length(digits); i++) {
        c = index("0123456789abcdef", tolower(substr(digits, i, 1))) - 1
        v = v * base + c
    }
    return v
}

function keycode(t) { if (!(t in KEYCODE)) fail("unknown key code label '" t "'"); return t }

# Meta state of a property token as AOSP parseModifier computes it; fails like AOSP does.
function modifier(t,   n, parts, i, bits, total) {
    if (t == "base") return 0
    if (t == "" || t ~ /^[+]|[+]$|[+][+]/) fail("expected a property name or modifier, got '" t "'")
    n = split(t, parts, "+")
    total = 0
    for (i = 1; i <= n; i++) {
        if (!(parts[i] in MOD)) fail("expected a property name or modifier, got '" t "'")
        bits = MOD[parts[i]]
        if (and_(total, bits)) fail("duplicate modifier combination '" t "'")
        total += bits
    }
    return total
}
# Bitwise AND for the distinct powers of two in MOD; awk has no portable bit operators.
function and_(a, b,   r, bit) {
    r = 0
    for (bit = 1; bit <= 4194304; bit *= 2)
        if (int(a / bit) % 2 && int(b / bit) % 2) r += bit
    return r
}

# One character literal at P; returns its value (never 0).
function char_literal(   c, v, h, i) {
    P++
    c = substr(L, P++, 1)
    if (c == "\\") {
        c = substr(L, P++, 1)
        if (c == "n") v = 10
        else if (c == "t") v = 9
        else if (c == "\\" || c == "'" || c == "\"") v = 1
        else if (c == "u") {
            h = substr(L, P, 4); P += 4
            if (h !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) fail("malformed character literal")
            v = 0
            for (i = 1; i <= 4; i++) v = v * 16 + index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
        } else fail("malformed character literal")
    } else if (c ~ /^[ -~]$/ && c != "'") v = 1
    else fail("malformed character literal")
    if (substr(L, P++, 1) != "'") fail("malformed character literal")
    if (token(WS) != "") fail("malformed character literal")
    if (v == 0) fail("invalid character literal for key")
    return v
}

function key_property(   t, props, nprops, i, ch, have_char, have_fallback, have_replace, have_literal, m) {
    t = token(WSP)
    if (t == "}") { state = "top"; expect_end(); return }
    nprops = 0
    for (;;) {
        props[++nprops] = (t == "label" || t == "number") ? t : "m" modifier(t)
        skip(WS)
        ch = eol() ? "" : substr(L, P++, 1)
        if (ch == ":") break
        if (ch != ",") fail("expected ',' or ':' after property name")
        skip(WS); t = token(WSP)
    }
    skip(WS)
    do {
        if (peek() == "'") {
            char_literal()
            if (have_char) fail("cannot combine multiple character literals or 'none'")
            if (have_replace) fail("cannot combine character literal with replace action")
            have_char = have_literal = 1
        } else {
            t = token(WS)
            if (t == "none") {
                if (have_char) fail("cannot combine multiple character literals or 'none'")
                if (have_replace) fail("cannot combine 'none' with replace action")
                have_char = 1
            } else if (t == "fallback" || t == "replace") {
                skip(WS); keycode(token(WS))
                if (have_fallback || have_replace) fail("cannot combine multiple fallback/replacement key codes")
                if (t == "replace" && have_char) fail("cannot combine character literal with replace action")
                if (t == "replace") have_replace = 1; else have_fallback = 1
            } else fail("expected a key behavior after ':'")
        }
        skip(WS)
    } while (!eol() && peek() != "#")
    for (i = 1; i <= nprops; i++) {
        m = props[i]
        if (m == "label" || m == "number") {
            # Stricter than AOSP: exactly one character literal, given once.
            if (!have_literal || have_fallback || have_replace) fail(m " needs a single character literal")
            if ((KEY SUBSEP m) in seen_prop) fail("duplicate " m " for key")
        } else if ((KEY SUBSEP m) in seen_prop) fail("duplicate key behavior for modifier")
        seen_prop[KEY, m] = 1
    }
}

BEGIN {
    WS = " \t\r"; WSP = " \t\r,:"
    split("shift lshift rshift alt lalt ralt ctrl lctrl rctrl meta lmeta rmeta sym fn capslock numlock scrolllock", names, " ")
    split("1 64 128 2 16 32 4096 8192 16384 65536 131072 262144 4 8 1048576 2097152 4194304", bits, " ")
    for (i = 1; i <= 17; i++) MOD[names[i]] = bits[i] + 0
    state = "top"
}
FILENAME == ARGV[1] { KEYCODE[$0] = 1; nkeycodes++; next }
{
    L = $0; P = 1
    skip(WS)
    if (eol() || peek() == "#") next
    if (state == "key") { key_property(); expect_end(); next }
    kw = token(WS)
    skip(WS)
    if (kw == "type") {
        if (type != "") fail("duplicate keyboard 'type' declaration")
        type = token(WS)
        # OVERLAY is a valid label but a base map must not use it.
        if (type !~ /^(NUMERIC|PREDICTIVE|ALPHA|FULL|SPECIAL_FUNCTION)$/) fail("unsupported keyboard type '" type "'")
    } else if (kw == "map") {
        if (token(WS) != "key") fail("expected 'key' after 'map'")
        skip(WS); t = token(WS); kind = "scan"
        if (t == "usage") { kind = "usage"; skip(WS); t = token(WS) }
        n = code_number(t)
        if ((kind SUBSEP n) in mapped) fail("duplicate entry for key " kind " code '" t "'")
        mapped[kind, n] = 1
        skip(WS); keycode(token(WS))
    } else if (kw == "key") {
        KEY = keycode(token(WS))
        if (KEY in seen_key) fail("duplicate entry for key code '" KEY "'")
        seen_key[KEY] = 1
        skip(WS)
        if (token(WS) != "{") fail("expected '{' after key code label")
        state = "key"
    } else fail("expected keyword, got '" kw "'")
    expect_end()
}
END {
    if (failed) exit 1
    if (!nkeycodes) { print "lint.awk: key code list is empty" > "/dev/stderr"; exit 1 }
    if (state != "top") fail("unterminated key description at end of file")
    if (type == "") fail("keyboard layout missing required keyboard 'type' declaration")
}
