#!/system/bin/sh
# Root-side helper for the WebUI.
#   remap.sh read                 saved assignments, one per line
#   remap.sh original             the original KCM
#   remap.sh preview ASSIGN...    the KCM that save would write (nothing is written)
#   remap.sh save ASSIGN...       generate, check and store the maps; applied at the next boot
#   remap.sh status               installation diagnostics as key=value lines
#   remap.sh verify               check that the stored originals can be regenerated
#   remap.sh reboot               reboot the device so that saved maps take effect
#   remap.sh touch-start          (re)start touchgestured if gesture mode is saved and in effect
#   remap.sh touch-stop           stop touchgestured
# ASSIGN is MODIFIERS:KEY=VALUE for the character map, e.g. sym:H=R_DPAD_LEFT (validated again
# by patch.awk), or kl:SCANCODE=KEYCODE for a modifier key's role in the key layout, e.g.
# kl:110=CTRL_LEFT (validated again by klpatch.awk), or tp:ID=VALUE for the keyboard's touch
# surface: tp:mode=off|gesture, a threshold such as tp:step_mm=3, a gesture's key such as
# tp:1_swipe_left=DPAD_LEFT+shift, or tp:3_pass=on (checked again by touchgestured check).
set -eu
case $0 in */*) dir=${0%/*} ;; *) dir=. ;; esac
BASE=$(cd "$dir" && pwd -P)
# Prefix for absolute system paths: empty on the device, a fake root in tests/remap.test.sh.
R=${KEY2REMAP_ROOT:-}
MODID=key2_remap_gui
DST="$BASE/system/vendor/usr/keychars/stmpe.kcm"
LIVE="$R/vendor/usr/keychars/stmpe.kcm"
DST_KL="$BASE/system/vendor/usr/keylayout/stmpe.kl"
LIVE_KL="$R/vendor/usr/keylayout/stmpe.kl"
# Scan codes of the KEY2's physical modifier keys: shift, alt, sym, speed key.
PHYSICAL='42 56 100 110'
BB="$R/data/adb/magisk/busybox"
LOCK="$BASE/.save.lock"
# The touch surface is turned off by listing it in an excluded-input-devices.xml. Android reads the
# one in /system/etc together with the vendor one, and the KEY2 has none in /system/etc, so the
# module adds its own there instead of copying and editing the vendor list.
TP_DEVICE=touch_keypad
DST_TP="$BASE/system/etc/excluded-input-devices.xml"
LIVE_TP="$R/system/etc/excluded-input-devices.xml"
TP_MARK_RE='<!-- KEY2_TP mode=(off|gesture) -->'
# Gesture mode: touchgestured reads the surface and sends keys through a virtual keyboard, whose key
# layout and the passthrough touchpad's IDC are found by device name.
TG="$BASE/bin/touchgestured"
DST_TG_CONF="$BASE/touchgestured.conf"
DST_TG_KL="$BASE/system/usr/keylayout/key2remap_touch_keys.kl"
DST_TG_IDC="$BASE/system/usr/idc/key2remap_touch_pad.idc"
LIVE_TG_KL="$R/system/usr/keylayout/key2remap_touch_keys.kl"
TG_PID="$BASE/.touchgestured.pid"
TG_LOG="$BASE/touchgestured.log"

fail() { echo "$*" >&2; exit 1; }
runawk() { if [ -x "$BB" ]; then LC_ALL=C "$BB" awk "$@"; else LC_ALL=C awk "$@"; fi; }
# busybox awk ends a record at NUL while Android's tokenizer treats NUL as whitespace, so the
# generator and lint.awk could read a different file than Android does. Refuse such input.
has_nul() { [ $(($(tr -d '\000' < "$1" | wc -c))) -ne $(($(wc -c < "$1"))) ]; }

# generate CONFIG OUT: build the map from base.kcm and check it with Android's KCM grammar.
generate() {
    has_nul "$BASE/base.kcm" && fail '元の文字配列にNUL文字が含まれているため、保存しませんでした。'
    runawk -f "$BASE/patch.awk" "$1" "$BASE/base.kcm" > "$2" || fail '文字配列を生成できなかったため、保存しませんでした。'
    [ -s "$2" ] || fail '生成した文字配列が空のため、保存しませんでした。'
    has_nul "$2" && fail '生成した文字配列にNUL文字が含まれているため、保存しませんでした。'
    runawk -f "$BASE/lint.awk" "$BASE/keycodes.txt" "$2" >&2 ||
        fail '生成した文字配列がAndroidの文法検査に通らなかったため、保存しませんでした。'
}

# generate_kl CONFIG OUT: build the key layout from base.kl and check it with Android's grammar.
generate_kl() {
    [ -s "$BASE/base.kl" ] || fail '元のキー配置が保存されていません。修飾キーの割り当てを変えるには、モジュールを入れ直してください。'
    has_nul "$BASE/base.kl" && fail '元のキー配置にNUL文字が含まれているため、保存しませんでした。'
    runawk -f "$BASE/klpatch.awk" "$1" "$BASE/base.kl" > "$2" || fail 'キー配置を生成できなかったため、保存しませんでした。'
    [ -s "$2" ] || fail '生成したキー配置が空のため、保存しませんでした。'
    has_nul "$2" && fail '生成したキー配置にNUL文字が含まれているため、保存しませんでした。'
    runawk -f "$BASE/kllint.awk" "$BASE/keycodes.txt" "$2" >&2 ||
        fail '生成したキー配置がAndroidの文法検査に通らなかったため、保存しませんでした。'
}

# write_configs KCM_CONFIG KL_CONFIG TP_CONFIG ASSIGN...: the generators' config files, kl:
# assignments to the second and tp: ones other than tp:mode to the third, without "tp:". Only a
# closed ASCII alphabet passes, with "." added for tp: thresholds. Sets KL_COUNT, TP_COUNT and
# TP_MODE (rom, off or gesture).
write_configs() {
    kcm=$1 kl=$2 tp=$3; shift 3
    [ "$#" -le 1500 ] || fail '割り当ては1500件までです。'
    printf '# config\n' > "$kcm"
    printf '# config\n' > "$kl"
    : > "$tp"
    KL_COUNT=0 TP_COUNT=0 TP_MODE=rom
    for item in "$@"; do
        case "$item" in
            tp:*[!A-Za-z0-9_+:=.]*) fail '割り当てに使えない文字が含まれています。' ;;
            tp:*) ;;
            *[!A-Za-z0-9_+:=]*|'') fail '割り当てに使えない文字が含まれています。' ;;
        esac
        case "$item" in
            kl:*) printf '%s\n' "$item" >> "$kl"; KL_COUNT=$((KL_COUNT + 1)) ;;
            tp:mode=off|tp:mode=gesture)
                [ "$TP_MODE" = rom ] || fail 'タッチ操作の設定が重複しています。'; TP_MODE=${item#tp:mode=} ;;
            tp:*) check_touch "${item#tp:}" "$tp"; printf '%s\n' "${item#tp:}" >> "$tp"; TP_COUNT=$((TP_COUNT + 1)) ;;
            *) printf '%s\n' "$item" >> "$kcm" ;;
        esac
    done
}

# check_touch ID=VALUE TP_CONFIG: the form of one tp: assignment and that its ID is not yet in
# TP_CONFIG. Ranges, modifier names and key code labels are checked on the generated files.
check_touch() {
    id=${1%%=*} value=${1#*=}
    case "$id" in
        start_mm|step_mm|flick_mm_s|tap_ms|hold_ms|gather_ms|after_key_ms)
            # The same grammar as the WebUI's (kcm.js): digits, optionally one "." between digits.
            case "$value" in ''|*[!0-9.]*|.*|*.|*.*.*) fail 'タッチ操作の設定が正しくありません。' ;; esac ;;
        [123]_swipe_up|[123]_swipe_down|[123]_swipe_left|[123]_swipe_right|[123]_tap|\
        [123]_flick_up|[123]_flick_down|[123]_flick_left|[123]_flick_right|\
        [123]_flick_upleft|[123]_flick_upright|[123]_flick_downleft|[123]_flick_downright)
            case "$value" in [A-Z0-9]*) ;; *) fail 'タッチ操作の設定が正しくありません。' ;; esac
            case "$value" in *[!A-Za-z0-9_+]*|*+|*++*) fail 'タッチ操作の設定が正しくありません。' ;; esac ;;
        [123]_pass) [ "$value" = on ] || fail 'タッチ操作の設定が正しくありません。' ;;
        *) fail 'タッチ操作の設定が正しくありません。' ;;
    esac
    ! grep -q "^$id=" "$2" || fail 'タッチ操作の設定が重複しています。'
}

# generate_touch TP_CONFIG STMPE_KL CONF_OUT KL_OUT: touchgestured's settings and the gesture
# keyboard's key layout, each checked by the program that reads it (or Android's KL grammar).
generate_touch() {
    runawk -v kl="$4" -f "$BASE/touch.awk" "$2" "$1" > "$3" || fail 'タッチ操作の設定を生成できなかったため、保存しませんでした。'
    "$TG" check "$3" >&2 || fail 'タッチ操作の設定が正しくないため、保存しませんでした。'
    runawk -f "$BASE/kllint.awk" "$BASE/keycodes.txt" "$4" >&2 ||
        fail 'ジェスチャーに割り当てたキーがAndroidの文法検査に通らなかったため、保存しませんでした。'
}

# tp_blockers: why this module's excluded-input-devices.xml would not be the one in effect, one
# "KEY=VALUE" line each: a live file the module did not write, or another module adding one.
tp_blockers() {
    if [ -e "$LIVE_TP" ] && ! grep -qxE "$TP_MARK_RE" "$LIVE_TP"; then echo "tp_foreign=/system/etc/excluded-input-devices.xml"; fi
    for m in "$R"/data/adb/modules/*; do
        [ -d "$m" ] && [ "${m##*/}" != "$MODID" ] && [ ! -e "$m/disable" ] || continue
        [ -e "$m/system/etc/excluded-input-devices.xml" ] && echo "tp_conflict_module=${m##*/}"
    done
    return 0
}

