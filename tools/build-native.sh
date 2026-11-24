#!/bin/sh
# Build touchgestured for the device (arm64, statically linked) with a pinned Android NDK.
#   tools/build-native.sh [OUTPUT]   (default: dist/native/touchgestured)
# The NDK is taken from $ANDROID_NDK_ROOT when it is the pinned release, otherwise downloaded once
# into ~/.cache/android-ndk and checked against the SHA-1 published on developer.android.com.
set -eu
NDK_RELEASE=r30
NDK_REVISION=30.0.16248370
NDK_SHA1=5107f898313790e449e87eee2183d9a20602dee9
# The binary is static, so the API level only selects the libc headers; Android 8 is the oldest
# release a KEY2 shipped with.
API=26
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/dist/native/touchgestured}

is_pinned() { [ -f "$1/source.properties" ] && grep -qx "Pkg.Revision = $NDK_REVISION" "$1/source.properties"; }

NDK=${ANDROID_NDK_ROOT:-}
if [ -z "$NDK" ] || ! is_pinned "$NDK"; then
    CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/android-ndk
    NDK=$CACHE/android-ndk-$NDK_RELEASE
    if ! is_pinned "$NDK"; then
        mkdir -p "$CACHE"
        zip=$CACHE/android-ndk-$NDK_RELEASE-linux.zip
        curl -fsS --max-time 1200 -o "$zip.tmp" "https://dl.google.com/android/repository/android-ndk-$NDK_RELEASE-linux.zip"
        echo "$NDK_SHA1  $zip.tmp" | sha1sum -c - >/dev/null
        mv "$zip.tmp" "$zip"
        rm -rf "$NDK"
        # python3 rather than unzip, which build hosts may lack; the NDK needs its file modes and
        # symlinks, which zipfile.extractall drops.
        python3 -I - "$zip" "$CACHE" <<'EOF'
import os, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist():
        mode = i.external_attr >> 16
        dest = os.path.join(sys.argv[2], i.filename)
        if i.is_dir():
            os.makedirs(dest, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if stat.S_ISLNK(mode):
            os.symlink(z.read(i).decode(), dest)
        else:
            with z.open(i) as src, open(dest, 'wb') as out:
                out.write(src.read())
            os.chmod(dest, stat.S_IMODE(mode) or 0o644)
EOF
        rm "$zip"
        is_pinned "$NDK" || { echo "NDK $NDK_RELEASE did not unpack as expected" >&2; exit 1; }
    fi
fi

CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$API-clang
SRC=$ROOT/native/touchgestured
mkdir -p "$(dirname "$OUT")"
# -s, no build id and a mapped source path keep the same sources giving the same bytes.
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror -static -s -Wl,--build-id=none \
    -ffile-prefix-map="$ROOT"=. -o "$OUT" "$SRC/main.c" "$SRC/config.c" "$SRC/gesture.c" -lm
sha256sum "$OUT"
