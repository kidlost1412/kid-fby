#Requires -Version 5.1
<#
  Kid FB.Y - Bo cap nhat qua GitHub
    updater.ps1 -Mode check     -> doc version.json tren GitHub, ghi ket qua ra core\_update\status.json
    updater.ps1 -Mode download  -> tai cac file thay doi vao core\_update\files, kiem SHA256, tao co READY
  Viec THAY FILE do Kid-FB.Y.exe lam luc khoi dong (khi khong co script nao dang chay).
#>
param(
    [ValidateSet('check','download')][string]$Mode = 'check'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$coreDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$root    = Split-Path $coreDir -Parent
$updDir  = Join-Path $coreDir '_update'
$stage   = Join-Path $updDir 'files'
$status  = Join-Path $updDir 'status.json'
New-Item -ItemType Directory -Path $updDir -Force | Out-Null

function Save-Status($obj) {
    $json = $obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($status, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Config {
    $f = Join-Path $coreDir 'update.json'
    if (-not (Test-Path $f)) { throw 'Thieu file core\update.json (chua cau hinh repo GitHub).' }
    $c = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $c.repo -or $c.repo -match 'OWNER/REPO') {
        throw 'Chua cau hinh repo GitHub trong core\update.json! Vui long mo file core\update.json va dien ten repo cua ban (vi du: "ten-ban/kid-fby").'
    }
    if (-not $c.branch) { $c | Add-Member -NotePropertyName branch -NotePropertyValue 'main' -Force }
    $c
}

function Get-Mirrors([string]$url) {
    @($url, "https://ghproxy.net/$url", "https://gh-proxy.com/$url")
}

function Get-Bytes([string]$url) {
    $lastErr = $null
    foreach ($u in (Get-Mirrors $url)) {
        try {
            $sep = if ($u.Contains('?')) { '&' } else { '?' }
            $fullUrl = "$u$($sep)t=$([DateTime]::UtcNow.Ticks)"
            $req = [System.Net.HttpWebRequest]::Create($fullUrl)
            $req.Timeout = 8000
            $req.ReadWriteTimeout = 15000
            $req.UserAgent = 'KidFBY-Updater'
            $req.Headers.Add('Cache-Control', 'no-cache')
            $resp = $req.GetResponse()
            try {
                $stream = $resp.GetResponseStream()
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                return $ms.ToArray()
            } finally {
                if ($resp) { $resp.Close() }
            }
        } catch { $lastErr = $_ }
    }
    throw "Khong tai duoc $url : $($lastErr.Exception.Message)"
}

function Get-Sha([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-','') } finally { $sha.Dispose() }
}

function Get-NormalizedHash([byte[]]$bytes, [string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    if ($ext -in '.ico','.exe','.dll','.zip') {
        return Get-Sha $bytes
    }
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $cleanTxt = $txt -replace "`r`n", "`n"
    $normBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanTxt)
    return Get-Sha $normBytes
}

function Get-FileSha([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $ext = [System.IO.Path]::GetExtension($p).ToLower()
    if ($ext -in '.ico','.exe','.dll','.zip') {
        return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    }
    $txt = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $cleanTxt = $txt -replace "`r`n", "`n"
    $normBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanTxt)
    return Get-Sha $normBytes
}

function Save-FileWithBom([string]$dst, [byte[]]$bytes) {
    $ext = [System.IO.Path]::GetExtension($dst).ToLower()
    if ($ext -in '.ico','.exe','.dll','.zip') {
        [System.IO.File]::WriteAllBytes($dst, $bytes)
        return
    }
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $crlfTxt = ($txt -replace "`r?`n", "`r`n")
    [System.IO.File]::WriteAllText($dst, $crlfTxt, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-LocalVersion {
    $f = Join-Path $coreDir 'version.txt'
    if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '0.0.0' }
}

function Test-SafePath([string]$rel) {
    # Chi cho phep ghi trong thu muc du an, cam '..' va duong dan tuyet doi
    if ($rel -match '\.\.' -or $rel -match '^[a-zA-Z]:' -or $rel.StartsWith('/') -or $rel.StartsWith('\')) { return $false }
    $norm = ($rel -replace '\\', '/').ToLower()
    return ($norm.StartsWith('core/') -or $norm.StartsWith('tools/') -or $norm -eq 'kid-fb.y.exe')
}

try {
    $cfg  = Get-Config
    $ref  = if ($cfg.branch) { $cfg.branch } else { 'main' }
    try {
        $apiReq = [System.Net.HttpWebRequest]::Create("https://api.github.com/repos/$($cfg.repo)/commits/$ref")
        $apiReq.Timeout = 4000
        $apiReq.UserAgent = 'KidFBY-Updater'
        $apiResp = $apiReq.GetResponse()
        $apiSr = New-Object System.IO.StreamReader($apiResp.GetResponseStream())
        $cData = $apiSr.ReadToEnd() | ConvertFrom-Json
        if ($cData.sha) { $ref = $cData.sha }
        $apiResp.Close()
    } catch { }

    $base = "https://raw.githubusercontent.com/$($cfg.repo)/$ref"
    $man  = [System.Text.Encoding]::UTF8.GetString((Get-Bytes "$base/version.json")).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $local = Get-LocalVersion

    # Tim file khac SHA256 (chi can tim khi ban moi lon hon ban hien tai)
    $changed = @()
    if ([version]$man.version -gt [version]$local) {
        foreach ($f in @($man.files)) {
            if (-not (Test-SafePath $f.path)) { continue }
            $lp = Join-Path $root ($f.path -replace '/', '\')
            if ((Get-FileSha $lp) -ne $f.sha256.ToUpper()) { $changed += $f }
        }
    }
    $hasNew = ([version]$man.version -gt [version]$local)
    if ($hasNew -and $changed.Count -eq 0) {
        $changed = @($man.files | Where-Object { Test-SafePath $_.path })
    }

    if ($Mode -eq 'check') {
        Save-Status @{
            ok = $true; hasUpdate = $hasNew; local = $local; remote = $man.version
            mandatory = [bool]$man.mandatory; changelog = @($man.changelog)
            files = if ($hasNew) { @($changed | ForEach-Object { $_.path }) } else { @() }
            size = if ($hasNew) { ($changed | Measure-Object -Property size -Sum).Sum } else { 0 }
        }
        exit 0
    }

    # ---- download ----
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Remove-Item (Join-Path $updDir 'READY') -Force -ErrorAction SilentlyContinue
    $list = @()
    foreach ($f in $changed) {
        $bytes = Get-Bytes "$base/$($f.path)"
        $calcHash = Get-NormalizedHash $bytes $f.path
        if ($calcHash -ne $f.sha256.ToUpper()) { throw "Sai SHA256: $($f.path) (file tai ve bi hong, thu lai sau)" }
        $dst = Join-Path $stage ($f.path -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Save-FileWithBom $dst $bytes
        $list += ($f.path -replace '/', '\')
    }
    # version.txt di kem
    New-Item -ItemType Directory -Path (Join-Path $stage 'core') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stage 'core\version.txt'), [string]$man.version)
    $list += 'core\version.txt'

    # Co READY: danh sach file can thay (exe se doc)
    [System.IO.File]::WriteAllLines((Join-Path $updDir 'READY'), [string[]]$list)
    Save-Status @{ ok = $true; ready = $true; remote = $man.version; files = $list }
    exit 0
} catch {
    Save-Status @{ ok = $false; error = $_.Exception.Message }
    exit 1
}