# generate_tp MODE OUT: the excluded device list that takes the touch surface from Android, marked
# with MODE (off or gesture).
generate_tp() {
    printf '<?xml version="1.0" encoding="utf-8"?>\n<!-- KEY2_TP mode=%s -->\n<devices>\n    <device name="%s"/>\n</devices>\n' \
        "$1" "$TP_DEVICE" > "$2"
}

# tp_mode FILE: the mode an excluded device list of this module is marked with (empty if none).
tp_mode() { [ ! -e "$1" ] || sed -nE 's/^<!-- KEY2_TP mode=(off|gesture) -->$/\1/p' "$1" | head -n 1; }

# The lock is a symlink whose target is the owner's PID, created atomically by ln -s. A lock whose
# owner is gone (WebUI X may kill its shell in the background) is taken over instead of blocking
# saves forever. The owner counts as alive only while that PID still runs remap.sh, because
# Android reuses PIDs and a stale lock could otherwise name an unrelated long-lived process.
# Two sessions recovering the same stale lock at once could both proceed; the GUI runs one save
# at a time, so that window is accepted.
acquire_lock() {
    ln -s "$$" "$LOCK" 2>/dev/null && return 0
    owner=$(readlink "$LOCK" 2>/dev/null || :)
    case "$owner" in
        ''|*[!0-9]*) ;;
        *) tr '\000' ' ' 2>/dev/null < "/proc/$owner/cmdline" | grep -q 'remap\.sh' &&
            fail '別の保存が実行中です。少し待ってからやり直してください。' ;;
    esac
    rm -f "$LOCK"
    ln -s "$$" "$LOCK" 2>/dev/null || fail '別の保存が実行中です。少し待ってからやり直してください。'
}

