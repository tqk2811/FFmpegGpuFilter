#!/bin/sh
# Runs the gpufx effects through the ffmpeg of a bundle made by build-prebuilt.sh or
# build.sh, including the manifest rules (mismatches must fail).
#   scripts/test-bundle.sh dist/linux64 [clips-dir]
# Test clips come from another ffmpeg with lavfi sources ($REF_FFMPEG, default `ffmpeg`),
# since the bundle has no video source filters; pass clips-dir to reuse existing ones.
# Clips and logs default to build/test-<bundle name>, outside the bundle.
# Effect and model packages come from $GPUFX_PACKAGES; unset, the script first packs the source
# packages and models into dist/packages (scripts/pack-packages.sh --models) and tests those zips.
# The packages dir is laid out like the
# release asset gpufx-packages.zip: gpufx/<group>/<name>.zip (scripts/pack-packages.sh -o
# dist/packages/gpufx), gpufx_ai_upscale/<name>.zip and gpufx_ai_framerate/<name>.zip (copied from
# build/packages/ after scripts/fetch-models.sh). REQUIRE_MODELS=1 fails when a model is missing.
# TEST_CLIPS_ONLY=1 only writes the clips (for a runner that has no reference ffmpeg).
# REQUIRE_D3D=1 fails when the D3D11 frame tests are skipped, or the D3D12 ones are skipped
# although the FFmpeg has a d3d12va hwdevice (FFmpeg's D3D frames are D3D11).
# VK_ADAPTER=N picks the Vulkan device index (default 0); DX_ADAPTER=N tries only that D3D
# adapter index (default: adapters 0-3, first that works).
# VK_DEVICE_OPTS=a=1,b=2 appends extra options to every Vulkan device the tests open, e.g.
# linear_images=1 for drivers that cannot allocate optimal rgba images (Intel, FFmpeg 9).
# REQUIRE_VT=1 fails when the VideoToolbox frame tests (macOS) are skipped, unless FFmpeg
# cannot create a videotoolbox device or there is no Metal adapter.
set -eu
VK_ADAPTER=${VK_ADAPTER:-0}
VKX=${VK_DEVICE_OPTS:+,$VK_DEVICE_OPTS}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST=$(cd "${1:?usage: test-bundle.sh <bundle dir> [clips dir]}" && pwd)
CLIPS=${2:-$ROOT/build/test-$(basename "$DIST")}
mkdir -p "$CLIPS"
CLIPS=$(cd "$CLIPS" && pwd)
FF=$DIST/bin/ffmpeg
[ -f "$FF" ] || FF=$DIST/bin/ffmpeg.exe
# Effects and models are passed relative to $PACKAGES: a Windows path (C:/...) would break the
# filter graph, where ':' separates options.
FX=gpufx
# Package of an effect by name: gpufx/<group>/<name>.zip, as in packages/gpufx (a group may be nested).
fx() { find "$FX" -name "$1.zip" | sort | head -n 1; }

if [ ! -f "$CLIPS/straight.png" ]; then
    REF=${REF_FFMPEG:-ffmpeg}
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=1 -f lavfi -i sine=d=1 \
        -c:v ffv1 -c:a flac -shortest "$CLIPS/a.mkv"
    "$REF" -v error -y -f lavfi -i smptebars=s=320x180:d=1 -c:v ffv1 "$CLIPS/b.mkv"
    "$REF" -v error -y -f lavfi -i smptebars=s=300x180:d=1 -c:v ffv1 "$CLIPS/c.mkv"
    # Same size as a.mkv (25 fps) but 60 fps, for the frame rate test. NUT stores a 1/60
    # time base, so the output time base differs from a.mkv's 1/1000 (duration test).
    "$REF" -v error -y -f lavfi -i smptebars=s=320x180:r=60:d=1 -c:v ffv1 "$CLIPS/d.nut"
    # BT.709 limited range YUV (colorspace test) with non-square pixels (SAR warning).
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=1 -vf setsar=2 -pix_fmt yuv420p \
        -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
        -c:v ffv1 "$CLIPS/e.mkv"
    # Size changes from 320x180 to 300x180 in the middle of one stream. MJPEG carries the
    # size in every frame (FFV1 would decode the second clip at the first size).
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=0.4 -pix_fmt yuvj420p -c:v mjpeg "$CLIPS/r1.mkv"
    "$REF" -v error -y -f lavfi -i testsrc2=s=300x180:d=0.4 -pix_fmt yuvj420p -c:v mjpeg "$CLIPS/r2.mkv"
    # Half transparent image; FFmpeg 9 decodes EXR alpha as premultiplied.
    "$REF" -v error -y -f lavfi -i testsrc2=s=64x36 -vf format=rgba,colorchannelmixer=aa=0.5 \
        -frames:v 1 -c:v exr "$CLIPS/premul.exr"
    # Same size, straight alpha (the PNG decoder says so).
    "$REF" -v error -y -f lavfi -i testsrc2=s=64x36 -vf format=rgba -frames:v 1 "$CLIPS/straight.png"
    printf "file 'r1.mkv'\nfile 'r2.mkv'\n" > "$CLIPS/resize.txt"
fi
# Frame interpolation clips (gpufx_ai_framerate), made apart so older clip dirs get them too:
# 12 fps testsrc2, and a cut from yellow to blue (both 12 fps, 0.5 s each).
if [ ! -f "$CLIPS/ai12.mkv" ] || [ ! -f "$CLIPS/aicut.mkv" ]; then
    REF=${REF_FFMPEG:-ffmpeg}
    "$REF" -v error -y -f lavfi -i testsrc2=s=160x96:r=12:d=1 -c:v ffv1 "$CLIPS/ai12.mkv"
    "$REF" -v error -y -f lavfi -i color=yellow:s=160x96:r=12:d=0.5 -f lavfi -i color=blue:s=160x96:r=12:d=0.5 \
        -filter_complex "[0][1]concat" -c:v ffv1 "$CLIPS/aicut.mkv"
fi
[ "${TEST_CLIPS_ONLY:-0}" = 1 ] && exit 0
A=$CLIPS/a.mkv B=$CLIPS/b.mkv C=$CLIPS/c.mkv D=$CLIPS/d.nut E=$CLIPS/e.mkv R=$CLIPS/resize.txt
X=$CLIPS/premul.exr P=$CLIPS/straight.png
AI=$CLIPS/ai12.mkv AICUT=$CLIPS/aicut.mkv
if command -v cygpath >/dev/null; then   # Git Bash on Windows: give ffmpeg.exe C:/ paths
    A=$(cygpath -m "$A") B=$(cygpath -m "$B") C=$(cygpath -m "$C") D=$(cygpath -m "$D")
    E=$(cygpath -m "$E") R=$(cygpath -m "$R") X=$(cygpath -m "$X") P=$(cygpath -m "$P")
    AI=$(cygpath -m "$AI") AICUT=$(cygpath -m "$AICUT")
