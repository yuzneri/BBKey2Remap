#!/bin/sh
# src/remap.sh, the root-side save path, on a fake device root.
. "$ROOT/tests/lib.sh"
DEV="$WORK/dev"
MOD="$DEV/data/adb/modules/key2_remap_gui"
DST="$MOD/system/vendor/usr/keychars/stmpe.kcm"
fake_device "$DEV"
module_files "$MOD"
mkdir -p "${DST%/*}"
cp "$FIXTURES/key2-base.kcm" "$MOD/base.kcm"
cp "$FIXTURES/key2-base.kcm" "$DST"
cp "$FIXTURES/key2-base.kl" "$MOD/base.kl"
DST_KL="$MOD/system/vendor/usr/keylayout/stmpe.kl"
DST_TP="$MOD/system/etc/excluded-input-devices.xml"
DST_TG_CONF="$MOD/touchgestured.conf"
DST_TG_KL="$MOD/system/usr/keylayout/key2remap_touch_keys.kl"
DST_TG_IDC="$MOD/system/usr/idc/key2remap_touch_pad.idc"
export KEY2REMAP_ROOT="$DEV" PATH="$DEV/bin:$PATH"
: "${KLTOOL:?run tests through tests/run.sh}"

remap() { sh "$MOD/remap.sh" "$@"; }
# refused MESSAGE COMMAND...: COMMAND must fail with exit 1 and MESSAGE in its output, leaving the
# stored map exactly as it was and no lock or temporary file behind.
refused() {
    message=$1; shift
    cp "$DST" "$WORK/before"
    rm -f "$WORK/before.kl"; [ ! -e "$DST_KL" ] || cp "$DST_KL" "$WORK/before.kl"
    rm -f "$WORK/before.tp"; [ ! -e "$DST_TP" ] || cp "$DST_TP" "$WORK/before.tp"
    rm -f "$WORK/before.tg"; [ ! -e "$DST_TG_CONF" ] || cp "$DST_TG_CONF" "$WORK/before.tg"
    "$@" > "$WORK/out" 2>&1
    status=$?
    [ "$status" -eq 1 ] && grep -qF "$message" "$WORK/out" || { echo "exit $status"; cat "$WORK/out"; return 1; }
    cmp "$DST" "$WORK/before" || return 1
    if [ -e "$WORK/before.kl" ]; then cmp "$DST_KL" "$WORK/before.kl" || return 1; else [ ! -e "$DST_KL" ] || { echo 'key layout appeared'; return 1; }; fi
    if [ -e "$WORK/before.tp" ]; then cmp "$DST_TP" "$WORK/before.tp" || return 1; else [ ! -e "$DST_TP" ] || { echo 'excluded device list appeared'; return 1; }; fi
    if [ -e "$WORK/before.tg" ]; then cmp "$DST_TG_CONF" "$WORK/before.tg" || return 1; else [ ! -e "$DST_TG_CONF" ] || { echo 'gesture settings appeared'; return 1; }; fi
    [ ! -e "$MOD/.save.lock" ] && [ ! -L "$MOD/.save.lock" ] || { echo 'lock left behind'; return 1; }
    ! ls "$MOD"/.stmpe.kcm.* "$MOD"/.config.* "$MOD"/.excluded.xml.* "$MOD"/.touchgestured.conf.* "$MOD"/.touch.* \
        >/dev/null 2>&1 || { echo 'temporary files left'; return 1; }
}

save_writes_checked_map() {
    out=$(remap save sym:H=R_DPAD_LEFT shift+sym:H=R_DPAD_LEFT) || { echo "$out"; return 1; }
    [ "$(printf '%s\n' "$out" | tail -n 1)" = OK ] || { echo "$out"; return 1; }
    "$KCMTOOL" check "$DST" >/dev/null && expect_eval "$DST" H 0x4 'key=21 meta=0x0 ' &&
        [ "$(remap read)" = "$(printf 'sym:H=R_DPAD_LEFT\nshift+sym:H=R_DPAD_LEFT')" ]
}
check 'save stores a map AOSP accepts, with the assignment in effect and readable back' save_writes_checked_map
check 'save gives the stored map mode 0644 and the live SELinux label' \
    sh -c '[ "$(stat -c %a "$1")" = 644 ] && grep -qx "u:object_r:vendor_keychars_file:s0 .*/.stmpe.kcm.[0-9]*" "$2"' _ "$DST" "$DEV/chcon.log"

