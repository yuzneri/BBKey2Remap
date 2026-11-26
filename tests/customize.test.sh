#!/bin/sh
# src/customize.sh as the Magisk app runs it (sourced by busybox sh), on a fake device root.
. "$ROOT/tests/lib.sh"
DEV="$WORK/dev"
NEW="$DEV/data/adb/modules_update/key2_remap_gui"
PREV="$DEV/data/adb/modules/key2_remap_gui"
export KEY2REMAP_ROOT="$DEV" PATH="$DEV/bin:$PATH"

# Magisk sets its default permissions (files 0644) before it sources customize.sh.
fresh_device() { rm -rf "$DEV" && fake_device "$DEV" && module_files "$NEW" && chmod 0644 "$NEW/bin/touchgestured"; }

# install: run customize.sh with stand-ins for the installer functions; output in $WORK/install.log.
install() {
    cat > "$WORK/installer.sh" <<'SH'
BOOTMODE=true
abort() { echo "ABORT: $*"; exit 1; }
ui_print() { echo "$*"; }
set_perm() { echo "set_perm $*"; chmod "$4" "$1"; }
. "$MODPATH/customize.sh"
SH
    MODPATH="$NEW" busybox sh "$WORK/installer.sh" > "$WORK/install.log" 2>&1
}
installed_ok() { install || { cat "$WORK/install.log"; return 1; }; }
aborts_with() { # MESSAGE
    install && { echo 'installed'; return 1; }
    grep '^ABORT: ' "$WORK/install.log" | grep -qF "$1" || { cat "$WORK/install.log"; return 1; }
}

fresh_install_keeps_original() {
    installed_ok && cmp "$NEW/base.kcm" "$FIXTURES/key2-base.kcm" &&
        cmp "$NEW/base.kl" "$FIXTURES/key2-base.kl" && [ ! -e "$NEW/system/vendor/usr/keylayout" ] &&
        cmp "$NEW/system/vendor/usr/keychars/stmpe.kcm" "$FIXTURES/key2-base.kcm" &&
        grep -qx "set_perm $NEW/system/vendor/usr/keychars/stmpe.kcm 0 0 0644 u:object_r:vendor_keychars_file:s0" "$WORK/install.log" &&
        grep -q 'Initial map unchanged' "$WORK/install.log"
}
fresh_device; check 'a fresh install stores both originals and installs no key layout' fresh_install_keeps_original
daemon_is_executable() { installed_ok && grep -qx "set_perm $NEW/bin/touchgestured 0 0 0755" "$WORK/install.log"; }
fresh_device; check 'the install makes the gesture daemon executable' daemon_is_executable

fresh_device
sed -i '/SYM/d' "$DEV/vendor/usr/keylayout/stmpe.kl"
check 'a key layout without SYM does not block installation' installed_ok

fresh_device
mkdir -p "$DEV/product/usr/keychars" && touch "$DEV/product/usr/keychars/stmpe.kcm"
check 'a stmpe.kcm in /product (searched before /vendor) blocks installation' aborts_with 'overrides this module: /product/usr/keychars/stmpe.kcm'

fresh_device
mkdir -p "$DEV/data/adb/modules/other/system/vendor/usr/keychars"
touch "$DEV/data/adb/modules/other/system/vendor/usr/keychars/stmpe.kcm"
check 'another enabled module replacing stmpe.kcm blocks installation' aborts_with 'overrides this module: other'
touch "$DEV/data/adb/modules/other/disable"
check 'a disabled module replacing stmpe.kcm does not block installation' installed_ok

fresh_device
sed -i "s/^    label:  *'Q'$/    label: 'Q' fallback TAB/" "$DEV/vendor/usr/keychars/stmpe.kcm"
check 'an original that fails the grammar check blocks installation' aborts_with 'cannot be regenerated or fails the Android grammar check'

fresh_device
printf 'type ALPHA\nkey Q {\000}\n' > "$DEV/vendor/usr/keychars/stmpe.kcm"
check 'an original containing NUL blocks installation' aborts_with 'cannot be regenerated'

fresh_device
cp "$FIXTURES/key2-v03-live.kcm" "$DEV/vendor/usr/keychars/stmpe.kcm"
check 'a modified live map without the previous module blocks installation' aborts_with 'Active modified map detected'

fresh_device
printf '\n# KEY2_KL 110=ESCAPE\n' >> "$DEV/vendor/usr/keylayout/stmpe.kl"
check 'a modified live key layout without the previous module blocks installation' aborts_with 'Active modified key layout detected'

fresh_device
printf '\nkey 200 NOT_A_KEY\n' >> "$DEV/vendor/usr/keylayout/stmpe.kl"
check 'an original key layout that fails the grammar check blocks installation' aborts_with 'cannot be regenerated or fails the Android grammar check'

fresh_device
mkdir -p "$DEV/system_ext/usr/keylayout" && touch "$DEV/system_ext/usr/keylayout/stmpe.kl"
check 'a stmpe.kl in /system_ext (searched before /vendor) blocks installation' aborts_with 'overrides this module: /system_ext/usr/keylayout/stmpe.kl'

