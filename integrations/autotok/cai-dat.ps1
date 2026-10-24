#Requires -Version 5.1
<#
Cai dat autotok (backend dang TikTok) tren may moi. Chay lai nhieu lan van an toan.
  .\cai-dat.ps1 [-DataDir "D:\duong\dan\du-lieu"]
#>
param([string]$DataDir)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$src = Join-Path $here 'src'
$venv = Join-Path $here '.venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$configPath = Join-Path $here 'config.json'
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$localJson = Join-Path $repoRoot 'integrations\tiktok\local.json'

function Test-PythonOk([string]$exe, [string[]]$extra) {
    # Exit code 0 only for a real Python >= 3.11 (the Microsoft Store stub exits non-zero).
    try {
        $null = & $exe @extra -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Invoke-Native([string]$exe, [string[]]$arguments) {
    # pip writes warnings to stderr; keep them from becoming terminating errors in Windows PowerShell 5.1.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $exe @arguments 2>&1 | ForEach-Object { Write-Host "$_" } } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw "Lenh that bai (ma $LASTEXITCODE): $exe $($arguments -join ' ')" }
}

# 1. Tim Python 3.11+
$python = $null; $pyArgs = @()
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    foreach ($v in @('-3.13', '-3.12', '-3.11')) {
        if ((Get-Command py -ErrorAction SilentlyContinue) -and (Test-PythonOk 'py' @($v))) { $python = 'py'; $pyArgs = @($v); break }
    }
    if (-not $python) {
        $cmd = Get-Command python -ErrorAction SilentlyContinue
        if ($cmd -and (Test-PythonOk $cmd.Source @())) { $python = $cmd.Source }
    }
    if (-not $python) {
        throw 'Khong tim thay Python 3.11 tro len. Hay cai Python tu https://www.python.org/downloads/ (tick "Add python.exe to PATH"), mo lai PowerShell roi chay lai cai-dat.ps1.'
    }
    Write-Host "Tao moi truong ao: $venv"
    Invoke-Native $python ($pyArgs + @('-m', 'venv', $venv))
}
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { throw "Khong tao duoc moi truong ao: $venvPython" }
if (-not (Test-PythonOk $venvPython @())) { throw "Moi truong ao hien co khong phai Python 3.11+. Xoa thu muc $venv roi chay lai." }

# 2. Cai thu vien
Invoke-Native $venvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', (Join-Path $src 'web\requirements.txt'))
Invoke-Native $venvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '-e', $src)

# 3. Kiem tra import
Invoke-Native $venvPython @('-c', 'import autotok,fastapi,uvicorn,sqlmodel,httpx,sse_starlette,playwright; print(autotok.__version__)')

# 4. config.json (noi luu du lieu, gom ca phien dang nhap TikTok)
if ($DataDir -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'KidFBY\autotok-data' }
    $json = ConvertTo-Json -InputObject ([ordered]@{ DataDir = $DataDir })
    [IO.File]::WriteAllText($configPath, $json, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Da ghi $configPath"
}

# 5. Tro Kid-FB.Y toi start.ps1 (chi khi chua co)
if (-not (Test-Path -LiteralPath $localJson -PathType Leaf)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $localJson) -Force | Out-Null
    $json = ConvertTo-Json -InputObject ([ordered]@{ Starter = (Join-Path $here 'start.ps1') })
    [IO.File]::WriteAllText($localJson, $json, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Da ghi $localJson"
}
Write-Host 'Cai dat xong. Mo Kid-FB.Y.exe; bang dieu khien TikTok se tu khoi dong khi can.'