label_failure_only_warns() {
    echo 1 > "$DEV/chcon.status"
    out=$(remap save sym:J=R_DPAD_DOWN); status=$?
    echo 0 > "$DEV/chcon.status"
    [ "$status" -eq 0 ] && printf '%s\n' "$out" | grep -q '^WARNING: .*のSELinuxラベルを付けられませんでした' &&
        [ "$(printf '%s\n' "$out" | tail -n 1)" = OK ]
}
check 'a failed SELinux relabel is reported but does not block the save' label_failure_only_warns

check 'invalid assignment characters are refused without touching the map' refused '割り当てに使えない文字' remap save 'sym:H=R_DPAD_LEFT;reboot'
check 'an assignment the generator rejects is refused without touching the map' refused '文字配列を生成できなかった' remap save sym:H=R_NOT_A_KEY
check 'an unknown command is refused' refused '不明なコマンド' remap frobnicate

broken_original() { # CONTENT: save with a different base.kcm, restoring it afterwards
    cp "$MOD/base.kcm" "$WORK/base.saved"
    printf "$1" > "$MOD/base.kcm"
    remap save sym:H=R_DPAD_LEFT; status=$?
    cp "$WORK/base.saved" "$MOD/base.kcm"
    return "$status"
}
check 'an original with a NUL byte is refused' refused 'NUL文字が含まれている' broken_original 'type ALPHA\nkey H {\000}\n'
check 'a generated map failing the grammar check is refused' refused '文字配列がAndroidの文法検査に通らなかった' broken_original "type ALPHA\nkey H {\n    label: 'H' fallback TAB\n}\n"
check 'an original the generator does not understand is refused' refused 'Unsupported top-level line' broken_original 'type ALPHA\nbogus\n'

with_flag() { touch "$MOD/$1"; remap save sym:H=R_DPAD_LEFT; status=$?; rm -f "$MOD/$1"; return "$status"; }
check 'save is refused while a module update is pending' refused '更新が再起動待ち' with_flag update
check 'save is refused while module removal is pending' refused '削除が再起動待ち' with_flag remove

live_lock_blocks() {
    sh -c 'sleep 30' remap.sh & holder=$!
    ln -s "$holder" "$MOD/.save.lock"
    cp "$DST" "$WORK/before"
    remap save sym:H=R_TAB > "$WORK/out" 2>&1; status=$?
    kill "$holder"
    held=$(readlink "$MOD/.save.lock"); rm -f "$MOD/.save.lock"
    [ "$status" -eq 1 ] && [ "$held" = "$holder" ] && cmp "$DST" "$WORK/before" &&
        grep -q '別の保存が実行中' "$WORK/out"
}
check 'a lock held by a running process blocks the save and is left alone' live_lock_blocks

stale_lock_is_recovered() {
    sh -c 'exit 0' & dead=$!; wait "$dead"
    ln -s "$dead" "$MOD/.save.lock"
    remap save sym:K=R_DPAD_UP >/dev/null && [ ! -L "$MOD/.save.lock" ] && expect_eval "$DST" K 0x4 'key=19 '
}
check 'a lock left by a killed save is taken over' stale_lock_is_recovered

lock_of_unrelated_process_is_recovered() {
    sleep 30 & other=$!
    ln -s "$other" "$MOD/.save.lock"
    remap save sym:L=R_DPAD_RIGHT >/dev/null; status=$?
    kill "$other"
    [ "$status" -eq 0 ] && [ ! -L "$MOD/.save.lock" ] && expect_eval "$DST" L 0x4 'key=22 '
}
check 'a stale lock whose PID now belongs to another program is taken over' lock_of_unrelated_process_is_recovered

preview_matches_save() {
    cp "$DST" "$WORK/before"
    remap preview sym:Q=R_ESCAPE sym:W=R_TAB > "$WORK/preview" && cmp "$DST" "$WORK/before" &&
        remap save sym:Q=R_ESCAPE sym:W=R_TAB >/dev/null && cmp "$WORK/preview" "$DST"
}
check 'preview prints exactly the map save then stores, without writing' preview_matches_save
check 'preview refuses what save refuses' refused '文字配列を生成できなかった' remap preview sym:H=R_NOT_A_KEY