v03_update_migrates() {
    module_files "$PREV"
    mkdir -p "$PREV/system/vendor/usr/keychars"
    cp "$FIXTURES/key2-base.kcm" "$PREV/base.kcm"
    cp "$FIXTURES/key2-v03-live.kcm" "$PREV/system/vendor/usr/keychars/stmpe.kcm"
    cp "$FIXTURES/key2-v03-live.kcm" "$DEV/vendor/usr/keychars/stmpe.kcm"
    installed_ok && grep -q 'Previous settings migrated' "$WORK/install.log" &&
        cmp "$NEW/base.kcm" "$FIXTURES/key2-base.kcm" &&
        compare_maps "$FIXTURES/key2-v03-live.kcm" "$NEW/system/vendor/usr/keychars/stmpe.kcm" "$WORK/diff" &&
        [ ! -s "$WORK/diff" ] && [ "$(sh "$NEW/remap.sh" read | wc -l)" -eq 11 ]
}
fresh_device; check 'an update over v0.3 migrates its SYM settings to an equivalent map' v03_update_migrates
check 'an update over v0.3 takes the live key layout as the original' cmp "$NEW/base.kl" "$FIXTURES/key2-base.kl"

update_keeps_modifier_roles() {
    module_files "$PREV"
    mkdir -p "$PREV/system/vendor/usr/keychars" "$PREV/system/vendor/usr/keylayout"
    cp "$FIXTURES/key2-base.kcm" "$PREV/base.kcm"
    cp "$FIXTURES/key2-base.kcm" "$PREV/system/vendor/usr/keychars/stmpe.kcm"
    cp "$FIXTURES/key2-base.kl" "$PREV/base.kl"
    printf '# config\nkl:110=ESCAPE\nkl:100=CTRL_LEFT\n' > "$WORK/kl.cfg"
    busybox awk -f "$ROOT/src/klpatch.awk" "$WORK/kl.cfg" "$PREV/base.kl" > "$PREV/system/vendor/usr/keylayout/stmpe.kl"
    # While the previous module is active, the live layout is its generated one.
    cp "$PREV/system/vendor/usr/keylayout/stmpe.kl" "$DEV/vendor/usr/keylayout/stmpe.kl"
    installed_ok && cmp "$NEW/base.kl" "$FIXTURES/key2-base.kl" &&
        "$KLTOOL" dump "$NEW/system/vendor/usr/keylayout/stmpe.kl" | grep -qx '110 ESCAPE 0x0' &&
        "$KLTOOL" dump "$NEW/system/vendor/usr/keylayout/stmpe.kl" | grep -qx '100 CTRL_LEFT 0x0' &&
        [ "$(sh "$NEW/remap.sh" read | grep -c '^kl:')" -eq 2 ]
}
fresh_device; check 'an update keeps the modifier roles and the original key layout of the previous version' update_keeps_modifier_roles

update_keeps_touch_off() {
    module_files "$PREV"
    mkdir -p "$PREV/system/vendor/usr/keychars"
    cp "$FIXTURES/key2-base.kcm" "$PREV/base.kcm"
    cp "$FIXTURES/key2-base.kcm" "$PREV/system/vendor/usr/keychars/stmpe.kcm"
    cp "$FIXTURES/key2-base.kl" "$PREV/base.kl"
    sh "$PREV/remap.sh" save tp:mode=off >/dev/null || return 1
    # While the previous module is active, its list is the live one.
    mkdir -p "$DEV/system/etc" && cp "$PREV/system/etc/excluded-input-devices.xml" "$DEV/system/etc/"
    installed_ok && cmp "$NEW/system/etc/excluded-input-devices.xml" "$PREV/system/etc/excluded-input-devices.xml" &&
        [ "$(sh "$NEW/remap.sh" read)" = tp:mode=off ]
}
fresh_device; check 'an update keeps the touch surface turned off' update_keeps_touch_off

update_keeps_gestures() {
    module_files "$PREV"
    mkdir -p "$PREV/system/vendor/usr/keychars"
    cp "$FIXTURES/key2-base.kcm" "$PREV/base.kcm"
    cp "$FIXTURES/key2-base.kcm" "$PREV/system/vendor/usr/keychars/stmpe.kcm"
    cp "$FIXTURES/key2-base.kl" "$PREV/base.kl"
    sh "$PREV/remap.sh" save tp:mode=gesture tp:1_swipe_left=DPAD_LEFT+shift tp:3_pass=on >/dev/null || return 1
    mkdir -p "$DEV/system/etc" && cp "$PREV/system/etc/excluded-input-devices.xml" "$DEV/system/etc/"
    installed_ok && cmp "$NEW/touchgestured.conf" "$PREV/touchgestured.conf" &&
        cmp "$NEW/system/usr/keylayout/key2remap_touch_keys.kl" "$PREV/system/usr/keylayout/key2remap_touch_keys.kl" &&
        [ "$(sh "$NEW/remap.sh" read | sort | tr '\n' ' ')" = 'tp:1_swipe_left=DPAD_LEFT+shift tp:3_pass=on tp:mode=gesture ' ] &&
        { [ ! -e "$NEW/daemon.calls" ] || { echo 'the module being installed started its daemon'; return 1; }; }
}
fresh_device; check 'an update keeps the gesture mode and its settings' update_keeps_gestures

finish
