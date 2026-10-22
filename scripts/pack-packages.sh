#!/bin/sh
# Packs effect folders into .zip packages only: no FFmpeg, no Docker.
# Every package is validated first (manifest, rules, file references) by `gpufx pack`.
#   scripts/pack-packages.sh                       all of packages/gpufx -> dist/packages/gpufx/<group>/<name>.zip
#   scripts/pack-packages.sh -o out my-fx other-fx  chosen folders -> out/ (group kept for packages/gpufx)
#   scripts/pack-packages.sh --check               also compile every shader on the GPU
#   scripts/pack-packages.sh --models              also fetch the models (scripts/fetch-models.sh) and copy
#                                                  them next to out/: ../gpufx_ai_<filter>/<name>.zip (+ .LICENSE.txt)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/dist/packages/gpufx
CHECK=0
MODELS=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT=${2:?-o needs a directory}; shift 2 ;;
        --check) CHECK=1; shift ;;
        --models) MODELS=1; shift ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done
# A package is any folder with a manifest.json below packages/gpufx, at any depth.
if [ $# -eq 0 ]; then
    OLD_IFS=$IFS; IFS="
"
    set -- $(find "$ROOT/packages/gpufx" -name manifest.json | sort | sed 's|/manifest.json$||')
    IFS=$OLD_IFS
fi
[ "$MODELS" = 0 ] || [ "$(basename "$OUT")" = gpufx ] || { echo "--models needs -o <root>/gpufx (models go to <root>/gpufx_ai_*)" >&2; exit 1; }

cargo build --release --quiet --manifest-path "$ROOT/Cargo.toml" -p gpufx-cli
GPUFX=$ROOT/target/release/gpufx
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

for dir in "$@"; do
    dir=${dir%/}
    [ -f "$dir/manifest.json" ] || { echo "$dir: no manifest.json" >&2; exit 1; }
    [ "$CHECK" = 1 ] && "$GPUFX" check "$dir"
    # Effects of packages/gpufx keep their group folder (out/<group>/<name>.zip, a nested group keeps all its folders);
    # other folders are packed flat (out/<name>.zip).
    dir=$(cd "$dir" && pwd)
    case "$dir" in
        "$ROOT"/packages/gpufx/*) rel=${dir#"$ROOT"/packages/gpufx/} ;;
        *) rel=$(basename "$dir") ;;
    esac
    mkdir -p "$OUT/$(dirname "$rel")"
    "$GPUFX" pack "$dir" "$OUT/$rel.zip"
done

# Models: the release layout of gpufx-packages.zip, <out>/../gpufx_ai_<filter>/<name>.zip. A failed
# fetch fails the script.
if [ "$MODELS" = 1 ]; then
    "$ROOT/scripts/fetch-models.sh"
    PKGS=$(dirname "$OUT")
    for d in "$ROOT"/packages/gpufx_ai_*/*/; do
        [ -f "$d/source.json" ] || continue
        name=$(basename "$d") filter=$(basename "$(dirname "$d")")
        src=$ROOT/build/packages/$filter
        mkdir -p "$PKGS/$filter"
        cp "$src/$name.zip" "$PKGS/$filter/"
        if [ -f "$src/$name/LICENSE" ]; then cp "$src/$name/LICENSE" "$PKGS/$filter/$name.LICENSE.txt"; fi
    done
fi
