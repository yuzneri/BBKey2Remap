#!/bin/sh
# Build the Magisk module ZIP from src/ so that the same sources always give the same bytes:
# entries sorted, timestamps fixed, modes normalised (scripts 0755, others 0644).
# python3's zipfile is used because a zip utility is not assumed on the build host.
#   tools/build-zip.sh [OUTPUT.zip]   (default: dist/key2_remap_gui-<version>.zip)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^version=//p' "$ROOT/src/module.prop")
[ -n "$version" ] || { echo 'version missing in src/module.prop' >&2; exit 1; }
OUT=${1:-$ROOT/dist/key2_remap_gui-$version.zip}
mkdir -p "$(dirname "$OUT")"
python3 -I - "$ROOT/src" "$OUT" <<'EOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
files = sorted(os.path.relpath(os.path.join(d, f), src) for d, _, fs in os.walk(src) for f in fs)
tmp = out + '.tmp'
with zipfile.ZipFile(tmp, 'w') as z:
    for rel in files:
        info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
        info.external_attr = (0o100000 | (0o755 if rel.endswith('.sh') else 0o644)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(src, rel), 'rb') as f:
            z.writestr(info, f.read(), compresslevel=9)
os.replace(tmp, out)
EOF
sha256sum "$OUT"
