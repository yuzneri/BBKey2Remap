# Rewrites the roles of the KEY2's physical modifier keys in a key layout (.kl).
#   awk -f klpatch.awk CONFIG BASE.kl > NEW.kl
# CONFIG holds "# config" and lines kl:SCANCODE=KEYCODE. Only the key code word of the line
# "key SCANCODE KEYCODE [FLAGS]" for each configured scan code changes; every other byte of BASE
# is copied. The caller rejects input containing NUL and checks the result with kllint.awk.
function fail(s) { print s > "/dev/stderr"; bad = 1; exit 1 }
# Scan codes of the KEY2's modifier keys: 42 shift, 56 alt, 100 sym, 110 speed key.
function physical(s) { return s ~ /^(42|56|100|110)$/ }
function modifier(s) { return s ~ /^(SHIFT_LEFT|SHIFT_RIGHT|ALT_LEFT|ALT_RIGHT|CTRL_LEFT|CTRL_RIGHT|META_LEFT|META_RIGHT|SYM|FUNCTION|CAPS_LOCK)$/ }
# Same key codes as patch.awk accepts for replace/fallback (tests/kl.test.sh checks they agree).
function action(s) { return s ~ /^([A-Z]|[0-9]|DPAD_UP|DPAD_DOWN|DPAD_LEFT|DPAD_RIGHT|DPAD_CENTER|TAB|ESCAPE|MOVE_HOME|MOVE_END|PAGE_UP|PAGE_DOWN|INSERT|FORWARD_DEL|DEL|ENTER|SPACE|LANGUAGE_SWITCH|SWITCH_CHARSET|F[1-9]|F1[0-2]|COMMA|PERIOD|MINUS|EQUALS|LEFT_BRACKET|RIGHT_BRACKET|BACKSLASH|SEMICOLON|APOSTROPHE|SLASH|GRAVE|AT|POUND|PLUS|STAR|BACK|MENU|SEARCH|HOME)$/ }
FNR == NR {
    if ($0 == "# config") next
    if (NF != 1 || $0 !~ /^kl:[0-9]+=[A-Z0-9_]+$/) fail("Bad key layout assignment: " $0)
    split(substr($0, 4), kv, "=")
    if (!physical(kv[1]) || !(modifier(kv[2]) || action(kv[2])) || (kv[1] in cfg)) fail("Invalid or duplicate key layout assignment: " $0)
    cfg[kv[1]] = kv[2]; order[++n] = kv[1]
    next
}
{ sub(/\r$/, ""); if (index($0, "\r")) fail("Unsupported carriage return at line " FNR) }
$1 == "key" && ($2 in cfg) {
    # The whole line must have the plain shape the generator understands; anything else stops.
    if ($0 !~ /^[ \t]*key[ \t]+[0-9]+[ \t]+[A-Z0-9_]+([ \t]+[A-Z_]+)*[ \t]*(#.*)?$/) fail("Unsupported key layout line " FNR ": " $0)
    if (++seen[$2] > 1) fail("Repeated scan code " $2)
    match($0, /^[ \t]*key[ \t]+[0-9]+[ \t]+/)
    rest = substr($0, RLENGTH + 1)
    match(rest, /^[A-Z0-9_]+/)
    print substr($0, 1, length($0) - length(rest)) cfg[$2] substr(rest, RLENGTH + 1)
    next
}
{ print }
END {
    if (bad) exit 1
    for (i = 1; i <= n; i++) if (!(order[i] in seen)) fail("Scan code " order[i] " not found in the key layout")
    for (i = 1; i <= n; i++) print "# KEY2_KL " order[i] "=" cfg[order[i]]
}
