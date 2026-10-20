#Requires -Version 5.1
<#
  Kid FB.Y - Bo cap nhat qua GitHub
    updater.ps1 -Mode check     -> doc version.json tren GitHub, ghi ket qua ra core\_update\status.json
    updater.ps1 -Mode download  -> tai cac file thay doi vao core\_update\files, kiem SHA256, tao co READY
  Viec THAY FILE do Kid-FB.Y.exe lam luc khoi dong (khi khong co script nao dang chay).
#>
param(
    [ValidateSet('check','download')][string]$Mode = 'check',
    [string]$LauncherVersion = ''
)
# Khoa cong khai RSA (XML) dung de xac minh chu ky version.json. Tao bang new-signing-key.ps1.
# Ban build phai thay placeholder nay bang noi dung update-signing-public.xml.
$UpdatePublicKeyXml = '<<PUBLIC_KEY_PLACEHOLDER>>'
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

function Get-BytesFromUrls([string[]]$urls, [string]$label, [long]$maxBytes) {
    $lastErr = $null
    foreach ($u in $urls) {
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
                if ($maxBytes -gt 0 -and $resp.ContentLength -gt $maxBytes) { throw "Phan hoi qua lon ($($resp.ContentLength) byte)." }
                $stream = $resp.GetResponseStream()
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                if ($maxBytes -gt 0 -and $ms.Length -gt $maxBytes) { throw "Phan hoi qua lon ($($ms.Length) byte)." }
                return $ms.ToArray()
            } finally {
                if ($resp) { $resp.Close() }
            }
        } catch { $lastErr = $_ }
    }
    throw "Khong tai duoc $label : $($lastErr.Exception.Message)"
}

# Manifest/chu ky/payload: nguon goc truoc, mirror chi la du phong. Toan ven duoc bao dam boi
# chu ky RSA tren manifest (manifest) va SHA256 trong manifest da xac thuc (payload).
function Get-Bytes([string]$url) {
    Get-BytesFromUrls (Get-Mirrors $url) $url 0
}

function Write-UpdLog([string]$msg) {
    try {
        $logDir = Join-Path $root 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
        [System.IO.File]::AppendAllText((Join-Path $logDir ('updater-' + (Get-Date).ToString('yyyyMMdd') + '.log')), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Warning "Khong ghi duoc log updater: $($_.Exception.Message)" }
}

# Xac minh chu ky RSA-SHA256 tren DUNG cac byte manifest da tai. Nem loi neu that bai; tra $true neu hop le.
function Test-ManifestSignature([byte[]]$manifestBytes, [string]$sigBase64, [string]$publicKeyXml) {
    if ([string]::IsNullOrWhiteSpace($publicKeyXml) -or $publicKeyXml -match 'PUBLIC_KEY_PLACEHOLDER') {
        throw 'ban build chua cau hinh khoa ky'
    }
    if ($null -eq $manifestBytes -or $manifestBytes.Length -eq 0) { throw 'Manifest rong, tu choi cap nhat.' }
    if ([string]::IsNullOrWhiteSpace($sigBase64)) { throw 'Thieu chu ky version.json.sig, tu choi cap nhat.' }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        try { $rsa.FromXmlString($publicKeyXml) } catch { throw "Khoa cong khai khong hop le: $($_.Exception.Message)" }
        try { $sig = [Convert]::FromBase64String($sigBase64.Trim()) } catch { throw 'Chu ky version.json.sig khong phai Base64 hop le, tu choi cap nhat.' }
        $ok = $false
        try { $ok = $rsa.VerifyData($manifestBytes, 'SHA256', $sig) } catch { $ok = $false }
        if (-not $ok) { throw 'Chu ky manifest KHONG khop, tu choi cap nhat.' }
        return $true
    } finally {
        $rsa.Dispose()
    }
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
    if ($UpdatePublicKeyXml -match 'PUBLIC_KEY_PLACEHOLDER') { throw 'ban build chua cau hinh khoa ky' }
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
    # Manifest + chu ky: thu nguon goc truoc, loi mang moi thu mirror. Chu ky RSA van bat buoc,
    # nen mirror khong the gia mao manifest. Loi ca hai -> khong cap nhat.
    $manBytes = Get-BytesFromUrls (Get-Mirrors "$base/version.json") "$base/version.json" 1048576
    $sigBytes = Get-BytesFromUrls (Get-Mirrors "$base/version.json.sig") "$base/version.json.sig" 8192
    $sigText = [System.Text.Encoding]::ASCII.GetString($sigBytes)
    [void](Test-ManifestSignature $manBytes $sigText $UpdatePublicKeyXml)
    $man  = [System.Text.Encoding]::UTF8.GetString($manBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $local = Get-LocalVersion

    $newer = ([version]$man.version -gt [version]$local)
    $failedFlag = Join-Path $updDir ("failed-$($man.version).flag")
    $skipFailed = $false
    if ($newer -and (Test-Path -LiteralPath $failedFlag)) {
        $skipFailed = $true
        Write-UpdLog "Bo qua phien ban $($man.version): da danh dau khoi dong loi truoc do ($failedFlag). Xoa file flag de thu lai."
    }
    if ($newer -and -not $skipFailed -and $man.minLauncher) {
        $curLauncher = $LauncherVersion
        if (-not $curLauncher) {
            $exe = Join-Path $root 'Kid-FB.Y.exe'
            if (Test-Path -LiteralPath $exe) { $curLauncher = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion }
        }
        if ($curLauncher -and ([version]$curLauncher -lt [version]$man.minLauncher)) {
            Write-UpdLog "Launcher $curLauncher < minLauncher $($man.minLauncher) cua ban $($man.version)."
            throw "Ban $($man.version) can Kid-FB.Y.exe tu $($man.minLauncher) tro len (hien tai $curLauncher). Hay tai ban day du moi, khong cap nhat tu dong."
        }
    }

    # Tim file khac SHA256 (chi can tim khi ban moi lon hon ban hien tai)
    $changed = @()
    if ($newer -and -not $skipFailed) {
        foreach ($f in @($man.files)) {
            if (-not (Test-SafePath $f.path)) { continue }
            $lp = Join-Path $root ($f.path -replace '/', '\')
            if ((Get-FileSha $lp) -ne $f.sha256.ToUpper()) { $changed += $f }
        }
    }
    $hasNew = $newer -and -not $skipFailed
    if ($hasNew -and $changed.Count -eq 0) {
        $changed = @($man.files | Where-Object { Test-SafePath $_.path })
    }

    if ($Mode -eq 'check') {
        Save-Status @{
            ok = $true; hasUpdate = $hasNew; local = $local; remote = $man.version
            mandatory = [bool]$man.mandatory; changelog = @($man.changelog)
            skippedFailed = $skipFailed; signed = $true
            files = if ($hasNew) { @($changed | ForEach-Object { $_.path }) } else { @() }
            size = if ($hasNew) { ($changed | Measure-Object -Property size -Sum).Sum } else { 0 }
        }
        exit 0
    }

    # ---- download ----
    if ($skipFailed) { throw "Phien ban $($man.version) da khoi dong loi tren may nay va bi bo qua (xem logs\updater-*.log)." }
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
