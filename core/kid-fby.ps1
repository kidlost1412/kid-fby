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
    [switch]$Watermark,
    [ValidateRange(0,95)][int]$LogoFade = 60,
    [ValidateRange(5,60)][int]$LogoSize = 30,
    [string]$LogoFile,
    [ValidateSet('Free','Fixed')][string]$LogoMotion = 'Free',
    [ValidateSet('TopLeft','TopRight','BottomLeft','BottomRight','Center')][string]$LogoPosition = 'BottomRight',
    [switch]$GifWatermark,
    [switch]$GifFullFrame,
    [string]$GifFile,
    [ValidateRange(5,100)][int]$GifSize = 25,
    [ValidateSet('TopLeft','TopRight','BottomLeft','BottomRight','Center')][string]$GifPosition = 'TopRight',
    [double]$LogoCustomX = -1,
    [double]$LogoCustomY = -1,
    [double]$GifCustomX = -1,
    [double]$GifCustomY = -1,
    [double]$LogoCustomWidth = -1,
    [double]$LogoCustomHeight = -1,
    [double]$GifCustomWidth = -1,
    [double]$GifCustomHeight = -1,
    [string]$WatermarkVideo,
    [string]$ReeditVideo,
    [System.Collections.IDictionary]$ProcessRegistry
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:Fb = 'com.facebook.katana'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
$script:Here = if ((Split-Path $scriptDir -Leaf) -in @('core','src','app')) { Split-Path $scriptDir -Parent } else { $scriptDir }
$languageHelper = Join-Path $scriptDir 'whisper-language.ps1'
if (Test-Path -LiteralPath $languageHelper) { . $languageHelper }
$linkHelper = Join-Path $scriptDir 'facebook-links.ps1'
if (Test-Path -LiteralPath $linkHelper) { . $linkHelper }
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
    $r = Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=duration','-of','json',$File)
    if ($r.Code -eq 0) {
        try {
            $data = ConvertFrom-Json -InputObject $r.Out -ErrorAction Stop
            $stream = @($data.streams | Select-Object -First 1)[0]
            $duration = 0.0
            if ($null -ne $stream -and [double]::TryParse([string]$stream.duration, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$duration) -and -not [double]::IsNaN($duration) -and -not [double]::IsInfinity($duration) -and $duration -gt 0.5) { return $duration }
        } catch { }
    }
    Get-Duration $T $File
}

