# Sourced by the Magisk app's module installer, which provides abort, ui_print, set_perm,
# MODPATH and BOOTMODE. The module files are already extracted into MODPATH.
[ "$BOOTMODE" = true ] || abort "Use Magisk app."
[ "$(getprop ro.product.model)" = "BlackBerry KEY2" ] || abort "KEY2 only."
[ "$(getprop ro.build.version.release)" = 16 ] || abort "Android 16 only."
# Prefix for absolute system paths: empty on the device, a fake root in tests/customize.test.sh.
R=${KEY2REMAP_ROOT:-}
OLD=$R/data/adb/modules/key2_navigation
if [ -d "$OLD" ] && [ ! -f "$OLD/disable" ]; then abort "Disable KEY2 Navigation v0.1/v0.2 and reboot first."; fi
PREV=$R/data/adb/modules/key2_remap_gui
SRC=$R/vendor/usr/keychars/stmpe.kcm
SRC_KL=$R/vendor/usr/keylayout/stmpe.kl
[ -s "$SRC" ] || abort "Missing keymap."
[ -s "$SRC_KL" ] || abort "Missing key layout."
if [ -d "$PREV" ] && [ "$MODPATH" != "$PREV" ]; then
 [ -s "$PREV/base.kcm" ] || abort "Previous module missing original. Remove it and reboot first."
 SRC="$PREV/base.kcm"
 # Versions before key layout editing kept no base.kl and never replaced the layout, so the live
 # one is still the original.
 [ ! -s "$PREV/base.kl" ] || SRC_KL="$PREV/base.kl"
fi
if grep -Eq '^[[:space:]]*# KEY2_(GUI|V4) ' "$SRC"; then abort "Active modified map detected. Disable previous module and reboot."; fi
if grep -Eq '^[[:space:]]*# KEY2_KL ' "$SRC_KL"; then abort "Active modified key layout detected. Disable previous module and reboot."; fi
mkdir -p "$MODPATH/system/vendor/usr/keychars" || abort "mkdir failed"
cp "$SRC" "$MODPATH/base.kcm" || abort "Backup failed"
cp "$SRC_KL" "$MODPATH/base.kl" || abort "Key layout backup failed"
cp "$SRC" "$MODPATH/system/vendor/usr/keychars/stmpe.kcm" || abort "Copy failed"
# Another stmpe.kcm/stmpe.kl earlier in Android's search path, or another module replacing one,
# would make this module's files silently ineffective.
STATUS=$(sh "$MODPATH/remap.sh" status) || abort "Cannot inspect the installed keymaps."
BLOCKERS=$(printf '%s\n' "$STATUS" | sed -n -e 's/^shadowed_by=//p' -e 's/^conflict_module=//p')
[ -z "$BLOCKERS" ] || abort "Another keymap or key layout overrides this module: $BLOCKERS"
# Every later save regenerates from these originals; refuse them now if that cannot work.
sh "$MODPATH/remap.sh" verify > /dev/null || abort "The original keymap or key layout cannot be regenerated or fails the Android grammar check."
set_perm "$MODPATH/base.kcm" 0 0 0600 || abort "Backup permissions failed"
set_perm "$MODPATH/base.kl" 0 0 0600 || abort "Key layout backup permissions failed"
set_perm "$MODPATH/remap.sh" 0 0 0755 || abort "Script permissions failed"
set_perm "$MODPATH/system/vendor/usr/keychars/stmpe.kcm" 0 0 0644 u:object_r:vendor_keychars_file:s0 || abort "Keymap permissions/label failed"
if [ -d "$PREV" ] && [ "$MODPATH" != "$PREV" ]; then
 P="$PREV/system/vendor/usr/keychars/stmpe.kcm"
 P_KL="$PREV/system/vendor/usr/keylayout/stmpe.kl"
 [ -s "$P" ] || abort "Previous generated map missing."
 # These records use a closed ASCII grammar. remap.sh independently validates every argument.
 CFG=$(sed -n -e 's/^# KEY2_V4 //p' -e 's/^# KEY2_GUI \([^=]*\)=\(.*\)$/sym:\1=R_\2/p' "$P")
 [ ! -s "$P_KL" ] || CFG="$CFG $(sed -n 's/^# KEY2_KL /kl:/p' "$P_KL")"
 set -f
 if [ -n "$CFG" ]; then
  sh "$MODPATH/remap.sh" save $CFG || abort "Cannot migrate previous settings."
 fi
 set +f
 ui_print "- Previous settings migrated."
else
 ui_print "- Initial map unchanged. Open WebUI X after reboot."
fi
