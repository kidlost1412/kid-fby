#Requires -Version 5.1
<#
Stable starter for the TikTok backend installed by Kid FB.Y (kid-install.ps1 writes this file to
<root>\integrations\autotok-start.ps1; integrations\tiktok\local.json points here). It starts the release named in
autotok-current.json, so updates never rewrite local.json.
While kid-install.ps1 holds autotok-upgrade.lock (switching releases) it refuses to start anything; the installer
starts releases itself.
An unverified release that does not come up goes back to the previous release, or - when it replaced a git/custom
setup (autotok-takeover-journal.json) - to that setup.
#>
$ErrorActionPreference = 'Stop'
$integrations = $PSScriptRoot
$appRoot = Split-Path -Parent $integrations

$lockPath = Join-Path $integrations 'autotok-upgrade.lock'
if ([IO.File]::Exists($lockPath)) {
    # The installer opens the lock with FileShare.None + DeleteOnClose: a file nobody holds is a leftover and is ignored.
    try { [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite).Dispose() }
    catch [IO.FileNotFoundException] { <# released between the two checks #> }
    catch { throw 'Đang cập nhật bộ đăng TikTok. Đợi cập nhật xong rồi thử lại.' }
}

$currentPath = Join-Path $integrations 'autotok-current.json'
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw 'Chưa cài bộ đăng TikTok (thiếu autotok-current.json). Mở Kid FB.Y > Cài đặt > Công cụ > Cài bộ đăng TikTok.' }
$current = [IO.File]::ReadAllText($currentPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$release = [string]$current.release
if ($release -notmatch '^[0-9a-f]{12}-[0-9]{8}-[0-9]{6}$') { throw "autotok-current.json không hợp lệ: '$release'." }
$start = Join-Path (Join-Path (Join-Path $integrations 'autotok-releases') $release) 'start.ps1'
if (-not (Test-Path -LiteralPath $start -PathType Leaf)) { throw "Thiếu bản bộ đăng TikTok đang dùng: $start" }

# Data folder: AUTOTOK_DATA_DIR from the environment wins (same order as run_autotok_web.py), else autotok-config.json.
$incomingDataDir = $env:AUTOTOK_DATA_DIR   # $null = not set; restored before a foreign starter runs
if (-not $env:AUTOTOK_DATA_DIR) {
    $configPath = Join-Path $integrations 'autotok-config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $dataDir = [string]([IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).DataDir
        if ($dataDir.Trim()) { $env:AUTOTOK_DATA_DIR = $dataDir.Trim() }
    }
}
# The release folder is not next to tools\: point the uploader at Kid FB.Y's ffprobe here.
$ffprobe = Join-Path $appRoot 'tools\ffmpeg\ffprobe.exe'
if (-not $env:KID_FBY_FFPROBE -and (Test-Path -LiteralPath $ffprobe -PathType Leaf)) { $env:KID_FBY_FFPROBE = $ffprobe }

$verified = ($null -eq $current.PSObject.Properties['verified']) -or [bool]$current.verified
if ($verified) { & $start; return }

