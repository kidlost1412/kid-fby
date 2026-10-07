#Requires -Version 5.1
<#
  Kid FB.Y - tai video Facebook kem long tieng Meta AI

    .\kid-fby.ps1                      dan link vao
    .\kid-fby.ps1 "<link>"             tai 1 video
    .\kid-fby.ps1 "<a>" "<b>"          tai nhieu video
    .\kid-fby.ps1 -Check               kiem tra may va thiet bi
    .\kid-fby.ps1 -Setup               cai cac cong cu can thiet

  Tuy chon: -OutDir <thu muc>   -Keep (giu file tam)   -Serial <ADB serial>
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Link,
    [string]$OutDir,
    [string]$Serial,
    [switch]$Check,
    [switch]$Setup,
    [string]$SetupTool,
    [switch]$Keep,
    [switch]$SkipLanguageCheck,
    [string]$DetectLanguageFile,
    [System.Collections.IDictionary]$ProcessRegistry
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:Fb = 'com.facebook.katana'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
$script:Here = if ((Split-Path $scriptDir -Leaf) -in @('core','src','app')) { Split-Path $scriptDir -Parent } else { $scriptDir }
$languageHelper = Join-Path $scriptDir 'whisper-language.ps1'
if (Test-Path -LiteralPath $languageHelper) { . $languageHelper }
if (-not (Test-Path (Join-Path $script:Here 'tools'))) {
    if (Test-Path (Join-Path (Get-Location).Path 'tools')) {
        $script:Here = (Get-Location).Path
    } elseif (Test-Path (Join-Path (Split-Path $scriptDir -Parent) 'tools')) {
        $script:Here = Split-Path $scriptDir -Parent
    }
}

# ------------------------------------------------------------------ in ra ----
function Write-Step($n, $t) { Write-Host ''; Write-Host "[$n] $t" -ForegroundColor Cyan }
function Write-Ok($t)       { Write-Host "    v  $t" -ForegroundColor Green }
function Write-Note($t)     { Write-Host "    -  $t" -ForegroundColor DarkGray }
function Write-Warn2($t)    { Write-Host "    !  $t" -ForegroundColor Yellow }
function Write-Bad($t)      { Write-Host "    x  $t" -ForegroundColor Red }

function Show-Fail {
    param([string]$Message, [string[]]$Fix)
    Write-Host ''
    Write-Host '  KHONG XONG  ' -ForegroundColor White -BackgroundColor DarkRed
    Write-Host ''
    Write-Host "  $Message" -ForegroundColor Red
    if ($Fix) {
        Write-Host ''
        Write-Host '  Cach sua:' -ForegroundColor Yellow
        foreach ($f in $Fix) { Write-Host "    - $f" -ForegroundColor Yellow }
    }
    Write-Host ''
}

# ---------------------------------------------------------------- tien ich ----
function Quote-Arg {
    param([string]$A)
    if ($null -eq $A -or $A -eq '') { return '""' }
    if ($A -match '[\s"]') { return '"' + ($A -replace '"', '\"') + '"' }
    return $A
}

