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

function Write-DurableBytes([string]$dst, [byte[]]$bytes) {
    $file = [IO.File]::Open($dst, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) }
    finally { $file.Dispose() }
}

function Publish-Ready([string]$directory, [string[]]$paths) {
    $temporary = Join-Path $directory ('READY.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $body = ($paths -join "`r`n") + "`r`n"
        Write-DurableBytes $temporary ([Text.Encoding]::UTF8.GetBytes($body))
        [IO.File]::Move($temporary, (Join-Path $directory 'READY'))
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Save-FileWithBom([string]$dst, [byte[]]$bytes) {
    $ext = [System.IO.Path]::GetExtension($dst).ToLower()
    if ($ext -in '.ico','.exe','.dll','.zip') {
        Write-DurableBytes $dst $bytes
        return
    }
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $crlfTxt = ($txt -replace "`r?`n", "`r`n")
    $encoding = New-Object System.Text.UTF8Encoding($true)
    Write-DurableBytes $dst ([byte[]]($encoding.GetPreamble() + $encoding.GetBytes($crlfTxt)))
}

function Get-LocalVersion {
    $f = Join-Path $coreDir 'version.txt'
    if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '0.0.0' }
}

function Test-SafePath([string]$rel) {
    if ([string]::IsNullOrWhiteSpace($rel) -or $rel -match '[\x00-\x1f:]' -or [IO.Path]::IsPathRooted($rel)) { return $false }
    $norm = ($rel -replace '\\', '/').ToLowerInvariant()
    foreach ($part in $norm.Split('/')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.TrimEnd(' ','.') -ne $part -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $part -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)') { return $false }
    }
    if ($norm -match '^core/_(update|backup)(/|$)') { return $false }
    return ($norm.StartsWith('core/') -or $norm.StartsWith('tools/') -or $norm -eq 'kid-fb.y.exe')
}

try {
    if ($Mode -eq 'download') {
        $updateLease = [IO.File]::Open((Join-Path $updDir 'transaction.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if ((Test-Path -LiteralPath (Join-Path $coreDir '_backup\JOURNAL')) -or (Test-Path -LiteralPath (Join-Path $updDir 'READY'))) {
            throw 'Dang co ban cap nhat cho khoi dong/phuc hoi. Hay khoi dong lai ung dung truoc khi tai tiep.'
        }
    }
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
    $stageFull = [IO.Path]::GetFullPath($stage)
    $updateBoundary = [IO.Path]::GetFullPath($updDir).TrimEnd('\') + '\'
    if (-not $stageFull.StartsWith($updateBoundary, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($stageFull) -ne 'files') { throw 'Duong dan staging khong an toan.' }
    if (Test-Path -LiteralPath $stageFull) {
        if ((Get-Item -LiteralPath $stageFull).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Staging khong duoc la lien ket.' }
        Remove-Item -LiteralPath $stageFull -Recurse -Force
    }
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
    Write-DurableBytes (Join-Path $stage 'core\version.txt') ([Text.Encoding]::UTF8.GetBytes([string]$man.version))
    $list = @($list | Where-Object { $_ -ine 'core\version.txt' } | Select-Object -Unique) + 'core\version.txt'

    # Co READY: danh sach file can thay (exe se doc)
    Publish-Ready $updDir ([string[]]$list)
    Save-Status @{ ok = $true; ready = $true; remote = $man.version; files = $list }
    exit 0
} catch {
    Save-Status @{ ok = $false; error = $_.Exception.Message }
    exit 1
} finally {
    if ($updateLease) { $updateLease.Dispose() }
}
