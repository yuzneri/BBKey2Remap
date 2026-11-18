#!/system/bin/sh
# Root-side helper for the WebUI.
#   remap.sh read                 saved assignments, one per line
#   remap.sh original             the original KCM
#   remap.sh preview ASSIGN...    the KCM that save would write (nothing is written)
#   remap.sh save ASSIGN...       generate, check and store the maps; applied at the next boot
#   remap.sh status               installation diagnostics as key=value lines
#   remap.sh verify               check that the stored originals can be regenerated
#   remap.sh reboot               reboot the device so that saved maps take effect
# ASSIGN is MODIFIERS:KEY=VALUE for the character map, e.g. sym:H=R_DPAD_LEFT (validated again
# by patch.awk), or kl:SCANCODE=KEYCODE for a modifier key's role in the key layout, e.g.
# kl:110=CTRL_LEFT (validated again by klpatch.awk).
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

# write_configs KCM_CONFIG KL_CONFIG ASSIGN...: the generators' config files, kl: assignments to
# the second. Only a closed ASCII alphabet passes. Sets KL_COUNT.
write_configs() {
    kcm=$1 kl=$2; shift 2
    [ "$#" -le 1500 ] || fail '割り当ては1500件までです。'
    printf '# config\n' > "$kcm"
    printf '# config\n' > "$kl"
    KL_COUNT=0
    for item in "$@"; do
        case "$item" in *[!A-Za-z0-9_+:=]*|'') fail '割り当てに使えない文字が含まれています。';; esac
        case "$item" in
            kl:*) printf '%s\n' "$item" >> "$kl"; KL_COUNT=$((KL_COUNT + 1)) ;;
            *) printf '%s\n' "$item" >> "$kcm" ;;
        esac
    done
}

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
        *) tr '\000' ' ' < "/proc/$owner/cmdline" 2>/dev/null | grep -q 'remap\.sh' &&
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
    dumpsys input 2>/dev/null | runawk '
        $1 == "KeyLayoutFile:" { kl = $2 }
        $1 == "KeyCharacterMapFile:" && (kl ~ /\/stmpe\.kl$/ || $2 ~ /\/stmpe\.kcm$/) {
            print "kl_loaded=" kl; print "kcm_loaded=" $2; found = 1; exit }
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
    for f in disable update remove; do [ -e "$BASE/$f" ] && echo "flag=$f"; done
    return 0
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
    status) status; exit 0 ;;
    # svc goes through PowerManager: apps are shut down normally, unlike a bare reboot.
    reboot) svc power reboot || fail '再起動できませんでした。'; exit 0 ;;
    read|original|preview|save|verify) ;;
    *) fail '不明なコマンドです。' ;;
esac
[ -s "$BASE/base.kcm" ] && [ -s "$DST" ] || fail 'モジュールのデータが見つかりません。モジュールを入れ直してください。'
case "$cmd" in
    read)
        sed -n 's/^# KEY2_V4 //p' "$DST"
        [ ! -s "$DST_KL" ] || sed -n 's/^# KEY2_KL /kl:/p' "$DST_KL"
        exit 0 ;;
    original) cat "$BASE/base.kcm"; exit 0 ;;
esac

umask 077
TMP="$BASE/.stmpe.kcm.$$"
TMP_KL="$BASE/.stmpe.kl.$$"
CFG="$BASE/.config.$$"
CFG_KL="$BASE/.config.kl.$$"
if [ "$cmd" = preview ] || [ "$cmd" = verify ]; then
    trap 'rm -f "$TMP" "$TMP_KL" "$CFG" "$CFG_KL"' EXIT
    trap 'exit 1' HUP INT TERM
    write_configs "$CFG" "$CFG_KL" "$@"
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
trap 'rm -f "$TMP" "$TMP_KL" "$CFG" "$CFG_KL"; if [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi' EXIT
trap 'exit 1' HUP INT TERM
write_configs "$CFG" "$CFG_KL" "$@"
generate "$CFG" "$TMP"
chmod 0644 "$TMP"
copy_label "$LIVE" "$TMP"
# Both files are generated and checked before either replaces the stored one.
if [ "$KL_COUNT" -gt 0 ]; then
    generate_kl "$CFG_KL" "$TMP_KL"
    chmod 0644 "$TMP_KL"
    copy_label "$LIVE_KL" "$TMP_KL"
fi
# The renames stay inside the module directory: the live bind mounts keep the old inodes until
# the next boot. sync before them so a power loss cannot leave a truncated file behind the name.
sync
mv -f "$TMP" "$DST"
if [ "$KL_COUNT" -gt 0 ]; then
    [ -d "${DST_KL%/*}" ] || mkdir -m 0755 "${DST_KL%/*}"
    mv -f "$TMP_KL" "$DST_KL"
else
    # No modifier key edits: install no key layout at all, so the original stays untouched.
    rm -f "$DST_KL"
    rmdir "${DST_KL%/*}" 2>/dev/null || :
fi
sync
echo OK