relative_invocation_works() { (cd "$MOD" && sh remap.sh read >/dev/null); }
check 'remap.sh works when started with a relative path' relative_invocation_works

save_writes_key_layout() {
    out=$(remap save sym:H=R_DPAD_LEFT kl:110=ESCAPE kl:100=CTRL_LEFT) || { echo "$out"; return 1; }
    "$KLTOOL" check "$DST_KL" >/dev/null && "$KLTOOL" dump "$DST_KL" | grep -qx '110 ESCAPE 0x0' &&
        "$KLTOOL" dump "$DST_KL" | grep -qx '100 CTRL_LEFT 0x0' && "$KLTOOL" dump "$DST_KL" | grep -qx '42 SHIFT_LEFT 0x0' &&
        [ "$(remap read | sort | tr '\n' ' ')" = 'kl:100=CTRL_LEFT kl:110=ESCAPE sym:H=R_DPAD_LEFT ' ] &&
        [ "$(stat -c %a "$DST_KL")" = 644 ] && [ "$(stat -c %a "${DST_KL%/*}")" = 755 ]
}
check 'save writes a key layout AOSP accepts with the new modifier roles, readable back' save_writes_key_layout

save_without_roles_removes_layout() {
    remap save sym:H=R_DPAD_LEFT >/dev/null && [ ! -e "$DST_KL" ] && [ ! -e "${DST_KL%/*}" ] && [ -s "$DST" ]
}
check 'saving without modifier roles installs no key layout' save_without_roles_removes_layout

remap save sym:H=R_DPAD_LEFT kl:110=ESCAPE >/dev/null
check 'an invalid modifier role is refused without touching either file' refused 'キー配置を生成できなかった' remap save sym:J=R_DPAD_DOWN kl:30=ESCAPE
check 'a role for a non-modifier target key code is refused' refused 'キー配置を生成できなかった' remap save kl:110=POWER
check 'preview refuses an invalid modifier role' refused 'キー配置を生成できなかった' remap preview kl:110=POWER

without_original_layout() { mv "$MOD/base.kl" "$WORK/base.kl.saved"; "$@"; status=$?; mv "$WORK/base.kl.saved" "$MOD/base.kl"; return "$status"; }
check 'modifier roles need the original key layout of the installation' refused 'モジュールを入れ直して' without_original_layout remap save kl:110=ESCAPE
check 'character map edits still work without an original key layout' without_original_layout sh -c 'sh "$1" save sym:K=R_DPAD_UP >/dev/null' _ "$MOD/remap.sh"
broken_layout() { cp "$MOD/base.kl" "$WORK/base.kl.saved"; printf "$1" > "$MOD/base.kl"; shift; "$@"; status=$?; cp "$WORK/base.kl.saved" "$MOD/base.kl"; return "$status"; }
check 'an original key layout with NUL is refused' refused 'NUL文字が含まれている' broken_layout 'key 110 CTRL_LEFT\000\n' remap save kl:110=ESCAPE
check 'a generated key layout failing the grammar check is refused' refused 'キー配置がAndroidの文法検査に通らなかった' broken_layout 'key 110 CTRL_LEFT\nled 0 CAPS_LOCK\n' remap save kl:110=ESCAPE

check 'verify accepts the stored originals' sh -c '[ "$(sh "$1" verify)" = OK ]' _ "$MOD/remap.sh"
check 'verify rejects an original key layout failing the grammar check' refused '文法検査に通らなかった' broken_layout 'key 110 CTRL_LEFT\nled 0 CAPS_LOCK\n' remap verify

status_reports() {
    # A saved modifier role makes the stored key layout differ from the live one until reboot.
    remap save sym:H=R_DPAD_LEFT kl:110=ESCAPE >/dev/null && remap status > "$WORK/status" && grep -qx 'kcm_loaded=/vendor/usr/keychars/stmpe.kcm' "$WORK/status" &&
        grep -qx 'applied=no' "$WORK/status" &&
        ! grep -q '^\(shadowed_by\|conflict_module\|flag\)=' "$WORK/status" &&
        grep -qx 'kl_loaded=/vendor/usr/keylayout/stmpe.kl' "$WORK/status" && grep -qx 'kl_editable=yes' "$WORK/status" &&
        [ "$(grep '^kl_base=' "$WORK/status" | tr '\n' ' ')" = 'kl_base=42:SHIFT_LEFT kl_base=56:ALT_LEFT kl_base=100:SYM kl_base=110:CTRL_LEFT ' ] &&
        grep -qx 'kl_live=110:CTRL_LEFT' "$WORK/status" && grep -qx 'kl_applied=no' "$WORK/status"
}
check 'status reports the loaded files, pending reboot, and original and live modifier roles' status_reports

status_reports_problems() {
    sed -i 's|/vendor/usr/keylayout/stmpe.kl|/system/usr/keylayout/Generic.kl|' "$DEV/dumpsys-input.txt"
    mkdir -p "$DEV/product/usr/keychars" "$DEV/data/adb/modules/other/system/vendor/usr/keychars" \
        "$DEV/data/adb/modules/off/system/vendor/usr/keychars"
    touch "$DEV/product/usr/keychars/stmpe.kcm" "$DEV/data/adb/modules/other/system/vendor/usr/keychars/stmpe.kcm" \
        "$DEV/data/adb/modules/off/system/vendor/usr/keychars/stmpe.kcm" "$DEV/data/adb/modules/off/disable" "$MOD/disable"
    cp "$DST" "$DEV/vendor/usr/keychars/stmpe.kcm"
    remap status > "$WORK/status"; status=$?
    sed -i 's|/system/usr/keylayout/Generic.kl|/vendor/usr/keylayout/stmpe.kl|' "$DEV/dumpsys-input.txt"
    rm -rf "$DEV/product" "$DEV/data/adb/modules/other" "$DEV/data/adb/modules/off" "$MOD/disable"
    cp "$FIXTURES/key2-base.kcm" "$DEV/vendor/usr/keychars/stmpe.kcm"
    [ "$status" -eq 0 ] && grep -qx 'kl_loaded=/system/usr/keylayout/Generic.kl' "$WORK/status" &&
        grep -qx 'kcm_loaded=/vendor/usr/keychars/stmpe.kcm' "$WORK/status" &&
        grep -qx 'shadowed_by=/product/usr/keychars/stmpe.kcm' "$WORK/status" &&
        grep -qx 'conflict_module=other' "$WORK/status" && ! grep -q 'conflict_module=off' "$WORK/status" &&
        grep -qx 'applied=yes' "$WORK/status" && grep -qx 'flag=disable' "$WORK/status"
}
check 'status reports a fallback key layout, shadowing files, conflicting modules and flags' status_reports_problems

status_reports_fallback_character_map_and_layout_conflicts() {
    sed -i 's|/vendor/usr/keychars/stmpe.kcm|/system/usr/keychars/Generic.kcm|' "$DEV/dumpsys-input.txt"
    mkdir -p "$DEV/odm/usr/keylayout" "$DEV/data/adb/modules/kl/system/vendor/usr/keylayout"
    touch "$DEV/odm/usr/keylayout/stmpe.kl" "$DEV/data/adb/modules/kl/system/vendor/usr/keylayout/stmpe.kl"
    remap status > "$WORK/status"; status=$?
    sed -i 's|/system/usr/keychars/Generic.kcm|/vendor/usr/keychars/stmpe.kcm|' "$DEV/dumpsys-input.txt"
    rm -rf "$DEV/odm" "$DEV/data/adb/modules/kl"
    [ "$status" -eq 0 ] && grep -qx 'kcm_loaded=/system/usr/keychars/Generic.kcm' "$WORK/status" &&
        grep -qx 'kl_loaded=/vendor/usr/keylayout/stmpe.kl' "$WORK/status" &&
        grep -qx 'shadowed_by=/odm/usr/keylayout/stmpe.kl' "$WORK/status" && grep -qx 'conflict_module=kl' "$WORK/status"
}
check 'status reports a fallback character map and key layout shadowing or conflicts' status_reports_fallback_character_map_and_layout_conflicts

# excluded_names FILE: the device names Android's ConfigurationProcessor would read from FILE
# (<device name="..."/> children of the <devices> root), one per line.
excluded_names() {
    python3 -I -c 'import sys, xml.etree.ElementTree as E
r = E.parse(sys.argv[1]).getroot()
assert r.tag == "devices"
print("\n".join(d.get("name") for d in r if d.tag == "device"))' "$1"
}

save_turns_touch_off() {
    : > "$DEV/chcon.log"
    out=$(remap save sym:H=R_DPAD_LEFT tp:mode=off) || { echo "$out"; return 1; }
    [ "$(excluded_names "$DST_TP")" = touch_keypad ] &&
        [ "$(stat -c %a "$DST_TP")" = 644 ] && [ "$(stat -c %a "${DST_TP%/*}")" = 755 ] &&
        grep -qx 'u:object_r:system_file:s0 .*/.excluded.xml.[0-9]*' "$DEV/chcon.log" &&
        [ "$(remap read | sort | tr '\n' ' ')" = 'sym:H=R_DPAD_LEFT tp:mode=off ' ] && [ -s "$DST" ]
}
check 'save with tp:mode=off adds an excluded device list naming touch_keypad, readable back' save_turns_touch_off

save_without_touch_mode_removes_list() {
    remap save tp:mode=off >/dev/null && remap save sym:H=R_DPAD_LEFT >/dev/null &&
        [ ! -e "$DST_TP" ] && [ ! -e "${DST_TP%/*}" ] && [ "$(remap read)" = sym:H=R_DPAD_LEFT ]
}
check 'saving without tp:mode=off installs no excluded device list' save_without_touch_mode_removes_list

check 'preview accepts tp:mode=off and prints only the character map' sh -c 'sh "$1" preview tp:mode=off | cmp - "$2"' _ "$MOD/remap.sh" "$MOD/base.kcm"
remap save tp:mode=off >/dev/null
check 'an unknown touch mode is refused' refused 'タッチ操作の設定が正しくありません' remap save tp:mode=on
check 'an unknown touch setting is refused' refused 'タッチ操作の設定が正しくありません' remap save tp:speed=3
check 'a repeated touch mode is refused' refused 'タッチ操作の設定が重複しています' remap save tp:mode=off tp:mode=off
check 'preview refuses an unknown touch mode' refused 'タッチ操作の設定が正しくありません' remap preview tp:mode=on

with_live_list() { # CONTENT COMMAND...: run COMMAND with /system/etc/excluded-input-devices.xml holding CONTENT
    mkdir -p "$DEV/system/etc"; printf "$1" > "$DEV/system/etc/excluded-input-devices.xml"; shift
    "$@"; status=$?
    rm -rf "$DEV/system"; return "$status"
}
check 'turning touch off is refused when another excluded device list is live in /system/etc' refused \
    '/system/etc/excluded-input-devices.xml' with_live_list '<devices>\n</devices>\n' remap save tp:mode=off
check 'the module'"'"'s own live list does not block saving it again' \
    with_live_list '<!-- KEY2_TP mode=off -->\n<devices/>\n' sh -c 'sh "$1" save tp:mode=off >/dev/null' _ "$MOD/remap.sh"
with_other_module_list() {
    mkdir -p "$DEV/data/adb/modules/other/system/etc"; touch "$DEV/data/adb/modules/other/system/etc/excluded-input-devices.xml"
    "$@"; status=$?
    rm -rf "$DEV/data/adb/modules/other"; return "$status"
}
check 'turning touch off is refused when another module adds an excluded device list' refused \
    'other' with_other_module_list remap save tp:mode=off

status_reports_touch() {
    remap save tp:mode=off >/dev/null && remap status > "$WORK/status" &&
        grep -qx 'tp_saved=off' "$WORK/status" && grep -qx 'tp_live=rom' "$WORK/status" &&
        ! grep -q '^tp_excluded=' "$WORK/status" && ! grep -q '^tp_\(foreign\|conflict_module\)=' "$WORK/status" || return 1
    printf '    ExcludedDeviceNames: [qti-haptics, touch_keypad, si_haptic]\n' >> "$DEV/dumpsys-input.txt"
    mkdir -p "$DEV/system/etc" && cp "$DST_TP" "$DEV/system/etc/"
    remap status > "$WORK/status"
    sed -i '/ExcludedDeviceNames/d' "$DEV/dumpsys-input.txt"; rm -rf "$DEV/system"
    grep -qx 'tp_live=off' "$WORK/status" && grep -qx 'tp_excluded=yes' "$WORK/status"
}
check 'status reports the saved and live touch mode and whether Android excludes touch_keypad' status_reports_touch

status_reports_touch_problems() {
    printf '    ExcludedDeviceNames: [qti-haptics, touch_keypad2]\n' >> "$DEV/dumpsys-input.txt"
    remap save sym:H=R_DPAD_LEFT >/dev/null
    with_other_module_list with_live_list '<devices/>\n' sh -c 'sh "$1" status' _ "$MOD/remap.sh" > "$WORK/status"
    sed -i '/ExcludedDeviceNames/d' "$DEV/dumpsys-input.txt"
    grep -qx 'tp_saved=rom' "$WORK/status" && grep -qx 'tp_live=foreign' "$WORK/status" &&
        grep -qx 'tp_excluded=no' "$WORK/status" && grep -qx 'tp_foreign=/system/etc/excluded-input-devices.xml' "$WORK/status" &&
        grep -qx 'tp_conflict_module=other' "$WORK/status"
}
check 'status reports a foreign excluded device list, a conflicting module and a touch surface still in use' status_reports_touch_problems

# Gesture mode (PR4): the settings for touchgestured, the gesture keyboard's key layout and the
# passthrough touchpad's IDC.
GESTURES='tp:mode=gesture tp:step_mm=2.5 tp:1_swipe_left=DPAD_LEFT+shift tp:2_tap=ENTER tp:3_pass=on'
save_gestures() {
    rm -f "$DEV/chcon.log"
    set -f; out=$(remap save sym:H=R_DPAD_LEFT $GESTURES) || { echo "$out"; set +f; return 1; }; set +f
    grep -qx '<!-- KEY2_TP mode=gesture -->' "$DST_TP" && [ "$(excluded_names "$DST_TP")" = touch_keypad ] &&
        grep -qx 'step_mm 2.5' "$DST_TG_CONF" && grep -qx 'bind 1 swipe left key 514 shift' "$DST_TG_CONF" &&
        grep -qx 'bind 2 tap key 540' "$DST_TG_CONF" && grep -qx 'pass 3' "$DST_TG_CONF" &&
        grep -qx 'mod 42 shift' "$DST_TG_CONF" && grep -qx 'mod 54 shift' "$DST_TG_CONF" &&
        grep -qx 'mod 56 alt' "$DST_TG_CONF" && grep -qx 'mod 110 ctrl' "$DST_TG_CONF" &&
        "$GESTURETOOL" check "$DST_TG_CONF" >/dev/null && [ "$(stat -c %a "$DST_TG_CONF")" = 600 ] &&
        "$KLTOOL" check "$DST_TG_KL" >/dev/null && grep -qx 'key 514 DPAD_LEFT' "$DST_TG_KL" &&
        grep -qx 'key 540 ENTER' "$DST_TG_KL" && grep -qx 'key 42 SHIFT_LEFT' "$DST_TG_KL" &&
        grep -qx 'touch.deviceType = touchPad' "$DST_TG_IDC" &&
        [ "$(stat -c %a "$DST_TG_KL")" = 644 ] && [ "$(stat -c %a "$DST_TG_IDC")" = 644 ] &&
        grep -q 'u:object_r:system_file:s0 .*/.touch.kl.[0-9]*' "$DEV/chcon.log" &&
        grep -q 'u:object_r:system_file:s0 .*/.touch.idc.[0-9]*' "$DEV/chcon.log" &&
        [ "$(remap read | sort | tr '\n' ' ')" = "$(printf '%s\n' sym:H=R_DPAD_LEFT $GESTURES | sort | tr '\n' ' ')" ]
}
check 'save in gesture mode writes the daemon settings, the gesture key layout and the touchpad IDC, readable back' save_gestures

gesture_modifiers_follow_key_layout_edits() {
    remap save kl:110=ALT_LEFT tp:1_tap=ENTER >/dev/null && grep -qx 'mod 110 alt' "$DST_TG_CONF" &&
        ! grep -q '^mod 110 ctrl' "$DST_TG_CONF"
}
check 'the physical modifiers in the gesture settings follow the key layout being saved' gesture_modifiers_follow_key_layout_edits

gestures_kept_in_off_mode() {
    remap save tp:mode=off tp:1_tap=ENTER >/dev/null &&
        grep -qx '<!-- KEY2_TP mode=off -->' "$DST_TP" && grep -qx 'bind 1 tap key 524' "$DST_TG_CONF" &&
        [ ! -e "$DST_TG_KL" ] && [ ! -e "$DST_TG_IDC" ] && [ ! -e "$MOD/system/usr" ] &&
        [ "$(remap read | sort | tr '\n' ' ')" = 'tp:1_tap=ENTER tp:mode=off ' ]
}
check 'gesture settings are kept outside gesture mode, without the key layout and IDC' gestures_kept_in_off_mode

gestures_removed() {
    remap save sym:H=R_DPAD_LEFT >/dev/null && [ ! -e "$DST_TG_CONF" ] && [ ! -e "$DST_TP" ] && [ ! -e "$MOD/system/usr" ]
}
check 'saving without tp: assignments removes every touch file' gestures_removed

gesture_mode_without_gestures() {
    remap save tp:mode=gesture >/dev/null && [ ! -e "$DST_TG_CONF" ] && [ -e "$DST_TG_KL" ] && "$KLTOOL" check "$DST_TG_KL" >/dev/null &&
        [ "$(remap read)" = tp:mode=gesture ]
}
check 'gesture mode without gestures installs an empty gesture key layout' gesture_mode_without_gestures

set -f; remap save $GESTURES >/dev/null; set +f
for bad in tp:1_swipe_upleft=DPAD_UP tp:4_tap=ENTER tp:1_tap=enter tp:1_tap=ENTER+ tp:1_tap=ENTER++ctrl tp:1_pass=yes \
    tp:tap_ms=fast tp:step_mm= tp:1_tap=; do
    check "a malformed touch setting is refused: $bad" refused 'タッチ操作の設定が正しくありません' remap save "$bad"
done
check 'a touch setting given twice is refused' refused 'タッチ操作の設定が重複しています' remap save tp:1_tap=ENTER tp:1_tap=SPACE
check 'a threshold out of range is refused by the daemon check' refused 'タッチ操作の設定が正しくないため' remap save tp:start_mm=99
check 'an unknown modifier is refused by the daemon check' refused 'タッチ操作の設定が正しくないため' remap save tp:1_tap=ENTER+super
check 'passthrough and gestures for one finger count are refused by the daemon check' refused \
    'タッチ操作の設定が正しくないため' remap save tp:1_pass=on tp:1_tap=ENTER
check 'an unknown key code is refused by the key layout check' refused 'ジェスチャーに割り当てたキー' remap save tp:1_tap=NO_SUCH_KEY
check 'a dot is accepted only in touch settings' refused '使えない文字' remap save sym:H=R_DPAD.LEFT
check 'preview accepts gesture settings and prints only the character map' sh -c 'sh "$1" preview tp:mode=gesture tp:1_tap=ENTER | cmp - "$2"' _ "$MOD/remap.sh" "$MOD/base.kcm"

status_reports_gesture_mode() {
    set -f; remap save $GESTURES >/dev/null; set +f
    mkdir -p "$DEV/system/etc" && cp "$DST_TP" "$DEV/system/etc/" && remap status > "$WORK/status"
    rm -f "$DEV/system/etc/excluded-input-devices.xml"
    grep -qx 'tp_saved=gesture' "$WORK/status" && grep -qx 'tp_live=gesture' "$WORK/status" &&
        ! grep -q '^tp_foreign=' "$WORK/status"
}
check 'status reports gesture mode as saved and live' status_reports_gesture_mode
remap save sym:H=R_DPAD_LEFT >/dev/null

reboots_through_power_manager() {
    rm -f "$DEV/svc.log"
    remap reboot && [ "$(cat "$DEV/svc.log")" = 'power reboot' ]
}
check 'reboot asks the power manager to reboot' reboots_through_power_manager
reboot_failure() { echo 1 > "$DEV/svc.status"; remap reboot; status=$?; rm -f "$DEV/svc.status"; return "$status"; }
check 'a failed reboot is reported' refused '再起動できませんでした' reboot_failure

finish