# copy_label FROM FILE: give FILE the SELinux label of the live file FROM. Best effort: Magisk
# copies the real file's label onto the module file at every boot, so a failure is only reported.
copy_label() {
    label=$(ls -Z "$1" 2>/dev/null) || label=''
    label=${label%% *}
    case "$label" in
        u:object_r:*:s0) chcon "$label" "$2" 2>/dev/null && return 0 ;;
    esac
    echo "WARNING: $1のSELinuxラベルを付けられませんでした。次回の起動時にMagiskが付け直します。"
}

# label_new_system_file FILE: a file Magisk adds to /system has no live file to copy a label from,
# and Magisk mounts it with the module file's own label, so give it the one /system/etc files have.
label_new_system_file() {
    chcon u:object_r:system_file:s0 "$1" 2>/dev/null ||
        echo "WARNING: ${1##*/}のSELinuxラベルを付けられませんでした。再起動後、診断でタッチ操作の設定が効いているか確かめてください。"
}

# touch_pid: the PID of the running touchgestured, or nothing. The PID file alone is not trusted,
# since Android reuses PIDs: the process must still be this module's touchgestured.
touch_pid() {
    pid=$(cat "$TG_PID" 2>/dev/null) || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    tr '\000' ' ' 2>/dev/null < "/proc/$pid/cmdline" | grep -qF "$TG" && echo "$pid"
    return 0
}