fi
# No packages dir given: pack packages/gpufx and the models now, so the zips match the source.
[ -n "${GPUFX_PACKAGES:-}" ] || "$ROOT/scripts/pack-packages.sh" --models -o "$ROOT/dist/packages/gpufx"
PACKAGES=$(cd "${GPUFX_PACKAGES:-$ROOT/dist/packages}" && pwd)
[ -d "$PACKAGES/gpufx" ] || { echo "$PACKAGES has no gpufx/ (scripts/pack-packages.sh -o $PACKAGES/gpufx)" >&2; exit 1; }
cd "$PACKAGES"

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# gpufx outputs GPU frames only: the tests run on FFmpeg's Vulkan device ($GPU), gpufx
# uploads software inputs itself, and hwdownload brings results back for the encoders.
# One image per plane (disable_multiplane=1) is what gpufx reads from hwupload.
VKDEV="vulkan=vk:$VK_ADAPTER,disable_multiplane=1$VKX"
GPU="-init_hw_device $VKDEV -filter_hw_device vk"
DEV=$GPU  # the device of the helpers below; the D3D tests set their own
# ok NAME ARGS...: must succeed
ok() {
    name=$1; shift
    # shellcheck disable=SC2086
    if "$FF" -hide_banner -nostdin -v error $DEV "$@" > "$CLIPS/last.log" 2>&1; then pass "$name"
    else fail "$name"; cat "$CLIPS/last.log"; fi
}
# warns NAME PATTERN ARGS...: must succeed with the warning PATTERN in the log
warns() {
    name=$1 pattern=$2; shift 2
    # shellcheck disable=SC2086
    if ! "$FF" -hide_banner -nostdin -v warning $DEV "$@" > "$CLIPS/last.log" 2>&1; then fail "$name (failed)"; cat "$CLIPS/last.log"
    elif grep -q "$pattern" "$CLIPS/last.log"; then pass "$name"
    else fail "$name (no warning)"; cat "$CLIPS/last.log"; fi
}
# rejects NAME PATTERN ARGS...: must fail with PATTERN in the log (no device: NODEV=1)
rejects() {
    name=$1 pattern=$2; shift 2
    rdev=$DEV; [ "${NODEV:-0}" = 1 ] && rdev=; NODEV=0
    # shellcheck disable=SC2086
    if "$FF" -hide_banner -nostdin -v error $rdev "$@" > "$CLIPS/last.log" 2>&1; then fail "$name (was accepted)"
    elif grep -q "$pattern" "$CLIPS/last.log"; then pass "$name"
    else fail "$name (wrong error)"; cat "$CLIPS/last.log"; fi
}
# shellcheck disable=SC2086
gpu_ff() { "$FF" -hide_banner -nostdin -v error $DEV "$@"; }
# raw OUT ARGS...: first 3 frames as raw video.
raw() {
    out=$1; shift
    gpu_ff "$@" -frames:v 3 -an -f rawvideo -y "$out" 2> "$CLIPS/last.log"
}
# diff_stats A B BYTES: "max mean" of the differences of the 1 or 2 byte samples.
diff_stats() {
    od -An -v -tu"$3" "$1" | tr -s ' ' '\n' | grep -v '^$' > "$CLIPS/a.txt"
    od -An -v -tu"$3" "$2" | tr -s ' ' '\n' | grep -v '^$' > "$CLIPS/b.txt"
    paste "$CLIPS/a.txt" "$CLIPS/b.txt" | awk '{d = $1 - $2; if (d < 0) d = -d; if (d > m) m = d; s += d; n++}
                                              END {if (n) printf "%d %.3f\n", m, s / n}'
}
# below VALUE LIMIT: VALUE < LIMIT
below() { awk -v v="$1" -v l="$2" 'BEGIN {exit !(v < l)}'; }
# sw_md5 FORMAT FILTERS: framemd5 of 3 frames of A in FORMAT through FILTERS (software
# frames, uploaded by the first gpufx), downloaded again.
sw_md5() {
    gpu_ff -i "$A" -frames:v 3 -an -vf "format=$1,$2,hwdownload,format=$1" -pix_fmt "$1" -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
# Each GPU-frames test keeps its own stderr in $CLIPS/vk-$VKN.log (set VKN first), so the
# reference command run next (into last.log) does not overwrite it.
VKN=probe
vk_log() { echo "$CLIPS/vk-$VKN.log"; }
show_vk_log() { echo "    --- GPU stderr ($(vk_log), last 30 lines):"; tail -n 30 "$(vk_log)" 2>/dev/null || true; }
# same NAME HW_MD5 SW_MD5
same() {
    if [ -n "$2" ] && [ "$2" = "$3" ]; then pass "$1"
    else fail "$1"; echo "    hw: $2"; echo "    sw: $3"; show_vk_log; echo "    --- last.log:"; cat "$CLIPS/last.log"; fi
}
# pt_md5 FORMAT FILTERS: framemd5 of 3 frames of A in FORMAT through FILTERS (which upload
# them first), downloaded again; the verbose log goes to $CLIPS/pt.log.
pt_md5() {
    gpu_ff -i "$A" -frames:v 3 -an -vf "format=$1,$2,hwdownload,format=$1" -pix_fmt "$1" -v verbose \
        -f framemd5 - 2> "$CLIPS/pt.log" | grep -v '^#' | awk -F, '{print $NF}'
}
# relabelled / copied: the last pt_md5 had a disabled gpufx hand on its input textures as
# its output frames (no GPU work), or copy them on the GPU.
relabelled() { grep -q "relabelling the input frames as output frames" "$CLIPS/pt.log"; }
# relabelled_n N: that line was logged N times (once per disabled gpufx that relabels).
relabelled_n() { [ "$(grep -c "relabelling the input frames as output frames" "$CLIPS/pt.log")" = "$1" ]; }
relabelled_twice() { relabelled_n 2; }
copied() { grep -q "Disabled: copying on the GPU" "$CLIPS/pt.log" && ! relabelled; }
# pt_check NAME RESULT EXPECTED PATH: RESULT equals EXPECTED (when given) and the disabled
# gpufx took PATH (relabelled or copied).
pt_check() {
    if [ -n "$2" ] && { [ -z "$3" ] || [ "$2" = "$3" ]; } && $4; then pass "$1"
    else fail "$1"; echo "    got: $2"; echo "    want: $3"; tail -n 30 "$CLIPS/pt.log"; fi
}
# pt_tests LABEL FORMAT UPLOAD EXACT: a gpufx disabled by enable= on GPU frames of FORMAT
# made by UPLOAD. EXACT=1: the GPU copy is exact for FORMAT (8-bit RGBA), so its frames can
# be compared with the input's. A relabelled frame is the input's texture: always exact.
pt_tests() {
    l=$1 f=$2 u=$3 I="gpufx=graph=$FX/ffmpeg/invert.zip"
    PT_SRC=$(pt_md5 "$f" "$u")
    PT_ONCE=$(pt_md5 "$f" "$u,$I")
    # Into hwdownload, which takes only frames of its link's frames context: relabelled.
    pt_check "$l: disabled gpufx relabels its input for hwdownload" "$(pt_md5 "$f" "$u,$I:enable=0")" "$PT_SRC" relabelled
    # Into a second gpufx, which reads the input texture in place.
    pt_check "$l: disabled gpufx relabels its input for the next gpufx" "$(pt_md5 "$f" "$u,$I:enable=0,$I")" "$PT_ONCE" relabelled
    # Two disabled gpufx chained: the first relabels for the second, which relabels for hwdownload.
    pt_check "$l: two disabled gpufx both relabel" "$(pt_md5 "$f" "$u,$I:enable=0,$I:enable=0")" "$PT_SRC" relabelled_twice
    # passthrough=off: the GPU copy as before.
    [ "$4" = 1 ] && want=$PT_ONCE || want=
    pt_check "$l: passthrough=off keeps the GPU copy" "$(pt_md5 "$f" "$u,$I:enable=0:passthrough=off,$I")" "$want" copied
    # A filter not known to read only the texture (null here) next: the GPU copy.
    [ "$4" = 1 ] && want=$PT_SRC || want=
    pt_check "$l: other next filter keeps the GPU copy" "$(pt_md5 "$f" "$u,$I:enable=0,null")" "$want" copied
    # Another output format than the input's: the copy converts, nothing is relabelled.
    # Vulkan only: out_format=rgba fails at configure on D3D frames (RTX 4060, FFmpeg 9).
    if [ "$f" != rgba ] && [ "${l#Vulkan}" != "$l" ]; then
        pt_check "$l: out_format=rgba keeps the GPU conversion" \
            "$(pt_md5 "$f" "$u,$I:enable=0:out_format=rgba,$I:out_format=$f")" "" copied
    fi
    # Disabled after the first frame, into hwdownload: the later frames are the input's.
    PT_EN=$(pt_md5 "$f" "$u,$I:enable='eq(n\,0)'")
    pt_check "$l: frames after enable= turns off equal the input" "$PT_EN" \
        "$(echo "$PT_ONCE" | head -n 1; echo "$PT_SRC" | tail -n +2)" relabelled
    # Inline enable= of the effects: every effect of a chain off is a disabled gpufx
    # (relabelled); one off copies its input on the GPU inside the chain.
    pt_check "$l: every effect switched off by its inline enable relabels" \
        "$(pt_md5 "$f" "$u,gpufx=graph='$FX/ffmpeg/invert.zip=enable=0|$FX/ffmpeg/invert.zip=enable=0'")" "$PT_SRC" relabelled
    [ "$4" = 1 ] && want=$PT_ONCE || want=
    pt_check "$l: one effect of a chain switched off" \
        "$(pt_md5 "$f" "$u,gpufx=graph='$FX/ffmpeg/invert.zip|$FX/ffmpeg/invert.zip=enable=0'")" "$want" true
    # bypass: which input a disabled two-input gpufx passes (input 1: the clip inverted).
    # A crossfade at progress=1 is its second input; exact on 8-bit RGBA only.
    [ "$4" = 1 ] || return 0
    BX="split[x][y];[y]$I[yi];[x][yi]gpufx=graph="
    pt_check "$l: bypass=auto after the enabled frames relabels the last input" \
        "$(pt_md5 "$f" "$u,$BX'$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=1':enable='eq(n\,1)':bypass=auto")" \
        "$(echo "$PT_SRC" | head -n 1; echo "$PT_ONCE" | tail -n +2)" relabelled
    pt_check "$l: bypass=0 passes input 0" \
        "$(pt_md5 "$f" "$u,$BX'$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=1':enable='eq(n\,1)':bypass=0")" \
        "$(echo "$PT_SRC" | head -n 1; echo "$PT_ONCE" | sed -n 2p; echo "$PT_SRC" | sed -n 3p)" relabelled
    # Inline bypass=auto: the effect alone (every effect off: relabelled), and inside a chain
    # (copied into the input of the next effect). FFmpeg's option parser splits at ':', so
    # the keys are separated by '&' (or '\:') inside the quotes.
    pt_check "$l: inline bypass=auto of a single effect" \
        "$(pt_md5 "$f" "$u,$BX'$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=1&enable=eq(n\,1)&bypass=auto'")" \
        "$(echo "$PT_SRC" | head -n 1; echo "$PT_ONCE" | tail -n +2)" relabelled
    pt_check "$l: inline bypass=auto inside a chain" \
        "$(pt_md5 "$f" "$u,$BX'$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=1\:enable=eq(n\,1)\:bypass=auto|$FX/ffmpeg/invert.zip'")" \
        "$(echo "$PT_ONCE" | head -n 1; echo "$PT_SRC" | tail -n +2)" true
}
# Main frame count, without gpufx (the late input tests compare against it).
MAIN_N=$("$FF" -hide_banner -nostdin -v error -i "$A" -an -vf "format=rgba" -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' ')

"$FF" -hide_banner -version | head -n1
"$FF" -hide_banner -filters > "$CLIPS/filters.txt" 2>&1
grep -qw gpufx "$CLIPS/filters.txt" && pass "gpufx is registered" || fail "gpufx is registered"
# alpha-extract mattes are joined back with alphamerge (kept by both FFMPEG_FILTERS modes).
grep -qw alphamerge "$CLIPS/filters.txt" && pass "alphamerge is registered" || fail "alphamerge is registered"

NULL="-f null -"
# Without a device gpufx has nowhere to put its GPU frames: refused, with the fix.
NODEV=1 rejects "software input without a device" "gpufx outputs GPU frames: add -init_hw_device" \
    -i "$A" -an -vf "gpufx=graph=$FX/ffmpeg/invert.zip" $NULL
NODEV=1 rejects "out_format the GPU does not convert" "out_format=gray is not converted" -i "$A" -an \
    -vf "gpufx=graph=$FX/ffmpeg/sepia.zip:out_format=gray" $NULL
NODEV=1 rejects "backend=gl in the filter" "backend=gl" -i "$A" -an -vf "gpufx=graph=$FX/ffmpeg/invert.zip:backend=gl" $NULL

# Every test below needs the Vulkan device. Hosted runners may have none: skipped with a
# warning, not failed (the D3D tests further down have their own device check).
VK=
# FFmpeg 9 copies its own Vulkan frames (hwupload, hwdownload) with VK_EXT_host_image_copy,
# which the Intel Windows driver gets wrong unless the device has both disable_multiplane=1
# and linear_images=1 (docs/INTEL_VULKAN.md). There the tests upload with gpufx_upload
# ($UP) and check that gpufx refuses hwupload frames; gpufx's own frames take no host copy.
UP=hwupload
INTEL_HIC=
# shellcheck disable=SC2086
if [ "${OS:-}" = Windows_NT ] && ! echo "$VKX" | grep -q "linear_images=1" &&
   "$FF" -hide_banner -nostdin -v verbose $DEV -i "$A" -frames:v 1 -an -f null - > "$CLIPS/last.log" 2>&1 &&
   grep -q "Device [0-9]* selected: Intel" "$CLIPS/last.log" &&
   grep -q "Using device extension VK_EXT_host_image_copy" "$CLIPS/last.log"; then
    INTEL_HIC=1
    UP=gpufx_upload
    echo "  note  Intel Windows driver with host image copy: Vulkan frames are uploaded with gpufx_upload"
fi
if ! grep -qw hwupload "$CLIPS/filters.txt"; then
    vk_why="this bundle has no hwupload/hwdownload"
elif [ -n "$INTEL_HIC" ] && ! grep -qw gpufx_upload "$CLIPS/filters.txt"; then
    vk_why="Intel host image copy and this bundle has no gpufx_upload"
elif ! gpu_ff -i "$A" -frames:v 1 -an -vf "format=rgba,$UP,hwdownload,format=rgba" -f null - > "$CLIPS/last.log" 2>&1; then
    # The device opened (INTEL_HIC): only gpufx_upload's own frames failed, a gpufx bug.
    if [ -n "$INTEL_HIC" ]; then
        vk_why=; fail "rgba gpufx_upload,hwdownload on the Intel host image copy device"; cat "$CLIPS/last.log"; VK=1
    else
        vk_why="no Vulkan device ($(head -n1 "$CLIPS/last.log"))"
    fi
elif ! gpu_ff -i "$A" -frames:v 1 -an -vf "format=rgba,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=rgba" -f null - > "$CLIPS/last.log" 2>&1; then
    # A gpufx without Vulkan frames does not output AV_PIX_FMT_VULKAN: no format in common.
    if grep -q "Impossible to convert\|No format\|negotiat\|takes no Vulkan" "$CLIPS/last.log"; then vk_why="this gpufx is built without Vulkan frames"
    else vk_why=; fail "gpufx runs on the Vulkan device"; cat "$CLIPS/last.log"; fi
else
    VK=1
fi
if [ -z "$VK" ] && [ -n "$vk_why" ]; then
    echo "  skip  every test on the Vulkan device: $vk_why"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::gpufx tests on Vulkan skipped: $vk_why"; fi
fi

# Software inputs (uploaded by gpufx) and Vulkan frames; runs only with a Vulkan device.
vulkan_tests() {
# Two input transitions driven by `progress`.
TRANSITIONS="wipe-transition crossfade slide-transition circle-reveal clock-wipe collapse expand dip-to-color dissolve pixelize-transition zoom-transition fade-grays blinds checkerboard push-box push-film photo-collection box-in sliding-bars spin-transition"
# Every capcut effect is a two input transition too.
for e in "$FX"/capcut/*.zip; do TRANSITIONS="$TRANSITIONS $(basename "$e" .zip)"; done
echo "single input effects (audio stream kept, GPU frames into the null muxer):"
# Other effects with several inputs, name:number of inputs (every input the same clip).
MULTI="blend:2 displace:3 masked-merge:3 masked-minmax:3 maskedclamp:3 maskedthreshold:2 threshold:4 varblur:2 xfade:2 xstack:4 zoom-canvas:2"
for e in $(find "$FX" -name '*.zip' | sort); do
    case " $TRANSITIONS $MULTI overlay fit hstack vstack luma-matte " in *" $(basename "$e" .zip) "* | *" $(basename "$e" .zip):"*) continue ;; esac
    # shellcheck disable=SC2086
    ok "$(basename "$e" .zip)" -i "$A" -vf "gpufx=graph=$e" $NULL
done
echo "multi input effects:"
for m in $MULTI; do
    n=${m#*:} args="" pads="" i=0
    while [ $i -lt "$n" ]; do args="$args -i $A"; pads="$pads[$i]"; i=$((i + 1)); done
    # shellcheck disable=SC2086
    ok "${m%:*} ($n inputs)" $args -filter_complex "${pads}gpufx=graph='$pads$(fx "${m%:*}")'" -an $NULL
done
echo "two input effects:"
for e in $TRANSITIONS; do
    # shellcheck disable=SC2086
    ok "$e" -i "$A" -i "$B" -filter_complex "[0][1]gpufx=graph='$(fx "$e")=progress=t'" -an $NULL
done
# shellcheck disable=SC2086
ok "overlay (different sizes)" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=graph='$FX/ffmpeg/overlay.zip=border=2'" -an $NULL
# shellcheck disable=SC2086
ok "hstack of 3 inputs" -i "$A" -i "$A" -i "$A" -filter_complex "[0][1][2]gpufx=graph='[0][1][2]$FX/ffmpeg/hstack.zip'" -an $NULL
# shellcheck disable=SC2086
ok "vstack" -i "$A" -i "$A" -filter_complex "[0][1]gpufx=graph='$FX/ffmpeg/vstack.zip'" -an $NULL
echo "effects with several outputs:"
LM=$(fx luma-matte)
# shellcheck disable=SC2086
ok "two output pads of one effect" -i "$A" -an -filter_complex "[0]gpufx=graph='$LM'[c][m]" -map "[c]" $NULL -map "[m]" $NULL
# shellcheck disable=SC2086
ok "an output in a graph and one along the chain" -i "$A" -an     -filter_complex "[0]gpufx=graph='[0]$LM[matte=m]|$FX/ffmpeg/invert.zip[x]'[x][m]" -map "[x]" $NULL -map "[m]" $NULL
# Both outputs: same frames, same timestamps; one output ending early does not stop the other.
pts_of() { grep -v '^#' "$1" | cut -d, -f3 | tr -d ' '; }
if gpu_ff -i "$A" -an -filter_complex "[0]gpufx=graph='$LM'[c][m];[c]hwdownload,format=yuva420p[co];[m]hwdownload,format=yuv420p[mo]"     -map "[co]" -f framemd5 -y "$CLIPS/lm_c.md5" -map "[mo]" -f framemd5 -y "$CLIPS/lm_m.md5" > "$CLIPS/last.log" 2>&1     && [ -s "$CLIPS/lm_c.md5" ] && [ "$(pts_of "$CLIPS/lm_c.md5")" = "$(pts_of "$CLIPS/lm_m.md5")" ]     && [ "$(grep -vc '^#' "$CLIPS/lm_c.md5")" -gt 5 ]; then pass "two outputs: same frame count and pts"
else fail "two outputs: same frame count and pts"; cat "$CLIPS/last.log"; fi
if gpu_ff -i "$A" -an -filter_complex "[0]gpufx=graph='$LM'[c][m];[c]hwdownload,format=yuva420p[co];[m]hwdownload,format=yuv420p[mo]"     -map "[co]" -f framemd5 -y "$CLIPS/lm_c2.md5" -map "[mo]" -frames:v 3 -f framemd5 -y "$CLIPS/lm_m2.md5" > "$CLIPS/last.log" 2>&1     && [ "$(grep -vc '^#' "$CLIPS/lm_m2.md5")" -eq 3 ] && [ "$(pts_of "$CLIPS/lm_c2.md5")" = "$(pts_of "$CLIPS/lm_c.md5")" ]; then
    pass "two outputs: the second ends early, the first runs to the end"
else fail "two outputs: the second ends early, the first runs to the end"; cat "$CLIPS/last.log"; fi
# out_format per output pad: one entry per pad, an empty entry keeps the default.
# shellcheck disable=SC2086
ok "out_format per output pad" -i "$A" -an -filter_complex     "[0]gpufx=graph='$LM':out_format=rgba|nv12[c][m];[c]hwdownload,format=rgba[co];[m]hwdownload,format=nv12[mo]" -map "[co]" $NULL -map "[mo]" $NULL
# shellcheck disable=SC2086
ok "out_format with an empty entry" -i "$A" -an -filter_complex "[0]gpufx=graph='$LM':out_format=|nv12[c][m];[m]hwdownload,format=nv12[mo]" -map "[c]" $NULL -map "[mo]" $NULL
# shellcheck disable=SC2086
rejects "out_format with the wrong number of entries" "has 3 entries" -i "$A" -an -filter_complex "[0]gpufx=graph='$LM':out_format=rgba|nv12|rgba[c][m]" -map "[c]" $NULL -map "[m]" $NULL
# shellcheck disable=SC2086
rejects "out_format with an unknown format" "unknown pixel format 'nope'" -i "$A" -an -filter_complex "[0]gpufx=graph='$LM':out_format=rgba|nope[c][m]" -map "[c]" $NULL -map "[m]" $NULL
# shellcheck disable=SC2086
rejects "out_format outside an output's formats" "output 'matte' of" -i "$A" -an -filter_complex "[0]gpufx=graph='$LM':out_format=rgba|yuva420p[c][m]" -map "[c]" $NULL -map "[m]" $NULL
for m in 0 1 2 3; do
    # shellcheck disable=SC2086
    ok "fit mode $m (different sizes)" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=graph='$FX/tqk2811/FFmpegArgs.TanersenerSlideShow/fit.zip=mode=$m'" -an $NULL
done
echo "expressions, sendcmd, timeline, chains:"
# shellcheck disable=SC2086
ok "expression params" -i "$A" -vf "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=clip(t\,0\,1)&color=#ff0000'" $NULL
# shellcheck disable=SC2086
ok "expression params: mixed & and escaped colon separators" -i "$A" -vf "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.5&color=#ff0000\:radius=0.5'" $NULL
# shellcheck disable=SC2086
ok "expression params: a, sar, dar" -i "$E" -vf "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=clip(dar/a/sar-0.5\,0\,1)'" $NULL
# shellcheck disable=SC2086
ok "expression params: one per component of a vec2" -i "$A" -i "$A" -an -filter_complex "[0][1]gpufx=graph='$FX/ffmpeg/zoom-canvas.zip=zoom=1+t&anchor=0.5+0.1*sin(t)\,if(lt(t\,0.5)\,0.3\,0.7)'" $NULL
# shellcheck disable=SC2086
ok "sendcmd + chain" -i "$A" -vf "gpufx=graph=$FX/ffmpeg/gaussian-blur.zip,sendcmd=c='0.5 gpufx@g params intensity=0.2',gpufx@g=graph=$FX/standalone/gradient-map.zip,gpufx=graph=$FX/standalone/rgb-split.zip" $NULL
# shellcheck disable=SC2086
ok "timeline enable" -i "$A" -vf "format=yuv420p,gpufx=graph=$FX/ffmpeg/chroma-key.zip:enable='gte(t\,0.5)',hwdownload,format=rgba" $NULL
# shellcheck disable=SC2086
ok "encode mpeg4 + aac (hwdownload)" -i "$A" -vf "gpufx=graph=$FX/ffmpeg/sepia.zip,hwdownload,format=yuv420p" -c:v mpeg4 -c:a aac -y "$CLIPS/out.mp4"
echo "manifest rules:"
# shellcheck disable=SC2086
ok "chroma-key: yuv420p in, rgba out" -i "$A" -vf "format=yuv420p,gpufx=graph=$FX/ffmpeg/chroma-key.zip,hwdownload,format=rgba" $NULL
# shellcheck disable=SC2086
rejects "chroma-key: gray input" "pixel format .gray. is not supported" -i "$A" -vf "format=gray,gpufx=graph=$FX/ffmpeg/chroma-key.zip" $NULL
# shellcheck disable=SC2086
rejects "crossfade: inputs of different sizes" "must equal the first input" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=graph=$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip" -an $NULL
# Without graph reinit, frames of the new size reach gpufx: it must refuse them, not
# overflow its buffers. chroma-key takes YUV as it is, so no scale sits in between.
# shellcheck disable=SC2086
rejects "size change mid-stream" "changed from 320x180 yuvj420p to 300x180" -reinit_filter 0 -f concat -i "$R" -an -vf "gpufx=graph=$FX/ffmpeg/chroma-key.zip" $NULL
# GPU frames only: a CPU filter right after gpufx needs hwdownload first.
# shellcheck disable=SC2086
rejects "GPU output into a CPU filter" "Impossible to convert\|hwdownload" -i "$A" -an -vf "gpufx=graph=$FX/ffmpeg/invert.zip,format=rgba" $NULL
echo "warnings:"
# shellcheck disable=SC2086
warns "different sample aspect ratios" "has sample aspect ratio 2:1" -i "$A" -i "$E" -filter_complex "[0][1]gpufx=graph=$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip" -an $NULL

echo "pixels:"
# The GPU must really change frames: invert once differs from the source, twice restores
# it exactly (8-bit RGBA, 1 - (1 - x) has no rounding loss). The frames are RGBA before
# gpufx, else it converts YUV itself and differs from swscale by rounding.
md5() {
    gpu_ff -i "$A" -frames:v 3 -an -vf "format=rgba,$1,hwdownload,format=rgba" -pix_fmt rgba -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
SRC_MD5=$(md5 "$UP")
ONCE_MD5=$(md5 "gpufx=graph=$FX/ffmpeg/invert.zip")
TWICE_MD5=$(md5 "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip")
if [ -n "$SRC_MD5" ] && [ "$ONCE_MD5" != "$SRC_MD5" ] && [ "$TWICE_MD5" = "$SRC_MD5" ]; then
    pass "invert changes pixels, twice restores them"
else
    fail "invert changes pixels, twice restores them"; cat "$CLIPS/last.log"
fi
# Both filters share one compiled package; their parameters must stay separate.
SHARED_MD5=$(md5 "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph='$FX/ffmpeg/invert.zip=amount=0'")
if [ -n "$ONCE_MD5" ] && [ "$SHARED_MD5" = "$ONCE_MD5" ]; then
    pass "same package twice keeps parameters per filter"
else
    fail "same package twice keeps parameters per filter"; cat "$CLIPS/last.log"
fi
echo "disabled by enable= (passthrough):"
pt_tests "Vulkan rgba" rgba "$UP" 1
pt_tests "Vulkan nv12" nv12 "$UP" 0
# Into gpufx_download, which copies by the layout of its link's frames context: relabelled,
# same pixels as the input.
if grep -qw gpufx_download "$CLIPS/filters.txt"; then
    for f in rgba nv12; do
        dl() {
            gpu_ff -i "$A" -frames:v 3 -an -vf "format=$f,$UP,$1gpufx_download,format=$f" -pix_fmt $f -v verbose \
                -f framemd5 - 2> "$CLIPS/pt.log" | grep -v '^#' | awk -F, '{print $NF}'
        }
        DL_SRC=$(dl "")
        pt_check "Vulkan $f: disabled gpufx relabels its input for gpufx_download" \
            "$(dl "gpufx=graph=$FX/ffmpeg/invert.zip:enable=0,")" "$DL_SRC" relabelled
    done
fi
echo "chains in one filter:"
# graph='a|b' runs both on the GPU in one go: same pixels as two filters in a row.
CHAIN_MD5=$(md5 "gpufx=graph='$FX/ffmpeg/invert.zip|$FX/ffmpeg/invert.zip'")
if [ -n "$SRC_MD5" ] && [ "$CHAIN_MD5" = "$SRC_MD5" ]; then pass "invert|invert restores the frame"
else fail "invert|invert restores the frame"; cat "$CLIPS/last.log"; fi
TWO_MD5=$(md5 "gpufx=graph=$FX/ffmpeg/grayscale.zip,gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.8'")
ONE_MD5=$(md5 "gpufx=graph='$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/vignette.zip=strength=0.8'")
if [ -n "$TWO_MD5" ] && [ "$ONE_MD5" = "$TWO_MD5" ]; then pass "grayscale|vignette equals two filters"
else fail "grayscale|vignette equals two filters"; cat "$CLIPS/last.log"; fi
# Inline parameters belong to their effect (spaces around | allowed), constants and expressions.
IDX_MD5=$(md5 "gpufx=graph='$FX/ffmpeg/invert.zip | $FX/ffmpeg/invert.zip=amount=0'")
EXPR_MD5=$(md5 "gpufx=graph='$FX/ffmpeg/invert.zip|$FX/ffmpeg/invert.zip=amount=0*t'")
if [ -n "$ONCE_MD5" ] && [ "$IDX_MD5" = "$ONCE_MD5" ] && [ "$EXPR_MD5" = "$ONCE_MD5" ]; then pass "inline parameters of one effect of a chain, and expressions"
else fail "inline parameters of one effect of a chain, and expressions"; cat "$CLIPS/last.log"; fi
# shellcheck disable=SC2086
rejects "inline key the effect does not have" "has no parameter" -i "$A" -an -vf "gpufx=graph='$FX/ffmpeg/invert.zip|$FX/ffmpeg/invert.zip=strength=0'" $NULL
# shellcheck disable=SC2086
rejects "inline key given twice" "given twice" -i "$A" -an -vf "gpufx=graph='$FX/ffmpeg/invert.zip=amount=0&amount=1'" $NULL
# shellcheck disable=SC2086
rejects "inline option that is not key=value" "is not key=value" -i "$A" -an -vf "gpufx=graph='$FX/ffmpeg/invert.zip=0'" $NULL
# shellcheck disable=SC2086
rejects "enum number that is not a value" "Invalid value for 'transition'" -i "$A" -i "$A" -an -filter_complex "[0][1]gpufx=graph='$FX/ffmpeg/xfade.zip=transition=99'" $NULL
# shellcheck disable=SC2086
rejects "enum name the package does not have" "unknown value .wipeup2." -i "$A" -i "$A" -an -filter_complex "[0][1]gpufx=graph='$FX/ffmpeg/xfade.zip=transition=wipeup2'" $NULL
# shellcheck disable=SC2086
rejects "more expressions than components" "3 expressions for 2 component(s)" -i "$A" -i "$A" -an -filter_complex "[0][1]gpufx=graph='$FX/ffmpeg/zoom-canvas.zip=anchor=t\,t\,t'" $NULL
# shellcheck disable=SC2086
rejects "the params option is gone" "params" -i "$A" -an -vf "gpufx=graph=$FX/ffmpeg/invert.zip:params='amount=0'" $NULL
# shellcheck disable=SC2086
rejects "only the first effect takes two inputs" "takes 2 inputs" -i "$A" -an -vf "gpufx=graph='$FX/ffmpeg/invert.zip|$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip'" $NULL
# shellcheck disable=SC2086
ok "a transition first in a chain" -i "$A" -i "$B" -filter_complex "[0][1]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip|$FX/ffmpeg/invert.zip'" -an $NULL

echo "graphs in one filter:"
# graph='...' runs a DAG on the GPU: same pixels as the filters it stands for.
SPLIT_MD5=$(md5 "split[a][b];[a]gpufx=graph=$FX/ffmpeg/grayscale.zip[g];[g][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.3'")
GRAPH_MD5=$(md5 "gpufx=graph='[0]split[a][b]; [a]$FX/ffmpeg/grayscale.zip[g]; [g][b]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.3[out]'")
if [ -n "$SPLIT_MD5" ] && [ "$GRAPH_MD5" = "$SPLIT_MD5" ]; then pass "graph with split equals split + two filters"
else fail "graph with split equals split + two filters"; cat "$CLIPS/last.log"; fi
LINEAR_MD5=$(md5 "gpufx=graph='[0]$FX/ffmpeg/invert.zip|$FX/ffmpeg/invert.zip[out]'")
if [ -n "$SRC_MD5" ] && [ "$LINEAR_MD5" = "$SRC_MD5" ]; then pass "linear graph invert|invert restores the frame"
else fail "linear graph invert|invert restores the frame"; cat "$CLIPS/last.log"; fi
# Two output pads mapped to two files, emitted together: each equals its effect alone.
rm -f "$CLIPS/p.md5" "$CLIPS/q.md5"
gpu_ff -i "$A" -filter_complex \
    "[0:v]format=rgba,gpufx=graph='[0]split[a][b]; [a]$FX/ffmpeg/invert.zip[inv]; [b]$FX/ffmpeg/grayscale.zip[gray]'[p][q];[p]hwdownload,format=rgba[p2];[q]hwdownload,format=rgba[q2]" \
    -map "[p2]" -frames:v 3 -pix_fmt rgba -f framemd5 -y "$CLIPS/p.md5" \
    -map "[q2]" -frames:v 3 -pix_fmt rgba -f framemd5 -y "$CLIPS/q.md5" > "$CLIPS/last.log" 2>&1
P_MD5=$(grep -v '^#' "$CLIPS/p.md5" 2>/dev/null | awk -F, '{print $NF}')
Q_MD5=$(grep -v '^#' "$CLIPS/q.md5" 2>/dev/null | awk -F, '{print $NF}')
GRAY_MD5=$(md5 "gpufx=graph=$FX/ffmpeg/grayscale.zip")
if [ -n "$P_MD5" ] && [ "$P_MD5" = "$ONCE_MD5" ] && [ "$Q_MD5" = "$GRAY_MD5" ]; then pass "two output pads to two files"
else fail "two output pads to two files"; cat "$CLIPS/last.log"; fi
# Two inputs, two outputs, inline parameters, sendcmd by node label and the timeline.
# shellcheck disable=SC2086
ok "graph: 2 inputs, 2 outputs, sendcmd, enable" -i "$A" -i "$B" -filter_complex \
    "[0:v][1:v]gpufx@g=graph='[0]split[a][b]; [a]$FX/ffmpeg/gaussian-blur.zip[ba]; [b]$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/vignette.zip[gb]; [ba][gb]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.5[x]; [x]split[x1][x2]; [x2][1]$FX/ffmpeg/wipe-transition.zip=progress=t[out]':enable='lt(t\,0.8)'[p][q];[q]sendcmd=c='0.5 gpufx@g params gb.strength=0.2',nullsink" \
    -map "[p]" -an $NULL
# shellcheck disable=SC2086
rejects "the effect option is gone" "Option not found" -i "$A" -an -vf "gpufx=effect=$FX/ffmpeg/invert.zip" $NULL
# shellcheck disable=SC2086
rejects "graph: cycle" "cycle through" -i "$A" -an -vf "gpufx=graph='[0][b]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip[a]; [a]split[b][out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: label never written" "is read but never written" -i "$A" -an -vf "gpufx=graph='[0][c]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip[out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: label read twice" "is read twice" -i "$A" -an -vf "gpufx=graph='[0]$FX/ffmpeg/invert.zip[a]; [a][a]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip[out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: wrong number of labels" "takes 2 inputs, the node gives it 1" -i "$A" -an -vf "gpufx=graph='[0]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip[out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: same size rule inside the graph" "must equal the first input" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=graph='[0]$FX/ffmpeg/invert.zip[i]; [i][1]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip[out]'" -an $NULL

echo "effects switched by their inline enable=:"
NE_IDX=$(md5 "gpufx=graph='$FX/ffmpeg/invert.zip=enable=0|$FX/ffmpeg/invert.zip'")
NE_LBL=$(md5 "gpufx=graph='$FX/ffmpeg/grayscale.zip=enable=0|$FX/ffmpeg/invert.zip'")
if [ -n "$ONCE_MD5" ] && [ "$NE_IDX" = "$ONCE_MD5" ] && [ "$NE_LBL" = "$ONCE_MD5" ]; then pass "inline enable=0 skips that effect"
else fail "inline enable=0 skips that effect"; cat "$CLIPS/last.log"; fi
# Per frame: both effects on for frame 0 (restored), the first off later (inverted once).
NE_EXPR=$(md5 "gpufx=graph='$FX/ffmpeg/invert.zip=enable=lt(n\,1)|$FX/ffmpeg/invert.zip'")
if [ -n "$SRC_MD5" ] && [ "$NE_EXPR" = "$(echo "$SRC_MD5" | head -n 1; echo "$ONCE_MD5" | tail -n +2)" ]; then pass "enable expression per frame"
else fail "enable expression per frame"; echo "    got: $NE_EXPR"; cat "$CLIPS/last.log"; fi
# A graph statement whose effects are switched off still writes its output pad (in place
# on Vulkan frames).
rm -f "$CLIPS/p.md5" "$CLIPS/q.md5"
gpu_ff -i "$A" -filter_complex \
    "[0:v]format=rgba,gpufx=graph='[0]split[a][b]; [a]$FX/ffmpeg/invert.zip=enable=0[inv]; [b]$FX/ffmpeg/grayscale.zip=enable=0|$FX/ffmpeg/invert.zip[gray]'[p][q];[p]hwdownload,format=rgba[p2];[q]hwdownload,format=rgba[q2]" \
    -map "[p2]" -frames:v 3 -pix_fmt rgba -f framemd5 -y "$CLIPS/p.md5" \
    -map "[q2]" -frames:v 3 -pix_fmt rgba -f framemd5 -y "$CLIPS/q.md5" > "$CLIPS/last.log" 2>&1
P_MD5=$(grep -v '^#' "$CLIPS/p.md5" 2>/dev/null | awk -F, '{print $NF}')
Q_MD5=$(grep -v '^#' "$CLIPS/q.md5" 2>/dev/null | awk -F, '{print $NF}')
if [ -n "$P_MD5" ] && [ "$P_MD5" = "$SRC_MD5" ] && [ "$Q_MD5" = "$ONCE_MD5" ]; then
    pass "graph: statement switched off by inline enable"
else fail "graph: statement switched off by inline enable"; cat "$CLIPS/last.log"; fi
# A single effect: its inline enable (not the filter's timeline enable=).
NE_ONE=$(md5 "gpufx=graph='$FX/ffmpeg/invert.zip=enable=0'")
if [ -n "$SRC_MD5" ] && [ "$NE_ONE" = "$SRC_MD5" ]; then pass "inline enable=0 of a single effect"
else fail "inline enable=0 of a single effect"; cat "$CLIPS/last.log"; fi
# shellcheck disable=SC2086
ok "<node>.enable toggled by sendcmd (accepted)" -i "$A" -an -vf \
    "gpufx@n=graph='$FX/ffmpeg/invert.zip|$FX/ffmpeg/grayscale.zip',sendcmd=c='0.3 gpufx@n params 1.enable=0;0.6 gpufx@n params 0.enable=0;0.9 gpufx@n params 0.enable=1'" $NULL
# The clip has 25 fps: sendcmd switches the first of two inverts off before frame 1 and on
# again before frame 2, so the frames are the source, inverted once, the source.
NE_SC=$(md5 "sendcmd=c='0.03 gpufx@n params 0.enable=0;0.07 gpufx@n params 0.enable=1',gpufx@n=graph='$FX/ffmpeg/invert.zip|$FX/ffmpeg/invert.zip'")
if [ -n "$SRC_MD5" ] && [ "$NE_SC" = "$(echo "$SRC_MD5" | sed -n 1p; echo "$ONCE_MD5" | sed -n 2p; echo "$SRC_MD5" | sed -n 3p)" ]; then
    pass "<node>.enable toggled by sendcmd changes the frames"
else fail "<node>.enable toggled by sendcmd changes the frames"; echo "    got: $NE_SC"; cat "$CLIPS/last.log"; fi
# sendcmd replaces an inline enable: off from the start, back on before frame 1.
NE_SC2=$(md5 "sendcmd=c='0.03 gpufx@n params 0.enable=1',gpufx@n=graph='$FX/ffmpeg/invert.zip=enable=0|$FX/ffmpeg/invert.zip'")
if [ -n "$SRC_MD5" ] && [ "$NE_SC2" = "$(echo "$ONCE_MD5" | sed -n 1p; echo "$SRC_MD5" | tail -n +2)" ]; then
    pass "sendcmd replaces an inline enable"
else fail "sendcmd replaces an inline enable"; echo "    got: $NE_SC2"; cat "$CLIPS/last.log"; fi
# shellcheck disable=SC2086
rejects "inline bypass other than 0 or auto" "bypass is 0 or auto" -i "$A" -an -vf "gpufx=graph='$FX/ffmpeg/invert.zip=bypass=1'" $NULL
# shellcheck disable=SC2086
rejects "inline enable given twice" "given twice" -i "$A" -an -vf "gpufx=graph='$FX/ffmpeg/invert.zip=enable=1&enable=0'" $NULL
# The input bypass passes has another size than the output: an error, not input 0.
# shellcheck disable=SC2086
rejects "bypass=auto onto an input of another size" "Choose another bypass" -i "$A" -an -filter_complex \
    "[0:v]split[x][y];[y]scale=32:16[s];[x][s]gpufx=graph=$FX/ffmpeg/overlay.zip:enable='eq(n\,0)':bypass=auto" $NULL

echo "frame rate:"
# The first input sets the output frame rate: a 25 fps clip mixed with a 60 fps clip must
# give exactly the 25 fps timestamps and durations (passthrough keeps what the filter
# emits), although the inputs have different time bases.
pts() {
    gpu_ff "$@" -an -fps_mode passthrough -enc_time_base filter \
        -f framemd5 - 2> "$CLIPS/last.log" |
        # pts and duration in milliseconds: the time bases of the two runs differ.
        awk -F'[ ,:/]+' '/^#tb 0/ {num = $3; den = $4; next} /^#/ {next}
                        {printf "%d/%d ", $3 * num * 1000 / den + 0.5, $4 * num * 1000 / den + 0.5}'
}
MAIN_PTS=$(pts -i "$A" -vf "format=rgba")
MIXED_PTS=$(pts -i "$A" -i "$D" -filter_complex "[0][1]gpufx=graph=$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip,hwdownload,format=yuv420p")
if [ -n "$MAIN_PTS" ] && [ "$MIXED_PTS" = "$MAIN_PTS" ]; then
    pass "25 fps + 60 fps input keeps the 25 fps timestamps and durations"
else
    fail "25 fps + 60 fps input keeps the 25 fps timestamps and durations"
    echo "    want: $MAIN_PTS"; echo "    got:  $MIXED_PTS"; cat "$CLIPS/last.log"
fi

echo "colors:"
# RGBA -> YUV inside gpufx (on the GPU) must use the colorspace and range negotiated on
# the output link (BT.709 here, set by the encoder through hwdownload), like a CPU scale
# after an RGBA output: the same picture up to rounding, far from what BT.601 gives.
raw "$CLIPS/scale.yuv" -i "$E" -vf "format=rgba,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=rgba,hwdownload,format=rgba,format=nv12" -pix_fmt nv12 -colorspace bt709 -color_range tv
raw "$CLIPS/inside.yuv" -i "$E" -vf "format=rgba,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=nv12,hwdownload,format=nv12" -pix_fmt nv12 -colorspace bt709 -color_range tv
raw "$CLIPS/bt601.yuv" -i "$E" -vf "format=rgba,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=nv12,hwdownload,format=nv12" -pix_fmt nv12 -colorspace bt470bg -color_range tv
GOOD=$(diff_stats "$CLIPS/scale.yuv" "$CLIPS/inside.yuv" 1 | cut -d' ' -f2)
BAD=$(diff_stats "$CLIPS/scale.yuv" "$CLIPS/bt601.yuv" 1 | cut -d' ' -f2)
if [ -n "$GOOD" ] && [ -n "$BAD" ] && below "$GOOD" 1 && below 3 "$BAD"; then
    pass "YUV output follows the BT.709 output link (mean difference $GOOD, BT.601 $BAD)"
else
    fail "YUV output follows the BT.709 output link (mean difference $GOOD, BT.601 $BAD)"; cat "$CLIPS/last.log"
fi
# yuv420p in and out: gpufx converts on the GPU, FFmpeg inserts no scale filter.
gpu_ff -v verbose -i "$A" -frames:v 2 -an -vf "gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=yuv420p" -pix_fmt yuv420p -f null - > "$CLIPS/last.log" 2>&1
if grep -q "Loaded 'Invert'" "$CLIPS/last.log" && ! grep -q auto_scale "$CLIPS/last.log"; then pass "yuv420p in and out without swscale"
else fail "yuv420p in and out without swscale"; cat "$CLIPS/last.log"; fi
# GPU formats round trip: invert twice gives the frame back, up to chroma filtering on
# the sharp edges of testsrc2 (limits in sample units: 8-bit, P010 high bits, 10-bit).
for spec in nv12:1:2 yuv420p:1:2 p010le:2:640 yuv420p10le:2:10; do
    f=${spec%%:*} rest=${spec#*:}; bytes=${rest%%:*} limit=${rest#*:}
    raw "$CLIPS/ref.yuv" -i "$A" -vf "format=$f" -pix_fmt "$f"
    raw "$CLIPS/gpu.yuv" -i "$A" -vf "format=$f,gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=$f" -pix_fmt "$f"
    MEAN=$(diff_stats "$CLIPS/ref.yuv" "$CLIPS/gpu.yuv" "$bytes" | cut -d' ' -f2)
    if [ -n "$MEAN" ] && below "$MEAN" "$limit"; then pass "$f through the GPU (mean difference $MEAN)"
    else fail "$f through the GPU (mean difference $MEAN)"; cat "$CLIPS/last.log"; fi
done

echo "premultiplied alpha:"
# The bundles have no premultiply_dynamic filter: gpufx converts alpha modes itself.
# shellcheck disable=SC2086
ok "premultiplied input (EXR)" -i "$X" -vf "gpufx=graph=$FX/ffmpeg/invert.zip" $NULL
# shellcheck disable=SC2086
ok "premultiplied and straight inputs together" -i "$X" -i "$P" -filter_complex "[0][1]gpufx=graph=$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip" $NULL
ok "premultiplied output (EXR)" -i "$X" -vf "format=rgba,gpufx=graph=$FX/ffmpeg/chroma-key.zip,hwdownload,format=rgba" -c:v exr -f image2 -update 1 -y "$CLIPS/out.exr"

echo "late second input:"
# Main frames before the second input starts are kept, with a transparent second input.
count() {
    gpu_ff "$@" -an -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' '
}
LATE_N=$(count -i "$A" -itsoffset 0.5 -i "$B" -filter_complex "[0][1]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.5',hwdownload,format=yuv420p")
if [ "$MAIN_N" -gt 0 ] && [ "$LATE_N" = "$MAIN_N" ]; then
    pass "second input starting at 0.5 s keeps all $MAIN_N main frames"
else
    fail "second input starting at 0.5 s keeps all main frames (want $MAIN_N, got $LATE_N)"; cat "$CLIPS/last.log"
fi

echo "falling leaves:"
# Leaves are a function of the frame time only: seeking must draw the same last frame.
last_md5() {
    gpu_ff "$@" -an -vf "gpufx=graph=$FX/standalone/falling-maple.zip,hwdownload,format=yuv420p" -pix_fmt rgba \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | tail -n 1 | awk -F, '{print $NF}'
}
FULL_MD5=$(last_md5 -i "$A")
SEEK_MD5=$(last_md5 -ss 0.6 -copyts -i "$A")
if [ -n "$FULL_MD5" ] && [ "$FULL_MD5" = "$SEEK_MD5" ]; then
    pass "falling-maple: seeking draws the same frame"
else
    fail "falling-maple: seeking draws the same frame"; cat "$CLIPS/last.log"
fi
# Mode 4: paths from expressions compiled into the shader, changed by sendcmd mid-stream.
ok "falling-maple: custom path (mode 4) + sendcmd" -i "$A" \
    -vf "sendcmd=c='0.5 gpufx@l params path_x=x0+0.2*sin(u)',gpufx@l=graph='$FX/standalone/falling-maple.zip=mode=4&life=2&path_y=-0.1+1.2*p&angle=max(90*u\,0)'" -f null -
rejects "falling-maple: bad path expression" "unknown variable .q." -i "$A" \
    -vf "gpufx=graph='$FX/standalone/falling-maple.zip=mode=4&path_x=q*2'" -f null -

echo "frame interpolation (gpufx_ai_framerate):"
# Frame flow only, not quality: the output is a constant rate grid whatever the input
# timestamps do. The model comes from the packages dir ($PACKAGES).
AIF="gpufx_upload,gpufx_ai_framerate=model=gpufx_ai_framerate/rife-v4.6.zip:fps=24000/1001,hwdownload,format=nv12"
# ai_flow NAME FRAMES END_MS ARGS...: FRAMES output frames, pts strictly increasing, every
# duration > 0, the last frame ending at END_MS (+-10 ms; empty: not checked).
ai_flow() {
    name=$1 want=$2 end=$3; shift 3
    got=$(pts "$@")
    if echo "$got" | tr ' ' '\n' | grep -v '^$' | awk -F/ -v want="$want" -v end="$end" '
        {if (NR > 1 && $1 <= last) bad = 1; if ($2 <= 0) bad = 1; last = $1; stop = $1 + $2}
        END {if (bad || NR != want) exit 1; if (end != "" && (stop < end - 10 || stop > end + 10)) exit 1}'
    then pass "$name ($want frames)"
    else fail "$name (want $want frames ending at ${end:-?} ms)"; echo "    got: $got"; cat "$CLIPS/last.log"; fi
}
if ! grep -qw gpufx_ai_framerate "$CLIPS/filters.txt"; then
    echo "  skip  this bundle has no gpufx_ai_framerate"
elif [ ! -f gpufx_ai_framerate/rife-v4.6.zip ]; then
    [ "${REQUIRE_MODELS:-0}" = 1 ] && { echo "REQUIRE_MODELS=1: $PACKAGES has no gpufx_ai_framerate/rife-v4.6.zip" >&2; exit 1; }
    echo "  skip  $PACKAGES has no gpufx_ai_framerate/rife-v4.6.zip"
else
    # 12 frames over 1 s: 24 grid points of 1001/24000 s below 1 s, the last ending at 1.001 s.
    ai_flow "12 -> 24000/1001 fps" 24 1001 -i "$AI" -vf "format=nv12,$AIF"
    # A 0.5 s gap after frame 6 (more than max_gap): the grid goes on over the gap, 1.5 s.
    ai_flow "gap in the input pts" 36 1502 -i "$AI" -vf "setpts='PTS+gte(N,6)*0.5/TB',format=nv12,$AIF"
    # Frame 6 goes back 0.3 s: it is not interpolated, the output pts still go forward.
    ai_flow "backward input pts" 24 1001 -i "$AI" -vf "setpts='PTS-eq(N,6)*0.3/TB',format=nv12,$AIF"
    # 320x180 then 300x180, 25 fps, 0.8 s; the filter sees the size change itself
    # (-reinit_filter 0) and restarts its pairs: 20 grid points below 0.8 s.
    ai_flow "size change mid-stream" 20 834 -reinit_filter 0 -f concat -safe 0 -i "$R" -vf "format=nv12,$AIF"
    # A cut is never blended: every output frame is pure yellow or pure blue (one pixel of
    # the middle of each frame, as RGB, within 15 levels: with scene=0 RIFE gives 248,249,5).
    CUT=$(gpu_ff -i "$AICUT" -an -vf "format=nv12,$AIF,crop=2:2,scale=1:1,format=rgb24" -f rawvideo - \
        2> "$CLIPS/last.log" | od -An -v -tu1 | tr -s ' ' '\n' | grep -v '^$' | paste -d, - - - | tr '\n' ' ')
    if [ -n "$CUT" ] && echo "$CUT" | tr ' ' '\n' | grep -v '^$' | awk -F, '
        {if (!(($1 >= 240 && $2 >= 240 && $3 <= 15) || ($1 <= 15 && $2 <= 15 && $3 >= 240))) exit 1; n++}
        END {exit n != 24}'
    then pass "a cut (yellow -> blue) is not blended"
    else fail "a cut (yellow -> blue) is not blended"; echo "    got: $CUT"; cat "$CLIPS/last.log"; fi
    # Real interpolation happens: on the moving clip some output frames (nv12 md5) match no
    # input frame, so a filter that only repeated frames cannot pass the cut test above.
    "$FF" -hide_banner -nostdin -v error -i "$AI" -vf format=nv12 -f framemd5 - 2> "$CLIPS/last.log" \
        | awk -F', *' '!/^#/ {print $NF}' > "$CLIPS/ai_in.md5"
    gpu_ff -i "$AI" -an -vf "format=nv12,$AIF" -f framemd5 - 2>> "$CLIPS/last.log" \
        | awk -F', *' '!/^#/ {print $NF}' > "$CLIPS/ai_out.md5"
    NEW=$(grep -c -v -x -F -f "$CLIPS/ai_in.md5" "$CLIPS/ai_out.md5" || true)
    if [ -s "$CLIPS/ai_in.md5" ] && [ "${NEW:-0}" -gt 0 ]
    then pass "interpolation makes new frames ($NEW of $(wc -l < "$CLIPS/ai_out.md5") differ from every input frame)"
    else fail "interpolation makes new frames"; cat "$CLIPS/last.log"; fi
fi

echo "super resolution (gpufx_ai_upscale):"
# The anime model x2 (the packages dir's gpufx_ai_upscale/realesr-animevideov3.zip, scales 2, 3, 4) on a 320x180 clip.
AIU="gpufx_upload,gpufx_ai_upscale=model=gpufx_ai_upscale/realesr-animevideov3.zip"
if ! grep -qw gpufx_ai_upscale "$CLIPS/filters.txt"; then
    echo "  skip  this bundle has no gpufx_ai_upscale"
elif [ ! -f gpufx_ai_upscale/realesr-animevideov3.zip ] || [ ! -f gpufx_ai_upscale/realesr-general-x4v3.zip ]; then
    [ "${REQUIRE_MODELS:-0}" = 1 ] && { echo "REQUIRE_MODELS=1: $PACKAGES has no gpufx_ai_upscale/realesr-animevideov3.zip and realesr-general-x4v3.zip" >&2; exit 1; }
    echo "  skip  $PACKAGES has no gpufx_ai_upscale/realesr-animevideov3.zip and realesr-general-x4v3.zip"
else
    # Output size: one 320x180 frame x2 as rgb24 is 640x360x3 bytes; x3 is 960x540x3.
    for s in 2 3; do
        BYTES=$(gpu_ff -i "$A" -frames:v 1 -an -vf "format=nv12,$AIU:scale=$s,hwdownload,format=nv12,format=rgb24" \
            -f rawvideo - 2> "$CLIPS/last.log" | wc -c | tr -d ' ')
        if [ "$BYTES" = $((320 * s * 180 * s * 3)) ]; then pass "x$s: 320x180 -> $((320 * s))x$((180 * s))"
        else fail "x$s: 320x180 -> $((320 * s))x$((180 * s)) (got $BYTES bytes)"; cat "$CLIPS/last.log"; fi
    done
    # The result looks like the input: PSNR against a bicubic x2 of the same frames well above noise
    # (Real-ESRGAN sharpens, so not near identical). Both precisions, and rgba frames.
    for v in "nv12:auto" "nv12:f32" "rgba:auto"; do
        f=${v%%:*} p=${v#*:}
        DB=$(gpu_ff -v info -i "$A" -frames:v 5 -an -filter_complex \
            "[0]format=$f,split[a][b];[a]$AIU:precision=$p,hwdownload,format=$f,format=yuv444p[u];[b]scale=640:360:flags=bicubic,format=yuv444p[r];[u][r]psnr" \
            -f null - 2>&1 | sed -n 's/.*PSNR .* average:\([0-9.inf]*\).*/\1/p' | tail -n 1)
        if [ -n "$DB" ] && below 25 "$DB"; then pass "$f, precision=$p: close to a bicubic x2 ($DB dB)"
        else fail "$f, precision=$p: close to a bicubic x2 (got ${DB:-no} dB, want > 25)"; fi
    done
    # 320x180 then 300x180 (-reinit_filter 0): the filter makes output frames of the new size itself.
    ai_flow "size change mid-stream" 20 800 -reinit_filter 0 -f concat -safe 0 -i "$R" -vf "format=nv12,$AIU,hwdownload,format=nv12"
    rejects "a scale the package does not have" "available: 4" -i "$A" -frames:v 1 \
        -vf "format=nv12,gpufx_upload,gpufx_ai_upscale=model=gpufx_ai_upscale/realesr-general-x4v3.zip:scale=2,hwdownload,format=nv12" -f null -
    NODEV=1 rejects "model is required" "model is required" -i "$A" -frames:v 1 -vf "gpufx_ai_upscale" -f null -
fi

echo "unpacked packages (directories):"
# A package or model also opens from its unpacked directory. The zips above are unpacked into
# $PACKAGES/unpacked (relative paths, like the zips) and must give exactly the zip's pixels.
rm -rf unpacked && mkdir -p unpacked
# dir_md5 INPUTS FILTERS: framemd5 of 3 rgba frames of A (INPUTS copies of it, 1 or 2) through
# FILTERS, which take [i0] (and [i1]) as rgba software frames, downloaded again.
dir_md5() {
    if [ "$1" = 2 ]; then set -- "-i $A -i $A" "[0]format=rgba[i0];[1]format=rgba[i1];[i0][i1]$2"
    else set -- "-i $A" "[0]format=rgba[i0];[i0]$2"; fi
    # shellcheck disable=SC2086
    gpu_ff $1 -frames:v 3 -an -filter_complex "$2,hwdownload,format=rgba" -pix_fmt rgba -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
# dir_same NAME INPUTS ZIP_FILTERS DIR_FILTERS: both give the same, non-empty frames.
dir_same() {
    z=$(dir_md5 "$2" "$3") d=$(dir_md5 "$2" "$4")
    if [ -n "$z" ] && [ "$z" = "$d" ]; then pass "$1"
    else fail "$1"; echo "    zip: $z"; echo "    dir: $d"; cat "$CLIPS/last.log"; fi
}
for p in grayscale vignette zoom-canvas; do
    unzip -q "$FX/ffmpeg/$p.zip" -d "unpacked/$p"
done
dir_same "grayscale from a directory equals the zip" 1 \
    "gpufx=graph=$FX/ffmpeg/grayscale.zip" "gpufx=graph=unpacked/grayscale"
dir_same "vignette with a parameter from a directory equals the zip" 1 \
    "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'" "gpufx=graph='unpacked/vignette=strength=0.7'"
dir_same "zoom-canvas (2 inputs, per-component expressions) from a directory equals the zip" 2 \
    "gpufx=graph='$FX/ffmpeg/zoom-canvas.zip=zoom=1+t&anchor=0.5+0.1*sin(t)\,0.5'" \
    "gpufx=graph='unpacked/zoom-canvas=zoom=1+t&anchor=0.5+0.1*sin(t)\,0.5'"
rejects "a directory that is no package" "missing manifest.json" -i "$A" -frames:v 1 \
    -vf "format=rgba,gpufx=graph=unpacked,hwdownload,format=rgba" -f null -
if grep -qw gpufx_ai_upscale "$CLIPS/filters.txt" && [ -f gpufx_ai_upscale/realesr-animevideov3.zip ]; then
    unzip -q gpufx_ai_upscale/realesr-animevideov3.zip -d unpacked/animevideov3
    dir_same "an upscale model from a directory equals the zip" 1 \
        "gpufx_upload,gpufx_ai_upscale=model=gpufx_ai_upscale/realesr-animevideov3.zip:scale=2" \
        "gpufx_upload,gpufx_ai_upscale=model=unpacked/animevideov3:scale=2"
else
    echo "  skip  no gpufx_ai_upscale or no gpufx_ai_upscale/realesr-animevideov3.zip"
fi
rm -rf unpacked

echo "Vulkan frames:"
# hwupload -> gpufx -> hwdownload runs on FFmpeg's own Vulkan device, frames never leave
# the GPU in between, and must give exactly the pixels of software frames gpufx uploads.
vk_ff() { gpu_ff "$@"; }
# vk_md5 FORMAT FILTERS...: framemd5 of 3 frames of A in FORMAT, uploaded first.
vk_md5() {
    f=$1; shift
    vk_ff -i "$A" -frames:v 3 -an -vf "format=$f,$UP,$1,hwdownload,format=$f" -pix_fmt "$f" -f framemd5 - \
        2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}'
}
VKN=grayscale-rgba
same "rgba: grayscale on Vulkan frames equals software frames" \
    "$(vk_md5 rgba "gpufx=graph=$FX/ffmpeg/grayscale.zip")" "$(sw_md5 rgba "gpufx=graph=$FX/ffmpeg/grayscale.zip")"
for f in nv12 yuv420p yuv444p p010le yuv420p10le rgba64le; do
    VKN=vignette-$f
    same "$f: vignette on Vulkan frames equals software frames" \
        "$(vk_md5 $f "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")" \
        "$(sw_md5 $f "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")"
done
# Two gpufx in a row: the second waits on the semaphores the first signals.
VKN=invert-twice
same "invert twice on Vulkan frames restores the frame" \
    "$(vk_md5 rgba "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip")" "$(sw_md5 rgba "$UP")"
# A graph whose two inputs are one frame (split before gpufx): locked and waited once.
G="[0]split[a][b]; [a]$FX/ffmpeg/gaussian-blur.zip[ba]; [b]$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/vignette.zip[gb]; [ba][gb]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4[x]; [x][1]$FX/ffmpeg/wipe-transition.zip=progress=0.6[out]"
VKN=graph
same "graph on Vulkan frames equals software frames" \
    "$(vk_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G'")" \
    "$(sw_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G'")"
# Output in another format than the input (the effect may output yuv420p or rgba).
VKN=sepia-nv12
same "sepia keeps nv12 on Vulkan frames" "$(vk_md5 nv12 "gpufx=graph=$FX/ffmpeg/sepia.zip")" \
    "$(sw_md5 nv12 "gpufx=graph=$FX/ffmpeg/sepia.zip")"
# shellcheck disable=SC2086
ok "timeline enable on Vulkan frames" -i "$A" -an \
    -vf "format=nv12,$UP,gpufx=graph=$FX/ffmpeg/invert.zip:enable='gte(t\,0.5)',hwdownload,format=nv12" $NULL
VKN=late-input
LATE_VK=$(vk_ff -i "$A" -itsoffset 0.5 -i "$B" -an -filter_complex \
    "[0]format=rgba,$UP[a];[1]format=rgba,$UP[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.5',hwdownload,format=rgba" \
    -f framemd5 - 2> "$(vk_log)" | grep -v '^#' | wc -l | tr -d ' ')
if [ "$LATE_VK" = "$MAIN_N" ]; then pass "late second input on Vulkan frames keeps all $MAIN_N frames"
else fail "late second input on Vulkan frames (want $MAIN_N, got $LATE_VK)"; show_vk_log; fi
# yuva420p: the output keeps the input format when the GPU can store it; out_format=rgba pins it.
VKN=yuva420p-rgba
YUVA_VK=$(vk_ff -i "$A" -frames:v 3 -an -vf "format=yuva420p,$UP,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=rgba,hwdownload,format=rgba" \
    -f framemd5 - 2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}')
# FFmpeg does not always give yuva420p images a sampled usage (on lavapipe the usage
# changes from run to run: 0x400001, 0x400002...); gpufx then refuses the input, by design.
if [ -z "$YUVA_VK" ] && grep -q "yuva420p that cannot be sampled" "$(vk_log)"; then
    echo "  skip  yuva420p in, rgba Vulkan frames out (FFmpeg made yuva420p frames without sampled usage)"
else
    # Software yuva420p frames go up as they are, or as rgba converted by swscale when the
    # device's yuva420p frames lack sampled usage (same lavapipe flakiness): swscale rounds
    # YUV to RGB unlike the GPU, so then only the Vulkan side is checked.
    YUVA_SW=$(gpu_ff -v verbose -i "$A" -frames:v 3 -an -vf "format=yuva420p,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=rgba,hwdownload,format=rgba" \
            -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')
    if grep -q "yuva420p uploaded as .* rgba frames" "$CLIPS/last.log"; then
        if [ -n "$YUVA_VK" ]; then pass "yuva420p in, rgba Vulkan frames out (software side went up as rgba, not compared)"
        else fail "yuva420p in, rgba Vulkan frames out (no output)"; show_vk_log; fi
    else
        same "yuva420p in, rgba Vulkan frames out" "$YUVA_VK" "$YUVA_SW"
    fi
fi
# Vulkan and software inputs together: gpufx uploads the software one on the same device.
VKN=mixed
same "Vulkan and software inputs mixed" \
    "$(vk_ff -i "$A" -i "$B" -frames:v 3 -an -filter_complex "[0]format=rgba,$UP[a];[1]format=rgba[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4',hwdownload,format=rgba" \
        -f framemd5 - 2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}')" \
    "$(gpu_ff -i "$A" -i "$B" -frames:v 3 -an -filter_complex "[0]format=rgba[a];[1]format=rgba[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4',hwdownload,format=rgba" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
# out_format=rgba between chained gpufx: the middle ones skip the YUV conversions, and the
# chain gives the pixels of the same effects chained in one gpufx.
OUTFMT="gpufx=graph=$FX/ffmpeg/vignette.zip:out_format=rgba,gpufx=graph=$FX/ffmpeg/grayscale.zip:out_format=rgba,gpufx=graph=$FX/ffmpeg/sepia.zip:out_format=nv12"
VKN=out-format
same "out_format=rgba chain on Vulkan frames equals one chained gpufx" \
    "$(vk_md5 nv12 "$OUTFMT")" "$(sw_md5 nv12 "gpufx=graph=$FX/ffmpeg/vignette.zip|$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/sepia.zip")"
same "out_format=rgba chain on software frames equals one chained gpufx" \
    "$(sw_md5 nv12 "$OUTFMT")" "$(sw_md5 nv12 "gpufx=graph=$FX/ffmpeg/vignette.zip|$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/sepia.zip")"
# gpufx_upload / gpufx_download: pipelined hwupload / hwdownload, bit-exact both ways,
# on multiplane and one-image-per-plane frames, and mixed with hwupload / hwdownload.
if grep -qw gpufx_upload "$CLIPS/filters.txt"; then
    for dev in "$VKDEV" "vulkan=vk:$VK_ADAPTER$VKX"; do
        for f in nv12 yuv420p rgba; do
            for c in "gpufx_upload,gpufx_download" "hwupload,gpufx_download=latency=0" "gpufx_upload=depth=1,hwdownload"; do
                VKN=transfer-$f
                # hwupload frames: FFmpeg's host copy, broken on that driver (not gpufx).
                if [ -n "$INTEL_HIC" ] && [ "${c%%,*}" = hwupload ]; then
                    echo "  skip  $f: $c ($dev): hwupload uses Intel's host image copy"; continue
                fi
                same "$f: $c is lossless ($dev)" \
                    "$("$FF" -hide_banner -nostdin -v error -init_hw_device "$dev" -filter_hw_device vk -i "$A" -frames:v 5 -an \
                        -vf "format=$f,$c,format=$f" -f framemd5 - 2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}')" \
                    "$("$FF" -hide_banner -nostdin -v error -i "$A" -frames:v 5 -an -vf "format=$f" -f framemd5 - \
                        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
            done
        done
    done
    VKN=transfer-gpufx
    same "gpufx_upload,gpufx,gpufx_download equals software frames" \
        "$(vk_ff -i "$A" -frames:v 3 -an -vf "format=nv12,gpufx_upload,gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7',gpufx_download,format=nv12" \
            -f framemd5 - 2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}')" \
        "$(sw_md5 nv12 "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")"
    # gpufx then gpufx_download: the software-input chain with a pipelined readback.
    VKN=gpufx-download
    same "software input, gpufx, gpufx_download equals hwdownload" \
        "$(vk_ff -i "$A" -frames:v 3 -an -vf "format=nv12,gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7',gpufx_download,format=nv12" \
            -f framemd5 - 2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}')" \
        "$(sw_md5 nv12 "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")"
    # Frames in flight at the end are flushed: every frame comes out.
    DL_N=$(vk_ff -i "$A" -an -vf "format=nv12,gpufx_upload,gpufx_download=latency=4,format=nv12" -f framemd5 - \
        2> "$(vk_log)" | grep -v '^#' | wc -l | tr -d ' ')
    if [ "$DL_N" = "$MAIN_N" ]; then pass "gpufx_download flushes all $MAIN_N frames"
    else fail "gpufx_download flushes all frames (want $MAIN_N, got $DL_N)"; show_vk_log; fi
    # shellcheck disable=SC2086
    rejects "gpufx_download to another format" "add format=nv12 after gpufx_download" \
        -i "$A" -an -vf "format=nv12,gpufx_upload,gpufx_download,format=rgba" $NULL
    # gpufx's output frames carry no host-transfer usage, so hwdownload reads them with
    # FFmpeg's buffer copy: the same bytes as gpufx_download, also on a multiplane device
    # and on the Intel driver whose host image copies are broken.
    for dev in "$VKDEV" "vulkan=vk:$VK_ADAPTER$VKX"; do
        for f in nv12 yuv420p rgba; do
            VKN=out-hwdownload-$f
            same "$f: gpufx output through hwdownload equals gpufx_download ($dev)" \
                "$("$FF" -hide_banner -nostdin -v error -init_hw_device "$dev" -filter_hw_device vk -i "$A" -frames:v 3 -an \
                    -vf "format=$f,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=$f,hwdownload,format=$f" -f framemd5 - \
                    2> "$(vk_log)" | grep -v '^#' | awk -F, '{print $NF}')" \
                "$("$FF" -hide_banner -nostdin -v error -init_hw_device "$dev" -filter_hw_device vk -i "$A" -frames:v 3 -an \
                    -vf "format=$f,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=$f,gpufx_download,format=$f" -f framemd5 - \
                    2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
        done
    done
else
    echo "  skip  this bundle has no gpufx_upload"
fi
# Without disable_multiplane an nv12 frame may be one multiplane image: refused clearly
# (or, where the driver has no multiplane nv12, processed).
if "$FF" -hide_banner -nostdin -v error -init_hw_device "vulkan=vk:$VK_ADAPTER$VKX" -filter_hw_device vk -i "$A" -frames:v 2 -an \
    -vf "format=nv12,hwupload,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1 ||
    grep -q "multiplane images are not supported\|gpufx_upload instead of hwupload" "$CLIPS/last.log"; then
    pass "multiplane nv12 is processed or refused clearly"
else
    fail "multiplane nv12 is processed or refused clearly"; cat "$CLIPS/last.log"
fi
# gpufx uploads software frames as one image per plane whatever the device was opened with.
VKN=own-upload
if "$FF" -hide_banner -nostdin -v error -init_hw_device "vulkan=vk:$VK_ADAPTER$VKX" -filter_hw_device vk -i "$A" -frames:v 2 -an \
    -vf "format=nv12,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=nv12" -f null - > "$(vk_log)" 2>&1; then
    pass "software nv12 on a multiplane device"
else
    fail "software nv12 on a multiplane device"; show_vk_log
fi
# rgba frames gpufx allocates itself (output, own upload) work without linear_images=1,
# which the Intel driver needs for FFmpeg's own rgba frames.
VKN=rgba-alloc
if "$FF" -hide_banner -nostdin -v error -init_hw_device "vulkan=vk:$VK_ADAPTER" -filter_hw_device vk -i "$A" -frames:v 2 -an \
    -vf "format=rgba,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=rgba,hwdownload,format=rgba" -f null - > "$(vk_log)" 2>&1; then
    pass "rgba gpufx frames allocate on a device without extra options"
else
    fail "rgba gpufx frames allocate on a device without extra options"; show_vk_log
fi
# hwupload frames on the Intel driver with host image copy: refused before any frame,
# with the fix, on both kinds of devices (optimal rgba fails to allocate, multiplane nv12
# gets its chroma corrupted).
if [ -n "$INTEL_HIC" ]; then
    for dev in "$VKDEV" "vulkan=vk:$VK_ADAPTER$VKX"; do
        for f in rgba nv12; do
            DEV="-init_hw_device $dev -filter_hw_device vk"
            # shellcheck disable=SC2086
            rejects "$f: hwupload into gpufx refused on Intel host image copy ($dev)" "gpufx_upload instead of hwupload" \
                -i "$A" -frames:v 2 -an -vf "format=$f,hwupload,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=$f" $NULL
            DEV=$GPU
        done
    done
else
    echo "  skip  hwupload refused on Intel host image copy (not the Intel Windows driver with host image copy)"
fi
}
if [ -n "$VK" ]; then
    vulkan_tests
fi

echo "D3D12 and D3D11 frames:"
# hwupload -> gpufx -> hwdownload on FFmpeg's D3D12 device (D3D11: on the D3D12 device of
# its adapter), same pixels as the software path. The device is tried on adapters 0-3:
# wgpu skips the headless "Microsoft Basic Render Driver" duplicate of WARP.
dx_md5() {
    f=$1; shift
    "$FF" -hide_banner -nostdin -v error -init_hw_device "$DXDEV" -filter_hw_device dx -i "$A" -frames:v 3 -an \
        -vf "format=$f,hwupload,$1,hwdownload,format=$f" -pix_fmt "$f" -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
# REQUIRE_D3D=1 (the Windows CI job): a skipped API is a failure, unless FFmpeg itself
# cannot create the device on any adapter (hosted runners: WARP only, d3d12va -22,
# d3d11va DXGI_ERROR_UNSUPPORTED), since gpufx is never reached then. FFmpeg's D3D frames
# are D3D11, so D3D11 must always be tested; D3D12 only when the FFmpeg has a d3d12va hwdevice.
dx_ran= dx_skipped=
dx_skip() {
    echo "  skip  $1"
    if [ "${2:-}" = nohwdevice ]; then
        dx_skipped="$dx_skipped $API(no hwdevice)"
    elif [ "${2:-}" = nodevice ]; then
        dx_skipped="$dx_skipped $API(no device)"
        if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::D3D12/D3D11 frames not tested: $1"; fi
    else
        dx_skipped="$dx_skipped $API"
        if [ "${REQUIRE_D3D:-0}" = 1 ]; then fail "REQUIRE_D3D=1: $API frames were not tested"; fi
    fi
}
dx_hwdevs=$("$FF" -hide_banner -init_hw_device list 2>&1)
for api in d3d12va d3d11va; do
    API=$(echo "$api" | sed 's/va$//' | tr a-z A-Z)
    if ! grep -qw hwupload "$CLIPS/filters.txt"; then dx_skip "$API: this bundle has no hwupload"; continue; fi
    if ! echo "$dx_hwdevs" | grep -qx "$api"; then
        if [ "$api" = d3d12va ]; then dx_skip "$API: this ffmpeg has no $api hwdevice" nohwdevice; else dx_skip "$API: this ffmpeg has no $api hwdevice"; fi
        continue
    fi
    DXDEV= why= dx_dev=
    for n in ${DX_ADAPTER:-0 1 2 3}; do
        if ! "$FF" -hide_banner -nostdin -v error -init_hw_device "$api=dx:$n" -filter_hw_device dx -i "$A" -frames:v 1 -an \
            -vf "format=nv12,hwupload,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1; then
            # Only a failed device creation means "no device here"; anything else is a bug.
            if ! grep -qi "Device creation failed\|Failed to create Direct3D device\|-22\|887a0004" "$CLIPS/last.log"; then
                fail "$API: hwupload/hwdownload probe on adapter $n"; cat "$CLIPS/last.log"; dx_dev=1 why=; break
            fi
            [ -n "$why" ] || why="$(head -n1 "$CLIPS/last.log")"
            continue
        fi
        dx_dev=1
        if "$FF" -hide_banner -nostdin -v error -init_hw_device "$api=dx:$n" -filter_hw_device dx -i "$A" -frames:v 1 -an \
            -vf "format=nv12,hwupload,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1; then
            DXDEV="$api=dx:$n"; break
        fi
        cp "$CLIPS/last.log" "$CLIPS/$api-$n.log"
        why="gpufx on adapter $n: $(grep -m1 -i "gpufx\|error\|impossible" "$CLIPS/last.log")"
        # A gpufx without these frames, or an adapter wgpu cannot share: try the next one.
        grep -q "Impossible to convert\|No format\|negotiat\|only supported on Windows\|not one wgpu uses\|another ID3D12Device\|no shared fences\|has no fences" \
            "$CLIPS/last.log" || { fail "$API: gpufx takes $API frames"; cat "$CLIPS/last.log"; why=; break; }
    done
    if [ -z "$DXDEV" ]; then
        if [ -z "$dx_dev" ]; then
            dx_skip "$API: FFmpeg cannot create a $api device on this machine ($why)" nodevice
        elif [ -n "$why" ]; then
            dx_skip "$API: $why"
        fi
        continue
    fi
    echo "  ($API on ${DXDEV#*=})"; dx_ran="$dx_ran $API"
    # The helpers (ok, raw, sw_md5...) run on this device now; VKREF is the Vulkan run.
    DEV="-init_hw_device $DXDEV -filter_hw_device dx"
    VKN=dx-$API
    # A real GPU rounds a few samples of the vignette one step apart from another API (4 of
    # 259200 on an RTX 4060): within one step of the Vulkan run, else of software frames
    # gpufx uploads to this device itself.
    for f in nv12 p010le; do
        V="gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'"
        if [ $f = nv12 ]; then bytes=1 step=1; else bytes=2 step=64; fi  # p010le: 10 bits << 6
        rm -f "$CLIPS/dx.yuv" "$CLIPS/sw.yuv"
        raw "$CLIPS/dx.yuv" -i "$A" -vf "format=$f,hwupload,$V,hwdownload,format=$f" -pix_fmt $f || true
        if [ -n "$VK" ]; then
            ref="the Vulkan run"; DEV=$GPU
        else
            ref="software frames"
        fi
        raw "$CLIPS/sw.yuv" -i "$A" -vf "format=$f,$V,hwdownload,format=$f" -pix_fmt $f || true
        DEV="-init_hw_device $DXDEV -filter_hw_device dx"
        DMAX=-
        if [ -s "$CLIPS/dx.yuv" ] && [ "$(wc -c < "$CLIPS/dx.yuv")" = "$(wc -c < "$CLIPS/sw.yuv")" ]; then
            DMAX=$(diff_stats "$CLIPS/dx.yuv" "$CLIPS/sw.yuv" $bytes | cut -d' ' -f1); DMAX=${DMAX:--}
        fi
        if [ "$DMAX" != - ] && [ "$DMAX" -le $step ]; then pass "$API $f: vignette within one step of $ref"
        else fail "$API $f: vignette within one step of $ref (max difference $DMAX)"; cat "$CLIPS/last.log"; fi
    done
    # Software frames gpufx uploads itself give the pixels of hwupload.
    same "$API: software input equals hwupload" \
        "$(dx_md5 nv12 "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")" \
        "$(sw_md5 nv12 "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")"
    # yuv420p cannot be uploaded as it is: gpufx converts it to nv12 first.
    same "$API: yuv420p software input (uploaded as nv12)" \
        "$(dx_md5 nv12 "gpufx=graph=$FX/ffmpeg/invert.zip")" \
        "$(gpu_ff -i "$A" -frames:v 3 -an -vf "format=yuv420p,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=nv12" -pix_fmt nv12 \
            -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
    # Two gpufx in a row: the second waits for the first (fences).
    same "$API: invert twice equals software frames" \
        "$(dx_md5 nv12 "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip")" \
        "$(sw_md5 nv12 "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip")"
    pt_tests "$API nv12" nv12 hwupload 0
    # One frame on two input pads (split before gpufx).
    G="[0]split[a][b]; [a]$FX/ffmpeg/gaussian-blur.zip[ba]; [b]$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/vignette.zip[gb]; [ba][gb]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4[x]; [x][1]$FX/ffmpeg/wipe-transition.zip=progress=0.6[out]"
    same "$API: graph equals software frames" \
        "$(dx_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G'")" \
        "$(sw_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G'")"
    # shellcheck disable=SC2086
    ok "$API: timeline enable" -i "$A" -an \
        -vf "format=nv12,hwupload,gpufx=graph=$FX/ffmpeg/invert.zip:enable='gte(t\,0.5)',hwdownload,format=nv12" $NULL
    LATE_DX=$(gpu_ff -i "$A" -itsoffset 0.5 -i "$B" -an -filter_complex \
        "[0]format=nv12,hwupload[a];[1]format=nv12,hwupload[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.5',hwdownload,format=nv12" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' ')
    if [ "$LATE_DX" = "$MAIN_N" ]; then pass "$API: late second input keeps all $MAIN_N frames"
    else fail "$API: late second input (want $MAIN_N, got $LATE_DX)"; cat "$CLIPS/last.log"; fi
    # A late software input: its blank frame is made on the device too.
    LATE_SW=$(gpu_ff -i "$A" -itsoffset 0.5 -i "$B" -an -filter_complex \
        "[0]format=nv12[a];[1]format=nv12[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.5',hwdownload,format=nv12" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' ')
    if [ "$LATE_SW" = "$MAIN_N" ]; then pass "$API: late second software input keeps all $MAIN_N frames"
    else fail "$API: late second software input (want $MAIN_N, got $LATE_SW)"; cat "$CLIPS/last.log"; fi
    # GPU and software inputs together: gpufx uploads the software one to the same device.
    same "$API and software inputs mixed" \
        "$(gpu_ff -i "$A" -i "$B" -frames:v 3 -an -filter_complex "[0]format=nv12,hwupload[a];[1]format=nv12[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4',hwdownload,format=nv12" \
            -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')" \
        "$(gpu_ff -i "$A" -i "$B" -frames:v 3 -an -filter_complex "[0]format=nv12,hwupload[a];[1]format=nv12,hwupload[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4',hwdownload,format=nv12" \
            -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
    # DXGI formats of ffmpeg/patches: hwupload then hwdownload gives the frame back bit for
    # bit. A format the GPU has no texture for is left out by FFmpeg (no error to check).
    for f in rgba bgra gray gray16le rgba64le yuyv422; do
        DXF=$(gpu_ff -i "$A" -frames:v 2 -an -vf "format=$f,hwupload,hwdownload,format=$f" -f framemd5 - 2> "$CLIPS/last.log" |
            grep -v '^#' | awk -F, '{print $NF}')
        if [ -z "$DXF" ] && grep -q "Invalid output format $f for hwframe download" "$CLIPS/last.log" && [ $f != rgba ]; then
            echo "  skip  $API $f: not a texture format of this GPU"; continue
        fi
        same "$API $f: hwupload and hwdownload give the frame back" "$DXF" \
            "$(gpu_ff -i "$A" -frames:v 2 -an -vf "format=$f" -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
    done
    # A still picture with alpha made into video: uploaded once, looped on the GPU, alpha kept
    # through gpufx (out_format=rgba) like software frames gpufx uploads itself.
    DXA=$(gpu_ff -i "$P" -an -vf "format=rgba,hwupload,loop=loop=-1:size=1,setpts=N/25/TB,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=rgba,hwdownload,format=rgba" \
        -frames:v 5 -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}' | sort -u)
    same "$API: rgba still picture looped after hwupload keeps alpha" "$DXA" \
        "$(gpu_ff -i "$P" -frames:v 1 -an -vf "format=rgba,gpufx=graph=$FX/ffmpeg/invert.zip:out_format=rgba,hwdownload,format=rgba" \
            -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
    # -filter_hw_device against the device of decoded D3D11 frames (MPEG-2 clip made by
    # this ffmpeg, decoded with -hwaccel d3d11va on a second device instance).
    if [ "$API" = D3D11 ]; then
        DEC="-init_hw_device ${DXDEV%%=*}=dd:${DXDEV##*:} -hwaccel d3d11va -hwaccel_device dd -hwaccel_output_format d3d11"
        # shellcheck disable=SC2086
        if ! "$FF" -v error -y -i "$A" -an -frames:v 5 -c:v mpeg2video "$CLIPS/m2.mpg" > "$CLIPS/last.log" 2>&1 ||
           ! "$FF" -hide_banner -nostdin -v error $DEC -i "$CLIPS/m2.mpg" -frames:v 1 -vf hwdownload,format=nv12 \
               -f null - > "$CLIPS/last.log" 2>&1; then
            echo "  skip  D3D11: device mismatch tests (no mpeg2video d3d11va decoding: $(head -n1 "$CLIPS/last.log"))"
        else
            M2=$CLIPS/m2.mpg
            if command -v cygpath >/dev/null; then M2=$(cygpath -m "$M2"); fi
            # shellcheck disable=SC2086
            ok "$API: GPU input of another device than -filter_hw_device (no upload: its device wins)" \
                $DEC -i "$M2" -frames:v 3 -vf "gpufx=graph=$FX/ffmpeg/invert.zip" $NULL
            # shellcheck disable=SC2086
            ok "$API: GPU and software inputs, GPU input of another device (its device wins)" \
                $DEC -i "$M2" -i "$B" -frames:v 3 -filter_complex "[0][1]gpufx=graph=$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip" $NULL
            if [ -n "$VK" ]; then
                DEV=$GPU
                # shellcheck disable=SC2086
                rejects "$API: GPU input with a Vulkan -filter_hw_device" \
                    "has D3D11 frames but -filter_hw_device is a vulkan device" \
                    $DEC -i "$M2" -frames:v 3 -vf "gpufx=graph=$FX/ffmpeg/invert.zip" $NULL
            else
                echo "  skip  $API: GPU input with a Vulkan -filter_hw_device (no Vulkan device)"
            fi
        fi
    fi
    DEV=$GPU
done
echo "  D3D frames tested:${dx_ran:- none}; skipped:${dx_skipped:- none}"

echo "VideoToolbox frames:"
# macOS only: hwupload -> gpufx -> hwdownload on FFmpeg's VideoToolbox device (gpufx runs
# on Metal and reads/writes the IOSurfaces in place), same pixels as the software frames
# gpufx uploads to that device itself, and as the Vulkan run when there is one.
# REQUIRE_VT=1 fails when the tests are skipped, unless FFmpeg cannot create the device.
VTDEV="-init_hw_device videotoolbox=vt -filter_hw_device vt"
vt_ran=
vt_skip() {
    echo "  skip  VideoToolbox: $1"
    if [ "${2:-}" = nodevice ]; then
        if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::VideoToolbox frames not tested: $1"; fi
    elif [ "${REQUIRE_VT:-0}" = 1 ]; then
        fail "REQUIRE_VT=1: VideoToolbox frames were not tested"
    fi
}
vt_tests() {
    VKN=vt
    # shellcheck disable=SC2086
    if ! "$FF" -hide_banner -nostdin -v error $VTDEV -i "$A" -frames:v 1 -an \
        -vf "format=nv12,hwupload,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1; then
        vt_skip "FFmpeg cannot create a videotoolbox device ($(head -n1 "$CLIPS/last.log"))" nodevice; return
    fi
    # shellcheck disable=SC2086
    if ! "$FF" -hide_banner -nostdin -v error $VTDEV -i "$A" -frames:v 1 -an \
        -vf "format=nv12,hwupload,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1; then
        cp "$CLIPS/last.log" "$CLIPS/vt-probe.log"
        # A gpufx without these frames, or a machine without a Metal adapter.
        if grep -q "Impossible to convert\|No format\|negotiat\|only supported on macOS" "$CLIPS/last.log"; then
            vt_skip "this gpufx is built without VideoToolbox frames"
        elif grep -q "no Metal adapter\|no GPU adapter" "$CLIPS/last.log"; then
            vt_skip "no Metal adapter ($(grep -m1 "adapter" "$CLIPS/last.log"))" nodevice
        else
            fail "VideoToolbox: gpufx takes VideoToolbox frames"; cat "$CLIPS/last.log"
        fi
        return
    fi
    vt_ran=1
    DEV=$VTDEV
    vt_md5() {
        f=$1; shift
        gpu_ff -i "$A" -frames:v 3 -an -vf "format=$f,hwupload,$1,hwdownload,format=$f" -pix_fmt "$f" -f framemd5 - \
            2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
    }
    # Within one step (as for D3D) of the Vulkan run, else of software frames uploaded by gpufx.
    for f in nv12 p010le; do
        V="gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'"
        if [ $f = nv12 ]; then bytes=1 step=1; else bytes=2 step=64; fi  # p010le: 10 bits << 6
        rm -f "$CLIPS/vt.yuv" "$CLIPS/sw.yuv"
        raw "$CLIPS/vt.yuv" -i "$A" -vf "format=$f,hwupload,$V,hwdownload,format=$f" -pix_fmt $f || true
        cp "$CLIPS/last.log" "$CLIPS/vt-$f.log"
        if [ -n "$VK" ]; then ref="the Vulkan run"; DEV=$GPU; else ref="software frames"; fi
        raw "$CLIPS/sw.yuv" -i "$A" -vf "format=$f,$V,hwdownload,format=$f" -pix_fmt $f || true
        DEV=$VTDEV
        DMAX=-
        if [ -s "$CLIPS/vt.yuv" ] && [ "$(wc -c < "$CLIPS/vt.yuv")" = "$(wc -c < "$CLIPS/sw.yuv")" ]; then
            DMAX=$(diff_stats "$CLIPS/vt.yuv" "$CLIPS/sw.yuv" $bytes | cut -d' ' -f1); DMAX=${DMAX:--}
        fi
        if [ "$DMAX" != - ] && [ "$DMAX" -le $step ]; then pass "VideoToolbox $f: vignette within one step of $ref"
        else
            # p010le outputs need R16/RG16 storage textures, which some (non-Apple) GPUs lack.
            if [ $f = p010le ] && grep -q "cannot write" "$CLIPS/vt-$f.log"; then
                echo "  skip  VideoToolbox p010le output: $(grep -m1 "cannot write" "$CLIPS/vt-$f.log")"
            else
                fail "VideoToolbox $f: vignette within one step of $ref (max difference $DMAX)"; cat "$CLIPS/vt-$f.log"
            fi
        fi
    done
    same "VideoToolbox: software input equals hwupload" \
        "$(vt_md5 nv12 "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")" \
        "$(sw_md5 nv12 "gpufx=graph='$FX/ffmpeg/vignette.zip=strength=0.7'")"
    # Two gpufx in a row: the second reads what the first wrote (no fence: each waits).
    same "VideoToolbox: invert twice equals software frames" \
        "$(vt_md5 nv12 "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip")" \
        "$(sw_md5 nv12 "gpufx=graph=$FX/ffmpeg/invert.zip,gpufx=graph=$FX/ffmpeg/invert.zip")"
    G="[0]split[a][b]; [a]$FX/ffmpeg/gaussian-blur.zip[ba]; [b]$FX/ffmpeg/grayscale.zip|$FX/ffmpeg/vignette.zip[gb]; [ba][gb]$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.4[x]; [x][1]$FX/ffmpeg/wipe-transition.zip=progress=0.6[out]"
    same "VideoToolbox: graph equals software frames" \
        "$(vt_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G'")" \
        "$(sw_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G'")"
    LATE_VT=$(gpu_ff -i "$A" -itsoffset 0.5 -i "$B" -an -filter_complex \
        "[0]format=nv12,hwupload[a];[1]format=nv12[b];[a][b]gpufx=graph='$FX/tqk2811/TqkLibrary.FFmpegTransition/crossfade.zip=progress=0.5',hwdownload,format=nv12" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' ')
    if [ "$LATE_VT" = "$MAIN_N" ]; then pass "VideoToolbox: late second software input keeps all $MAIN_N frames"
    else fail "VideoToolbox: late second software input (want $MAIN_N, got $LATE_VT)"; cat "$CLIPS/last.log"; fi
    # bgra VideoToolbox frames are not read by gpufx: refused with the formats it takes.
    rejects "VideoToolbox: bgra frames are refused" "gpufx reads VideoToolbox frames of nv12, p010le" \
        -i "$A" -an -vf "format=bgra,hwupload,gpufx=graph=$FX/ffmpeg/invert.zip,hwdownload,format=nv12" $NULL
    DEV=$GPU
}
if [ "$(uname -s)" != Darwin ]; then
    echo "  skip  VideoToolbox: not macOS"
elif ! grep -qw hwupload "$CLIPS/filters.txt"; then
    vt_skip "this bundle has no hwupload"
elif ! "$FF" -hide_banner -init_hw_device list 2>&1 | grep -qx videotoolbox; then
    vt_skip "this ffmpeg has no videotoolbox hwdevice"
else
    vt_tests
fi
echo "  VideoToolbox frames tested: $([ -n "$vt_ran" ] && echo yes || echo no)"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