# Unverified release: the installer was interrupted after switching. Start it and require /health + scheduler;
# if it does not come up, go back to the previous release (the one that worked) and start that instead.
$installLock = Join-Path $integrations 'autotok-install.lock'
if ([IO.File]::Exists($installLock)) {
    try { [IO.File]::Open($installLock, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite).Dispose() }
    catch [IO.FileNotFoundException] { <# released between the two checks #> }
    catch { throw 'Đang cài bộ đăng TikTok. Đợi cài xong rồi thử lại.' }
}
$healthUrl = 'http://127.0.0.1:8765/health'
if ($env:KID_FBY_TIKTOK_URL) {
    $uri = [Uri]$env:KID_FBY_TIKTOK_URL.TrimEnd('/')
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1') { throw 'KID_FBY_TIKTOK_URL phải là http://127.0.0.1.' }
    $healthUrl = $uri.GetLeftPart([UriPartial]::Authority) + '/health'
}
$releaseDir = Split-Path -Parent $start
function Test-ReleaseReady {
    try {
        $req = [Net.HttpWebRequest]::Create($healthUrl); $req.Proxy = $null; $req.Timeout = 3000
        $resp = $req.GetResponse()
        try { $h = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } finally { $resp.Close() }
        if ([string]$h.status -ne 'ok' -or [int]$h.native_schedule -ne 1) { return $false }
        $records = [IO.File]::ReadAllText((Join-Path $releaseDir 'runtime\processes.json')) | ConvertFrom-Json
        foreach ($r in @($records)) {
            if (-not $r -or [string]$r.service -ne 'scheduler') { continue }
            $p = Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'python' -and $p.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$r.startTimeUtcTicks) { return $true }
        }
    } catch { return $false }
    return $false
}
function Save-Current($Object) {
    $tmp = $currentPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Replace($tmp, $currentPath, [NullString]::Value)
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
try { & $start } catch { Write-Warning "Bản mới chưa khởi động được: $($_.Exception.Message)" }
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    if (Test-ReleaseReady) {
        $current | Add-Member -NotePropertyName verified -NotePropertyValue $true -Force
        Save-Current $current
        return
    }
    Start-Sleep -Seconds 2
}
$previous = [string]$current.previous.release
$previousDir = Join-Path (Join-Path $integrations 'autotok-releases') $previous
$stop = Join-Path $releaseDir 'dung.ps1'
if (Test-Path -LiteralPath $stop -PathType Leaf) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop -Force | Out-Null }
$journalPath = Join-Path $integrations 'autotok-takeover-journal.json'
if ([IO.File]::Exists($journalPath)) {
    $journal = [IO.File]::ReadAllText($journalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$journal.release -eq $release) {
        # This release replaced a git/custom setup and never passed the readiness gate: put that setup back
        # (same fixed file list as kid-install.ps1) and start it.
        $files = [ordered]@{
            local = (Join-Path $integrations 'tiktok\local.json'); config = (Join-Path $integrations 'autotok-config.json')
            current = $currentPath; launcher = (Join-Path $integrations 'autotok-start.ps1'); tiktokStart = (Join-Path $integrations 'tiktok\start.ps1')
        }
        foreach ($k in $files.Keys) {
            $path = $files[$k]; $b64 = [string]$journal.files.$k
            if (-not $b64) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }; continue }
            $tmp = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($b64))
                if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
            } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
        }
        [IO.File]::Delete($journalPath)
        $starter = [string]$journal.starter
        if (-not $starter -or -not (Test-Path -LiteralPath $starter -PathType Leaf)) { throw "Bộ đăng TikTok mới không chạy được; đã trả lại cấu hình bộ đăng cũ nhưng không thấy file khởi động của nó ($starter)." }
        Write-Warning "Bộ đăng TikTok mới không chạy được; đã trả lại bộ đăng cũ ($starter)."
        # The old setup picks its own data folder: undo the managed-config override (env wins in run_autotok_web.py).
        if ($null -eq $incomingDataDir) { Remove-Item -LiteralPath Env:\AUTOTOK_DATA_DIR -ErrorAction SilentlyContinue } else { $env:AUTOTOK_DATA_DIR = $incomingDataDir }
        & $starter
        return
    }
}
if ($previous -notmatch '^[0-9a-f]{12}-[0-9]{8}-[0-9]{6}$' -or -not (Test-Path -LiteralPath (Join-Path $previousDir '.kid-release-ok') -PathType Leaf)) {
    throw 'Bản bộ đăng vừa cập nhật không chạy được và không có bản cũ. Mở Kid FB.Y > Cài đặt > Công cụ và bấm cài lại.'
}
$sha = ([IO.File]::ReadAllText((Join-Path $previousDir '.kid-release-ok'))).Trim()
$version = ''
try { $version = [string]([IO.File]::ReadAllText((Join-Path $previousDir '.kid\bundle.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version } catch { $version = '' }
Save-Current ([ordered]@{ release = $previous; sha = $sha; version = $version; installedAt = (Get-Date).ToString('o'); verified = $true; previous = [ordered]@{ release = ''; kind = 'none' } })
Write-Warning "Bản bộ đăng mới không chạy được; đã quay lại bản $previous."
& (Join-Path $previousDir 'start.ps1')
