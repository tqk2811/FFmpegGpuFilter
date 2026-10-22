# Packs effect folders into .zip packages only: no FFmpeg, no Docker.
# Every package is validated first (manifest, rules, file references) by `gpufx pack`.
#   .\scripts\pack-packages.ps1                          all of packages\gpufx -> dist\packages\gpufx\<group>\<name>.zip
#   .\scripts\pack-packages.ps1 -Out out my-fx other-fx   chosen folders -> out\ (group kept for packages\gpufx)
#   .\scripts\pack-packages.ps1 -Check                   also compile every shader on the GPU
#   .\scripts\pack-packages.ps1 -Models                  also fetch the models (scripts\fetch-models.ps1) and copy
#                                                        them next to out\: ..\gpufx_ai_<filter>\<name>.zip (+ .LICENSE.txt)
param(
    [string]$Out = "",
    [switch]$Check,
    [switch]$Models,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Dirs
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root "dist/packages/gpufx" }
if ($Models -and (Split-Path -Leaf $Out.TrimEnd('\', '/')) -ne "gpufx") { throw "-Models needs -Out <root>\gpufx (models go to <root>\gpufx_ai_*)" }
if (-not $Dirs) { $Dirs = Get-ChildItem -Recurse -File -Filter manifest.json (Join-Path $root "packages/gpufx") | Sort-Object FullName | ForEach-Object { $_.Directory.FullName } }

cargo build --release --quiet --manifest-path (Join-Path $root "Cargo.toml") -p gpufx-cli
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
$gpufx = Join-Path $root "target/release/gpufx"
New-Item -ItemType Directory -Force $Out | Out-Null

foreach ($dir in $Dirs) {
    if (-not (Test-Path (Join-Path $dir "manifest.json"))) { throw "${dir}: no manifest.json" }
    if ($Check) {
        & $gpufx check $dir
        if ($LASTEXITCODE -ne 0) { throw "check failed: $dir" }
    }
    # Effects of packages\gpufx keep their group folder (out\<group>\<name>.zip);
    # other folders are packed flat (out\<name>.zip).
    $full = (Resolve-Path $dir).Path.TrimEnd('\', '/')
    $examples = (Resolve-Path (Join-Path $root "packages/gpufx")).Path
    $rel = Split-Path -Leaf $full
    if ($full.StartsWith($examples + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($examples.Length + 1)
    }
    $zip = Join-Path $Out ($rel + ".zip")
    New-Item -ItemType Directory -Force (Split-Path -Parent $zip) | Out-Null
    & $gpufx pack $full $zip
    if ($LASTEXITCODE -ne 0) { throw "pack failed: $dir" }
}

# Models: the release layout of gpufx-packages.zip, <out>\..\gpufx_ai_<filter>\<name>.zip. A failed
# fetch fails the script.
if ($Models) {
    & (Join-Path $PSScriptRoot "fetch-models.ps1")
    if (-not $?) { throw "fetching the models failed" }
    $pkgs = Split-Path -Parent (Resolve-Path $Out).Path
    foreach ($src in Get-ChildItem (Join-Path $root "packages/gpufx_ai_*/*/source.json")) {
        $name = $src.Directory.Name
        $filter = $src.Directory.Parent.Name
        $from = Join-Path $root "build/packages/$filter"
        $to = Join-Path $pkgs $filter
        New-Item -ItemType Directory -Force $to | Out-Null
        Copy-Item (Join-Path $from "$name.zip") $to
        $license = Join-Path $from "$name/LICENSE"
        if (Test-Path $license) { Copy-Item $license (Join-Path $to "$name.LICENSE.txt") }
    }
}