# touch_stop: stop touchgestured; fails if it is still running.
touch_stop() {
    pid=$(touch_pid)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || :
        for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(touch_pid)" ] || break; sleep 0.2; done
        # One that ignores SIGTERM would otherwise go on sending keys next to its replacement.
        if [ -n "$(touch_pid)" ]; then kill -9 "$pid" 2>/dev/null || :; sleep 0.2; fi
        [ -z "$(touch_pid)" ] || return 1
    fi
    rm -f "$TG_PID"
}

# layouts_live: the key layouts in effect are the saved ones. Android reads them at boot, while the
# daemon reads only its settings, written for the saved layouts: run against older live ones it
# would send gestures they do not map yet, or take other keys for the physical modifiers.
layouts_live() {
    cmp -s "$DST_TG_KL" "$LIVE_TG_KL" || return 1
    if [ -s "$DST_KL" ]; then kl=$DST_KL; else kl=$BASE/base.kl; fi
    cmp -s "$kl" "$LIVE_KL"
}

# touch_start: restart touchgestured when gesture mode is saved and in effect (the live excluded
# device list is this module's, marked gesture) and the saved key layouts are live; until a reboot
# makes them live, a running daemon keeps the settings that match the live ones. Outside the active
# module directory (a pending update being installed) nothing changes: the running module's daemon
# stays until the reboot. Fails if the daemon cannot be (re)started.
touch_start() {
    [ "$BASE" = "$(cd "$R/data/adb/modules/$MODID" 2>/dev/null && pwd -P)" ] || return 0
    if [ "$(tp_mode "$DST_TP")" != gesture ] || [ "$(tp_mode "$LIVE_TP")" != gesture ] || [ ! -s "$DST_TG_CONF" ]; then
        touch_stop
        return
    fi
    layouts_live || return 0
    touch_stop || return 1
    # setsid detaches it from the WebUI's shell, which may be killed once the command returns.
    if command -v setsid >/dev/null; then detach=setsid; else detach=; fi
    $detach "$TG" "$DST_TG_CONF" > "$TG_LOG" 2>&1 < /dev/null &
    echo $! > "$TG_PID"
    sleep 0.2
    [ -n "$(touch_pid)" ]
}