function Get-VideoSize {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=width,height','-of','json',$File)
    if ($r.Code -ne 0) { throw ("ffprobe could not read video dimensions (exit code {0}): {1}" -f $r.Code, ([string]$r.Err).Trim()) }
    try {
        $data = ConvertFrom-Json -InputObject $r.Out -ErrorAction Stop
        $stream = @($data.streams | Select-Object -First 1)[0]
        $width = 0; $height = 0
        if ($null -eq $stream -or -not [int]::TryParse([string]$stream.width, [Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture, [ref]$width) -or -not [int]::TryParse([string]$stream.height, [Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture, [ref]$height) -or $width -le 0 -or $height -le 0) { throw 'ffprobe returned missing or invalid width/height values.' }
        return [pscustomobject]@{ W = [int]$width; H = [int]$height }
    } catch {
        throw ("Could not read video dimensions from ffprobe JSON: {0}" -f $_.Exception.Message)
    }
}

function Get-VideoCodec {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=codec_name','-of','json',$File)
    if ($r.Code -ne 0) { throw ("ffprobe could not read the video codec (exit code {0}): {1}" -f $r.Code, ([string]$r.Err).Trim()) }
    try {
        $data = ConvertFrom-Json -InputObject $r.Out -ErrorAction Stop
        $stream = @($data.streams | Select-Object -First 1)[0]
        $codec = ([string]$stream.codec_name).Trim().ToLowerInvariant()
        if ($null -eq $stream -or $codec -notmatch '^[a-zA-Z0-9_]+$') { throw 'ffprobe returned a missing or invalid codec name.' }
        return $codec
    } catch {
        throw ("Could not read video codec from ffprobe JSON: {0}" -f $_.Exception.Message)
    }
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
    if (-not $T -or -not $T.ffmpeg) { return 0.0 }

    # 1. Kiem tra luong am thanh va lay thoi luong (format + stream fallback an toan)
    $fileDur = 0.0
    $hasAudio = $false
    if ($T.ffprobe) {
        $probe = Invoke-Exe $T.ffprobe @('-v','error','-select_streams','a:0',
            '-show_entries','stream=index,duration:format=duration','-of','default=noprint_wrappers=1', $File) -TimeoutMs 10000
        if ($probe.Code -eq 0 -and $probe.Out) {
            foreach ($line in ($probe.Out -split "`r?`n")) {
                $trimmed = $line.Trim()
                if ($trimmed -match '^index=\d+') { $hasAudio = $true }
                elseif ($trimmed -match '^duration=(-?[\d.]+(?:[eE][+-]?\d+)?)') {
                    $d = 0.0
                    if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d) -and $d -gt 0) {
                        if ($fileDur -le 0) { $fileDur = $d }
                    }
                }
            }
        }
    }
    # Neu file khong co audio stream hoac thoi luong <= 50ms -> an toan tra ve 0.0
    if (-not $hasAudio -or $fileDur -le 0.05) { return 0.0 }

    # Gioi han vung scan onset toi da 10 giay dau de tang toc gap 20x tren file dai
    $reFloat = '(-?[\d.]+(?:[eE][+-]?\d+)?)'

    # Helper de phan tich output silencedetect
    $parseSilence = {
        param([string]$Output, [double]$DurationLimit)
        $lines = $Output -split "`r?`n"
        $currentStart = $null
        $leadingSilence = $null
        $hitLimit = $false

        foreach ($line in $lines) {
            if ($line -match "silence_start:\s*$reFloat") {
                $sVal = 0.0
                if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$sVal)) {
                    $currentStart = $sVal
                }
            }
            if ($line -match "silence_end:\s*$reFloat") {
                $eVal = 0.0
                if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$eVal)) {
                    $hasExplicitStart = ($null -ne $currentStart)
                    $sVal = if ($hasExplicitStart) { $currentStart } else { 0.0 }

                    # Neu silence bat dau voi timestamp ro rang > 0.01s: kiem tra xem co am thanh thuc su o dau file khong (M2)
                    $hasAudioBeforeSilence = $false
                    if ($hasExplicitStart -and $sVal -gt 0.01) {
                        $sValStr = $sVal.ToString('0.###', [cultureinfo]::InvariantCulture)
                        $volProbe = Invoke-Exe $T.ffmpeg @('-hide_banner','-t',$sValStr,'-vn','-i',$File,'-af','volumedetect','-f','null','-') -TimeoutMs 15000
                        if ($volProbe.Code -eq 0 -and $volProbe.Err -match 'max_volume:\s*(-?[\d.]+)\s*dB') {
                            $maxVol = 0.0
                            if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$maxVol)) {
                                if ($maxVol -gt -58.0) {
                                    $hasAudioBeforeSilence = $true
                                }
                            }
                        }
                    }

                    if ($hasAudioBeforeSilence) {
                        # Co am thanh that ngay dau file truoc khoang lang -> khong cat, onset = 0.0
                        return @{ IsSilentAll = $false; Onset = 0.0; HitLimit = $false }
                    }

                    # Khoang lang phai bat dau tu ngay dau file (dung sai container/buffer delay <= 0.12s)
                    if ($sVal -le 0.12) {
                        # Neu silence_end cham toi gioi han scan (EOF cua pham vi quet) -> chua ket thuc silence that
                        if ($DurationLimit -gt 0 -and [Math]::Abs($eVal - $DurationLimit) -le 0.08) {
                            $hitLimit = $true
                            break
                        }
                        # Neu khoang lang keo dai toi tan cuoi video (file cam toan bo) -> khong cat den EOF
                        if ($eVal -ge ($fileDur - 0.15)) {
                            return @{ IsSilentAll = $true; Onset = 0.0; HitLimit = $false }
                        }
                        $leadingSilence = $eVal
                        break
                    }
                    $currentStart = $null
                }
            }
        }

        if ($null -ne $currentStart -and $currentStart -le 0.12 -and $null -eq $leadingSilence) {
            $hitLimit = $true
        }

        return @{ IsSilentAll = $false; Onset = $leadingSilence; HitLimit = $hitLimit }
    }

    # 2. Quet voi nguong chuan -60dB; khong nang nguong -50dB de tranh cat nham am thanh nho o dau file (M1)
    $noiseTier = '-60dB'
    $scanLimit = [Math]::Min(10.0, $fileDur)
    $scanLimitStr = $scanLimit.ToString('0.###', [cultureinfo]::InvariantCulture)

    $r = Invoke-Exe $T.ffmpeg @('-hide_banner','-nostats','-t',$scanLimitStr,'-vn','-i',$File,
        '-af',"silencedetect=noise=$noiseTier`:d=0.10",'-f','null','-') -TimeoutMs 60000
    if ($r.Code -eq 0) {
        $res = & $parseSilence $r.Err $scanLimit
        if ($res.IsSilentAll) { return 0.0 }
        if ($null -ne $res.Onset) { return $res.Onset }

        # Neu khoang lang vuot qua 10s scan window va file con dai hon -> scan toan bo file
        if ($res.HitLimit -and $scanLimit -lt ($fileDur - 0.15)) {
            $rFull = Invoke-Exe $T.ffmpeg @('-hide_banner','-nostats','-vn','-i',$File,
                '-af',"silencedetect=noise=$noiseTier`:d=0.10",'-f','null','-') -TimeoutMs 120000
            if ($rFull.Code -eq 0) {
                $resFull = & $parseSilence $rFull.Err 0.0
                if ($resFull.IsSilentAll) { return 0.0 }
                if ($null -ne $resFull.Onset) { return $resFull.Onset }
            }
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

function Expand-KidLogo {
    param([string]$WorkDir)
    $archive = Join-Path $script:Here 'core/kid-logo.zip'
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'Thieu logo Kid: core/kid-logo.zip. Hay cap nhat lai app.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.GetEntry('kid-logo.png')
        if ($null -eq $entry -or $entry.Length -le 0) { throw 'Goi logo Kid khong hop le.' }
        $target = Join-Path $WorkDir 'kid-logo.png'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        return $target
    } finally { $zip.Dispose() }
}

function Test-LogoPng {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf) -or [IO.Path]::GetExtension($File) -ine '.png') { throw 'Hay chon file logo PNG co san.' }
    Add-Type -AssemblyName System.Drawing
    $image = $null
    try {
        $image = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $File).Path)
        if ($image.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid -or $image.Width -le 0 -or $image.Height -le 0) { throw 'Invalid PNG.' }
    } catch { throw 'Khong doc duoc logo PNG. Hay chon lai anh PNG da tach nen.' }
    finally { if ($image) { $image.Dispose() } }
}

function Resolve-WatermarkLogo {
    param([string]$WorkDir, [string]$CustomFile)
    if ([string]::IsNullOrWhiteSpace($CustomFile)) { return Expand-KidLogo -WorkDir $WorkDir }
    Test-LogoPng -File $CustomFile
    $target = Join-Path $WorkDir 'custom-logo.png'
    Copy-Item -LiteralPath $CustomFile -Destination $target -Force -ErrorAction Stop
    return $target
}

