#!/bin/sh
# Packs effect folders into .zip packages only: no FFmpeg, no Docker.
# Every package is validated first (manifest, rules, file references) by `gpufx pack`.
#   scripts/pack-effects.sh                       all of packages/effects -> dist/effects/<group>/<name>.zip
#   scripts/pack-effects.sh -o out my-fx other-fx  chosen folders -> out/ (group kept for packages/effects)
#   scripts/pack-effects.sh --check               also compile every shader on the GPU
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/dist/effects
CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT=${2:?-o needs a directory}; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done
# A package is any folder with a manifest.json below packages/effects, at any depth.
if [ $# -eq 0 ]; then
    OLD_IFS=$IFS; IFS="
"
    set -- $(find "$ROOT/packages/effects" -name manifest.json | sort | sed 's|/manifest.json$||')
    IFS=$OLD_IFS
fi

cargo build --release --quiet --manifest-path "$ROOT/Cargo.toml" -p gpufx-cli
GPUFX=$ROOT/target/release/gpufx
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

for dir in "$@"; do
    dir=${dir%/}
    [ -f "$dir/manifest.json" ] || { echo "$dir: no manifest.json" >&2; exit 1; }
    [ "$CHECK" = 1 ] && "$GPUFX" check "$dir"
    # Effects of packages/effects keep their group folder (out/<group>/<name>.zip, a nested group keeps all its folders);
    # other folders are packed flat (out/<name>.zip).
    dir=$(cd "$dir" && pwd)
    case "$dir" in
        "$ROOT"/packages/effects/*) rel=${dir#"$ROOT"/packages/effects/} ;;
        *) rel=$(basename "$dir") ;;
    esac
    mkdir -p "$OUT/$(dirname "$rel")"
    "$GPUFX" pack "$dir" "$OUT/$rel.zip"
done