# touch_command start|stop: touch-start and touch-stop, holding the save lock so that two of them, or
# one and a save, cannot leave two daemons.
touch_command() {
    acquire_lock
    trap 'if [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi' EXIT
    trap 'exit 1' HUP INT TERM
    if [ "$1" = start ]; then touch_start || fail "タッチ操作の常駐プログラムを起動できませんでした。$(tail -n 1 "$TG_LOG" 2>/dev/null)"
    else touch_stop || fail 'タッチ操作の常駐プログラムを止められませんでした。'; fi
}

# roles PREFIX FILE: "PREFIX=SCAN:KEYCODE" for each physical modifier key mapped in FILE.
roles() {
    [ -r "$2" ] || return 0
    runawk -v prefix="$1" -v physical="$PHYSICAL" '
        BEGIN { n = split(physical, p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
        { sub(/\r$/, "") }
        $1 == "key" && ($2 in want) { print prefix "=" $2 ":" $3 }' "$2"
}

status() {
    # The keyboard's block in dumpsys input lists its key layout, then its character map. Either
    # file name identifies it: a rejected one is replaced by Generic.kl / Generic.kcm.
    # ExcludedDeviceNames is the list InputReader got from the excluded-input-devices.xml files.
    dumpsys input 2>/dev/null | runawk -v tp="$TP_DEVICE" '
        $1 == "KeyLayoutFile:" { kl = $2 }
        !found && $1 == "KeyCharacterMapFile:" && (kl ~ /\/stmpe\.kl$/ || $2 ~ /\/stmpe\.kcm$/) {
            print "kl_loaded=" kl; print "kcm_loaded=" $2; found = 1 }
        $1 == "ExcludedDeviceNames:" && !listed {
            listed = 1; line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
            n = split(line, names, /, */); ex = "no"
            for (i = 1; i <= n; i++) if (names[i] == tp) ex = "yes"
            print "tp_excluded=" ex }
        END { if (!found) { print "kl_loaded="; print "kcm_loaded=" } }' || :
    for p in product system_ext odm; do
        for f in keychars/stmpe.kcm keylayout/stmpe.kl; do
            [ -e "$R/$p/usr/$f" ] && echo "shadowed_by=/$p/usr/$f"
        done
    done
    for m in "$R"/data/adb/modules/*; do
        [ -d "$m" ] && [ "${m##*/}" != "$MODID" ] && [ ! -e "$m/disable" ] || continue
        for p in vendor product system_ext odm; do
            for f in keychars/stmpe.kcm keylayout/stmpe.kl; do
                [ -e "$m/system/$p/usr/$f" ] && echo "conflict_module=${m##*/}"
            done
        done
    done
    if [ -s "$DST" ] && cmp -s "$LIVE" "$DST"; then echo applied=yes; else echo applied=no; fi
    # Without edits the module installs no key layout, so the live one should be the original.
    if [ -s "$DST_KL" ]; then kl_target=$DST_KL; else kl_target=$BASE/base.kl; fi
    if [ -s "$kl_target" ] && cmp -s "$LIVE_KL" "$kl_target"; then echo kl_applied=yes; else echo kl_applied=no; fi
    if [ -s "$BASE/base.kl" ]; then echo kl_editable=yes; else echo kl_editable=no; fi
    roles kl_base "$BASE/base.kl"
    roles kl_live "$LIVE_KL"
    saved=$(tp_mode "$DST_TP"); echo "tp_saved=${saved:-rom}"
    live=$(tp_mode "$LIVE_TP")
    if [ -n "$live" ]; then echo "tp_live=$live"; elif [ -e "$LIVE_TP" ]; then echo tp_live=foreign; else echo tp_live=rom; fi
    tp_blockers
    # The thresholds' defaults and ranges come from touchgestured itself, so the WebUI keeps no copy.
    "$TG" thresholds 2>/dev/null | runawk 'NF == 4 { print "tp_threshold=" $1 ":" $2 ":" $3 ":" $4 }' || :
    if [ -n "$(touch_pid)" ]; then echo tp_daemon=running
    else
        echo tp_daemon=stopped
        [ ! -s "$TG_LOG" ] || echo "tp_daemon_log=$(tail -n 1 "$TG_LOG" | tr -d '\r')"
    fi
    for f in disable update remove; do [ -e "$BASE/$f" ] && echo "flag=$f"; done
    return 0
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
    status) status; exit 0 ;;
    # svc goes through PowerManager: apps are shut down normally, unlike a bare reboot.
    reboot) svc power reboot || fail '再起動できませんでした。'; exit 0 ;;
    touch-start) touch_command start; exit 0 ;;
    touch-stop) touch_command stop; exit 0 ;;
    read|original|preview|save|verify) ;;
    *) fail '不明なコマンドです。' ;;