function Test-GifFile {
    param([string]$File)
    if ([string]::IsNullOrWhiteSpace($File)) { throw 'Duong dan file GIF khong duoc de trong.' }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Khong tim thay file GIF: $File" }
    $ext = [IO.Path]::GetExtension($File)
    if ($ext -notmatch '(?i)^\.gif$') { throw "File phai co duoi dinh dang .gif: $File" }
    $resolvedPath = (Resolve-Path -LiteralPath $File).Path
    $bytes = [IO.File]::ReadAllBytes($resolvedPath)
    if ($bytes.Length -lt 14) { throw "File GIF khong hop le hoac bi hong: $File" }
    $header = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 6)
    if ($header -notmatch '^GIF8[79]a$') { throw "Dinh dang file khong phai GIF tieu chuan: $File" }

    # Kiem tra cau truc blocks va sub-blocks de phat hien GIF bi cut/truncated frame (M3)
    $offset = 13
    $screenPacked = [int]$bytes[10]
    if (($screenPacked -band 0x80) -ne 0) { $offset += 3 * (1 -shl (($screenPacked -band 7) + 1)) }
    while ($offset -lt $bytes.Length) {
        $tag = [int]$bytes[$offset]; $offset++
        if ($tag -eq 0x3B) { break } # Trailer hop le
        if ($tag -eq 0x21) { # Extension block
            if ($offset -ge $bytes.Length) { throw "File GIF bi cat o extension block: $File" }
            $offset++ # Label
            while ($offset -lt $bytes.Length) {
                $size = [int]$bytes[$offset]; $offset++
                if ($size -eq 0) { break }
                $offset += $size
            }
            continue
        }
        if ($tag -eq 0x2C) { # Image descriptor
            if (($offset + 9) -gt $bytes.Length) { throw "File GIF bi cat o image descriptor: $File" }
            $framePacked = [int]$bytes[$offset + 8]
            $offset += 9
            if (($framePacked -band 0x80) -ne 0) { $offset += 3 * (1 -shl (($framePacked -band 7) + 1)) }
            if ($offset -ge $bytes.Length) { throw "File GIF thieu LZW code size: $File" }
            $offset++ # LZW min code size
            $terminated = $false
            while ($offset -lt $bytes.Length) {
                $size = [int]$bytes[$offset]; $offset++
                if ($size -eq 0) { $terminated = $true; break }
                if (($offset + $size) -gt $bytes.Length) { throw "File GIF bi cat o du lieu LZW frame: $File" }
                $offset += $size
            }
            if (-not $terminated) { throw "File GIF chua ket thuc frame hop le: $File" }
            continue
        }
    }

    # Chinh sach tuong thich trailer 0x3B: Neu gap byte trailer 0x3B thi dung quet khoi hop le.
    # Neu file het ma khong co trailer (nhung framing cac block truoc khong bi cut do dang),
    # file khong bi reject vi thieu trailer ma tiep tuc sang buoc kiem tra giai ma pixel.
    Add-Type -AssemblyName System.Drawing
    $image = $null
    try {
        $image = [Drawing.Image]::FromFile($resolvedPath)
        if ($image.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Gif.Guid -or $image.Width -le 0 -or $image.Height -le 0) {
            throw 'Invalid GIF format.'
        }
        if ($image.Width -gt 4096 -or $image.Height -gt 4096) {
            throw "Kich thuoc GIF vuot qua gioi han ($($image.Width)x$($image.Height)): $File"
        }
    } catch {
        throw "Khong doc duoc file GIF hoac file bi hong: $File"
    } finally {
        if ($image) { $image.Dispose() }
    }

    # Giai ma toan bo animation bang FFmpeg de kiem tra du lieu pixel/LZW thuc te (fail-fast, timeout guard)
    $ffmpegExe = $null
    if (Get-Command 'Find-Tool' -ErrorAction SilentlyContinue) {
        try { $ffmpegExe = Find-Tool 'ffmpeg' } catch { }
    }
    if (-not $ffmpegExe) {
        $candBases = @(
            $(if ($PSScriptRoot) { $PSScriptRoot } else { $null }),
            $(if ($script:Here) { $script:Here } else { $null }),
            (Get-Location).Path,
            'D:\reup video fb meta',
            (Join-Path $env:LOCALAPPDATA 'Kid-FB.Y')
        )
        foreach ($base in $candBases) {
            if (-not $base) { continue }
            foreach ($sub in @('tools\ffmpeg\ffmpeg.exe', 'tools\ffmpeg\bin\ffmpeg.exe', 'tools\ffmpeg.exe')) {
                $cand = Join-Path $base $sub
                if (Test-Path -LiteralPath $cand -PathType Leaf) {
                    $ffmpegExe = $cand
                    break
                }
            }
            if ($ffmpegExe) { break }
        }
    }
    if (-not $ffmpegExe) {
        $cmd = Get-Command 'ffmpeg' -ErrorAction SilentlyContinue
        if ($cmd) { $ffmpegExe = $cmd.Source }
    }

    if ($ffmpegExe -and (Test-Path -LiteralPath $ffmpegExe -PathType Leaf)) {
        $decode = Invoke-Exe $ffmpegExe @('-hide_banner', '-v', 'error', '-i', $resolvedPath, '-f', 'null', '-') -TimeoutMs 15000
        $errText = [string]$decode.Err
        if ($decode.Code -ne 0 -or $errText -match '(?i)LZW decode failed|LZW init failed|invalid code|corrupt|error decoding|Invalid GIF|truncated') {
            throw "Du lieu anh GIF bi loi pixel/LZW khong giai ma duoc: $File"
        }
    }
}

