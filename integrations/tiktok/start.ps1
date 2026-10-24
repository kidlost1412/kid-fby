#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$starter = $env:KID_FBY_AUTOTOK_STARTER
$config = Join-Path $PSScriptRoot 'local.json'
if (-not $starter -and (Test-Path -LiteralPath $config -PathType Leaf)) {
    $starter = ([IO.File]::ReadAllText($config) | ConvertFrom-Json).Starter
}
if (-not $starter -or -not (Test-Path -LiteralPath $starter -PathType Leaf)) {
    throw 'Set KID_FBY_AUTOTOK_STARTER or integrations/tiktok/local.json to the installed autotok startup script.'
}
& $starter
