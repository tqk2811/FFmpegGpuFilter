#!/bin/sh
# Rebuilds the prebuilt FFmpeg's libavutil with the patches of ffmpeg/patches (D3D11/D3D12
# frames of every DXGI format with a software pixel format). Runs inside BtbN's
# FFmpeg-Builds image of the target (ghcr.io/btbn/ffmpeg-builds/<target>-lgpl-9.0), which
# has the toolchain (UCRT mingw-w64 / glibc 2.28) and the static libraries libavutil
# links (libvpl, OpenCL loader, libva, libdrm, nv-codec-headers, AMF, Vulkan): the
# configure line is the one stored in the prebuilt library itself, so the hardware device
# types (cuda, qsv, vaapi, opencl, amf...) and the exports stay the same.
#
#   build-avutil.sh SRC PREBUILT_LIB OUT_DIR VERSION
#     SRC          copy of the FFmpeg source (external/FFmpeg), patched in place
#     PREBUILT_LIB the prebuilt avutil-NN.dll or libavutil.so.NN.x.y
#     OUT_DIR      where the new library is written (same file name)
#     VERSION      FFmpeg version string of the prebuilt (n9.0-2-g03d9533176)
set -eu
SRC=${1:?usage: build-avutil.sh SRC PREBUILT_LIB OUT_DIR VERSION}
LIB=${2:?}
OUT=${3:?}
VERSION=${4:?}
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=$(basename "$LIB")

case $NAME in
    *.dll) WIN=1; NM=${FFBUILD_CROSS_PREFIX:-x86_64-w64-mingw32-}objdump ;;
    *)     WIN=0; NM=nm ;;
esac
# comm needs the byte order that sort gives under C.
export LC_ALL=C

# Exported symbols, sorted.
exports() {
    if [ $WIN = 1 ]; then
        $NM -p "$1" | sed -n '/Ordinal\/Name Pointer/,/^$/p' | awk '/\[ *[0-9]+\]/ {print $NF}' | sort -u
    else
        nm -D --defined-only "$1" | awk '{print $NF}' | sort -u
    fi
}
# Libraries it loads at start.
imports() {
    if [ $WIN = 1 ]; then $NM -p "$1" | awk '/DLL Name:/ {print tolower($3)}' | sort -u
    else readelf -d "$1" | awk '/NEEDED/ {print $NF}' | sort -u; fi
}

CONF=$(strings "$LIB" | grep -m1 -- '--prefix=') || { echo "no configure line in $LIB" >&2; exit 1; }
cd "$SRC"
for p in "$HERE"/../ffmpeg/patches/*.patch; do
    [ -f "$p" ] || continue
    patch -p1 -R -s -f --dry-run < "$p" > /dev/null 2>&1 && continue
    patch -p1 -s -f --no-backup-if-mismatch < "$p"
done
# av_version_info() gives the prebuilt's version, not the one of a tree without .git.
echo "$VERSION" > VERSION
echo "==> configure: $CONF"
# shellcheck disable=SC2086
eval ./configure $CONF > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
MAJOR=$(sed -n "s/^#define LIBAVUTIL_VERSION_MAJOR *//p" libavutil/version.h)
if [ $WIN = 1 ]; then SLIB=avutil-$MAJOR.dll; else SLIB=libavutil.so.$MAJOR; fi
echo "==> make libavutil/$SLIB"
make -j"$(nproc)" "libavutil/$SLIB" > make.log 2>&1 || { tail -40 make.log; exit 1; }
NEW=libavutil/$SLIB
[ $WIN = 1 ] || NEW=$(readlink -f "libavutil/$SLIB")

MISSING=$(exports "$LIB" | comm -23 - "$(exports "$NEW" > /tmp/new-exports.txt; echo /tmp/new-exports.txt)")
[ -z "$MISSING" ] || { echo "new $NAME lacks prebuilt exports: $MISSING" >&2; exit 1; }
EXTRA=$(imports "$NEW" | comm -13 "$(imports "$LIB" > /tmp/old-imports.txt; echo /tmp/old-imports.txt)" -)
[ -z "$EXTRA" ] || { echo "new $NAME loads libraries the prebuilt does not: $EXTRA" >&2; exit 1; }
# The hardware device type names are strings in libavutil: none may go missing.
for t in cuda vaapi dxva2 qsv d3d11va opencl vulkan d3d12va amf drm videotoolbox mediacodec vdpau; do
    if strings "$LIB" | grep -qx "$t" && ! strings "$NEW" | grep -qx "$t"; then
        echo "new $NAME lacks the $t device type" >&2; exit 1
    fi
done
mkdir -p "$OUT"
cp "$NEW" "$OUT/$NAME"
# Stripped like make install does for the prebuilt.
STRIP=$(sed -n 's/^STRIP=//p' ffbuild/config.mak)
[ -z "$STRIP" ] || $STRIP "$OUT/$NAME"
echo "==> $OUT/$NAME"