function Get-OptimalVideoEncoder {
    param($T)
    if ($script:optimalVideoEncoder) { return $script:optimalVideoEncoder }
    if (-not $T -or -not $T.ffmpeg) { return 'libx264' }
    try {
        $testNvenc = Invoke-Exe $T.ffmpeg @('-hide_banner','-f','lavfi','-i','color=c=black:s=256x256:d=0.04','-c:v','h264_nvenc','-f','null','-') -TimeoutMs 3000
        if ($testNvenc.Code -eq 0) {
            $script:optimalVideoEncoder = 'h264_nvenc'
            return $script:optimalVideoEncoder
        }
        $testQsv = Invoke-Exe $T.ffmpeg @('-hide_banner','-f','lavfi','-i','color=c=black:s=256x256:d=0.04','-c:v','h264_qsv','-f','null','-') -TimeoutMs 3000
        if ($testQsv.Code -eq 0) {
            $script:optimalVideoEncoder = 'h264_qsv'
            return $script:optimalVideoEncoder
        }
        $testAmf = Invoke-Exe $T.ffmpeg @('-hide_banner','-f','lavfi','-i','color=c=black:s=256x256:d=0.04','-c:v','h264_amf','-f','null','-') -TimeoutMs 3000
        if ($testAmf.Code -eq 0) {
            $script:optimalVideoEncoder = 'h264_amf'
            return $script:optimalVideoEncoder
        }
    } catch { }
    $script:optimalVideoEncoder = 'libx264'
    return $script:optimalVideoEncoder
}

function Get-MovingLogoMuxArgs {
    param([string]$Video, [string]$Audio, [string]$Logo, [string]$Output,
          [int]$Width, [int]$Height, [ValidateRange(0,95)][int]$Fade = 60,
          [ValidateRange(5,60)][int]$Size = 30,
          [ValidateSet('Free','Fixed')][string]$Motion = 'Free',
          [ValidateSet('TopLeft','TopRight','BottomLeft','BottomRight','Center')][string]$Position = 'BottomRight',
          [string]$Gif = '',
          [ValidateRange(5,100)][int]$GifSize = 25,
          [ValidateSet('TopLeft','TopRight','BottomLeft','BottomRight','Center')][string]$GifPosition = 'TopRight',
          [double]$CustomX = -1,
          [double]$CustomY = -1,
          [double]$GifCustomX = -1,
          [double]$GifCustomY = -1,
          [string]$VideoEncoder = 'libx264',
          [switch]$GifFullFrame,
          [double]$CustomWidth = -1,
          [double]$CustomHeight = -1,
          [double]$GifCustomWidth = -1,
          [double]$GifCustomHeight = -1)
    if ($Width -le 0 -or $Height -le 0) { throw 'Kich thuoc video khong hop le de chen logo.' }

    $coordinates = @{
        TopLeft     = @('(W-w)*0.04','(H-h)*0.04')
        TopRight    = @('(W-w)*0.96','(H-h)*0.04')
        BottomLeft  = @('(W-w)*0.04','(H-h)*0.96')
        BottomRight = @('(W-w)*0.96','(H-h)*0.96')
        Center      = @('(W-w)*0.5','(H-h)*0.5')
    }

    $encArgs = switch ($VideoEncoder) {
        'h264_nvenc' { @('-c:v','h264_nvenc','-preset','p4','-rc:v','vbr','-cq:v','19','-pix_fmt','yuv420p') }
        'h264_qsv'   { @('-c:v','h264_qsv','-global_quality','20','-pix_fmt','yuv420p') }
        'h264_amf'   { @('-c:v','h264_amf','-quality','speed','-rc','cqp','-qp_i','19','-qp_p','19','-pix_fmt','yuv420p') }
        default      { @('-c:v','libx264','-crf','18','-preset','veryfast','-pix_fmt','yuv420p') }
    }
    $hasLogo = -not [string]::IsNullOrWhiteSpace($Logo)
    $hasGif  = -not [string]::IsNullOrWhiteSpace($Gif)
    $outputWidth = [Math]::Max(2, [int]([Math]::Ceiling($Width / 2.0) * 2))
    $outputHeight = [Math]::Max(2, [int]([Math]::Ceiling($Height / 2.0) * 2))

    if ($hasLogo) {
        if ($CustomWidth -gt 0.0 -and $CustomHeight -gt 0.0) {
            $logoWidthFraction = [Math]::Max(0.0, [Math]::Min(1.0, $CustomWidth))
            $logoHeightFraction = [Math]::Max(0.0, [Math]::Min(1.0, $CustomHeight))
            $logoWidth = [Math]::Max(2, [int][Math]::Round($outputWidth * $logoWidthFraction))
            $logoHeight = [Math]::Max(2, [int][Math]::Round($outputHeight * $logoHeightFraction))
            $logoScale = "${logoWidth}:${logoHeight}"
        } else {
            $logoWidth = [Math]::Max(2, [int]($Width * $Size / 100.0))
            $logoHeight = [Math]::Max(2, [int]($Height * 0.60))
            $logoScale = "${logoWidth}:${logoHeight}:force_original_aspect_ratio=decrease"
        }
        $alpha = ((100 - $Fade) / 100.0).ToString('0.00', [cultureinfo]::InvariantCulture)
        if ($CustomX -ge 0 -and $CustomY -ge 0) {
            $cxStr = [Math]::Max(0.0, [Math]::Min(1.0, $CustomX)).ToString('0.000', [cultureinfo]::InvariantCulture)
            $cyStr = [Math]::Max(0.0, [Math]::Min(1.0, $CustomY)).ToString('0.000', [cultureinfo]::InvariantCulture)
            $x = "(W-w)*$cxStr"; $y = "(H-h)*$cyStr"
        } elseif ($Motion -eq 'Fixed') {
            $x = $coordinates[$Position][0]; $y = $coordinates[$Position][1]
        } else {
            $x = '(W-w)*(0.5+0.46*sin(0.23*t+0.6))'
            $y = '(H-h)*(0.5+0.46*sin(0.17*t-1.1))'
        }
    }

    if ($hasGif) {
        if ($GifFullFrame) {
            $gifWidth = $outputWidth
            $gifHeight = $outputHeight
            $gx = '0'; $gy = '0'
            $gifScale = "${gifWidth}:${gifHeight}"
        } elseif ($GifCustomWidth -gt 0.0 -and $GifCustomHeight -gt 0.0) {
            $gifWidthFraction = [Math]::Max(0.0, [Math]::Min(1.0, $GifCustomWidth))
            $gifHeightFraction = [Math]::Max(0.0, [Math]::Min(1.0, $GifCustomHeight))
            $gifWidth = [Math]::Max(2, [int][Math]::Round($outputWidth * $gifWidthFraction))
            $gifHeight = [Math]::Max(2, [int][Math]::Round($outputHeight * $gifHeightFraction))
            $gifScale = "${gifWidth}:${gifHeight}"
        } else {
            $gifWidth = [Math]::Max(2, [int]($Width * $GifSize / 100.0))
            $gifHeight = [Math]::Max(2, [int]($Height * 1.0))
            $gifScale = "${gifWidth}:${gifHeight}:force_original_aspect_ratio=decrease"
        }
        if (-not $GifFullFrame -and $GifCustomX -ge 0 -and $GifCustomY -ge 0) {
            $gcxStr = [Math]::Max(0.0, [Math]::Min(1.0, $GifCustomX)).ToString('0.000', [cultureinfo]::InvariantCulture)
            $gcyStr = [Math]::Max(0.0, [Math]::Min(1.0, $GifCustomY)).ToString('0.000', [cultureinfo]::InvariantCulture)
            $gx = "(W-w)*$gcxStr"; $gy = "(H-h)*$gcyStr"
        } elseif (-not $GifFullFrame) {
            $gx = $coordinates[$GifPosition][0]; $gy = $coordinates[$GifPosition][1]
        }
    }

    if ($hasLogo -and $hasGif) {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[vbase];" +
                  "[2:v]format=rgba,scale=${logoScale},colorchannelmixer=aa=${alpha}[logo];" +
                  "[3:v]format=rgba,scale=${gifScale}[gif];" +
                  "[vbase][logo]overlay=x='${x}':y='${y}':eval=frame:shortest=1:format=auto[vtmp];" +
                  "[vtmp][gif]overlay=x='${gx}':y='${gy}':shortest=1:format=auto[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-loop','1','-i',$Logo,'-stream_loop','-1','-i',$Gif,'-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy','-shortest','-movflags','+faststart',$Output)
    } elseif ($hasGif) {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[vbase];" +
                  "[2:v]format=rgba,scale=${gifScale}[gif];" +
                  "[vbase][gif]overlay=x='${gx}':y='${gy}':shortest=1:format=auto[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-stream_loop','-1','-i',$Gif,'-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy','-shortest','-movflags','+faststart',$Output)
    } elseif ($hasLogo) {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[vbase];" +
                  "[2:v]format=rgba,scale=${logoScale},colorchannelmixer=aa=${alpha}[logo];" +
                  "[vbase][logo]overlay=x='${x}':y='${y}':eval=frame:shortest=1:format=auto[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-loop','1','-i',$Logo,'-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy','-shortest','-movflags','+faststart',$Output)
    } else {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy','-shortest','-movflags','+faststart',$Output)
    }
}

