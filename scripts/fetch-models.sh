#!/bin/sh
# Downloads the neural network models of models/*/source.json (pinned URLs, sha256 checked) into
# build/models/<name>/ and converts each to build/models/<name>.zip (gpufx-nn package).
# The model files are not in git.
#   scripts/fetch-models.sh                        all models
#   scripts/fetch-models.sh rife-v4.6              chosen models
#   scripts/fetch-models.sh --bin <gpufx-nnconv>   use a built converter instead of `cargo run`
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=
while [ $# -gt 0 ]; do
    case "$1" in
        --bin) BIN=${2:?--bin needs a path}; shift 2 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done
if [ $# -eq 0 ]; then
    set --
    for d in "$ROOT"/models/*/; do
        [ -f "$d/source.json" ] && set -- "$@" "$(basename "$d")"
    done
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Value of a flat string key of source.json (one key per line).
json_get() {
    sed -n 's/^[[:space:]]*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# fetch <url> <sha256> <file>: skips a cached file with the right hash, fails on a wrong download.
fetch() {
    if [ -f "$3" ] && [ "$(sha256 "$3")" = "$2" ]; then
        echo "cached: $3"
        return
    fi
    echo "download: $1"
    curl -fsSL --retry 3 -o "$3.part" "$1"
    got=$(sha256 "$3.part")
    if [ "$got" != "$2" ]; then
        rm -f "$3.part"
        echo "sha256 mismatch for $1: expected $2, got $got" >&2
        exit 1
    fi
    mv "$3.part" "$3"
}

convert() {
    if [ -n "$BIN" ]; then
        "$BIN" "$@"
    else
        cargo run --release --quiet --manifest-path "$ROOT/Cargo.toml" -p gpufx-nnconv -- "$@"
    fi
}

for name in "$@"; do
    src=$ROOT/models/$name/source.json
    [ -f "$src" ] || { echo "$name: no models/$name/source.json" >&2; exit 1; }
    dir=$ROOT/build/models/$name
    mkdir -p "$dir"
    fetch "$(json_get "$src" url_param)" "$(json_get "$src" sha256_param)" "$dir/flownet.param"
    fetch "$(json_get "$src" url_bin)" "$(json_get "$src" sha256_bin)" "$dir/flownet.bin"
    license=
    if [ -n "$(json_get "$src" license_url)" ]; then
        fetch "$(json_get "$src" license_url)" "$(json_get "$src" sha256_license)" "$dir/LICENSE"
        license=$dir/LICENSE
    fi
    readme=
    [ -f "$ROOT/models/$name/README.md" ] && readme=$ROOT/models/$name/README.md
    convert ncnn --param "$dir/flownet.param" --bin "$dir/flownet.bin" --io "$ROOT/models/$name/io.json" \
        ${license:+--license "$license"} ${readme:+--readme "$readme"} --name "$name" -o "$ROOT/build/models/$name.zip"
done
