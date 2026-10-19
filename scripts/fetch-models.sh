#!/bin/sh
# Downloads the neural network models of models/*/source.json (pinned URLs, sha256 checked) into
# build/models/<name>/ and converts each to build/models/<name>.zip (gpufx-nn package).
# The model files are not in git.
#   scripts/fetch-models.sh                        all models
#   scripts/fetch-models.sh rife-v4.6              chosen models
#   scripts/fetch-models.sh --bin <gpufx-nnconv>   use a built converter instead of `cargo run`
#
# A source.json with a "variants" array is a multi-scale bundle: each variant has a dir, io, url_param,
# sha256_param, url_bin and sha256_bin; the variants are converted and bundled into build/models/<name>.zip.
# A flat source.json (url_param/url_bin/io.json) stays a single-model package.
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

# One line "dir|io|url_param|sha256_param|url_bin|sha256_bin" per variant object of a "variants" array.
json_variants() {
    awk '
        /"variants"[[:space:]]*:/ { invar = 1 }
        invar && /\[/ { started = 1 }
        started && /\{/ { depth++; dir=io=up=sp=ub=sb="" }
        started {
            if (match($0, /"dir"[[:space:]]*:[[:space:]]*"[^"]*"/))        { dir = extract($0) }
            if (match($0, /"io"[[:space:]]*:[[:space:]]*"[^"]*"/))         { io = extract($0) }
            if (match($0, /"url_param"[[:space:]]*:[[:space:]]*"[^"]*"/))  { up = extract($0) }
            if (match($0, /"sha256_param"[[:space:]]*:[[:space:]]*"[^"]*"/)) { sp = extract($0) }
            if (match($0, /"url_bin"[[:space:]]*:[[:space:]]*"[^"]*"/))    { ub = extract($0) }
            if (match($0, /"sha256_bin"[[:space:]]*:[[:space:]]*"[^"]*"/)) { sb = extract($0) }
        }
        started && /\}/ { depth--; print dir "|" io "|" up "|" sp "|" ub "|" sb }
        started && /\]/ { invar = 0; started = 0 }
        function extract(line,   s) {
            s = substr(line, RSTART, RLENGTH)
            sub(/^[^:]*:[[:space:]]*"/, "", s)
            sub(/".*/, "", s)
            return s
        }
    ' "$1"
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

    license=
    if [ -n "$(json_get "$src" license_url)" ]; then
        fetch "$(json_get "$src" license_url)" "$(json_get "$src" sha256_license)" "$dir/LICENSE"
        license=$dir/LICENSE
    fi
    readme=
    [ -f "$ROOT/models/$name/README.md" ] && readme=$ROOT/models/$name/README.md

    if grep -q '"variants"' "$src"; then
        # Multi-scale bundle: convert each variant to a package directory, then bundle them.
        rm -f "$dir/.variants"
        json_variants "$src" | while IFS='|' read -r vdir vio vurl_param vsha_param vurl_bin vsha_bin; do
            [ -n "$vdir" ] || continue
            vd=$dir/$vdir
            mkdir -p "$vd"
            fetch "$vurl_param" "$vsha_param" "$vd/model.param"
            fetch "$vurl_bin" "$vsha_bin" "$vd/model.bin"
            convert ncnn --param "$vd/model.param" --bin "$vd/model.bin" --io "$ROOT/models/$name/$vio" \
                --name "$name-$vdir" -o "$dir/pkg-$vdir"
            echo "$vdir|$dir/pkg-$vdir" >> "$dir/.variants"
        done
        [ -f "$dir/.variants" ] || { echo "$name: no variants parsed" >&2; exit 1; }
        set --
        while IFS='|' read -r vdir pkg; do
            set -- "$@" --variant "$vdir=$pkg"
        done < "$dir/.variants"
        rm -f "$dir/.variants"
        convert bundle "$@" --name "$name" \
            ${readme:+--readme "$readme"} ${license:+--license "$license"} -o "$ROOT/build/models/$name.zip"
    else
        # Single-model package (e.g. RIFE).
        fetch "$(json_get "$src" url_param)" "$(json_get "$src" sha256_param)" "$dir/flownet.param"
        fetch "$(json_get "$src" url_bin)" "$(json_get "$src" sha256_bin)" "$dir/flownet.bin"
        convert ncnn --param "$dir/flownet.param" --bin "$dir/flownet.bin" --io "$ROOT/models/$name/io.json" \
            ${license:+--license "$license"} ${readme:+--readme "$readme"} --name "$name" -o "$ROOT/build/models/$name.zip"
    fi
done