esac
[ -s "$BASE/base.kcm" ] && [ -s "$DST" ] || fail 'モジュールのデータが見つかりません。モジュールを入れ直してください。'
case "$cmd" in
    read)
        sed -n 's/^# KEY2_V4 //p' "$DST"
        [ ! -s "$DST_KL" ] || sed -n 's/^# KEY2_KL /kl:/p' "$DST_KL"
        [ ! -s "$DST_TP" ] || sed -n 's/^<!-- KEY2_TP \(.*\) -->$/tp:\1/p' "$DST_TP"
        [ ! -s "$DST_TG_CONF" ] || sed -n 's/^# KEY2_TP /tp:/p' "$DST_TG_CONF"
        exit 0 ;;
    original) cat "$BASE/base.kcm"; exit 0 ;;
esac

umask 077
TMP="$BASE/.stmpe.kcm.$$"
TMP_KL="$BASE/.stmpe.kl.$$"
CFG="$BASE/.config.$$"
CFG_KL="$BASE/.config.kl.$$"
TMP_TP="$BASE/.excluded.xml.$$"
CFG_TP="$BASE/.config.tp.$$"
TMP_TG_CONF="$BASE/.touchgestured.conf.$$"
TMP_TG_KL="$BASE/.touch.kl.$$"
TMP_TG_IDC="$BASE/.touch.idc.$$"
if [ "$cmd" = preview ] || [ "$cmd" = verify ]; then
    trap 'rm -f "$TMP" "$TMP_KL" "$CFG" "$CFG_KL" "$CFG_TP"' EXIT
    trap 'exit 1' HUP INT TERM
    write_configs "$CFG" "$CFG_KL" "$CFG_TP" "$@"
    generate "$CFG" "$TMP"
    # verify also checks the original key layout, which an empty config reproduces.
    if [ "$KL_COUNT" -gt 0 ] || { [ "$cmd" = verify ] && [ -s "$BASE/base.kl" ]; }; then
        generate_kl "$CFG_KL" "$TMP_KL"
    fi
    [ "$cmd" = verify ] && echo OK || cat "$TMP"
    exit 0
fi

# A pending Magisk update replaces this directory at the next boot and a pending removal deletes
# it; a save now would be lost, so ask for the reboot first.
[ -e "$BASE/update" ] && fail 'モジュールの更新が再起動待ちです。再起動してから編集してください。'
[ -e "$BASE/remove" ] && fail 'モジュールの削除が再起動待ちです。再起動してから編集してください。'
acquire_lock
trap 'rm -f "$TMP" "$TMP_KL" "$CFG" "$CFG_KL" "$TMP_TP" "$CFG_TP" "$TMP_TG_CONF" "$TMP_TG_KL" "$TMP_TG_IDC"; if [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi' EXIT
trap 'exit 1' HUP INT TERM
write_configs "$CFG" "$CFG_KL" "$CFG_TP" "$@"
generate "$CFG" "$TMP"
chmod 0644 "$TMP"
copy_label "$LIVE" "$TMP"
# Both files are generated and checked before either replaces the stored one.
if [ "$KL_COUNT" -gt 0 ]; then
    generate_kl "$CFG_KL" "$TMP_KL"
    chmod 0644 "$TMP_KL"
    copy_label "$LIVE_KL" "$TMP_KL"