function Invoke-ReeditVideo {
    param($T, [string]$File, [switch]$Enabled,
          [string]$CustomLogo, [int]$Size = 30, [int]$Fade = 60,
          [string]$Motion = 'Free', [string]$Position = 'BottomRight',
          [switch]$GifEnabled, [string]$GifFile, [int]$GifSize = 25,
          [string]$GifPosition = 'TopRight',
          [double]$CustomX = -1,
          [double]$CustomY = -1,
          [double]$GifCustomX = -1,
          [double]$GifCustomY = -1,
          [string]$VideoEncoder = '', [switch]$GifFullFrame,
          [double]$CustomWidth = -1, [double]$CustomHeight = -1,
          [double]$GifCustomWidth = -1, [double]$GifCustomHeight = -1)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Khong tim thay video can sua.' }
    $final = (Resolve-Path -LiteralPath $File).Path
    $name = [IO.Path]::GetFileName($final)
    if ($name -notmatch '^(.+)-3-hoan-chinh\.mp4$') { throw 'Hay chon video hoan chinh trong Kho Video de sua logo.' }
    $id = $matches[1]; $dest = Split-Path $final -Parent
    $source = Join-Path $dest ($id + '-1-video-goc.mp4')
    $audio = Join-Path $dest ($id + '-2-am-thanh-tho.m4a')
    foreach ($inputFile in @($source,$audio)) {
        if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw "Thieu file da luu de sua video: $inputFile. Khong tai hoac thu am lai tu dong." }
    }
    $sizeInfo = Get-VideoSize $T $source
    $duration = Get-VideoDuration $T $source
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $work = Join-Path $tempBase ('kidfby-reedit-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
    try {
        $staged = Join-Path $work 'edited.mp4'
        $resolvedLogo = ''
        $resolvedGif  = ''
        if ($Enabled) {
            $resolvedLogo = Resolve-WatermarkLogo -WorkDir $work -CustomFile $CustomLogo
        }
        if ($GifEnabled) {
            if ([string]::IsNullOrWhiteSpace($GifFile)) {
                Show-Fail -Message 'Bat tuy chon GIF (-GifWatermark hoac -GifEnabled) nhung chua cung cap duong dan file GIF (-GifFile).'
                exit 1
            }
            Test-GifFile -File $GifFile
            $resolvedGif = (Resolve-Path -LiteralPath $GifFile).Path
        }

        $activeEncoder = if ([string]::IsNullOrWhiteSpace($VideoEncoder)) {
            if (Get-Command 'Get-OptimalVideoEncoder' -ErrorAction SilentlyContinue) { Get-OptimalVideoEncoder -T $T } else { 'libx264' }
        } else { $VideoEncoder }

        if ($resolvedLogo -or $resolvedGif) {
            $editArgs = Get-MovingLogoMuxArgs -Video $source -Audio $audio -Logo $resolvedLogo -Output $staged `
                -Width $sizeInfo.W -Height $sizeInfo.H -Fade $Fade -Size $Size -Motion $Motion -Position $Position `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $CustomWidth -CustomHeight $CustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $CustomX -CustomY $CustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder $activeEncoder
        } else {
            $editArgs = @('-hide_banner','-loglevel','error','-y','-i',$source,'-i',$audio,'-map','0:v:0','-map','1:a:0?','-c','copy','-shortest','-movflags','+faststart',$staged)
        }
        Write-Note 'Sua tu video goc va audio da luu; khong tai video, khong thu am lai.'
        $result = Invoke-Exe $T.ffmpeg $editArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        if ($result.Code -ne 0 -and $activeEncoder -ne 'libx264' -and ($resolvedLogo -or $resolvedGif)) {
            Write-Warn2 "Hardware encoder ($activeEncoder) that bai, tu dong chuyen sang CPU libx264..."
            $script:optimalVideoEncoder = 'libx264'
            $editArgs = Get-MovingLogoMuxArgs -Video $source -Audio $audio -Logo $resolvedLogo -Output $staged `
                -Width $sizeInfo.W -Height $sizeInfo.H -Fade $Fade -Size $Size -Motion $Motion -Position $Position `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $CustomWidth -CustomHeight $CustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $CustomX -CustomY $CustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder 'libx264'
            $result = Invoke-Exe $T.ffmpeg $editArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        }
        if ($result.Code -ne 0) { throw "Sua video that bai: $($result.Err)" }
        if (-not (Test-ValidReelOutput $T $staged)) { throw 'Video sua khong qua kiem tra. Giu nguyen ban cu.' }
        Publish-ReelFiles -Dest $dest -Pairs @(@{Source=$staged;Destination=$final})
        Write-Host "REEDIT_OK: $final"
        Write-Host "Video : $final"
        return $final
    } finally {
        $resolved = [IO.Path]::GetFullPath($work)
        if (-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^kidfby-reedit-[0-9a-f]{32}$') { throw 'Duong dan don dep sua video khong an toan.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ValidReelOutput {
    param($T, [string]$File, [switch]$AllowSilent)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $File).Length -le 0) { return $false }
    try {
        $probe = Invoke-Exe $T.ffprobe @('-v','error','-show_entries','stream=codec_type:format=duration','-of','json',$File) -TimeoutMs 15000
        if ($probe.Code -ne 0) { return $false }
        $data = ConvertFrom-Json -InputObject $probe.Out -ErrorAction Stop
        $types = @($data.streams | ForEach-Object { [string]$_.codec_type })
        if ($types -notcontains 'video') { return $false }
        if (-not $AllowSilent -and $types -notcontains 'audio') { return $false }
        $duration = 0.0
        $value = [string]$data.format.duration
        $hasValidDuration = [double]::TryParse($value, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$duration) -and -not [double]::IsNaN($duration) -and -not [double]::IsInfinity($duration) -and $duration -gt 0.5
        if (-not $hasValidDuration) { return $false }

        # Kiem tra giai ma toan bo stream de loai bo file bi cat / thieu frame (M4)
        if ($T -and $T.ffmpeg) {
            $decode = Invoke-Exe $T.ffmpeg @('-hide_banner','-v','error','-i',$File,'-f','null','-') -TimeoutMs 30000
            if ($decode.Code -ne 0) { return $false }
            if ($decode.Err -match 'partial file|Invalid data found|Input buffer exhausted|Error submitting packet|corrupt') {
                return $false
            }
        }

        return $true
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.Management.Automation.PipelineStoppedException]) { throw $exception }
            $exception = $exception.InnerException
        }
        return $false
    }
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
    param($T, [string]$Url, [string]$Dest, [switch]$KeepFiles, [switch]$GifFullFrame,
          [double]$LogoCustomWidth = -1, [double]$LogoCustomHeight = -1,
          [double]$GifCustomWidth = -1, [double]$GifCustomHeight = -1)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # ---------- 3. tai video goc va do thoi luong ----------
        Write-Step 3 'Tai video HD va doc thoi luong chuan'
        if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) {
            $cleanLinks = @(Get-FacebookInputLinks -Text $Url)
            if ($cleanLinks.Count -ne 1) {
                Show-Fail -Message 'Can mot link video Facebook hop le cho moi tac vu.' -Fix @('Dan URL Facebook/share/Reel, khong dan nhieu link vao mot tac vu.')
                return $null
            }
            $Url = $cleanLinks[0]
            $resolvedUrl = Resolve-FacebookShareUrl -Url $Url
            if ($resolvedUrl -ne $Url) { Write-Note "Link chia se -> $resolvedUrl"; $Url = $resolvedUrl }
        }
        $idr = Invoke-Exe $T.ytdlp @('--ignore-config','--no-playlist','--no-warnings','--print','%(id)s',$Url) -TimeoutMs 120000
        $vid = ($idr.Out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        if ($vid) { $vid = $vid.Trim() }
        if ($idr.Code -ne 0 -or -not $vid) {
            Show-Fail -Message 'Chua doc duoc video tu link Facebook.' -Fix @('Xem loi yt-dlp ben duoi; neu video can dang nhap, rieng tu hoac bi gioi han thi thu link cong khai.', 'Neu bao Unsupported URL, tai lai yt-dlp tai tab cong cu.', $idr.Err)
            return $null
        }
        if (Get-Command Get-FacebookCanonicalVideoUrl -CommandType Function -ErrorAction SilentlyContinue) {
            $Url = Get-FacebookCanonicalVideoUrl -Url $Url -VideoId $vid
        }

        # Tai ban chat luong cao nhat tuyet doi (4K / 2K / 1080p, uu tien do phan giai va bitrate cao nhat)
        $dlr = Invoke-Exe $T.ytdlp @('--ignore-config','--no-playlist','-S','res,fps,br','-f','bestvideo/best','--no-warnings','-o',"$tmp\v.%(ext)s",$Url) -TimeoutMs 600000
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
        $cv = Get-VideoCodec -T $T -File $vf.FullName
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
            '--no-window',
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

        $resolvedLogo = ''
        $resolvedGif  = ''
        if ($Watermark) {
            $resolvedLogo = Resolve-WatermarkLogo -WorkDir $tmp -CustomFile $LogoFile
            Write-Note "Chen logo: kich thuoc $LogoSize%, do mo $LogoFade%, che do $LogoMotion."
        }
        if ($GifWatermark) {
            if ([string]::IsNullOrWhiteSpace($GifFile)) {
                throw 'Bat tuy chon GIF (-GifWatermark hoac -GifEnabled) nhung chua cung cap duong dan file GIF (-GifFile).'
            }
            Test-GifFile -File $GifFile
            $resolvedGif = (Resolve-Path -LiteralPath $GifFile).Path
            Write-Note "Chen GIF: kich thuoc $GifSize%, vi tri $GifPosition."
        }
        $chosenEncoder = if (Get-Command "Get-OptimalVideoEncoder" -ErrorAction SilentlyContinue) { Get-OptimalVideoEncoder -T $T } else { "libx264" }
        if ($resolvedLogo -or $resolvedGif) {
            $muxArgs = Get-MovingLogoMuxArgs -Video $vf.FullName -Audio $cut -Logo $resolvedLogo -Output $out `
                -Width $sz.W -Height $sz.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder $chosenEncoder
        }
        $muxResult = Invoke-Exe $T.ffmpeg $muxArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        if ($muxResult.Code -ne 0 -and $chosenEncoder -ne 'libx264' -and ($resolvedLogo -or $resolvedGif)) {
            Write-Warn2 "Hardware encoder ($chosenEncoder) that bai, tu dong chuyen sang CPU libx264..."
            $script:optimalVideoEncoder = 'libx264'
            $muxArgs = Get-MovingLogoMuxArgs -Video $vf.FullName -Audio $cut -Logo $resolvedLogo -Output $out `
                -Width $sz.W -Height $sz.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder 'libx264'
            $muxResult = Invoke-Exe $T.ffmpeg $muxArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        }
        if ($muxResult.Code -ne 0 -or -not (Test-Path -LiteralPath $out -PathType Leaf) -or (Get-Item -LiteralPath $out).Length -le 0) {
            Show-Fail -Message 'Ghep video that bai.' -Fix @('Chay lai thu.', $muxResult.Err)
            return $null
        }
        if (-not (Test-ValidReelOutput -T $T -File $out)) {
            Show-Fail -Message 'File da ghep nhung khong qua kiem tra dau ra.' -Fix @('FFmpeg da ket thuc thanh cong; ffprobe can doc du stream video/audio va thoi luong hop le.','Kiem tra lai ffprobe hoac giu file tam bang -Keep de doi chieu.')
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

if ($ReeditVideo) {
    $editTools = Get-Toolset
    if (-not $editTools.ffmpeg -or -not $editTools.ffprobe) { throw 'Can FFmpeg va ffprobe de sua video.' }
    Invoke-ReeditVideo -T $editTools -File $ReeditVideo -Enabled:$Watermark -CustomLogo $LogoFile -Size $LogoSize -Fade $LogoFade -Motion $LogoMotion -Position $LogoPosition `
        -GifEnabled:$GifWatermark -GifFullFrame:$GifFullFrame -GifFile $GifFile -GifSize $GifSize -GifPosition $GifPosition `
        -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY `
        -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
        -VideoEncoder $(if (Get-Command "Get-OptimalVideoEncoder" -ErrorAction SilentlyContinue) { Get-OptimalVideoEncoder -T $editTools } else { "libx264" })
    return
}

# Chen logo vao video co san, khong ket noi Android hay tai video.
if ($WatermarkVideo) {
    if (-not (Test-Path -LiteralPath $WatermarkVideo -PathType Leaf)) { throw 'Khong tim thay video can chen logo.' }
    $sourceVideo = (Resolve-Path -LiteralPath $WatermarkVideo).Path
    $previewOutput = Join-Path (Split-Path $sourceVideo -Parent) (([IO.Path]::GetFileNameWithoutExtension($sourceVideo)) + '-logo-preview.mp4')
    if (Test-Path -LiteralPath $previewOutput) { throw "File thu da ton tai: $previewOutput. Hay doi ten truoc khi xuat lai." }
    $logoTools = Get-Toolset
    if (-not $logoTools.ffmpeg -or -not $logoTools.ffprobe) { throw 'Can FFmpeg va ffprobe de chen logo.' }
    $logoTemp = Join-Path ([IO.Path]::GetTempPath()) ('kidfby-logo-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $logoTemp -ErrorAction Stop | Out-Null
    try {
        $resolvedLogo = ''
        $resolvedGif  = ''
        if ($Watermark -or -not [string]::IsNullOrWhiteSpace($LogoFile) -or -not $GifWatermark) {
            $resolvedLogo = Resolve-WatermarkLogo -WorkDir $logoTemp -CustomFile $LogoFile
            Write-Note "Chen logo: kich thuoc $LogoSize%, do mo $LogoFade%, che do $LogoMotion."
        }
        if ($GifWatermark) {
            if ([string]::IsNullOrWhiteSpace($GifFile)) {
                Show-Fail -Message 'Bat tuy chon GIF (-GifWatermark hoac -GifEnabled) nhung chua cung cap duong dan file GIF (-GifFile).'
                exit 1
            }
            Test-GifFile -File $GifFile
            $resolvedGif = (Resolve-Path -LiteralPath $GifFile).Path
            Write-Note "Chen GIF: kich thuoc $GifSize%, vi tri $GifPosition."
        }
        $size = Get-VideoSize $logoTools $sourceVideo
        $duration = Get-VideoDuration $logoTools $sourceVideo
        $hasAudio = (Invoke-Exe $logoTools.ffprobe @('-v','error','-select_streams','a:0','-show_entries','stream=codec_type','-of','json',$sourceVideo)).Out -match 'audio'
        $stagedVideo = Join-Path $logoTemp 'preview.mp4'
        $chosenEncoder = if (Get-Command "Get-OptimalVideoEncoder" -ErrorAction SilentlyContinue) { Get-OptimalVideoEncoder -T $logoTools } else { "libx264" }
        $logoArgs = Get-MovingLogoMuxArgs -Video $sourceVideo -Audio $sourceVideo -Logo $resolvedLogo -Output $stagedVideo `
            -Width $size.W -Height $size.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
            -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
            -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY `
            -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight -VideoEncoder $chosenEncoder
        $result = Invoke-Exe $logoTools.ffmpeg $logoArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        if ($result.Code -ne 0 -and $chosenEncoder -ne 'libx264') {
            Write-Warn2 "Hardware encoder ($chosenEncoder) that bai, tu dong chuyen sang CPU libx264..."
            $script:optimalVideoEncoder = 'libx264'
            $logoArgs = Get-MovingLogoMuxArgs -Video $sourceVideo -Audio $sourceVideo -Logo $resolvedLogo -Output $stagedVideo `
                -Width $size.W -Height $size.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY `
                -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight -VideoEncoder 'libx264'
            $result = Invoke-Exe $logoTools.ffmpeg $logoArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        }
        if ($result.Code -ne 0) { throw "Chen logo that bai: $($result.Err)" }
        if (-not (Test-ValidReelOutput $logoTools $stagedVideo -AllowSilent:(-not $hasAudio))) { throw 'Video chen logo khong qua kiem tra dau ra.' }
        [IO.File]::Copy($stagedVideo, $previewOutput, $false)
        Write-Ok "Video thu: $previewOutput"
        $previewOutput
    } finally {
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolved = [IO.Path]::GetFullPath($logoTemp)
        if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^kidfby-logo-[0-9a-f]{32}$') { throw 'Duong dan don dep logo khong an toan.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
    return
}

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
if ($Link) {
    if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) { $links = @(Get-FacebookInputLinks -Text ($Link -join "`n")) }
    else { $links = @($Link | Where-Object { $_ -match '\S' }) }
}
if ($Link -and $links.Count -eq 0) {
    Show-Fail -Message 'Khong tim thay URL Facebook hop le trong noi dung da dan.' -Fix @('Dan URL Facebook/Reel/share, co the kem van ban.')
    return
}
if ($links.Count -eq 0) {
    Write-Host ''
    Write-Host '  Dan link video Facebook roi bam Enter:' -ForegroundColor Gray
    $typed = Read-Host '  Link'
    if ($typed -match '\S') {
        if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) { $links = @(Get-FacebookInputLinks -Text $typed) }
        else { $links = @($typed -split '\s+' | Where-Object { $_ -match '\S' }) }
    }
}
if ($links.Count -eq 0) { Write-Note 'Khong co link nao, thoat.'; return }

if ($Watermark) {
    if (-not [string]::IsNullOrWhiteSpace($LogoFile)) { Test-LogoPng -File $LogoFile }
    elseif (-not (Test-Path -LiteralPath (Join-Path $script:Here 'core/kid-logo.zip') -PathType Leaf)) { throw 'Thieu logo Kid: core/kid-logo.zip. Hay cap nhat lai app.' }
}
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
    try { $kq = Invoke-OneLink -T $tools -Url $u -Dest $OutDir -KeepFiles:$Keep -GifFullFrame:$GifFullFrame `
        -LogoCustomWidth $LogoCustomWidth -LogoCustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight }
    catch { Show-Fail -Message "Loi: $($_.Exception.Message)" -Fix @('Chay lai thu.') }
    if ($kq) { $xong++ } else { $loi++ }
}
if ($links.Count -gt 1) {
    Write-Host ''
    Write-Host "  Tong ket: xong $xong  |  loi $loi" -ForegroundColor White
    Write-Host ''
}