function Invoke-Exe {
    param([string]$Exe, [string[]]$ExeArgs, [int]$TimeoutMs = 15000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = (($ExeArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $started = $false
    $registered = $null
    $tO = $null; $tE = $null
    $timedOut = $false
    $streamError = ''
    try {
        [void]$p.Start()
        $started = $true
        $registered = $script:ProcessRegistry
        if ($registered) { $registered[$p.Id] = $p }
        $tO = $p.StandardOutput.ReadToEndAsync()
        $tE = $p.StandardError.ReadToEndAsync()
        $exited = $p.WaitForExit($TimeoutMs)
        if (-not $exited) {
            $timedOut = $true
            try { $p.Kill() } catch { }
            try { $null = $p.WaitForExit(5000) } catch { }
        }
        # Process exit closes the redirected streams. Bound stream completion in case
        # a child inherited a pipe, then close our readers before disposing the process.
        try { $null = $tO.Wait(10000) } catch { }
        try { $null = $tE.Wait(10000) } catch { }
        if (-not $tO.IsCompleted) { try { $p.StandardOutput.Close() } catch { }; try { $null = $tO.Wait(1000) } catch { } }
        if (-not $tE.IsCompleted) { try { $p.StandardError.Close() } catch { }; try { $null = $tE.Wait(1000) } catch { } }
        $o = if ($tO.IsCompleted -and -not $tO.IsFaulted) { $tO.Result } else { '' }
        $e = if ($tE.IsCompleted -and -not $tE.IsFaulted) { $tE.Result } else { '' }
        if ($null -eq $o) { $o = '' }
        if ($null -eq $e) { $e = '' }
        if (-not $tO.IsCompleted -or -not $tE.IsCompleted) { $streamError = ' Output capture did not finish within the bounded wait.' }
        $c = if ($timedOut) { -1 } elseif ($p.HasExited) { $p.ExitCode } else { -1 }
        if ($timedOut) { $e = ('Timed out after {0} ms; process termination was requested.{1}{2}' -f $TimeoutMs, $(if ($e) { ' ' + $e } else { '' }), $streamError) }
        elseif ($streamError) { $e = ($e + $streamError).Trim() }
        return [pscustomobject]@{ Code = $c; Out = $o; Err = $e }
    } finally {
        if ($started -and -not $p.HasExited) {
            try { $p.Kill() } catch { }
            try { $null = $p.WaitForExit(5000) } catch { }
        }
        if ($registered -and $started) {
            try { $registered.Remove($p.Id) } catch { }
        }
        if ($tO -and -not $tO.IsCompleted) { try { $p.StandardOutput.Close() } catch { }; try { $null = $tO.Wait(1000) } catch { } }
        if ($tE -and -not $tE.IsCompleted) { try { $p.StandardError.Close() } catch { }; try { $null = $tE.Wait(1000) } catch { } }
        $p.Dispose()
    }
}

function Find-Tool {
    param([string]$Name)
    $toolBases = @($script:Here, (Get-Location).Path, (Join-Path $env:LOCALAPPDATA 'Kid-FB.Y'))
    foreach ($tb in $toolBases) {
        if (-not $tb) { continue }
        $candidates = @(
            (Join-Path $tb "tools\$Name.exe"),
            (Join-Path $tb "tools\$Name\$Name.exe"),
            (Join-Path $tb "tools\scrcpy\$Name.exe"),
            (Join-Path $tb "tools\scrcpy\scrcpy-win64-v5.0\$Name.exe"),
            (Join-Path $tb "tools\scrcpy\scrcpy-win64-v4.1\$Name.exe"),
            (Join-Path $tb "tools\scrcpy\scrcpy-win64-v3.1\$Name.exe"),
            (Join-Path $tb "tools\scrcpy\scrcpy-win64-v2.7\$Name.exe"),
            (Join-Path $tb "tools\ffmpeg\$Name.exe"),
            (Join-Path $tb "tools\ffmpeg\bin\$Name.exe")
        )
        foreach ($c in $candidates) {
            try {
                if (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue) { return (Get-Item -LiteralPath $c).FullName }
            } catch { }
        }
    }

    # Kiem tra trong LDPlayer (dac biet cho adb)
    if ($Name -eq 'adb') {
        $ldCandidates = @(
            'D:\LDPlayer\LDPlayer14\adb.exe',
            'D:\LDPlayer\LDPlayer9\adb.exe',
            'C:\LDPlayer\LDPlayer14\adb.exe',
            'C:\LDPlayer\LDPlayer9\adb.exe'
        )
        foreach ($ld in $ldCandidates) {
            try {
                if (Test-Path -LiteralPath $ld -ErrorAction SilentlyContinue) { return (Get-Item -LiteralPath $ld).FullName }
            } catch { }
        }
    }

    # Kiem tra trong PATH he thong
    try {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -ErrorAction SilentlyContinue)) {
            return $cmd.Source
        }
    } catch { }

    # Kiem tra trong WinGet Packages (chua file that) va WinGet Links
    $roots = @(
        (Join-Path $script:Here 'tools'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
    )
    foreach ($r in $roots) {
        try {
            if ($r -and (Test-Path -LiteralPath $r -ErrorAction SilentlyContinue)) {
                $hit = Get-ChildItem -Path $r -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 10000 } | Select-Object -First 1
                if ($hit) { return $hit.FullName }
            }
        } catch { }
    }
    return $null
}

function Invoke-Adb {
    param($T, [string[]]$AdbArgs)
    if ($T.Serial) { $AdbArgs = @('-s', $T.Serial) + $AdbArgs }
    Invoke-Exe $T.adb $AdbArgs
}

function Get-Toolset {
    $t = [ordered]@{}
    $t.adb     = Find-Tool 'adb'
    $t.scrcpy  = Find-Tool 'scrcpy'
    $t.ytdlp   = Find-Tool 'yt-dlp'
    $t.ffmpeg  = Find-Tool 'ffmpeg'
    $t.ffprobe = Find-Tool 'ffprobe'
    $t
}

# ------------------------------------------------------------------ cai dat ----
function Invoke-Setup {
    param([string]$Tool = 'all')
    Write-Host ''
    Write-Host '  CAI DAT THU VIEN & CONG CU (PORTABLE)  ' -ForegroundColor White -BackgroundColor DarkBlue
    Invoke-SetupDirect -Tool $Tool
}

function Get-GitHubAsset {
    param([string]$Repo, [string]$Pattern)
    $rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'Kid-FB.Y' }
    $a = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $a) { throw "Khong thay ban tai phu hop trong $Repo" }
    $a.browser_download_url
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    
    $destParent = Split-Path -Parent $OutFile
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        try { New-Item -ItemType Directory -Path $destParent -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    $partDir = if ($destParent -and (Test-Path -LiteralPath $destParent)) {
        $destParent
    } else {
        $fallback = Join-Path $script:Here 'tools\_download'
        if (-not (Test-Path -LiteralPath $fallback)) {
            try { New-Item -ItemType Directory -Path $fallback -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
        $fallback
    }
    $partName = "part_" + ([System.IO.Path]::GetRandomFileName()) + ".tmp"
    $partFile = Join-Path $partDir $partName

    $dlSuccess = $false

    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls -bor 12288

    # 1. Thu bang .NET HttpWebRequest Stream (Sieu toc, tu dong redirect, khong phu thuoc curl)
    try {
        Write-Note "Dang tai truc tiep (.NET Engine)..."
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.AllowAutoRedirect = $true
        $req.MaximumAutomaticRedirections = 10
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $req.Timeout = 45000
        $req.ReadWriteTimeout = 90000
        $resp = $req.GetResponse()
        $sIn = $resp.GetResponseStream()
        $sOut = [System.IO.File]::Create($partFile)
        try {
            $buffer = New-Object byte[] 65536
            while (($bytesRead = $sIn.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $sOut.Write($buffer, 0, $bytesRead)
            }
        } finally {
            $sOut.Dispose()
            $sIn.Dispose()
            $resp.Dispose()
        }
        if ((Test-Path -LiteralPath $partFile) -and ((Get-Item -LiteralPath $partFile).Length -gt 10000)) {
            $dlSuccess = $true
        }
    } catch {
        Write-Note "Loi .NET Engine: $($_.Exception.Message)"
        try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
    }

    # 2. Thu bang curl.exe vao file .tmp (Doc stream bat dong bo tranh loi ma 23)
    if (-not $dlSuccess) {
        $curlExe = (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)
        $curlPath = if ($curlExe) { $curlExe.Source } elseif (Test-Path 'C:\Windows\System32\curl.exe') { 'C:\Windows\System32\curl.exe' } else { $null }
        if ($curlPath -and (Test-Path -LiteralPath $curlPath)) {
            try {
                Write-Note "Dang tai bang curl..."
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $curlPath
                $psi.Arguments = "-s -S -L -k --retry 2 --connect-timeout 20 -A `"Mozilla/5.0`" -o `"$partFile`" `"$Url`""
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardError = $true
                $psi.RedirectStandardOutput = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $tO = $p.StandardOutput.ReadToEndAsync()
                $tE = $p.StandardError.ReadToEndAsync()
                $finished = $p.WaitForExit(120000)
                if ($finished -and $p.ExitCode -eq 0 -and (Test-Path -LiteralPath $partFile) -and ((Get-Item -LiteralPath $partFile).Length -gt 10000)) {
                    $dlSuccess = $true
                } else {
                    $errText = if ($tE.IsCompleted) { $tE.Result } else { '' }
                    Write-Note "curl tra ve ma $($p.ExitCode)$(if ($errText) { ": $errText" })"
                    try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
                }
                $p.Dispose()
            } catch {
                Write-Note "Loi curl: $($_.Exception.Message)"
            }
        }
    }

    # 3. Thu bang WebClient
    if (-not $dlSuccess) {
        try {
            Write-Note "Dang tai bang WebClient..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            try {
                $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
            } catch { }
            try {
                $wc.DownloadFile($Url, $partFile)
            } finally {
                $wc.Dispose()
            }
            if ((Test-Path -LiteralPath $partFile) -and ((Get-Item -LiteralPath $partFile).Length -gt 10000)) {
                $dlSuccess = $true
            }
        } catch {
            $errMsg = $_.Exception.Message
            if ($_.Exception.InnerException) { $errMsg += " (" + $_.Exception.InnerException.Message + ")" }
            Write-Note "Loi WebClient: $errMsg"
            try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
        }
    }

    # 4. Thu bang Invoke-WebRequest
    if (-not $dlSuccess) {
        try {
            Write-Note "Dang tai bang Invoke-WebRequest..."
            Invoke-WebRequest -Uri $Url -OutFile $partFile -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -TimeoutSec 90 -ErrorAction Stop
            if ((Test-Path -LiteralPath $partFile) -and ((Get-Item -LiteralPath $partFile).Length -gt 10000)) {
                $dlSuccess = $true
            }
        } catch {
            Write-Note "Loi Invoke-WebRequest: $($_.Exception.Message)"
            try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
        }
    }

    # 5. Thu bang BITS
    if (-not $dlSuccess) {
        try {
            Write-Note "Dang tai bang BITS..."
            Import-Module BitsTransfer -ErrorAction SilentlyContinue
            Start-BitsTransfer -Source $Url -Destination $partFile -ErrorAction Stop
            if ((Test-Path -LiteralPath $partFile) -and ((Get-Item -LiteralPath $partFile).Length -gt 10000)) {
                $dlSuccess = $true
            }
        } catch {
            Write-Note "Loi BITS: $($_.Exception.Message)"
            try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
        }
    }

    # Chuyen file .tmp thanh file dich sau khi stream da duoc dong an toan
    if ($dlSuccess -and (Test-Path -LiteralPath $partFile)) {
        try {
            if (Test-Path -LiteralPath $OutFile) {
                try { [System.IO.File]::Delete($OutFile) } catch { }
            }
            Move-Item -LiteralPath $partFile -Destination $OutFile -Force
            return (Test-Path -LiteralPath $OutFile)
        } catch {
            try {
                Copy-Item -LiteralPath $partFile -Destination $OutFile -Force
                [System.IO.File]::Delete($partFile)
                return (Test-Path -LiteralPath $OutFile)
            } catch {
                Write-Bad "Loi luu file vao tools: $($_.Exception.Message)"
            }
        }
    }

    try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
    return $false
}

function Invoke-SetupDirect {
    param([string]$Tool = 'all')
    Write-Note 'Dang tai cong cu truc tiep vao thu muc tools (chay doc lap, khong can cai vao he thong)...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    $ProgressPreference = 'SilentlyContinue'
    
    $dir = [System.IO.Path]::GetFullPath((Join-Path $script:Here 'tools'))
    foreach ($sub in @('', '_download', 'scrcpy', 'ffmpeg')) {
        $p = if ($sub) { Join-Path $dir $sub } else { $dir }
        if (-not (Test-Path -LiteralPath $p)) {
            try { New-Item -ItemType Directory -Path $p -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
    $tmpd = Join-Path $dir '_download'

    $viec = @(
        @{ Id = 'scrcpy'; Ten = 'scrcpy & adb (Ket noi Android & thu am thanh)'; Exe = 'scrcpy'; Zip = $true
           SubExe = 'adb';
           Urls = @(
               'https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-win64-v3.1.zip',
               'https://ghproxy.net/https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-win64-v3.1.zip',
               'https://gh-proxy.com/https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-win64-v3.1.zip',
               'https://github.com/Genymobile/scrcpy/releases/download/v2.7/scrcpy-win64-v2.7.zip'
           ) }
        @{ Id = 'ytdlp';  Ten = 'yt-dlp (Tai video Facebook 4K/2K/1080p)'; Exe = 'yt-dlp'; Zip = $false
           Urls = @(
               'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
               'https://ghproxy.net/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
               'https://gh-proxy.com/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
           ) }
        @{ Id = 'ffmpeg'; Ten = 'FFmpeg & ffprobe (Giai ma, chuyen ma H.264 & ghep video)'; Exe = 'ffmpeg'; Zip = $true
           SubExe = 'ffprobe';
           Urls = @(
               'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
               'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
               'https://ghproxy.net/https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
               'https://gh-proxy.com/https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
           ) }
    )

    if ($Tool -and $Tool -ne '' -and $Tool -ne 'all') {
        $viec = @($viec | Where-Object { $_.Id -match $Tool -or $_.Exe -match $Tool -or ($_.SubExe -and $_.SubExe -match $Tool) })
    }

    try {
        foreach ($v in $viec) {
            Write-Step '..' "Kiem tra & Cai $($v.Ten)"
            $localExe = (Find-Tool $v.Exe)
            $localSub = if ($v.SubExe) { Find-Tool $v.SubExe } else { $true }
            $inTools = (Test-Path -LiteralPath (Join-Path $dir "$($v.Exe).exe")) -or (Test-Path -LiteralPath (Join-Path $dir "$($v.Exe)\$($v.Exe).exe"))
            if ($inTools -and ($Tool -eq 'all' -or -not $Tool)) {
                Write-Ok "$($v.Exe) da san sang trong thu muc tools"
                continue
            }
            if ($localExe -and -not $inTools) {
                Write-Note "Phat hien $($v.Exe) tren may tai: $localExe. Dang sao chep vao tools..."
                try {
                    $srcFile = $localExe
                    try {
                        $fItem = Get-Item -LiteralPath $srcFile -Force -ErrorAction SilentlyContinue
                        if ($fItem.Target) { $srcFile = $fItem.Target }
                    } catch { }

                    if ($v.Zip) {
                        $destDir = Join-Path $dir $v.Exe
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            try { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
                        }
                        Copy-Item -LiteralPath $srcFile -Destination (Join-Path $destDir "$($v.Exe).exe") -Force -ErrorAction SilentlyContinue
                        if ($v.SubExe) {
                            $subLocal = Find-Tool $v.SubExe
                            if ($subLocal -and (Test-Path -LiteralPath $subLocal)) {
                                try {
                                    $subItem = Get-Item -LiteralPath $subLocal -Force -ErrorAction SilentlyContinue
                                    if ($subItem.Target) { $subLocal = $subItem.Target }
                                } catch { }
                                Copy-Item -LiteralPath $subLocal -Destination (Join-Path $destDir "$($v.SubExe).exe") -Force -ErrorAction SilentlyContinue
                                Copy-Item -LiteralPath $subLocal -Destination (Join-Path $dir "$($v.SubExe).exe") -Force -ErrorAction SilentlyContinue
                            }
                        }
                    } else {
                        Copy-Item -LiteralPath $srcFile -Destination (Join-Path $dir "$($v.Exe).exe") -Force -ErrorAction SilentlyContinue
                    }
                    $inToolsNow = (Test-Path -LiteralPath (Join-Path $dir "$($v.Exe).exe")) -or (Test-Path -LiteralPath (Join-Path $dir "$($v.Exe)\$($v.Exe).exe"))
                    if ($inToolsNow) {
                        Write-Ok "Da sao chep vao tools thanh cong: $($v.Exe)"
                        continue
                    }
                } catch {
                    Write-Note "Chua the sao chep $($localExe) vao tools, se tai truc tiep: $($_.Exception.Message)"
                }
            }

            # Neu la adb/scrcpy va tren may co LDPlayer, copy luon bo DLL va adb cua LDPlayer
            if ($v.Id -eq 'scrcpy' -or $v.SubExe -eq 'adb') {
                $ldAdb = Find-Tool 'adb'
                if ($ldAdb -and (Test-Path -LiteralPath $ldAdb)) {
                    Write-Note "Phat hien ADB tu gia lap: $ldAdb. Dang sao chep vao tools..."
                    try {
                        $destDir = Join-Path $dir 'scrcpy'
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            try { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
                        }
                        Copy-Item -LiteralPath $ldAdb -Destination (Join-Path $destDir 'adb.exe') -Force -ErrorAction SilentlyContinue
                        Copy-Item -LiteralPath $ldAdb -Destination (Join-Path $dir 'adb.exe') -Force -ErrorAction SilentlyContinue
                        $ldDir = Split-Path $ldAdb -Parent
                        foreach ($dll in @('AdbWinApi.dll','AdbWinUsbApi.dll')) {
                            $dllSrc = Join-Path $ldDir $dll
                            if (Test-Path -LiteralPath $dllSrc) {
                                Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $destDir $dll) -Force -ErrorAction SilentlyContinue
                                Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $dir $dll) -Force -ErrorAction SilentlyContinue
                            }
                        }
                        $hasAdbInTools = (Test-Path -LiteralPath (Join-Path $dir 'adb.exe')) -or (Test-Path -LiteralPath (Join-Path $destDir 'adb.exe'))
                        if ($Tool -eq 'adb' -and $hasAdbInTools) {
                            Write-Ok "Da sao chep ADB thanh cong tu gia lap vao thu muc tools"
                            continue
                        }
                    } catch { }
                }
            }

            # Uu tien WinGet: tien trinh winget tu tai/ghi file, khong bi loi quyen ghi/mang cua script
            if (-not (Find-Tool $v.Exe)) {
                $wg = $null
                foreach ($c in @('winget.exe', (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))) {
                    $gc = Get-Command $c -ErrorAction SilentlyContinue
                    if ($gc) { $wg = $gc.Source; break }
                    if (Test-Path -LiteralPath $c) { $wg = $c; break }
                }
                $pk = if ($v.Id -eq 'scrcpy') { 'Genymobile.scrcpy' } elseif ($v.Id -eq 'ytdlp') { 'yt-dlp.yt-dlp' } else { $null }
                if ($wg -and $pk) {
                    Write-Note "Dang cai qua WinGet: $pk ..."
                    try {
                        Start-Process -FilePath $wg -ArgumentList @('install','--id',$pk,'-e','--silent','--accept-source-agreements','--accept-package-agreements') -NoNewWindow -Wait | Out-Null
                    } catch { Write-Note "Loi WinGet: $($_.Exception.Message)" }
                    if (Find-Tool $v.Exe) { Write-Ok "Cai thanh cong qua WinGet: $($v.Exe)"; continue }
                    Write-Note "WinGet chua cai duoc, chuyen sang tai truc tiep..."
                } elseif (-not $wg) {
                    Write-Note "Khong tim thay winget tren may."
                }
            }

            $dlSuccess = $false
            $ext = if ($v.Zip) { '.zip' } else { '.exe' }
            $file = Join-Path $tmpd "$($v.Exe)$ext"

            $urls = if ($v.Urls) { $v.Urls } elseif ($v.Url) { @(& $v.Url) } else { @() }
            foreach ($url in $urls) {
                if (-not $url) { continue }
                Write-Note "Dang tai $($v.Ten)..."
                Write-Note "Nguon: $url"
                if (Invoke-Download -Url $url -OutFile $file) {
                    $dlSuccess = $true
                    $sizeMb = [math]::Round(((Get-Item -LiteralPath $file).Length / 1MB), 2)
                    Write-Ok "Tai ve hoan tat ($sizeMb MB)"
                    break
                }
            }

            if (-not $dlSuccess -or -not (Test-Path -LiteralPath $file)) {
                # Thu them fallback bang winget he thong neu co
                $wingetCmd = (Get-Command 'winget' -ErrorAction SilentlyContinue)
                $wingetPath = if ($wingetCmd) { $wingetCmd.Source } else {
                    $wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
                    if (Test-Path -LiteralPath $wa) { $wa } else { $null }
                }
                if ($wingetPath) {
                    $pkgId = if ($v.Id -eq 'scrcpy') { 'Genymobile.scrcpy' } elseif ($v.Id -eq 'ytdlp') { 'yt-dlp.yt-dlp' } elseif ($v.Id -eq 'ffmpeg') { 'Gyan.FFmpeg' } else { $null }
                    if ($pkgId) {
                        Write-Note "Dang thu cai qua Windows WinGet: $pkgId..."
                        try {
                            $wp = Start-Process -FilePath $wingetPath -ArgumentList @('install', '--id', $pkgId, '--silent', '--accept-source-agreements', '--accept-package-agreements') -NoNewWindow -Wait -PassThru
                            if (Find-Tool $v.Exe) {
                                Write-Ok "Cai dat thanh cong qua WinGet: $($v.Exe)"
                                continue
                            }
                        } catch { }
                    }
                }
                Write-Bad "Khong the tai $($v.Ten). Vui long kiem tra ket noi mang hoac quyen ghi."
                continue
            }

            try {
                if ($v.Zip) {
                    Write-Note "Dang giai nen vao tools\$($v.Exe)..."
                    $destDir = Join-Path $dir $v.Exe
                    if (-not (Test-Path -LiteralPath $destDir)) {
                        try { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
                    }
                    Expand-Archive -Path $file -DestinationPath $destDir -Force
                    Get-ChildItem -Path $destDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $_.Name) -Force -ErrorAction SilentlyContinue
                    }
                    if ($v.SubExe) {
                        $subFile = Join-Path $destDir "$($v.SubExe).exe"
                        if (Test-Path -LiteralPath $subFile) {
                            Copy-Item -LiteralPath $subFile -Destination (Join-Path $dir "$($v.SubExe).exe") -Force -ErrorAction SilentlyContinue
                        }
                    }
                } else {
                    Copy-Item -LiteralPath $file -Destination (Join-Path $dir "$($v.Exe).exe") -Force -ErrorAction SilentlyContinue
                }
                if (Find-Tool $v.Exe) { Write-Ok "Cai dat thanh cong: $($v.Exe)" }
                else { Write-Warn2 "Tai xong nhung chua thay file chay $($v.Exe)" }
            } catch {
                Write-Bad "Loi giai nen $($v.Ten): $($_.Exception.Message)"
                Write-Bad "Chi tiet: $($_.Exception.ToString())"
            }
        }
    } finally {
        try {
            if (Test-Path -LiteralPath $tmpd) {
                Get-ChildItem -LiteralPath $tmpd -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                    try { [System.IO.File]::Delete($_.FullName) } catch { }
                }
            }
        } catch { }
    }
    Write-Host ''
    Write-Note 'Kiem tra lai toan bo bang lenh: .\kid-fby.ps1 -Check'
}

# ------------------------------------------------------------ kiem tra may ----
function Test-Ready {
    param([switch]$Quiet)
    $tools = Get-Toolset
    if (-not $Quiet) { Write-Step 1 'Kiem tra cong cu' }
    $thieu = @()
    foreach ($k in $tools.Keys) {
        if ($tools[$k]) { if (-not $Quiet) { Write-Ok $k } }
        else { $thieu += $k; if (-not $Quiet) { Write-Bad "$k  (chua co)" } }
    }
    if ($thieu.Count -gt 0) {
        Show-Fail -Message "Thieu cong cu: $($thieu -join ', ')" -Fix @('Chay:  .\kid-fby.ps1 -Setup','Cai xong mo lai cua so lenh.')
        return $null
    }

    if (-not $Quiet) { Write-Step 2 'Kiem tra thiet bi Android / LDPlayer' }
    try {
        $pAdb = Start-Process $tools.adb -ArgumentList "start-server" -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($pAdb) { $pAdb.WaitForExit(4000) }
    } catch { }
    $dev = Invoke-Exe $tools.adb @('devices') -TimeoutMs 5000
    $lines = @($dev.Out -split "`n" | Where-Object { $_ -match '\sdevice\s*$' })
    if ($lines.Count -eq 0) {
        # Thu tu dong quet va ket noi cac cong gia lap thong dung (LDPlayer, Nox, MEmu, BlueStacks)
        if (-not $Quiet) { Write-Note 'Dang kiem tra cac cong gia lap (127.0.0.1:5555, 5557, 62001)...' }
        $emuPorts = @(5555, 5557, 5559, 62001, 21503, 16384)
        foreach ($port in $emuPorts) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $tcp.BeginConnect('127.0.0.1', $port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(150, $false)) {
                    try {
                        $tcp.EndConnect($ar)
                        if ($tcp.Connected) {
                            $null = Invoke-Exe $tools.adb @('connect', "127.0.0.1:$port") -TimeoutMs 2000
                        }
                    } catch { }
                }
            } catch { }
            finally {
                try { $tcp.Close() } catch { }
            }
        }
        Start-Sleep -Milliseconds 200
        $dev = Invoke-Exe $tools.adb @('devices') -TimeoutMs 5000
        $lines = @($dev.Out -split "`n" | Where-Object { $_ -match '\sdevice\s*$' })
    }
    if ($lines.Count -eq 0) {
        $un = @($dev.Out -split "`n" | Where-Object { $_ -match '\sunauthorized' })
        if ($un.Count -gt 0) {
            Show-Fail -Message 'Thiet bi chua cap quyen ket noi (unauthorized).' -Fix @(
                'Nhin len man hinh gia lap LDPlayer / Dien thoai.',
                'Tich vao o: "Luon cho phep tu may tinh nay" (Always allow from this computer).',
                'Bam nut: Cho phep (Allow / OK).'
            )
        } else {
            Show-Fail -Message 'Chua ket noi duoc voi Android / LDPlayer.' -Fix @(
                'Luu y quan trong: Bat ROOT la chua du! Root chi cap quyen cho app ben trong Android.',
                'Ban PHAI bat "Go loi ADB" (ADB Debugging) trong LDPlayer thi Tool moi ket noi duoc:',
                '  [1] Vao Cai dat LDPlayer (icon banh rang o goc tren ben phai cua LDPlayer)',
                '  [2] Chon tab "Cai dat khac" (Other Settings)',
                '  [3] O dong "Go loi ADB" (ADB Debug) -> Chon "Mo ket noi noi bo" (Open local connection)',
                '  [4] Bam "Luu cai dat" va KHOI DONG LAI LDPlayer',
                '  [5] Mo lai LDPlayer, doi vao han man hinh chinh Android roi bam "Kiem tra may" lai tren Tool.'
            )
        }
        return $null
    }
    if ($Serial) {
        $lines = @($lines | Where-Object { ($_ -split '\s+')[0] -eq $Serial })
        if ($lines.Count -eq 0) {
            Show-Fail -Message "Thiet bi $Serial khong san sang." -Fix @('Kiem tra danh sach bang adb devices.')
            return $null
        }
    }
    # Tu dong khu trung lap (khi emulator-5554 va 127.0.0.1:5555 la cung 1 LDPlayer)
    if ($lines.Count -gt 1) {
        $devMap = @{}
        foreach ($ln in $lines) {
            $s = ($ln -split '\s+')[0]
            $sNo = (Invoke-Exe $tools.adb @('-s', $s, 'shell', 'getprop', 'ro.serialno')).Out.Trim()
            if (-not $sNo) { $sNo = $s }
            if (-not $devMap.ContainsKey($sNo)) {
                $devMap[$sNo] = $s
            } else {
                if ($s -match '^\d+\.\d+\.\d+\.\d+:\d+') {
                    $null = Invoke-Exe $tools.adb @('disconnect', $s)
                }
            }
        }
        $serials = @($devMap.Values)
        if ($serials.Count -eq 1) {
            $lines = @($lines | Where-Object { ($_ -split '\s+')[0] -eq $serials[0] })
        }
    }
    if ($lines.Count -gt 1) {
        Show-Fail -Message "Co $($lines.Count) thiet bi Android dang ket noi." -Fix @('Chi de lai 1 thiet bi hoac truyen tham so -Serial <serial>.')
        return $null
    }
    $tools.Serial = ($lines[0] -split '\s+')[0]
    $model = (Invoke-Adb $tools @('shell','getprop','ro.product.model')).Out.Trim()
    $ver   = (Invoke-Adb $tools @('shell','getprop','ro.build.version.release')).Out.Trim()
    if (-not $Quiet) { Write-Ok "$model  (Android $ver)  [$($tools.Serial)]" }
    $major = 0; $null = [int]::TryParse(($ver -split '\.')[0], [ref]$major)
    if ($major -gt 0 -and $major -lt 11) {
        Show-Fail -Message "Android $ver qua cu." -Fix @('Hut am thanh truc tiep qua ADB can Android 11 tro len.')
        return $null
    }
    $pw = (Invoke-Adb $tools @('shell','dumpsys','power')).Out
    if ($pw -notmatch 'mWakefulness=Awake') {
        if (-not $Quiet) { Write-Warn2 'man hinh tat, dang bat' }
        $null = Invoke-Adb $tools @('shell','input','keyevent','KEYCODE_WAKEUP')
        Start-Sleep -Seconds 1
    }
    $wd = (Invoke-Adb $tools @('shell','dumpsys','window')).Out
    if ($wd -match 'mDreamingLockscreen=true') {
        Show-Fail -Message 'Man hinh dang khoa.' -Fix @('Mo khoa man hinh roi chay lai.')
        return $null
    }
    if (-not $Quiet) { Write-Ok 'man hinh sang, da mo khoa' }
    $pkgs = (Invoke-Adb $tools @('shell','pm','list','packages')).Out
    if ($pkgs -notmatch [regex]::Escape($script:Fb)) {
        Show-Fail -Message 'Khong tim thay app Facebook.' -Fix @('Cai dat app Facebook chinh thuc tren thiet bi.')
        return $null
    }
    if (-not $Quiet) { Write-Ok 'app Facebook co san' }
    return $tools
}

