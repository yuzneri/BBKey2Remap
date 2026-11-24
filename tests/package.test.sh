#!/bin/sh
# The module ZIP built by tools/build-zip.sh.
. "$ROOT/tests/lib.sh"

zip_entries() { python3 -I -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1"; }

sh "$ROOT/tools/build-zip.sh" "$WORK/a.zip" >/dev/null
sleep 1
sh "$ROOT/tools/build-zip.sh" "$WORK/b.zip" >/dev/null

check 'building twice gives byte-identical ZIPs' cmp "$WORK/a.zip" "$WORK/b.zip"

zip_holds_exactly_src_and_binary() {
    expected=$({ cd "$ROOT/src" && find . -type f | sed 's|^\./||'; echo bin/touchgestured; } | LC_ALL=C sort)
    [ "$(zip_entries "$WORK/a.zip")" = "$expected" ]
}
check 'ZIP holds exactly the files under src/ and bin/touchgestured' zip_holds_exactly_src_and_binary

binary_is_executable_arm64() {
    python3 -I - "$WORK/a.zip" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
info = z.getinfo('bin/touchgestured')
data = z.read(info)
# ELF, 64-bit, little endian, e_machine 183 (AArch64)
assert data[:5] == b'\x7fELF\x02' and data[5] == 1 and int.from_bytes(data[18:20], 'little') == 183, 'not arm64 ELF'
assert (info.external_attr >> 16) & 0o777 == 0o755, oct(info.external_attr >> 16)
EOF
}
check 'bin/touchgestured is an arm64 executable with mode 0755' binary_is_executable_arm64

root_has_module_files() {
    zip_entries "$WORK/a.zip" > "$WORK/entries" &&
        grep -qx module.prop "$WORK/entries" && grep -qx customize.sh "$WORK/entries"
}
check 'module.prop and customize.sh are at the ZIP root' root_has_module_files

finish
