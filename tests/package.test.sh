#!/bin/sh
# The module ZIP built by tools/build-zip.sh.
. "$ROOT/tests/lib.sh"

zip_entries() { python3 -I -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1"; }

sh "$ROOT/tools/build-zip.sh" "$WORK/a.zip" >/dev/null
sleep 1
sh "$ROOT/tools/build-zip.sh" "$WORK/b.zip" >/dev/null

check 'building twice gives byte-identical ZIPs' cmp "$WORK/a.zip" "$WORK/b.zip"

zip_holds_exactly_src() {
    expected=$(cd "$ROOT/src" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
    [ "$(zip_entries "$WORK/a.zip")" = "$expected" ]
}
check 'ZIP holds exactly the files under src/' zip_holds_exactly_src

root_has_module_files() {
    zip_entries "$WORK/a.zip" > "$WORK/entries" &&
        grep -qx module.prop "$WORK/entries" && grep -qx customize.sh "$WORK/entries"
}
check 'module.prop and customize.sh are at the ZIP root' root_has_module_files

finish