# ------------------------------------------------------------- am thanh ----
function Get-Duration {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffprobe @('-v','error','-show_entries','format=duration','-of','csv=p=0',$File)
    $v = ($r.Out -split "`n")[0].Trim(); $d = 0.0
    if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}

function Get-VideoDuration {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=duration','-of','csv=p=0',$File)
    $v = ($r.Out -split "`n")[0].Trim(); $d = 0.0
    if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d) -and $d -gt 0.5) { return $d }
    Get-Duration $T $File
}

function Get-VideoSize {
    param($T, [string]$File)
    $w = (Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=width','-of','csv=p=0:nk=1',$File)).Out
    $h = (Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=height','-of','csv=p=0:nk=1',$File)).Out
    [pscustomobject]@{ W = ($w -split "`n")[0].Trim(); H = ($h -split "`n")[0].Trim() }
}

function Get-MeanVolume {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffmpeg @('-hide_banner','-i',$File,'-af','volumedetect','-f','null','-') -TimeoutMs 300000
    if ($r.Err -match 'mean_volume:\s*(-?[\d.]+)') { return [double]$Matches[1] }
    return $null
}

# Tim diem bat dau tieng noi (onset t0) bang bo do khoang lang so
function Get-AudioOnset {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffmpeg @('-hide_banner','-i',$File,'-af','silencedetect=noise=-60dB:d=0.25','-f','null','-') -TimeoutMs 300000
    $m = [regex]::Match($r.Err, 'silence_start:\s*0(\.0+)?[\s\S]*?silence_end:\s*([\d.]+)')
    if ($m.Success) {
        $t0 = 0.0
        if ([double]::TryParse($m.Groups[2].Value, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$t0)) {
            return $t0
        }
    }
    $m2 = [regex]::Match($r.Err, 'silence_end:\s*([\d.]+)')
    if ($m2.Success) {
        $t0 = 0.0
        if ([double]::TryParse($m2.Groups[1].Value, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$t0)) {
            return $t0
        }
    }
    return 0.0
}

# ------------------------------------------------------------ thao tac app ----
function Open-Reel {
    param($T, [string]$Url)
    $r = Invoke-Adb $T @('shell','am','start','-a','android.intent.action.VIEW','-d', (Quote-Arg $Url),'-n',"$($script:Fb)/.IntentUriHandler")
    if ("$($r.Out)$($r.Err)" -match 'Error|does not exist') {
        $r = Invoke-Adb $T @('shell','am','start','-a','android.intent.action.VIEW','-d', (Quote-Arg $Url),$script:Fb)
    }
    return $r
}

# Tim phan tu giao dien dong dua tren content-desc hoac text
function Get-UiNodeBounds {
    param($T, [string[]]$Patterns)
    $xmlLocal = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-ui-" + [Guid]::NewGuid().ToString('N').Substring(0,6) + ".xml")
    $null = Invoke-Adb $T @('shell','uiautomator','dump','/sdcard/ui_find.xml')
    $null = Invoke-Adb $T @('pull','/sdcard/ui_find.xml',$xmlLocal)
    if (-not (Test-Path $xmlLocal)) { return $null }
    
    $found = $null
    try {
        [xml]$xml = Get-Content $xmlLocal -Encoding UTF8 -ErrorAction SilentlyContinue
        $nodes = $xml.SelectNodes("//node")
        foreach ($n in $nodes) {
            $desc = "$($n.GetAttribute('content-desc'))"
            $text = "$($n.GetAttribute('text'))"
            $combined = "$desc $text"
            foreach ($pat in $Patterns) {
                if ($combined -match $pat) {
                    $b = $n.GetAttribute('bounds')
                    if ($b -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
                        $x = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
                        $y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
                        $found = [pscustomobject]@{ X = $x; Y = $y; Text = $text; Desc = $desc; Bounds = $b }
                        break
                    }
                }
            }
            if ($found) { break }
        }
    } catch { }
    finally {
        Remove-Item $xmlLocal -Force -ErrorAction SilentlyContinue
    }
    return $found
}

function Ensure-VietnameseDubbing {
    param($T, [string]$Url)
    $dubbingUiStatus = 'unverified'
    Write-Step 4 'Kiem tra che do long tieng Viet (Meta AI)'
    
    # Tang am luong media thiet bi len muc toi da
    $null = Invoke-Adb $T @('shell','media','volume','--stream','3','--set','15')
    
    # Force-stop Facebook truoc de xoa sach moi hop thoai/binh luan cu
    $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
    Start-Sleep -Milliseconds 600

    # Mo reel de kiem tra giao dien
    $null = Open-Reel $T $Url
    Start-Sleep -Seconds 3

    # Tim nut 3 cham ("Khac", "more", "option")
    $moreNode = Get-UiNodeBounds -T $T -Patterns @('^Kh[a\u00e1]c$', 'Kh[a\u00e1]c', 'more', 'option')
    if ($moreNode) {
        Write-Ok "Tim thay nut tuy chon tai ($($moreNode.X), $($moreNode.Y))"
        $null = Invoke-Adb $T @('shell','input','tap', "$($moreNode.X)", "$($moreNode.Y)")
    } else {
        Write-Warn2 'Khong tim thay nut 3 cham bang ten, cham toa do chuan (672, 1110)'
        $null = Invoke-Adb $T @('shell','input','tap','672','1110')
    }
    Start-Sleep -Milliseconds 1500

    # Tim muc "Am thanh va ngon ngu" trong menu vua mo
    $audioMenuNode = Get-UiNodeBounds -T $T -Patterns @('[\u00c2\u00e2Aa]m thanh.*ng[o\u00f4\u00f2\u00f3]n ng[\u1eefu]', 'ng[o\u00f4]n ng[\u1eefu]', 'audio.*language')
    if ($audioMenuNode) {
        Write-Ok "Tim thay muc Am thanh va ngon ngu tai ($($audioMenuNode.X), $($audioMenuNode.Y))"
        $null = Invoke-Adb $T @('shell','input','tap', "$($audioMenuNode.X)", "$($audioMenuNode.Y)")
    } else {
        Write-Warn2 'Cham toa do chuan Am thanh va ngon ngu (360, 1214)'
        $null = Invoke-Adb $T @('shell','input','tap','360','1214')
    }
    Start-Sleep -Milliseconds 1500

    # Kiem tra danh sach ngon ngu: neu chua thay Tieng Viet thi vuot len
    $langNode = Get-UiNodeBounds -T $T -Patterns @('Ti[e\u00ea\u1ebf]ng Vi[e\u00ea\u1ec7]t', 'Vietnamese')
    if (-not $langNode) {
        Write-Note 'Cuon danh sach ngon ngu de tim Tieng Viet...'
        $null = Invoke-Adb $T @('shell','input','swipe','360','800','360','300','400')
        Start-Sleep -Milliseconds 1200
        $langNode = Get-UiNodeBounds -T $T -Patterns @('Ti[e\u00ea\u1ebf]ng Vi[e\u00ea\u1ec7]t', 'Vietnamese')
    }

    if ($langNode) {
        if ($langNode.Desc -match 'ng[o\u00f4]n ng[\u1eefu] \u01b0u ti[e\u00ea]n') {
            $dubbingUiStatus = 'selected'
            Write-Ok 'Tieng Viet da la ngon ngu duoc chon san (Uu tien)'
            Write-Note 'DUB_SELECTED: Giao dien bao Tieng Viet uu tien; can nghe nghiem thu.'
        } else {
            Write-Ok "Tim thay Tieng Viet tai ($($langNode.X), $($langNode.Y)), dang chon..."
            $tapResult = Invoke-Adb $T @('shell','input','tap', "$($langNode.X)", "$($langNode.Y)")
            Start-Sleep -Milliseconds 1200
            if ($tapResult.Code -eq 0) {
                $dubbingUiStatus = 'selected'
                Write-Note 'DUB_SELECTED: Da gui thao tac chon Tieng Viet; can nghe nghiem thu.'
            } else {
                Write-Warn2 'DUB_UNVERIFIED: Khong gui duoc thao tac chon Tieng Viet; can nghe nghiem thu.'
            }
        }
    } else {
        Write-Warn2 'DUB_UNVERIFIED: Chua xac nhan duoc Tieng Viet tu giao dien; can nghe nghiem thu.'
    }

    # Dung Facebook de san sang cho buoc thu am
    $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
    Start-Sleep -Milliseconds 500

    return $dubbingUiStatus
}

function Get-ReelProcessTimeoutMs {
    param([double]$Duration)
    $scaled = [Math]::Ceiling($Duration * 30000)
    return [int][Math]::Min(3600000, [Math]::Max(300000, $scaled))
}

function Test-ValidReelOutput {
    param($T, [string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $File).Length -le 0) { return $false }
    $streams = Invoke-Exe $T.ffprobe @('-v','error','-show_entries','stream=codec_type','-of','csv=p=0',$File)
    if ($streams.Code -ne 0) { return $false }
    $types = @($streams.Out -split "`r?`n" | ForEach-Object { $_.Trim() })
    if ($types -notcontains 'video' -or $types -notcontains 'audio') { return $false }
    $durationResult = Invoke-Exe $T.ffprobe @('-v','error','-show_entries','format=duration','-of','csv=p=0',$File)
    if ($durationResult.Code -ne 0) { return $false }
    $duration = 0.0
    $value = ($durationResult.Out -split "`r?`n")[0].Trim()
    return [double]::TryParse($value, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$duration) -and $duration -gt 0.5
}

function Publish-ReelFiles {
    param([System.Collections.IDictionary[]]$Pairs, [string]$Dest)
    if (-not (Test-Path -LiteralPath $Dest -PathType Container)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }
    $destFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Dest).Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $txnName = '.kidfby-publish-' + [Guid]::NewGuid().ToString('N')
    $txnPath = [IO.Path]::GetFullPath((Join-Path $destFull $txnName))
    $prefix = $destFull + [IO.Path]::DirectorySeparatorChar
    if (-not $txnPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Publish transaction path is outside the destination directory.' }
    New-Item -ItemType Directory -Path $txnPath -Force | Out-Null
    $staging = Join-Path $txnPath 'staging'
    $backups = Join-Path $txnPath 'backups'
    New-Item -ItemType Directory -Path $staging,$backups -Force | Out-Null
    $hadOld = @(); $attempted = @(); $rollbackErrors = @(); $safeCleanup = $true; $committed = $false; $publishError = ''
    try {
        for ($i = 0; $i -lt $Pairs.Count; $i++) {
            $source = [string]$Pairs[$i].Source
            $destination = [string]$Pairs[$i].Destination
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -le 0) { throw "Publish source is missing or empty: $source" }
            $stagedFile = Join-Path $staging ([IO.Path]::GetFileName($destination))
            Copy-Item -LiteralPath $source -Destination $stagedFile -Force -ErrorAction Stop
            $backupFile = Join-Path $backups ([IO.Path]::GetFileName($destination))
            $exists = Test-Path -LiteralPath $destination -PathType Leaf
            $hadOld += $exists
            if ($exists) { Copy-Item -LiteralPath $destination -Destination $backupFile -Force -ErrorAction Stop }
        }
        for ($i = 0; $i -lt $Pairs.Count; $i++) {
            $destination = [string]$Pairs[$i].Destination
            $stagedFile = Join-Path $staging ([IO.Path]::GetFileName($destination))
            $attempted += $i
            Move-Item -LiteralPath $stagedFile -Destination $destination -Force -ErrorAction Stop
        }
        $committed = $true
    } catch {
        $publishError = $_.Exception.Message
    } finally {
        if (-not $committed) {
            foreach ($i in @($attempted | Sort-Object -Descending)) {
                $destination = [string]$Pairs[$i].Destination
                try {
                    if ($hadOld[$i]) {
                        $backupFile = Join-Path $backups ([IO.Path]::GetFileName($destination))
                        [IO.File]::Copy($backupFile, $destination, $true)
                    } elseif ([IO.File]::Exists($destination)) {
                        [IO.File]::Delete($destination)
                    }
                } catch { $rollbackErrors += "$destination : $($_.Exception.Message)" }
            }
            if ($rollbackErrors.Count -gt 0) {
                $safeCleanup = $false
                throw "Publish failed: $publishError. Rollback failed: $($rollbackErrors -join '; '). Recoverable backups are in $txnPath"
            }
        }
        if ($safeCleanup -and (Test-Path -LiteralPath $txnPath)) {
            $resolvedTxn = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $txnPath).Path)
            if ($resolvedTxn.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedTxn -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if (-not $committed) { throw "Publish failed and previous destinations were restored: $publishError" }
}

# ---------------------------------------------------------- xu ly 1 link ----
function Invoke-OneLink {
    param($T, [string]$Url, [string]$Dest, [switch]$KeepFiles)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # ---------- 3. tai video goc va do thoi luong ----------
        Write-Step 3 'Tai video HD va doc thoi luong chuan'
        $idr = Invoke-Exe $T.ytdlp @('--no-warnings','--print','%(id)s',$Url) -TimeoutMs 120000
        $vid = ($idr.Out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        if ($vid) { $vid = $vid.Trim() }
        if ($idr.Code -ne 0 -or -not $vid) {
            Show-Fail -Message 'Khong doc duoc link.' -Fix @('Kiem tra lai link, video phai la cong khai.', $idr.Err)
            return $null
        }

        # Tai ban chat luong cao nhat tuyet doi (4K / 2K / 1080p, uu tien do phan giai va bitrate cao nhat)
        $dlr = Invoke-Exe $T.ytdlp @('-S','res,fps,br','-f','bestvideo/best','--no-warnings','-o',"$tmp\v.%(ext)s",$Url) -TimeoutMs 600000
        $vf = Get-ChildItem -LiteralPath $tmp -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'v.*' -and $_.Name -notmatch '\.(part|ytdl|tmp)$' -and $_.Extension.ToLowerInvariant() -notin @('.part','.ytdl','.tmp')
        } | Select-Object -First 1
        if ($dlr.Code -ne 0 -or -not $vf) {
            Show-Fail -Message 'Tai video that bai.' -Fix @('Kiem tra mang.','Video co the da bi xoa hoac rieng tu.', $dlr.Err)
            return $null
        }

        $dur = Get-VideoDuration $T $vf.FullName
        if ($dur -le 0.5) {
            Show-Fail -Message "Do dai video bat thuong ($dur giay)." -Fix @('Chay lai thu.')
            return $null
        }
        $sz = Get-VideoSize $T $vf.FullName
        $cv = (Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=codec_name','-of','csv=p=0',$vf.FullName)).Out.Trim()
        Write-Ok "$($sz.W)x$($sz.H)  $cv  |  $([Math]::Round($dur, 2)) giay  |  $([Math]::Round($vf.Length/1MB, 1)) MB"

        # ---------- 4. dam bao Facebook da bat tieng Viet ----------
        $dubbingUiStatus = Ensure-VietnameseDubbing -T $T -Url $Url

        # ---------- 5. thu am sach tu Giay 0 ----------
        # Tinh thoi luong thu am: buffer 10 giay dam bao video phat tron ven 100% truoc khi tat
        $recLen = [int][Math]::Ceiling($dur + 10)
        Write-Step 5 "Thu am thanh tu Giay 0 (thoi luong video $([Math]::Round($dur, 2))s, ghi buffer ${recLen}s)"
        Write-Host '       DUNG THAO TAC TREN MAN HINH KHI DANG THU' -ForegroundColor Yellow

        # Dung Facebook de dua ve trang thai moi
        $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
        Start-Sleep -Milliseconds 600

        $rec = Join-Path $tmp 'rec.m4a'

        # Khoi dong scrcpy thu am truoc trong background (an hoan toan cua so va icon)
        $captureArgs = @(
            '--serial', $T.Serial,
            '--no-video',
            '--no-audio-playback',
            '--audio-codec=aac',
            '--require-audio',
            "--time-limit=$recLen",
            "--record=$rec"
        )
        $captureCmd = ($captureArgs | ForEach-Object { Quote-Arg $_ }) -join ' '

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $T.scrcpy
        $psi.Arguments              = $captureCmd
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.EnvironmentVariables['SDL_VIDEODRIVER'] = 'dummy'

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $procStarted = $false
        $procRegistry = $script:ProcessRegistry
        $tO = $null; $tE = $null
        $captureOut = ''; $captureErr = ''; $captureCode = -1; $captureTimedOut = $false
        try {
            [void]$proc.Start()
            $procStarted = $true
            if ($procRegistry) { $procRegistry[$proc.Id] = $proc }
            $tO = $proc.StandardOutput.ReadToEndAsync()
            $tE = $proc.StandardError.ReadToEndAsync()

            # Cho 1.8 giay de scrcpy ket noi am thanh Android HAL
            Start-Sleep -Milliseconds 1800

            # Ban intent mo Reel: video bat dau phat sach tu 00:00:000
            $null = Open-Reel $T $Url

            # Cho scrcpy thu am dung thoi han va tu dong dong file hoan chinh.
            $captureWaitMs = [int][Math]::Min([int]::MaxValue, ([double]($recLen + 30) * 1000))
            if (-not $proc.WaitForExit($captureWaitMs)) {
                $captureTimedOut = $true
                try { $proc.Kill() } catch { }
                try { $null = $proc.WaitForExit(5000) } catch { }
            }
            try { $null = $tO.Wait(10000) } catch { }
            try { $null = $tE.Wait(10000) } catch { }
            if (-not $tO.IsCompleted) { try { $proc.StandardOutput.Close() } catch { }; try { $null = $tO.Wait(1000) } catch { } }
            if (-not $tE.IsCompleted) { try { $proc.StandardError.Close() } catch { }; try { $null = $tE.Wait(1000) } catch { } }
            if ($tO.IsCompleted -and -not $tO.IsFaulted) { $captureOut = $tO.Result }
            if ($tE.IsCompleted -and -not $tE.IsFaulted) { $captureErr = $tE.Result }
            if ($proc.HasExited -and -not $captureTimedOut) { $captureCode = $proc.ExitCode }
        } finally {
            if ($procStarted -and -not $proc.HasExited) {
                try { $proc.Kill() } catch { }
                try { $null = $proc.WaitForExit(5000) } catch { }
            }
            if ($procRegistry -and $procStarted) {
                try { $procRegistry.Remove($proc.Id) } catch { }
            }
            if ($tO -and -not $tO.IsCompleted) { try { $proc.StandardOutput.Close() } catch { }; try { $null = $tO.Wait(1000) } catch { } }
            if ($tE -and -not $tE.IsCompleted) { try { $proc.StandardError.Close() } catch { }; try { $null = $tE.Wait(1000) } catch { } }
            $proc.Dispose()
        }

        # Dung Facebook
        $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)

        if ($captureTimedOut -or $captureCode -ne 0) {
            Show-Fail -Message 'Thu am that bai.' -Fix @('scrcpy bi qua thoi gian hoac ket thuc voi loi.', $captureErr, $captureOut)
            return $null
        }
        if (-not (Test-Path $rec) -or (Get-Item $rec).Length -lt 1000) {
            Show-Fail -Message 'Thu am that bai.' -Fix @('Kiem tra ket noi thiet bi.', $captureErr, $captureOut)
            return $null
        }

        # ---------- 6. do onset t0 va cat am thanh chuan ----------
        Write-Step 6 'Xac dinh diem khoi dau Giay 0 va cat am thanh'
        $t0 = Get-AudioOnset -T $T -File $rec
        Write-Ok ("Phat hien am thanh bat dau tai t0 = {0:0.000}s" -f $t0)

        # Kiem tra thoi luong thuc te dam bao video da phat tron ven
        $recDur = Get-Duration -T $T -File $rec
        if (($recDur - $t0) -lt ($dur - 0.5)) {
            Write-Warn2 ("Am thanh ghi duoc ({0:0.0}s) co the chua phat het video ({1:0.0}s)" -f ($recDur - $t0), $dur)
        } else {
            Write-Ok ("Kiem tra phat tron ven: thoi gian nghe thuc te {0:0.0}s >= {1:0.0}s" -f ($recDur - $t0), $dur)
        }

        $durStr = $dur.ToString([cultureinfo]::InvariantCulture)
        $t0Str  = $t0.ToString([cultureinfo]::InvariantCulture)
        $cut    = Join-Path $tmp 'dub.m4a'

        # Chuan hoa am luong loudnorm phat thanh (-16 LUFS, Peak -1.5)
        $r1 = Invoke-Exe $T.ffmpeg @('-hide_banner','-nostats','-y','-ss',$t0Str,'-t',$durStr,'-i',$rec,'-vn',
                                     '-af','loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json','-f','null','-') -TimeoutMs 300000
        if ($r1.Code -ne 0) {
            Show-Fail -Message 'Phan tich am thanh that bai.' -Fix @($r1.Err)
            return $null
        }
        $mj = [regex]::Match($r1.Err, '\{[^{}]*"input_i"[\s\S]*?\}')
        $flt = 'loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000'
        if ($mj.Success) {
            try {
                $j = $mj.Value | ConvertFrom-Json
                if ("$($j.input_i)" -notmatch 'inf|nan') {
                    $flt = "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=$($j.input_i):measured_TP=$($j.input_tp)" +
                           ":measured_LRA=$($j.input_lra):measured_thresh=$($j.input_thresh):offset=$($j.target_offset):linear=true,aresample=48000"
                }
            } catch { }
        }

        $cutResult = Invoke-Exe $T.ffmpeg @('-hide_banner','-loglevel','error','-y','-ss',$t0Str,'-t',$durStr,'-i',$rec,'-vn',
                                            '-af',$flt,'-c:a','aac','-b:a','192k',$cut) -TimeoutMs 300000

        if ($cutResult.Code -ne 0 -or -not (Test-Path -LiteralPath $cut -PathType Leaf) -or (Get-Item -LiteralPath $cut).Length -le 0) {
            Show-Fail -Message 'Cat am thanh that bai.' -Fix @('Chay lai thu.', $cutResult.Err)
            return $null
        }

        $cutMean = Get-MeanVolume -T $T -File $cut
        Write-Ok ("Am thanh da cat va chuan hoa xong ({0:0.0}s, muc am {1} dB)" -f $dur, $cutMean)

        $audioLanguage = [pscustomobject]@{ Status='skipped'; Language=''; Probability=0; Samples=0; ElapsedMs=0; Reason='disabled' }
        if (-not $script:SkipLanguageCheck) {
            if (Get-Command Get-ReelAudioLanguage -CommandType Function -ErrorAction SilentlyContinue) {
                $audioLanguage = Get-ReelAudioLanguage -T $T -File $cut -Root $script:Here -WorkDir $tmp
                Write-ReelLanguageResult $audioLanguage
            } else {
                $audioLanguage.Status = 'unavailable'; $audioLanguage.Reason = 'missing-helper'
                Write-Warn2 'AUDIO_LANG_UNKNOWN: Thieu bo nhan dien tiny; can nghe nghiem thu.'
            }
        }

        # ---------- 7. ghep video HD va xuat file ----------
        Write-Step 7 'Ghep video HD va xuat file'
        $fGoc = Join-Path $tmp "$vid-1-video-goc.mp4"
        $fAm  = Join-Path $tmp "$vid-2-am-thanh-tho.m4a"
        $out  = Join-Path $tmp "$vid-3-hoan-chinh.mp4"
        $finalGoc = Join-Path $Dest "$vid-1-video-goc.mp4"
        $finalAm  = Join-Path $Dest "$vid-2-am-thanh-tho.m4a"
        $finalOut = Join-Path $Dest "$vid-3-hoan-chinh.mp4"

        # Kiem tra codec video de dam bao tuong thich 100% tren Windows DirectShow / Media Foundation, CapCut, Premiere
        $vCodecOpt = if ($cv -match 'av1|av01|vp9|vp09') {
            Write-Note "Phat hien codec $cv (chuyen ma H.264 tuong thich Player/CapCut/Premiere, giu nguyen do phan giai $($sz.W)x$($sz.H))..."
            @('-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-pix_fmt', 'yuv420p')
        } else {
            @('-c:v', 'copy')
        }

        # Ghep video goc + audio long tieng
        $muxArgs = @('-hide_banner','-loglevel','error','-y','-i',$vf.FullName,'-i',$cut,
                     '-map','0:v:0','-map','1:a:0') + $vCodecOpt + @('-c:a','copy','-shortest','-movflags','+faststart',$out)
        $muxResult = Invoke-Exe $T.ffmpeg $muxArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        if ($muxResult.Code -ne 0 -or -not (Test-Path -LiteralPath $out -PathType Leaf) -or (Get-Item -LiteralPath $out).Length -le 0 -or -not (Test-ValidReelOutput -T $T -File $out)) {
            Show-Fail -Message 'Ghep video that bai.' -Fix @('Chay lai thu.', $muxResult.Err)
            return $null
        }

        # Luu video goc khong tieng va file am thanh da tach
        $gocArgs = @('-hide_banner','-loglevel','error','-y','-i',$vf.FullName,'-map','0:v:0','-an') + $vCodecOpt + @($fGoc)
        $gocResult = Invoke-Exe $T.ffmpeg $gocArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        if ($gocResult.Code -ne 0 -or -not (Test-Path -LiteralPath $fGoc -PathType Leaf) -or (Get-Item -LiteralPath $fGoc).Length -le 0) {
            Show-Fail -Message 'Xuat video goc that bai.' -Fix @($gocResult.Err)
            return $null
        }
        Copy-Item -LiteralPath $cut -Destination $fAm -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $fAm -PathType Leaf) -or (Get-Item -LiteralPath $fAm).Length -le 0) {
            Show-Fail -Message 'Luu am thanh that bai.' -Fix @('Chay lai thu.')
            return $null
        }
        Publish-ReelFiles -Dest $Dest -Pairs @(
            @{ Source = $fGoc; Destination = $finalGoc },
            @{ Source = $fAm; Destination = $finalAm },
            @{ Source = $out; Destination = $finalOut }
        )

        Write-Host ''
        Write-Host '  XONG  ' -ForegroundColor White -BackgroundColor DarkGreen
        Write-Host ''
        Write-Host "  Video : $finalOut" -ForegroundColor Green
        Write-Host "          $($sz.W)x$($sz.H)  |  $([Math]::Round($dur,1)) giay  |  $([Math]::Round((Get-Item $finalOut).Length/1MB,1)) MB"
        Write-Host "  Goc   : $finalGoc" -ForegroundColor DarkGray
        Write-Host "  Tieng : $finalAm" -ForegroundColor DarkGray
        Write-Host ''
        return [pscustomobject]@{ File = $finalOut; Duration = $dur; DubbingUiStatus = $dubbingUiStatus; AudioLanguage = $audioLanguage }
    }
    finally {
        if (-not $KeepFiles) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        else { Write-Note "File tam luu tai: $tmp" }
    }
}