fi
if [ "$TP_MODE" != rom ]; then
    blockers=$(tp_blockers | sed 's/^[^=]*=//' | tr '\n' ' ')
    [ -z "$blockers" ] || fail "ほかの除外デバイス一覧（${blockers% }）があるため、タッチ操作を切り替えられません。"
    generate_tp "$TP_MODE" "$TMP_TP"
    chmod 0644 "$TMP_TP"
    label_new_system_file "$TMP_TP"
fi
# The gesture settings are kept whatever the mode, so switching back to gestures restores them.
if [ "$TP_COUNT" -gt 0 ]; then
    if [ "$KL_COUNT" -gt 0 ]; then stmpe_kl=$TMP_KL; else stmpe_kl=$BASE/base.kl; fi
    generate_touch "$CFG_TP" "$stmpe_kl" "$TMP_TG_CONF" "$TMP_TG_KL"
    chmod 0600 "$TMP_TG_CONF"
fi
if [ "$TP_MODE" = gesture ]; then
    [ "$TP_COUNT" -gt 0 ] || printf '# Generated by remap.sh: no gesture assigned.\n' > "$TMP_TG_KL"
    printf 'touch.deviceType = touchPad\ntouch.orientationAware = 1\n' > "$TMP_TG_IDC"
    chmod 0644 "$TMP_TG_KL" "$TMP_TG_IDC"
    label_new_system_file "$TMP_TG_KL"
    label_new_system_file "$TMP_TG_IDC"
fi
# The renames stay inside the module directory: the live bind mounts keep the old inodes until
# the next boot. sync before them so a power loss cannot leave a truncated file behind the name.
# The directories are made first, so a failure cannot leave only some of the files replaced.
[ "$KL_COUNT" -eq 0 ] || [ -d "${DST_KL%/*}" ] || mkdir -m 0755 "${DST_KL%/*}"
[ "$TP_MODE" = rom ] || [ -d "${DST_TP%/*}" ] || mkdir -m 0755 "${DST_TP%/*}"
if [ "$TP_MODE" = gesture ]; then
    for d in "$BASE/system/usr" "${DST_TG_KL%/*}" "${DST_TG_IDC%/*}"; do [ -d "$d" ] || mkdir -m 0755 "$d"; done
fi
sync
mv -f "$TMP" "$DST"
if [ "$KL_COUNT" -gt 0 ]; then
    mv -f "$TMP_KL" "$DST_KL"
else
    # No modifier key edits: install no key layout at all, so the original stays untouched.
    rm -f "$DST_KL"
    rmdir "${DST_KL%/*}" 2>/dev/null || :
fi
if [ "$TP_MODE" != rom ]; then
    mv -f "$TMP_TP" "$DST_TP"
else
    rm -f "$DST_TP"
    rmdir "${DST_TP%/*}" 2>/dev/null || :
fi
if [ "$TP_COUNT" -gt 0 ]; then mv -f "$TMP_TG_CONF" "$DST_TG_CONF"; else rm -f "$DST_TG_CONF"; fi
if [ "$TP_MODE" = gesture ]; then
    mv -f "$TMP_TG_KL" "$DST_TG_KL"
    mv -f "$TMP_TG_IDC" "$DST_TG_IDC"
else
    rm -f "$DST_TG_KL" "$DST_TG_IDC"
    rmdir "${DST_TG_KL%/*}" "${DST_TG_IDC%/*}" "$BASE/system/usr" 2>/dev/null || :
fi
sync
# Changed thresholds take effect now. New gesture keys and modes need the reboot like the other
# files, since Android reads key layouts and the excluded device list at boot.
touch_start || echo "WARNING: 保存しましたが、タッチ操作の常駐プログラムを起動し直せませんでした。$(tail -n 1 "$TG_LOG" 2>/dev/null)"
echo OK
