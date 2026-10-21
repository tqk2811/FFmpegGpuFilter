# Downloads the neural network models of packages/<filter>/<name>/source.json (<filter> is a
# gpufx_ai_* folder; pinned URLs, sha256 checked) into build/packages/<filter>/<name>/ and converts
# each to build/packages/<filter>/<name>.zip (gpufx-nn package). The model files are not in git.
#   scripts/fetch-models.ps1                      all models
#   scripts/fetch-models.ps1 rife-v4.6            chosen models
#   scripts/fetch-models.ps1 -Bin <gpufx-nnconv>  use a built converter instead of `cargo run`
#
# A source.json with a "variants" array is a multi-scale bundle: each variant has a dir, io, url_param,
# sha256_param, url_bin and sha256_bin; the variants are converted and bundled into build/packages/<filter>/<name>.zip.
# A flat source.json (url_param/url_bin/io.json) stays a single-model package. "used_for" (the FFmpeg
# filters the model is for) is passed to gpufx-nnconv --used-for.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Bin = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Names
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
# name -> packages/gpufx_ai_<filter>/<name> folder holding its source.json
$modelDirs = @{}
Get-ChildItem (Join-Path $root 'packages') -Directory -Filter 'gpufx_ai_*' | ForEach-Object {
    Get-ChildItem $_.FullName -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'source.json') } |
        ForEach-Object { $modelDirs[$_.Name] = $_.FullName }
}
if (-not $Names) { $Names = @($modelDirs.Keys | Sort-Object) }

function Get-Model([string]$url, [string]$sha256, [string]$file) {
    if ((Test-Path -LiteralPath $file) -and ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $sha256)) {
        Write-Host "cached: $file"
        return
    }
    Write-Host "download: $url"
    $part = "$file.part"
    Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
    if ($got -ne $sha256) {
        Remove-Item -LiteralPath $part -Force
        throw "sha256 mismatch for ${url}: expected $sha256, got $got"
    }
    Move-Item -LiteralPath $part -Destination $file -Force
}

function Invoke-Converter([string[]]$convertArgs) {
    if ($Bin) {
        & $Bin @convertArgs
    } else {
        cargo run --release --quiet --manifest-path (Join-Path $root 'Cargo.toml') -p gpufx-nnconv -- @convertArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "gpufx-nnconv failed" }
}

foreach ($name in $Names) {
    $mdir = $modelDirs[$name]
    if (-not $mdir) { throw "$name`: no packages/gpufx_ai_*/$name/source.json" }
    $srcFile = Join-Path $mdir 'source.json'
    $out = Join-Path $root "build/packages/$(Split-Path -Leaf (Split-Path -Parent $mdir))"
    $src = Get-Content -Raw $srcFile | ConvertFrom-Json
    $dir = Join-Path $out $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $usedFor = @($src.used_for) -join ','
    if (-not $usedFor) { throw "$name`: $srcFile has no `"used_for`"" }

    $license = $null
    if ($src.license_url) {
        Get-Model $src.license_url $src.sha256_license (Join-Path $dir 'LICENSE')
        $license = Join-Path $dir 'LICENSE'
    }
    $readmeFile = Join-Path $mdir "README.md"

    if ($src.variants) {
        # Multi-scale bundle: convert each variant to a package directory, then bundle them.
        $variantArgs = @()
        foreach ($v in $src.variants) {
            $vdir = Join-Path $dir $v.dir
            New-Item -ItemType Directory -Force $vdir | Out-Null
            Get-Model $v.url_param $v.sha256_param (Join-Path $vdir 'model.param')
            Get-Model $v.url_bin $v.sha256_bin (Join-Path $vdir 'model.bin')
            $pkgDir = Join-Path $dir "pkg-$($v.dir)"
            Invoke-Converter @('ncnn', '--param', (Join-Path $vdir 'model.param'), '--bin', (Join-Path $vdir 'model.bin'),
                '--io', (Join-Path $mdir "$($v.io)"), '--used-for', $usedFor, '--name', "$name-$($v.dir)", '-o', $pkgDir)
            $variantArgs += @('--variant', "$($v.dir)=$pkgDir")
        }
        $bundleArgs = @('bundle') + $variantArgs + @('--name', $name, '-o', (Join-Path $out "$name.zip"))
        if (Test-Path $readmeFile) { $bundleArgs += @('--readme', $readmeFile) }
        if ($license) { $bundleArgs += @('--license', $license) }
        Invoke-Converter $bundleArgs
    } else {
        # Single-model package (e.g. RIFE).
        Get-Model $src.url_param $src.sha256_param (Join-Path $dir 'flownet.param')
        Get-Model $src.url_bin $src.sha256_bin (Join-Path $dir 'flownet.bin')
        $convertArgs = @('ncnn', '--param', (Join-Path $dir 'flownet.param'), '--bin', (Join-Path $dir 'flownet.bin'),
            '--io', (Join-Path $mdir "io.json"), '--used-for', $usedFor, '--name', $name, '-o',
 (Join-Path $out "$name.zip"))
        if (Test-Path $readmeFile) { $convertArgs += @('--readme', $readmeFile) }
        if ($license) { $convertArgs += @('--license', $license) }
        Invoke-Converter $convertArgs
    }
}