# ------------------------------------------------------------------ chay ----
Write-Host ''
Write-Host '  Kid FB.Y - tai video Facebook kem long tieng Meta AI  ' -ForegroundColor White -BackgroundColor DarkBlue

# Kiem tra file audio co san, khong ket noi Android hay tai video.
if ($DetectLanguageFile) {
    if (-not (Test-Path -LiteralPath $DetectLanguageFile -PathType Leaf)) { throw 'Khong tim thay file audio can nhan dien.' }
    if (-not (Get-Command Get-ReelAudioLanguage -CommandType Function -ErrorAction SilentlyContinue)) { throw 'Thieu core/whisper-language.ps1.' }
    $t = Get-Toolset
    if (-not $t.ffmpeg -or -not $t.ffprobe) { throw 'Can FFmpeg va ffprobe de doc audio.' }
    $languageTemp = Join-Path ([IO.Path]::GetTempPath()) ('kidfby-language-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $languageTemp -Force | Out-Null
    try {
        $languageResult = Get-ReelAudioLanguage -T $t -File $DetectLanguageFile -Root $script:Here -WorkDir $languageTemp
        Write-ReelLanguageResult $languageResult
        $languageResult
    } finally {
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTemp = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $languageTemp).Path)
        if (-not $resolvedTemp.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Tu choi xoa thu muc tam ngoai Temp.' }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return
}

if ($Setup -or $SetupTool) {
    $t = if ($SetupTool) { $SetupTool } else { 'all' }
    if ($t -ne 'whisper') { Invoke-Setup -Tool $t }
    if ($t -eq 'all' -or $t -eq 'whisper') {
        if (-not (Get-Command Install-WhisperTiny -CommandType Function -ErrorAction SilentlyContinue)) { throw 'Thieu core/whisper-language.ps1.' }
        $null = Install-WhisperTiny -Root $script:Here
    }
    return
}

if ($Check) {
    $t = Test-Ready
    if ($t) {
        Write-Host ''
        Write-Host '  MAY DA SAN SANG  ' -ForegroundColor White -BackgroundColor DarkGreen
        Write-Host ''
    }
    return
}

if (-not $OutDir -or $OutDir -eq '') {
    $base = $PSScriptRoot
    if (-not $base) { $base = (Get-Location).Path }
    $OutDir = Join-Path $base 'output'
}

$links = @()
if ($Link) { $links = @($Link | Where-Object { $_ -match '\S' }) }
if ($links.Count -eq 0) {
    Write-Host ''
    Write-Host '  Dan link video Facebook roi bam Enter:' -ForegroundColor Gray
    $typed = Read-Host '  Link'
    if ($typed -match '\S') { $links = @($typed -split '\s+' | Where-Object { $_ -match '\S' }) }
}
if ($links.Count -eq 0) { Write-Note 'Khong co link nao, thoat.'; return }

$tools = Test-Ready
if (-not $tools) { return }

Write-Host ''
Write-Note "Se xu ly $($links.Count) video. Luu vao: $OutDir"
Write-Note 'De man hinh thiet bi SANG va DA MO KHOA suot qua trinh.'

$xong = 0; $loi = 0; $n = 0
foreach ($raw in $links) {
    $n++
    $u = $raw.Trim().Trim('"').Trim("'").Trim()
    if ($links.Count -gt 1) {
        Write-Host ''
        Write-Host ("  ===== video $n/$($links.Count) =====") -ForegroundColor DarkCyan
        Write-Host "  $u" -ForegroundColor DarkGray
    }
    $kq = $null
    try { $kq = Invoke-OneLink -T $tools -Url $u -Dest $OutDir -KeepFiles:$Keep }
    catch { Show-Fail -Message "Loi: $($_.Exception.Message)" -Fix @('Chay lai thu.') }
    if ($kq) { $xong++ } else { $loi++ }
}
if ($links.Count -gt 1) {
    Write-Host ''
    Write-Host "  Tong ket: xong $xong  |  loi $loi" -ForegroundColor White
    Write-Host ''
}



