# Downloads the neural network models of models/*/source.json (pinned URLs, sha256 checked) into
# build/models/<name>/ and converts each to build/models/<name>.zip (gpufx-nn package).
# The model files are not in git.
#   scripts/fetch-models.ps1                      all models
#   scripts/fetch-models.ps1 rife-v4.6            chosen models
#   scripts/fetch-models.ps1 -Bin <gpufx-nnconv>  use a built converter instead of `cargo run`
param(
    [string]$Bin = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Names
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Names) {
    $Names = Get-ChildItem (Join-Path $root 'models') -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'source.json') } | ForEach-Object { $_.Name }
}

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

foreach ($name in $Names) {
    $srcFile = Join-Path $root "models/$name/source.json"
    if (-not (Test-Path $srcFile)) { throw "$name`: no models/$name/source.json" }
    $src = Get-Content -Raw $srcFile | ConvertFrom-Json
    $dir = Join-Path $root "build/models/$name"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Get-Model $src.url_param $src.sha256_param (Join-Path $dir 'flownet.param')
    Get-Model $src.url_bin $src.sha256_bin (Join-Path $dir 'flownet.bin')
    $convertArgs = @('ncnn', '--param', (Join-Path $dir 'flownet.param'), '--bin', (Join-Path $dir 'flownet.bin'),
        '--io', (Join-Path $root "models/$name/io.json"), '--name', $name, '-o', (Join-Path $root "build/models/$name.zip"))
    if ($src.license_url) {
        Get-Model $src.license_url $src.sha256_license (Join-Path $dir 'LICENSE')
        $convertArgs += @('--license', (Join-Path $dir 'LICENSE'))
    }
    if ($Bin) {
        & $Bin @convertArgs
    } else {
        cargo run --release --quiet --manifest-path (Join-Path $root 'Cargo.toml') -p gpufx-nnconv -- @convertArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "gpufx-nnconv failed for $name" }
}
