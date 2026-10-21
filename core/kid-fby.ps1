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
    [switch]$ForceRetryRejected,
    [switch]$AllowOnsetSync,
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
if (-not (Test-Path -LiteralPath (Join-Path $script:Here 'tools'))) {
    if (Test-Path -LiteralPath (Join-Path (Get-Location).Path 'tools')) {
        $script:Here = (Get-Location).Path
    } elseif (Test-Path -LiteralPath (Join-Path (Split-Path $scriptDir -Parent) 'tools')) {
        $script:Here = Split-Path $scriptDir -Parent
    }
}

# ------------------------------------------------------------------ in ra ----
function Write-Step($n, $t) {
    Write-Host ''; Write-Host "[$n] $t" -ForegroundColor Cyan
    # Dong su kien may doc (hop dong GUI muc 1): chi cho buoc so 1-7.
    $stepNo = 0
    if ([int]::TryParse([string]$n, [ref]$stepNo) -and $stepNo -ge 1 -and $stepNo -le 7) {
        $stepName = ([string]$t) -replace '[^\x20-\x7E]', '?'
        Write-Host ('@@KIDFBY_STAGE ' + ([ordered]@{ step = $stepNo; name = $stepName } | ConvertTo-Json -Compress -Depth 5))
    }
}

# Phat dong ket qua cuoi cung cua mot link (hop dong GUI muc 1). Goi dung 1 lan / link.
function Write-KidResult {
    param([System.Collections.IDictionary]$Result)
    Write-Host ('@@KIDFBY_RESULT ' + ($Result | ConvertTo-Json -Compress -Depth 5))
}

function Set-KidResultState {
    param([System.Collections.IDictionary]$Result, [string]$Status, [string]$Reason, [string]$Message = '')
    $Result.status = $Status
    $Result.reason = $Reason
    $Result.message = $Message
}
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

# Quote cho shell Android (adb shell noi chuoi roi shell thiet bi dien giai ; & | ` $()).
# Quote-Arg giu nguyen cho CreateProcess cua Windows (GUI cung dung ban do).
function Quote-AndroidArg {
    param([string]$A)
    if ($null -eq $A) { $A = '' }
    return "'" + ($A -replace "'", "'\''") + "'"
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
                $hit = Get-ChildItem -LiteralPath $r -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 10000 } | Select-Object -First 1
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

    # Keep Windows certificate validation; enable TLS 1.2 on older .NET defaults.
    if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    # 1. Thu bang .NET HttpWebRequest Stream, tu dong redirect
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

    # 2. Thu bang curl.exe, dung chung timeout va registry tien trinh voi engine
    if (-not $dlSuccess) {
        $curlExe = (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)
        $curlPath = if ($curlExe) { $curlExe.Source } elseif (Test-Path -LiteralPath 'C:\Windows\System32\curl.exe') { 'C:\Windows\System32\curl.exe' } else { $null }
        if ($curlPath -and (Test-Path -LiteralPath $curlPath)) {
            try {
                Write-Note "Dang tai bang curl..."
                $curlResult = Invoke-Exe $curlPath @('-s','-S','-L','--retry','2','--connect-timeout','20','-A','Mozilla/5.0','-o',$partFile,$Url) -TimeoutMs 120000
                if ($curlResult.Code -eq 0 -and (Test-Path -LiteralPath $partFile) -and ((Get-Item -LiteralPath $partFile).Length -gt 10000)) {
                    $dlSuccess = $true
                } else {
                    $errText = [string]$curlResult.Err
                    Write-Note "curl tra ve ma $($curlResult.Code)$(if ($errText) { ": $errText" })"
                    try { if (Test-Path -LiteralPath $partFile) { [System.IO.File]::Delete($partFile) } } catch { }
                }
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

# ---- xac minh tai ve: chi nguon chinh thuc HTTPS + SHA256 + magic bytes ----
function Get-TextFromUrl {
    param([string]$Url)
    if ($Url -notmatch '^https://') { throw "Chi chap nhan HTTPS: $Url" }
    if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $true
    $req.MaximumAutomaticRedirections = 10
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    $resp = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try {
            $buf = New-Object char[] 1048577
            $n = $reader.ReadBlock($buf, 0, $buf.Length)
            if ($n -gt 1048576) { throw 'File checksum qua lon, bo qua.' }
            return (New-Object string($buf, 0, $n))
        } finally { $reader.Dispose() }
    } finally { $resp.Dispose() }
}

# Lay SHA256 cua AssetName tu noi dung file checksum ("<hash>  <ten>" hoac "<hash> *<ten>" hoac chi 1 dong hash).
function Get-ExpectedSha256 {
    param([string]$Text, [string]$AssetName)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -match '\S' })
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$')
        if ($m.Success) {
            $name = $m.Groups[2].Value.Trim().Replace('\','/')
            $leaf = $name.Substring($name.LastIndexOf('/') + 1)
            if ($leaf -ieq $AssetName) { return $m.Groups[1].Value.ToLowerInvariant() }
        }
    }
    if ($lines.Count -eq 1) {
        $single = [regex]::Match($lines[0], '^\s*([0-9a-fA-F]{64})\s*$')
        if ($single.Success) { return $single.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

function Test-FileMagic {
    param([string]$File, [ValidateSet('zip','exe')][string]$Kind)
    $fs = [System.IO.File]::OpenRead($File)
    try {
        $head = New-Object byte[] 4
        $n = $fs.Read($head, 0, 4)
        if ($Kind -eq 'zip') { return ($n -ge 4 -and $head[0] -eq 0x50 -and $head[1] -eq 0x4B -and $head[2] -eq 0x03 -and $head[3] -eq 0x04) }
        return ($n -ge 2 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A)
    } finally { $fs.Dispose() }
}

# Tra ve $null neu hop le, nguoc lai tra chuoi loi. Khong tu xoa file (nguoi goi xoa).
function Confirm-DownloadedTool {
    param([string]$File, [string]$SumsUrl, [string]$AssetName, [ValidateSet('zip','exe')][string]$Kind)
    if (-not $SumsUrl) { return 'Khong co file checksum chinh thuc; khong cai.' }
    try { $sumsText = Get-TextFromUrl -Url $SumsUrl }
    catch { return ('Khong tai duoc checksum chinh thuc (' + $SumsUrl + '): ' + $_.Exception.Message) }
    $expected = Get-ExpectedSha256 -Text $sumsText -AssetName $AssetName
    if (-not $expected) { return "Checksum chinh thuc khong co dong cho $AssetName; khong cai." }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { return "SHA256 khong khop (mong doi $expected, nhan $actual); khong cai." }
    if (-not (Test-FileMagic -File $File -Kind $Kind)) { return "File tai ve khong dung dinh dang $Kind (magic bytes); khong cai." }
    return $null
}

function Invoke-SetupDirect {
    param([string]$Tool = 'all')
    Write-Note 'Dang tai cong cu truc tiep vao thu muc tools (chay doc lap, khong can cai vao he thong)...'
    if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    $ProgressPreference = 'SilentlyContinue'
    
    $dir = [System.IO.Path]::GetFullPath((Join-Path $script:Here 'tools'))
    foreach ($sub in @('', '_download', 'scrcpy', 'ffmpeg')) {
        $p = if ($sub) { Join-Path $dir $sub } else { $dir }
        if (-not (Test-Path -LiteralPath $p)) {
            try { New-Item -ItemType Directory -Path $p -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
    $tmpd = Join-Path $dir '_download'

    # Chi nguon chinh thuc (GitHub / gyan.dev), HTTPS, bat buoc khop SHA256 cong bo cung nguon.
    $viec = @(
        @{ Id = 'scrcpy'; Ten = 'scrcpy & adb (Ket noi Android & thu am thanh)'; Exe = 'scrcpy'; Zip = $true
           SubExe = 'adb';
           Sources = @(
               @{ Url = 'https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-win64-v3.1.zip'
                  SumsUrl = 'https://github.com/Genymobile/scrcpy/releases/download/v3.1/SHA256SUMS.txt'
                  Asset = 'scrcpy-win64-v3.1.zip' }
           ) }
        @{ Id = 'ytdlp';  Ten = 'yt-dlp (Tai video Facebook 4K/2K/1080p)'; Exe = 'yt-dlp'; Zip = $false
           Sources = @(
               @{ Url = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
                  SumsUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS'
                  Asset = 'yt-dlp.exe' }
           ) }
        @{ Id = 'ffmpeg'; Ten = 'FFmpeg & ffprobe (Giai ma, chuyen ma H.264 & ghep video)'; Exe = 'ffmpeg'; Zip = $true
           SubExe = 'ffprobe';
           Sources = @(
               @{ Url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
                  SumsUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256'
                  Asset = 'ffmpeg-release-essentials.zip' },
               @{ Url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
                  SumsUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/checksums.sha256'
                  Asset = 'ffmpeg-master-latest-win64-gpl.zip' }
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
            if ($inTools -and $localExe -and $localSub -and ($Tool -eq 'all' -or -not $Tool)) {
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
                    $companionReady = -not $v.SubExe -or [bool](Find-Tool $v.SubExe)
                    if ($inToolsNow -and $companionReady) {
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
                    if ((Find-Tool $v.Exe) -and (-not $v.SubExe -or (Find-Tool $v.SubExe))) { Write-Ok "Cai thanh cong qua WinGet: $($v.Exe)"; continue }
                    Write-Note "WinGet chua cai duoc, chuyen sang tai truc tiep..."
                } elseif (-not $wg) {
                    Write-Note "Khong tim thay winget tren may."
                }
            }

            $dlSuccess = $false
            $ext = if ($v.Zip) { '.zip' } else { '.exe' }
            $file = Join-Path $tmpd "$($v.Exe)$ext"

            foreach ($src in @($v.Sources)) {
                if (-not $src -or -not $src.Url -or $src.Url -notmatch '^https://') { continue }
                Write-Note "Dang tai $($v.Ten)..."
                Write-Note "Nguon: $($src.Url)"
                if (-not (Invoke-Download -Url $src.Url -OutFile $file)) { continue }
                $verifyError = Confirm-DownloadedTool -File $file -SumsUrl $src.SumsUrl -AssetName $src.Asset -Kind $(if ($v.Zip) { 'zip' } else { 'exe' })
                if ($verifyError) {
                    Write-Bad "Xac minh that bai, khong cai tu nguon nay: $verifyError"
                    try { [System.IO.File]::Delete($file) } catch { Write-Warn2 "Khong xoa duoc file tai do: $($_.Exception.Message)" }
                    continue
                }
                $dlSuccess = $true
                $sizeMb = [math]::Round(((Get-Item -LiteralPath $file).Length / 1MB), 2)
                Write-Ok "Tai ve hoan tat va khop SHA256 chinh thuc ($sizeMb MB)"
                break
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
                            Start-Process -FilePath $wingetPath -ArgumentList @('install', '--id', $pkgId, '--silent', '--accept-source-agreements', '--accept-package-agreements') -NoNewWindow -Wait
                            if ((Find-Tool $v.Exe) -and (-not $v.SubExe -or (Find-Tool $v.SubExe))) {
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
                    Get-ChildItem -LiteralPath $destDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
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
                if ((Find-Tool $v.Exe) -and (-not $v.SubExe -or (Find-Tool $v.SubExe))) { Write-Ok "Cai dat thanh cong: $($v.Exe)" }
                else { Write-Warn2 "Tai xong nhung chua du file chay $($v.Exe) va cong cu di kem" }
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

    # Quet 10 giay dau truoc; quet ca file neu khoang lang chua ket thuc
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

# Thoi luong theo so mau (giay), khong tin pts: file scrcpy co the co khoang trong pts khi thiet bi khong phat tieng.
function Get-SampleDuration {
    param($T, [string]$File)
    $r = Invoke-Exe $T.ffmpeg @('-hide_banner','-i',$File,'-vn','-af','asetpts=N/SR/TB','-f','null','-') -TimeoutMs 120000
    $ms = [regex]::Matches([string]$r.Err, 'time=(\d+):(\d+):(\d+(?:\.\d+)?)')
    if ($r.Code -eq 0 -and $ms.Count -gt 0) {
        $m = $ms[$ms.Count - 1]
        return ([double]$m.Groups[1].Value * 3600.0 + [double]$m.Groups[2].Value * 60.0 + [double]::Parse($m.Groups[3].Value, [cultureinfo]::InvariantCulture))
    }
    return (Get-Duration -T $T -File $File)
}

# scrcpy khong gui goi khi thiet bi im lang => pts co khoang trong, pts la dong ho that. Chuan hoa 1 lan thanh WAV
# (aresample=async=1:first_pts=0 lap khoang trong bang im lang, bat dau tu 0); tren file nay truc mau = truc pts.
# Tra ve @{ Path; FixedSec; SampleSec; ContainerSec; GapFilledSec; Warning } hoac $null neu that bai.
function ConvertTo-FixedRecording {
    param($T, [string]$Rec, [string]$Out)
    $r = Invoke-Exe $T.ffmpeg @('-hide_banner','-loglevel','error','-y','-i',$Rec,'-vn','-af','aresample=async=1:first_pts=0','-c:a','pcm_s16le','-ar','48000',$Out) -TimeoutMs 300000
    if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $Out -PathType Leaf) -or (Get-Item -LiteralPath $Out).Length -le 0) { return $null }
    $sampleSec = Get-SampleDuration -T $T -File $Rec
    $containerSec = Get-Duration -T $T -File $Rec
    $fixedSec = Get-SampleDuration -T $T -File $Out
    $warn = ''
    if ($containerSec -gt 0 -and [Math]::Abs($fixedSec - $containerSec) -gt 0.05) {
        $warn = ('Thoi luong file da lap ({0:0.000}s) lech thoi luong container ({1:0.000}s) hon 0.05s' -f $fixedSec, $containerSec)
    }
    return @{ Path = $Out; FixedSec = $fixedSec; SampleSec = $sampleSec; ContainerSec = $containerSec; GapFilledSec = ($fixedSec - $sampleSec); Warning = $warn }
}

# Onset moi: nguong thich nghi theo nen on va muc noi dung, chi xet tu SearchFrom (= tOpen - tRec - 0.3).
# Tra hashtable @{ Onset; NoiseFloorDb; ThresholdDb; ContentDb; Reason }.
# File vao nen la rec-fixed.wav (truc mau = truc pts tu 0): onset = chi so cua so x 0.02 s, SearchFrom dung thang.
function Get-AudioOnsetInfo {
    param($T, [string]$File, [double]$SearchFrom = 0.0)
    $info = @{ Onset = $null; NoiseFloorDb = $null; ThresholdDb = $null; ContentDb = $null; Reason = 'no-onset' }
    if (-not $T -or -not $T.ffmpeg) { $info.Reason = 'no-ffmpeg'; return $info }
    if ($SearchFrom -lt 0) { $SearchFrom = 0.0 }
    # RMS moi 20 ms: ep 48 kHz, 960 mau / cua so, khong dem, astats reset moi frame.
    $r = Invoke-Exe $T.ffmpeg @('-hide_banner','-nostats','-t','15','-i',$File,'-vn','-af',
        'aformat=channel_layouts=mono,aresample=48000,asetnsamples=n=960:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
        '-f','null','-') -TimeoutMs 90000
    if ($r.Code -ne 0) { $info.Reason = 'analysis-failed'; return $info }

    $levels = New-Object 'System.Collections.Generic.List[double]'
    $inv = [cultureinfo]::InvariantCulture
    foreach ($line in ([string]$r.Out -split "`r?`n")) {
        if ($line -match 'lavfi\.astats\.Overall\.RMS_level=(\S+)') {
            $raw = $Matches[1]
            $lv = -120.0
            if ($raw -notmatch 'inf|nan') {
                if (-not [double]::TryParse($raw, [Globalization.NumberStyles]::Float, $inv, [ref]$lv)) { $lv = -120.0 }
            }
            if ($lv -lt -120.0) { $lv = -120.0 }
            $levels.Add($lv)
        }
    }
    $n = $levels.Count
    if ($n -eq 0) { $info.Reason = 'analysis-empty'; return $info }

    # Cua so dau tien co thoi diem >= SearchFrom = diem bat dau xet (cua so k bat dau o k x 0.02 s).
    $i0 = [int][Math]::Ceiling(($SearchFrom - 0.0005) / 0.02)
    if ($i0 -lt 0) { $i0 = 0 }
    if ($i0 -ge $n) { return $info }

    # Nen on: phan vi 20% cua RMS trong 1.0 s dau (50 cua so) tu diem bat dau, kep [-90, -45].
    $head = New-Object 'System.Collections.Generic.List[double]'
    for ($i = $i0; $i -lt $n -and $i -lt ($i0 + 50); $i++) { $head.Add($levels[$i]) }
    $sorted = @($head | Sort-Object)
    $floor = [double]$sorted[[int][Math]::Floor(0.2 * ($sorted.Count - 1))]
    if ($floor -lt -90.0) { $floor = -90.0 }
    if ($floor -gt -45.0) { $floor = -45.0 }

    # Muc noi dung L = trung vi RMS cac cua so > -100 dB tu diem bat dau den het du lieu (ban thu co the rat nho).
    $content = New-Object 'System.Collections.Generic.List[double]'
    for ($i = $i0; $i -lt $n; $i++) { if ($levels[$i] -gt -100.0) { $content.Add($levels[$i]) } }
    if ($content.Count -eq 0) { $info.NoiseFloorDb = $floor; return $info }
    $csorted = @($content | Sort-Object)
    $L = if ($csorted.Count % 2 -eq 1) { [double]$csorted[[int](($csorted.Count - 1) / 2)] }
         else { ([double]$csorted[$csorted.Count / 2 - 1] + [double]$csorted[$csorted.Count / 2]) / 2.0 }

    $threshold = [Math]::Max($floor + 12.0, $L - 15.0)
    $quietLimit = [Math]::Max($floor + 6.0, $L - 30.0)
    $info.NoiseFloorDb = $floor
    $info.ThresholdDb = $threshold
    $info.ContentDb = $L

    # Ung vien: cua so dau > nguong; trong 8 cua so (160 ms) cho phep toi da 2 cua so hut, moi cho hut <= 2 cua so lien tiep.
    # Loai ung vien dung mau blip: doan active < 400 ms roi >= 300 ms (15 cua so) lien tuc <= muc im lang.
    # Khoang nghi loi noi ngan (< 300 ms) khong bi loai. Ngoai ra can >= 70% cua so > nguong trong 1.0 s sau ung vien.
    $runLen = 8
    $quietNeed = 15
    $minActive = 20
    $start = -1
    $i = $i0
    while (($i + $runLen - 1) -lt $n) {
        if ($levels[$i] -le $threshold) { $i++; continue }
        $dips = 0; $dipRun = 0; $runOk = $true
        for ($k = 0; $k -lt $runLen; $k++) {
            if ($levels[$i + $k] -gt $threshold) { $dipRun = 0 }
            else { $dips++; $dipRun++; if ($dipRun -gt 2 -or $dips -gt 2) { $runOk = $false; break } }
        }
        if (-not $runOk) { $i++; continue }

        # Tim khoang lang dau tien >= 300 ms ke tu ung vien (trong pham vi du de ket luan blip).
        $scanEnd = [Math]::Min($n - 1, $i + $minActive + $quietNeed + 5)
        $quietCount = 0; $quietStart = -1; $quietEnd = -1
        for ($k = $i; $k -le $scanEnd; $k++) {
            if ($levels[$k] -le $quietLimit) {
                $quietCount++
                if ($quietCount -ge $quietNeed -and $quietStart -lt 0) { $quietStart = $k - $quietNeed + 1 }
            } else {
                if ($quietStart -ge 0) { $quietEnd = $k - 1; break }
                $quietCount = 0
            }
        }
        if ($quietStart -ge 0 -and ($quietStart - $i) -lt $minActive) {
            # blip: bo ung vien, tim tiep sau khoang lang
            $i = if ($quietEnd -ge 0) { $quietEnd + 1 } else { $quietStart + $quietNeed }
            while ($i -lt $n -and $levels[$i] -le $quietLimit) { $i++ }
            continue
        }
        $endIdx = [Math]::Min($n - 1, $i + 49)
        $aboveWin = 0
        for ($k = $i; $k -le $endIdx; $k++) { if ($levels[$k] -gt $threshold) { $aboveWin++ } }
        if (($aboveWin / [double]($endIdx - $i + 1)) -lt 0.7) { $i++; continue }
        $start = $i
        break
    }
    if ($start -lt 0) { return $info }

    # Lui ve truoc toi da 300 ms (15 cua so, khong qua diem bat dau xet) qua cac cua so > muc im lang,
    # cho phep bang qua cho hut <= 2 cua so (40 ms) neu truoc do con tieng.
    $j = $start
    while ($j - 1 -ge $i0 -and ($start - $j) -lt 15) {
        $q = $j - 1
        if ($levels[$q] -gt $quietLimit) { $j = $q; continue }
        $dipLen = 0
        while ($q -ge $i0 -and $levels[$q] -le $quietLimit -and $dipLen -lt 3) { $q--; $dipLen++ }
        if ($dipLen -le 2 -and $q -ge $i0 -and $levels[$q] -gt $quietLimit -and ($start - $q) -le 15) { $j = $q; continue }
        break
    }
    $info.Onset = [double]($j * 0.02)
    $info.Reason = 'ok'
    return $info
}
# ------------------------------------------------ dong bo theo hinh (khop khung hinh) ----
# Khop khung hinh man hinh (ban thu scrcpy, cung dong ho voi audio) voi video goc tai ve de tim t0 = thoi diem
# khung 0 cua video goc xuat hien tren truc pts cua file thu. Khong dua vao noi dung audio (long tieng khac audio goc).
$script:KidSyncSource = @'
using System;
using System.IO;

public class KidFrameSync
{
    int N;
    float[][] Ref;
    float[][] Scr;
    public int RefCount { get { return Ref.Length; } }
    public int ScrCount { get { return Scr.Length; } }

    // Moi khung: tru trung binh, chia do lech chuan (null neu gan den hoac phang).
    static float[][] LoadFrames(string path, int n)
    {
        byte[] b = File.ReadAllBytes(path);
        int cnt = b.Length / n;
        float[][] fr = new float[cnt][];
        for (int f = 0; f < cnt; f++)
        {
            double sum = 0; int o = f * n;
            for (int k = 0; k < n; k++) sum += b[o + k];
            double mean = sum / n, ss = 0;
            for (int k = 0; k < n; k++) { double d = b[o + k] - mean; ss += d * d; }
            double sd = Math.Sqrt(ss / n);
            if (sd < 3.0 || mean < 6.0) { fr[f] = null; continue; }
            float[] v = new float[n];
            double inv = 1.0 / (sd * Math.Sqrt(n));
            for (int k = 0; k < n; k++) v[k] = (float)((b[o + k] - mean) * inv);
            fr[f] = v;
        }
        return fr;
    }

    public KidFrameSync(string refPath, string scrPath, int w, int h)
    {
        N = w * h;
        Ref = LoadFrames(refPath, N);
        Scr = LoadFrames(scrPath, N);
    }

    public int ValidRef(int r0, int count)
    {
        int c = 0;
        for (int i = 0; i < count; i++) { int ri = r0 + i; if (ri >= 0 && ri < Ref.Length && Ref[ri] != null) c++; }
        return c;
    }

    // Pearson tren chuoi (pixel x thoi gian) sau khi tru khung trung binh cua cua so: bo nen tinh, giu chuyen dong.
    // Cap (ref[r0+i], scr[r0+i+d]), i buoc theo stride; chi tinh khi ca hai khung hop le.
    public double Score(int r0, int count, int d, int stride, out int used)
    {
        double dot = 0; used = 0;
        float[] sa = new float[N]; float[] sb = new float[N];
        for (int i = 0; i < count; i += stride)
        {
            int ri = r0 + i; int sj = ri + d;
            if (ri < 0 || ri >= Ref.Length || sj < 0 || sj >= Scr.Length) continue;
            float[] a = Ref[ri], b = Scr[sj];
            if (a == null || b == null) continue;
            double s = 0;
            for (int k = 0; k < N; k++) { float x = a[k], y = b[k]; s += x * y; sa[k] += x; sb[k] += y; }
            dot += s; used++;
        }
        if (used < 2) return -1.0;
        double saa = 0, sbb = 0, sab = 0;
        for (int k = 0; k < N; k++) { saa += sa[k] * sa[k]; sbb += sb[k] * sb[k]; sab += sa[k] * sb[k]; }
        double u = used;
        double va = u - saa / u, vb = u - sbb / u;
        if (va <= 1e-6 || vb <= 1e-6) return -1.0;
        return (dot - sab / u) / Math.Sqrt(va * vb);
    }

    // Tra ve [dSub, peak, second, dInt, used]. second = dinh cao nhat cach dinh chinh >= excl khung.
    // d tinh bang khung 30 fps; dSub la noi suy parabol quanh dinh.
    public double[] Match(int r0, int count, int dMin, int dMax, int minUsed, int excl, int stride)
    {
        if (dMin < 0) dMin = 0;
        if (stride < 1) stride = 1;
        int n = dMax - dMin + 1;
        if (n < 1) return new double[] { 0, -1, -1, 0, 0 };
        double[] sc = new double[n]; int[] us = new int[n];
        for (int d = dMin; d <= dMax; d++)
        {
            int u; double s = Score(r0, count, d, stride, out u);
            if (u < minUsed) s = -1.0;
            sc[d - dMin] = s; us[d - dMin] = u;
        }
        int best = 0;
        for (int k = 1; k < n; k++) if (sc[k] > sc[best]) best = k;
        double second = -1.0;
        for (int k = 0; k < n; k++) if (Math.Abs(k - best) >= excl && sc[k] > second) second = sc[k];
        double sub = best;
        if (best > 0 && best < n - 1 && sc[best - 1] > -1.0 && sc[best + 1] > -1.0)
        {
            double y0 = sc[best - 1], y1 = sc[best], y2 = sc[best + 1];
            double den = y0 - 2 * y1 + y2;
            if (Math.Abs(den) > 1e-9) { double off = 0.5 * (y0 - y2) / den; if (off > -1 && off < 1) sub = best + off; }
        }
        return new double[] { dMin + sub, sc[best], second, dMin + best, us[best] };
    }
}
'@

# Hinh hoc khung: Scr/Ref la bo loc crop (ty le theo iw/ih). 'fit' = vung giua man hinh Facebook Reel (bo thanh tren/duoi, cot nut ben phai);
# video hien tren man hinh 720x1280 lech len ~4% so voi video goc (do thuc nghiem tren LDPlayer), nen vung Ref doi xuong 0.04.
# 'mid' = cung vung crop hai ben; 'full' = khong crop. Thu lan luot, lay hinh hoc dau tien dat nguong.
$script:KidSyncGeoms = @(
    @{ Name = 'fit';  W = 24; H = 42; Scr = 'crop=iw*0.80:ih*0.60:iw*0.02:ih*0.10'; Ref = 'crop=iw*0.80:ih*0.60:iw*0.02:ih*0.14' },
    @{ Name = 'mid';  W = 24; H = 42; Scr = 'crop=iw*0.80:ih*0.60:iw*0.02:ih*0.10'; Ref = 'crop=iw*0.80:ih*0.60:iw*0.02:ih*0.10' },
    @{ Name = 'full'; W = 32; H = 56; Scr = ''; Ref = '' }
)

# Mot lan giai ma, tao raw gray 30 fps cho moi hinh hoc. Khung k = thoi diem k/30 s tren truc pts cua file vao
# (fps start_time=0 dem khung dau neu video bat dau muon; rawvideo khong doi pts).
function New-FrameSignatures {
    param($T, [string]$File, [string]$Side, $Geoms, [string]$Work)
    $n = $Geoms.Count
    $labels = ''
    for ($i = 0; $i -lt $n; $i++) { $labels += "[s$i]" }
    $fc = "[0:v:0]fps=30:start_time=0,split=$n$labels"
    $paths = @()
    for ($i = 0; $i -lt $n; $i++) {
        $g = $Geoms[$i]
        $crop = [string]$g[$Side]
        $chain = if ($crop) { $crop + ',' } else { '' }
        $fc += (";[s$i]" + $chain + 'scale=' + $g.W + ':' + $g.H + ':flags=area,format=gray' + "[o$i]")
        $paths += (Join-Path $Work ("sig-$Side-" + $g.Name + '.raw'))
    }
    $a = @('-hide_banner','-loglevel','error','-y','-i',$File,'-an','-filter_complex',$fc)
    for ($i = 0; $i -lt $n; $i++) { $a += @('-map',"[o$i]",'-f','rawvideo',$paths[$i]) }
    $r = Invoke-Exe $T.ffmpeg $a -TimeoutMs 600000
    if ($r.Code -ne 0) { return @{ Ok = $false; Err = [string]$r.Err } }
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -le 0) { return @{ Ok = $false; Err = ('Khong co du lieu khung: ' + $p) } }
    }
    return @{ Ok = $true; Paths = $paths }
}

# Danh gia mot hinh hoc: khop toan bo video goc -> d toan cuc (do tin cay), cac cua so 1.5 s -> cac "bac" d (player Facebook co the
# dung hinh vai tram ms trong khi audio van chay => d tang theo bac), kiem tra dau video co tren man hinh.
# D tra ve = bac thap nhat dang tin (audio la dong ho chu, hinh chi co the tre them), khong co bac => d toan cuc.
function Measure-FrameSync {
    param($K)
    $inv = [cultureinfo]::InvariantCulture
    $o = @{ Ok = $false; Reason = ''; Geometry = ''; D = $null; DGlobal = $null; Peak = $null; Ratio = $null; StartPeak = $null; StartVisible = $null; DriftMs = $null; SegText = ''; Plateaus = '' }
    $refN = $K.RefCount; $scrN = $K.ScrCount
    if ($refN -lt 60 -or $scrN -lt 60) { $o.Reason = 'too-few-frames'; return $o }
    $validRef = $K.ValidRef(0, $refN)
    if ($validRef -lt 45) { $o.Reason = 'ref-no-signal'; return $o }
    $minUsed = [int][Math]::Max(30, [Math]::Floor(0.5 * $validRef))
    # Tho (buoc 3 khung) toan khoang, roi tinh chinh +-4 khung buoc 1.
    $coarse = $K.Match(0, $refN, 0, ($scrN - 1), [int][Math]::Max(10, [Math]::Floor($minUsed / 3)), 10, 3)
    if ($coarse[1] -le 0) { $o.Reason = 'no-match'; $o.Peak = [Math]::Round($coarse[1], 3); return $o }
    $dc = [int]$coarse[3]
    $fine = $K.Match(0, $refN, ($dc - 4), ($dc + 4), $minUsed, 2, 1)
    if ($fine[1] -le 0) { $o.Reason = 'no-match'; return $o }
    $o.DGlobal = [double]$fine[0]
    $o.Peak = [double]$fine[1]
    $o.Ratio = [Math]::Min(10.0, [double]$coarse[1] / [Math]::Max(0.01, [double]$coarse[2]))
    $dg = [int][Math]::Round($o.DGlobal)
    $o.D = $o.DGlobal

    # Cua so 1.5 s (45 khung), buoc 0.5 s, tim d cuc bo trong +-30 khung quanh d toan cuc; giu cua so dang tin (dinh >= 0.65, ty le >= 1.25).
    $wl = [int][Math]::Min(45, [Math]::Floor($refN / 3))
    $locals = New-Object 'System.Collections.Generic.List[double]'
    $startConf = 0
    if ($wl -ge 30) {
        for ($r0 = 0; $r0 -le ($refN - $wl); $r0 += 15) {
            $m = $K.Match($r0, $wl, ($dg - 30), ($dg + 30), [int]($wl * 0.5), 8, 1)
            if ($m[1] -ge 0.65 -and ($m[1] / [Math]::Max(0.01, $m[2])) -ge 1.25) {
                $locals.Add([double]$m[0])
                if ($r0 -ge 30 -and $r0 -le 60) { $startConf++ }
            }
        }
    }
    # Gom d thanh bac (neo = gia tri thap nhat, dung sai 2.5 khung ~ 83 ms); bac hop le can >= 2 cua so dang tin.
    $sortedD = @($locals | Sort-Object)
    $plateaus = New-Object 'System.Collections.Generic.List[double]'
    $cur = New-Object 'System.Collections.Generic.List[double]'
    foreach ($v in $sortedD) {
        if ($cur.Count -gt 0 -and ($v - $cur[0]) -gt 2.5) {
            if ($cur.Count -ge 2) { $plateaus.Add([double]$cur[[int][Math]::Floor($cur.Count / 2)]) }
            $cur = New-Object 'System.Collections.Generic.List[double]'
        }
        $cur.Add([double]$v)
    }
    if ($cur.Count -ge 2) { $plateaus.Add([double]$cur[[int][Math]::Floor($cur.Count / 2)]) }
    if ($plateaus.Count -ge 1) {
        $dLow = [double]$plateaus[0]
        if ($dLow -ge ($o.DGlobal - 40.0)) { $o.D = $dLow }
        $o.DriftMs = [Math]::Round(([double]$plateaus[$plateaus.Count - 1] - [double]$plateaus[0]) / 30.0 * 1000.0, 1)
        $o.Plateaus = (($plateaus | ForEach-Object { [string]::Format($inv, '{0:0.0}', $_) }) -join ' ')
    }
    $dUse = [int][Math]::Round($o.D)

    # Dau video co hien tren man hinh khong? Xet doan 1.0-3.5 s (bo giay dau: Facebook hay giu khung dau/hieu ung nap): can >= 2 trong
    # 3 cua so bat dau 1.0/1.5/2.0 s khop dang tin. Reel tiep tuc tu giua => doan nay khong co tren man hinh.
    # Neu doan nay cua video goc toi/phang (it khung hop le) thi khong ket luan duoc (coi la hien).
    if ($wl -ge 30 -and $refN -ge 105) {
        if ($K.ValidRef(30, 75) -ge 23) { $o.StartVisible = ($startConf -ge 2) }
        $sc = $K.Match(30, 75, ($dUse - 6), ($dUse + 20), 10, 2, 1)
        if ($sc[1] -gt -1.0) { $o.StartPeak = [double]$sc[1] }
    }

    # Chan doan: 3 doan (dau, giua, cuoi) toi da 4 s, d tung doan so voi D (ms); 'n/a' neu doan khong khop dang tin.
    $sl = [int][Math]::Min(120, [Math]::Floor($refN / 3))
    if ($sl -ge 30) {
        $txt = @()
        foreach ($s0 in @(0, [int][Math]::Floor(($refN - $sl) / 2), ($refN - $sl))) {
            $m = $K.Match($s0, $sl, ($dUse - 10), ($dUse + 30), [int]($sl / 3), 4, 1)
            if ($m[1] -ge 0.5) { $txt += ([string]::Format($inv, '{0:0.0}', ([double]$m[0] - $o.D) / 30.0 * 1000.0)) } else { $txt += 'n/a' }
        }
        $o.SegText = ($txt -join '/')
    }
    $o.Ok = $true
    return $o
}

# Tra ve @{ Ok; Reason; T0; Peak; Ratio; Geometry; StartPeak; DriftMs; SegText; Plateaus; DGlobalSec; ElapsedSec }.
# Ok=$true khi dinh >= 0.6 va ty le >= 1.15 va dau video hien tren man hinh.
# Reason='start-missing' khi khop tin cay nhung dau video khong co trong ban thu (Reel chay tiep tu giua).
function Find-VideoSyncOffset {
    param($T, [string]$RefVideo, [string]$RecFile, [string]$Work)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = @{ Ok = $false; Reason = 'unknown'; T0 = $null; Peak = $null; Ratio = $null; Geometry = ''; StartPeak = $null; DriftMs = $null; SegText = ''; Plateaus = ''; DGlobalSec = $null; ElapsedSec = 0.0 }
    try {
        if (-not $T.ffmpeg -or -not $T.ffprobe) { $out.Reason = 'no-ffmpeg'; return $out }
        $pv = Invoke-Exe $T.ffprobe @('-v','error','-select_streams','v:0','-show_entries','stream=codec_type','-of','csv=p=0',$RecFile) -TimeoutMs 30000
        if ($pv.Code -ne 0 -or ([string]$pv.Out) -notmatch 'video') { $out.Reason = 'rec-no-video'; return $out }
        if (-not ('KidFrameSync' -as [type])) { Add-Type -TypeDefinition $script:KidSyncSource -Language CSharp -ErrorAction Stop }
        $geoms = $script:KidSyncGeoms
        $refSig = New-FrameSignatures -T $T -File $RefVideo -Side 'Ref' -Geoms $geoms -Work $Work
        if (-not $refSig.Ok) { $out.Reason = 'ref-decode-failed'; Write-Warn2 ('Giai ma video goc de khop hinh loi: ' + $refSig.Err); return $out }
        $scrSig = New-FrameSignatures -T $T -File $RecFile -Side 'Scr' -Geoms $geoms -Work $Work
        if (-not $scrSig.Ok) { $out.Reason = 'rec-decode-failed'; Write-Warn2 ('Giai ma hinh man hinh de khop hinh loi: ' + $scrSig.Err); return $out }
        $best = $null
        for ($i = 0; $i -lt $geoms.Count; $i++) {
            $g = $geoms[$i]
            $k = New-Object KidFrameSync($refSig.Paths[$i], $scrSig.Paths[$i], [int]$g.W, [int]$g.H)
            $m = Measure-FrameSync -K $k
            $m.Geometry = $g.Name
            if (-not $m.Ok) { if ($null -eq $best) { $best = $m }; continue }
            if ($null -eq $best -or -not $best.Ok -or $m.Peak -gt $best.Peak) { $best = $m }
            if ($m.Peak -ge 0.6 -and $m.Ratio -ge 1.15) { $best = $m; break }
        }
        if ($null -eq $best -or -not $best.Ok) { $out.Reason = if ($best) { 'match-' + $best.Reason } else { 'no-geometry' }; return $out }
        $out.Geometry = $best.Geometry; $out.Peak = [Math]::Round($best.Peak, 3); $out.Ratio = [Math]::Round($best.Ratio, 2)
        $out.StartPeak = if ($null -ne $best.StartPeak) { [Math]::Round($best.StartPeak, 3) } else { $null }
        $out.DriftMs = $best.DriftMs; $out.SegText = $best.SegText; $out.Plateaus = $best.Plateaus; $out.DGlobalSec = [Math]::Round($best.DGlobal / 30.0, 3)
        if ($best.Peak -lt 0.6 -or $best.Ratio -lt 1.15) {
            $out.Reason = [string]::Format([cultureinfo]::InvariantCulture, 'low-confidence peak={0:0.000} ratio={1:0.00}', $best.Peak, $best.Ratio)
            return $out
        }
        $out.T0 = [Math]::Round($best.D / 30.0, 3)
        if ($best.StartVisible -eq $false) { $out.Reason = 'start-missing'; return $out }
        $out.Ok = $true; $out.Reason = 'ok'
        return $out
    } catch {
        $out.Reason = 'exception'
        Write-Warn2 ('Khop khung hinh loi: ' + $_.Exception.Message)
        return $out
    } finally {
        $out.ElapsedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    }
}

# ------------------------------------------------------------ thao tac app ----
function Open-Reel {
    param($T, [string]$Url)
    $r = Invoke-Adb $T @('shell','am','start','-a','android.intent.action.VIEW','-d', (Quote-AndroidArg $Url),'-n',"$($script:Fb)/.IntentUriHandler")
    if ($r.Code -ne 0 -or "$($r.Out)$($r.Err)" -match 'Error|does not exist') {
        $r = Invoke-Adb $T @('shell','am','start','-a','android.intent.action.VIEW','-d', (Quote-AndroidArg $Url),$script:Fb)
    }
    if ($r.Code -ne 0 -or "$($r.Out)$($r.Err)" -match 'Error|does not exist') { throw 'Khong mo duoc Reel tren Facebook; khong xac nhan ngon ngu.' }
    return $r
}

function Get-VisibleUiBounds {
    param([System.Xml.XmlNode]$Node)
    $rect = $null
    for ($current = $Node; $current -and $current -is [System.Xml.XmlElement]; $current = $current.ParentNode) {
        $bounds = $current.GetAttribute('bounds')
        if (-not $bounds) { continue }
        $match = [regex]::Match($bounds, '^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$')
        if (-not $match.Success) { return $null }
        $b = @([int]$match.Groups[1].Value,[int]$match.Groups[2].Value,[int]$match.Groups[3].Value,[int]$match.Groups[4].Value)
        if ($b[2] -le $b[0] -or $b[3] -le $b[1]) { return $null }
        if (-not $rect) { $rect = $b }
        else { $rect = @([Math]::Max($rect[0],$b[0]),[Math]::Max($rect[1],$b[1]),[Math]::Min($rect[2],$b[2]),[Math]::Min($rect[3],$b[3])) }
    }
    if (-not $rect -or $rect[2]-$rect[0] -lt 16 -or $rect[3]-$rect[1] -lt 16) { return $null }
    return [pscustomobject]@{X=[int](($rect[0]+$rect[2])/2);Y=[int](($rect[1]+$rect[3])/2);Left=$rect[0];Top=$rect[1];Right=$rect[2];Bottom=$rect[3]}
}

function Get-DubbingVietnameseChoice {
    param([string]$Xml)
    try {
        [xml]$document = $Xml
        $nodes = @($document.SelectNodes('//node[@package="com.facebook.katana"]'))
        if (-not @($nodes | Where-Object { ($_.GetAttribute('text')+' '+$_.GetAttribute('content-desc')).Trim() -match '^(Âm thanh và ngôn ngữ|Audio and languages?)(?:\s|$)' }).Count) { return $null }
        $rows = @($nodes | Where-Object { $_.GetAttribute('checkable') -eq 'true' -and ($_.GetAttribute('text')+$_.GetAttribute('content-desc')).Trim() })
        $vietnamese = '^(Tiếng Việt|Vietnamese)(?:$|[\s·,:(])'
        $otherSelected = @($rows | Where-Object { $_.GetAttribute('checked') -eq 'true' -and ($_.GetAttribute('text')+' '+$_.GetAttribute('content-desc')).Trim() -notmatch $vietnamese })
        foreach ($row in $rows) {
            $label = ($row.GetAttribute('text')+' '+$row.GetAttribute('content-desc')).Trim()
            if ($label -notmatch $vietnamese -or $label -match 'không.*(hỗ trợ|khả dụng)|not available|unavailable|not supported' -or $row.GetAttribute('enabled') -eq 'false') { continue }
            $bounds = Get-VisibleUiBounds -Node $row
            if (-not $bounds) { continue }
            return [pscustomobject]@{X=$bounds.X;Y=$bounds.Y;Label=$label;Selected=($row.GetAttribute('checked') -eq 'true' -and $otherSelected.Count -eq 0);Clickable=($row.GetAttribute('clickable') -eq 'true')}
        }
    } catch { }
    return $null
}

# Tim phan tu giao dien dong dua tren content-desc hoac text
function Get-UiNodeBounds {
    param($T, [string[]]$Patterns, [switch]$SnapshotOnly)
    $xmlLocal = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-ui-" + [Guid]::NewGuid().ToString('N').Substring(0,6) + ".xml")
    $remoteXml = '/sdcard/kidfby-ui-'+[guid]::NewGuid().ToString('N')+'.xml'
    $found = $null
    try {
        $dump = Invoke-Adb $T @('shell','uiautomator','dump',$remoteXml)
        if ($dump.Code -ne 0) { return $null }
        $pull = Invoke-Adb $T @('pull',$remoteXml,$xmlLocal)
        if ($pull.Code -ne 0 -or -not (Test-Path -LiteralPath $xmlLocal)) { return $null }
        [xml]$xml = Get-Content -LiteralPath $xmlLocal -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($SnapshotOnly) { return $xml.OuterXml }
        $nodes = $xml.SelectNodes("//node")
        foreach ($n in $nodes) {
            $desc = "$($n.GetAttribute('content-desc'))"
            $text = "$($n.GetAttribute('text'))"
            $combined = "$desc $text".Trim()
            foreach ($pat in $Patterns) {
                if ($combined -match $pat) {
                    if ($n.GetAttribute('package') -ne $script:Fb -or $n.GetAttribute('enabled') -eq 'false') { continue }
                    $visible = Get-VisibleUiBounds -Node $n
                    if (-not $visible) { continue }
                    $found = [pscustomobject]@{ X=$visible.X; Y=$visible.Y; Text=$text; Desc=$desc; Bounds=$n.GetAttribute('bounds') }
                    break
                }
            }
            if ($found) { break }
        }
    } catch { }
    finally {
        Remove-Item -LiteralPath $xmlLocal -Force -ErrorAction SilentlyContinue
        $null = Invoke-Adb $T @('shell','rm','-f',$remoteXml)
    }
    return $found
}

function Get-DubbingMenuState {
    param([string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return 'unknown' }
    try {
        [xml]$document = $Xml
        $nodes = @($document.SelectNodes('//node[@package="com.facebook.katana"]'))
        if (-not $nodes.Count) { return 'unknown' }
        $labels = @($nodes | ForEach-Object {
            if ($_.GetAttribute('text')) { $_.GetAttribute('text').Trim() } else { $_.GetAttribute('content-desc').Trim() }
        })
        if (-not @($labels | Where-Object { $_ -match '^(Âm thanh và ngôn ngữ|Audio and languages?)$' }).Count) { return 'unknown' }
        $allChoices = @($nodes | Where-Object { $_.GetAttribute('checkable') -eq 'true' })
        $choices = @($allChoices | Where-Object { -not [string]::IsNullOrWhiteSpace(($_.GetAttribute('text')+$_.GetAttribute('content-desc'))) })
        if (@($choices | Where-Object { ($_.GetAttribute('text')+' '+$_.GetAttribute('content-desc')).Trim() -match '^(Tiếng Việt|Vietnamese)(?:[\s·:(]|$)' }).Count) { return 'vietnamese-visible' }
        # Absence is only conclusive for a complete, non-scrolling menu with a
        # selected original-only track and the translation availability footer.
        if (@($nodes | Where-Object { $_.GetAttribute('scrollable') -eq 'true' }).Count) { return 'unknown' }
        $footer = @($labels | Where-Object { $_ -match '^Tính năng dịch giọng nói hiện chưa hỗ trợ tất cả các ngôn ngữ\.|^Voice translations.*(support|available)' })
        if ($choices.Count -eq 1 -and $choices[0].GetAttribute('checked') -eq 'true' -and $footer.Count -gt 0) {
            $label = if ($choices[0].GetAttribute('text')) { $choices[0].GetAttribute('text').Trim() } else { $choices[0].GetAttribute('content-desc').Trim() }
            if ($label -match '(^|[·:]\s*)(Âm thanh gốc|Original audio)$') {
                foreach ($choice in $allChoices) {
                    $parent = $choice
                    while ($parent -and -not [object]::ReferenceEquals($parent,$choices[0])) { $parent = $parent.ParentNode }
                    if (-not $parent) { return 'unknown' }
                }
                return 'original-only'
            }
        }
    } catch { return 'unknown' }
    return 'unknown'
}

function Get-ReelOptionsMenuState {
    param([string]$Xml)
    try {
        [xml]$document = $Xml
        $windowRoot = $document.SelectSingleNode('/hierarchy/node')
        if (-not $windowRoot -or $windowRoot.GetAttribute('package') -ne 'com.facebook.katana') { return $null }
        $nodes = @($document.SelectNodes('//node[@package="com.facebook.katana"]'))
        if (-not $nodes.Count) { return $null }
        $close = $false; $anchors = 0; $selector = $null; $hiddenSelector = $false; $hasSpeed = $false; $hasQuality = $false
        $rows = New-Object 'System.Collections.Generic.List[string]'
        foreach ($node in $nodes) {
            $label = if ($node.GetAttribute('content-desc')) { $node.GetAttribute('content-desc').Trim() } else { $node.GetAttribute('text').Trim() }
            $isSelector = $label -match '^(Âm thanh và ngôn ngữ|Audio and languages?)(?:$|\s)'
            if ($isSelector) { $hiddenSelector = $true }
            $visible = Get-VisibleUiBounds -Node $node
            if (-not $visible) { continue }
            if ($node.GetAttribute('class') -match 'ProgressBar' -or $label -match '^(Đang tải|Loading)(?:\s|[.….]|$)') { return $null }
            if ($node.GetAttribute('clickable') -ne 'true' -or $node.GetAttribute('enabled') -eq 'false') { continue }
            if ($label -match '^(Đóng|Close)$') { $close = $true }
            if ($label -match '^(Tốc độ phát lại|Playback speed)$') { $hasSpeed = $true }
            if ($label -match '^(Cài đặt chất lượng|Quality settings?)$') { $hasQuality = $true }
            if ($label -match '^(Tốc độ phát lại|Playback speed|Cài đặt chất lượng|Quality settings?|Phụ đề|Captions|Chế độ rõ ràng|Clear mode|Tự động cuộn|Auto.?scroll|Bản chép lời|Transcript)(?:$|\s)') { $anchors++ }
            if ($label -match '^(Âm thanh và ngôn ngữ|Audio and languages?)(?:$|\s)') { $selector = [pscustomobject]@{X=$visible.X;Y=$visible.Y} }
            if ($label) { $rows.Add($label+'@'+$node.GetAttribute('bounds')) }
        }
        if (-not $close -or $anchors -lt 1) { return $null }
        $scroll = $null
        foreach ($node in $nodes | Where-Object { $_.GetAttribute('scrollable') -eq 'true' }) {
            $scroll = Get-VisibleUiBounds -Node $node
            if ($scroll) { break }
        }
        return [pscustomobject]@{Selector=$selector;HasSelectorNode=$hiddenSelector;StartVisible=($hasSpeed -and $hasQuality);Anchors=$anchors;Signature=($rows -join '|');Scroll=$scroll}
    } catch { return $null }
}

# Tom tat text cac node Facebook tren mot man hinh (chi de ghi bang chung loai video).
function Get-UiTextSummary {
    param([string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return '(khong doc duoc man hinh)' }
    try {
        [xml]$document = $Xml
        $labels = New-Object 'System.Collections.Generic.List[string]'
        foreach ($node in @($document.SelectNodes('//node[@package="com.facebook.katana"]'))) {
            $label = [string]$node.GetAttribute('text')
            if (-not $label) { $label = [string]$node.GetAttribute('content-desc') }
            $label = ($label.Trim() -replace '\s+', ' ')
            if (-not $label) { continue }
            if ($label.Length -gt 40) { $label = $label.Substring(0,40) }
            if (-not $labels.Contains($label)) { $labels.Add($label) }
            if ($labels.Count -ge 20) { break }
        }
        return ($labels -join ' | ')
    } catch {
        return ('(xml loi: ' + $_.Exception.Message + ')')
    }
}

# Chuoi bang chung: moi lan doc menu (thoi diem + text da thay) + so lan doc.
function Format-DubbingEvidence {
    param([string]$Kind, $Reads)
    $arr = @($Reads)
    $inv = [cultureinfo]::InvariantCulture
    if ($arr.Count -eq 0) { return "kind=$Kind; reads=0" }
    $span = [double]$arr[$arr.Count - 1].T - [double]$arr[0].T
    $parts = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $arr.Count; $i++) {
        $text = [string]$arr[$i].Text
        if ($text.Length -gt 300) { $text = $text.Substring(0,300) }
        $parts.Add([string]::Format($inv, '#{0} t={1:0.00}s: {2}', ($i + 1), [double]$arr[$i].T, $text))
    }
    return ([string]::Format($inv, 'kind={0}; reads={1}; span={2:0.0}s; ', $Kind, $arr.Count, $span) + ($parts -join ' || '))
}

# Doc lai nhieu lan, chi coi la on dinh khi >= Count lan cung Key (khac rong) tren >= MinSpanSec giay.
# Initial = lan doc dau (t=0) da lam truoc khi goi. Reader tra ve @{Key;Text} hoac $null.
function Confirm-StableReads {
    param([scriptblock]$Reader, $Initial, [int]$Count = 3, [double]$MinSpanSec = 2.0, [int]$IntervalMs = 1000, [int]$MaxReads = 6)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $reads = New-Object 'System.Collections.Generic.List[object]'
    $reads.Add([pscustomobject]@{ T = 0.0; Key = [string]$Initial.Key; Text = [string]$Initial.Text })
    while ($true) {
        $span = [double]$reads[$reads.Count - 1].T - [double]$reads[0].T
        if ($reads.Count -ge $Count -and $span -ge $MinSpanSec) { break }
        if ($reads.Count -ge $MaxReads) { break }
        Start-Sleep -Milliseconds $IntervalMs
        $r = & $Reader
        $key = if ($r) { [string]$r.Key } else { '' }
        $text = if ($r) { [string]$r.Text } else { '(khong doc duoc)' }
        $reads.Add([pscustomobject]@{ T = $sw.Elapsed.TotalSeconds; Key = $key; Text = $text })
        if ($key -ne [string]$reads[0].Key) { break }
    }
    $arr = $reads.ToArray()
    $span = [double]$arr[$arr.Count - 1].T - [double]$arr[0].T
    $same = $true
    foreach ($x in $arr) { if (-not $x.Key -or $x.Key -ne $arr[0].Key) { $same = $false } }
    return [pscustomobject]@{ Stable = ($same -and $arr.Count -ge $Count -and $span -ge $MinSpanSec); Reads = $arr; SpanSec = $span }
}

function Find-ReelLanguageSelector {
    param($T)
    $recognizedStart = $false; $hasScrolled = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $streak = New-Object 'System.Collections.Generic.List[object]'
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $xml = Get-UiNodeBounds -T $T -SnapshotOnly
        $state = Get-ReelOptionsMenuState -Xml $xml
        if (-not $state) { $streak.Clear(); Start-Sleep -Milliseconds 1000; continue }
        if ($state.Selector) { return [pscustomobject]@{Status='available';Node=$state.Selector;Evidence=''} }
        if (-not $hasScrolled -and $state.StartVisible) { $recognizedStart = $true }
        # Absence needs >= 3 consistent complete reads (same visible rows) spanning >= 2.0 s.
        # Missing/damaged/loading snapshots or changing rows never prove absence.
        if ($recognizedStart -and -not $state.HasSelectorNode) {
            if ($streak.Count -gt 0 -and $streak[0].Sig -ne $state.Signature) { $streak.Clear() }
            $streak.Add([pscustomobject]@{ T = $sw.Elapsed.TotalSeconds; Sig = [string]$state.Signature; Text = (Get-UiTextSummary -Xml $xml) })
            $streakSpan = [double]$streak[$streak.Count - 1].T - [double]$streak[0].T
            if ($streak.Count -ge 3 -and $streakSpan -ge 2.0) {
                Write-Note ('DUB_NO_SELECTOR: {0} lan doc menu ba cham day du on dinh trong {1:0.0}s khong co bo chon am thanh/ngon ngu.' -f $streak.Count, $streakSpan)
                return [pscustomobject]@{Status='unavailable';Node=$null;Evidence=(Format-DubbingEvidence -Kind 'no-selector' -Reads $streak.ToArray())}
            }
        } else {
            $streak.Clear()
        }
        if ($state.Scroll) {
            $from = [int]($state.Scroll.Top+($state.Scroll.Bottom-$state.Scroll.Top)*0.8)
            $to = [int]($state.Scroll.Top+($state.Scroll.Bottom-$state.Scroll.Top)*0.2)
            $swipe = Invoke-Adb $T @('shell','input','swipe',"$($state.Scroll.X)","$from","$($state.Scroll.X)","$to",'400')
            if ($swipe.Code -ne 0) { return [pscustomobject]@{Status='unverified';Node=$null;Evidence=''} }
            $hasScrolled = $true
        }
        Start-Sleep -Milliseconds 1000
    }
    return [pscustomobject]@{Status='unverified';Node=$null;Evidence=''}
}

# Meta closes the language sheet after applying a language. A successful tap alone
# is insufficient: require two fresh, recognizable Reel screens after that tap.
function Test-DubbingReturnedToReel {
    param([string]$Xml)
    try {
        [xml]$document = $Xml
        $nodes = @($document.SelectNodes('//node[@package="com.facebook.katana"]'))
        if (@($nodes | Where-Object { ($_.GetAttribute('text')+' '+$_.GetAttribute('content-desc')).Trim() -match '^(Âm thanh và ngôn ngữ|Audio and languages?)(?:\s|$)' }).Count) { return $false }
        $hasMore = $false; $hasReel = $false
        foreach ($node in $nodes) {
            if ($node.GetAttribute('enabled') -eq 'false' -or -not (Get-VisibleUiBounds -Node $node)) { continue }
            $label = ($node.GetAttribute('text')+' '+$node.GetAttribute('content-desc')).Trim()
            if ($node.GetAttribute('clickable') -eq 'true' -and $label -match '^(Khác(?:\s+Khác)?|More(?: options)?(?:\s+More(?: options)?)?|Options)$') { $hasMore = $true }
            if ($label -match '^(Reels(?:\s+Reels)?|Chi tiết về thước phim|Reel details)$') { $hasReel = $true }
        }
        return ($hasMore -and $hasReel)
    } catch { return $false }
}

function Ensure-VietnameseDubbing {
    param($T, [string]$Url)
    $dubbingUiStatus = 'unverified'
    $script:LastDubbingEvidence = ''
    Write-Step 4 'Kiem tra che do long tieng Viet (Meta AI)'
    
    # Tang am luong media thiet bi len muc toi da
    $null = Invoke-Adb $T @('shell','media','volume','--stream','3','--set','15')
    
    # Force-stop Facebook truoc de xoa sach moi hop thoai/binh luan cu
    $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
    Start-Sleep -Milliseconds 600

    # Mo reel de kiem tra giao dien
    $null = Open-Reel $T $Url
    Start-Sleep -Seconds 3

    # Wait for the Reel button, not a feed post's "more options for ..." action.
    $moreNode = $null
    for ($wait = 0; $wait -lt 4 -and -not $moreNode; $wait++) {
        $moreNode = Get-UiNodeBounds -T $T -Patterns @('^Khác(?:\s+Khác)?$','^More(?: options)?(?:\s+More(?: options)?)?$','^Options$')
        if (-not $moreNode) { Start-Sleep -Milliseconds 700 }
    }
    if ($moreNode) {
        Write-Ok "Tim thay nut tuy chon tai ($($moreNode.X), $($moreNode.Y))"
        $tap = Invoke-Adb $T @('shell','input','tap', "$($moreNode.X)", "$($moreNode.Y)")
        if ($tap.Code -ne 0) { return 'unverified' }
    } else {
        Write-Warn2 'DUB_UNVERIFIED: Khong tim thay nut tuy chon; dung truoc thu/tai, khong cham toa do doan.'
        $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
        return 'unverified'
    }
    Start-Sleep -Milliseconds 1500

    # Tim muc "Am thanh va ngon ngu" trong menu vua mo
    $selector = Find-ReelLanguageSelector -T $T
    $audioMenuNode = $selector.Node
    if ($selector.Status -eq 'available' -and $audioMenuNode) {
        Write-Ok "Tim thay muc Am thanh va ngon ngu tai ($($audioMenuNode.X), $($audioMenuNode.Y))"
        $tap = Invoke-Adb $T @('shell','input','tap', "$($audioMenuNode.X)", "$($audioMenuNode.Y)")
        if ($tap.Code -ne 0) { return 'unverified' }
    } else {
        $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
        if ($selector.Status -eq 'unavailable') { $script:LastDubbingEvidence = [string]$selector.Evidence; return 'unavailable' }
        Write-Warn2 'DUB_UNVERIFIED: Chua doc duoc menu ba cham day du; dung truoc thu/tai, chua loai vinh vien.'
        return 'unverified'
    }
    Start-Sleep -Milliseconds 1500

    $menuSnapshot = Get-UiNodeBounds -T $T -SnapshotOnly
    if ((Get-DubbingMenuState -Xml $menuSnapshot) -eq 'original-only') {
        # Chi ket luan 'unavailable' khi >= 3 lan doc nhat quan trai tren >= 2.0 s; neu khong thi di tiep
        # luong chon binh thuong (khong bao gio ghi loai).
        $initialRead = [pscustomobject]@{ Key = 'original-only'; Text = (Get-UiTextSummary -Xml $menuSnapshot) }
        $stateReader = {
            $xmlNow = Get-UiNodeBounds -T $T -SnapshotOnly
            [pscustomobject]@{ Key = [string](Get-DubbingMenuState -Xml $xmlNow); Text = (Get-UiTextSummary -Xml $xmlNow) }
        }
        $stable = Confirm-StableReads -Reader $stateReader -Initial $initialRead
        if ($stable.Stable) {
            Write-Note ('DUB_UNAVAILABLE: {0} lan doc menu hoan chinh trong {1:0.0}s deu chi co Am thanh goc; khong co ban dich.' -f @($stable.Reads).Count, $stable.SpanSec)
            $script:LastDubbingEvidence = Format-DubbingEvidence -Kind 'original-only' -Reads $stable.Reads
            $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
            return 'unavailable'
        }
        Write-Warn2 'DUB_UNVERIFIED: Cac lan doc menu khong nhat quan; khong ket luan khong co ban dich.'
    }
    $unavailablePatterns = @('Ti[e\u00ea\u1ebf]ng Vi[e\u00ea\u1ec7]t.*kh[o\u00f4]ng (kh[a\u1ea3] d[u\u1ee5]ng|[d\u0111][u\u01b0][o\u1ee3]c h[o\u1ed7] tr[o\u1ee3])', 'Vietnamese.*(not available|unavailable|not supported)')
    $unavailable = Get-UiNodeBounds -T $T -Patterns $unavailablePatterns
    if ($unavailable) {
        $nodeKey = ("$($unavailable.Text) $($unavailable.Desc)").Trim()
        $initialNode = [pscustomobject]@{ Key = $nodeKey; Text = ('node: ' + $nodeKey) }
        $nodeReader = {
            $nodeNow = Get-UiNodeBounds -T $T -Patterns $unavailablePatterns
            if ($nodeNow) { $k = ("$($nodeNow.Text) $($nodeNow.Desc)").Trim(); [pscustomobject]@{ Key = $k; Text = ('node: ' + $k) } } else { $null }
        }
        $stableNode = Confirm-StableReads -Reader $nodeReader -Initial $initialNode
        if ($stableNode.Stable) {
            $script:LastDubbingEvidence = Format-DubbingEvidence -Kind 'vietnamese-marked-unavailable' -Reads $stableNode.Reads
            $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
            return 'unavailable'
        }
        Write-Warn2 'DUB_UNVERIFIED: Nhan Tieng Viet khong kha dung chua nhat quan qua cac lan doc; khong ket luan loai.'
    }

    # Nodes outside a scrolling viewport may still exist in accessibility XML.
    # Confirm checked choices, or the post-tap transition back to the Reel.
    $selectionTapped = $false
    $returnedReelReads = 0
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $snapshot = Get-UiNodeBounds -T $T -SnapshotOnly
        $choice = Get-DubbingVietnameseChoice -Xml $snapshot
        if ($choice -and $choice.Selected) {
            Start-Sleep -Milliseconds 500
            $confirmation = Get-DubbingVietnameseChoice -Xml (Get-UiNodeBounds -T $T -SnapshotOnly)
            if ($confirmation -and $confirmation.Selected) {
                $dubbingUiStatus = 'selected'
                Write-Note 'DUB_SELECTED: Hai anh chup giao dien moi xac nhan muc Tieng Viet dang duoc chon va nam trong vung hien thi.'
                break
            }
            continue
        }
        # Do not reopen the selector or tap the language a second time.
        if ($selectionTapped) {
            if (Test-DubbingReturnedToReel -Xml $snapshot) { $returnedReelReads++ } else { $returnedReelReads = 0 }
            if ($returnedReelReads -ge 2) {
                $dubbingUiStatus = 'selected'
                Write-Note 'DUB_SELECTED: Da cham dung muc Tieng Viet; Meta dong menu va tro ve Reel, xac nhan qua hai lan doc moi.'
                break
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        if ($choice -and $choice.Clickable) {
            $selectionTapped = $true
            $tap = Invoke-Adb $T @('shell','input','tap',"$($choice.X)","$($choice.Y)")
            if ($tap.Code -ne 0) { break }
            Start-Sleep -Milliseconds 1000
            continue
        }
        $scroll = $null
        try {
            [xml]$document = $snapshot
            foreach ($node in $document.SelectNodes('//node[@package="com.facebook.katana" and @scrollable="true"]')) {
                $scroll = Get-VisibleUiBounds -Node $node
                if ($scroll) { break }
            }
        } catch { }
        if (-not $scroll) { break }
        $fromY = [int]($scroll.Top + ($scroll.Bottom-$scroll.Top)*0.8)
        $toY = [int]($scroll.Top + ($scroll.Bottom-$scroll.Top)*0.2)
        $swipe = Invoke-Adb $T @('shell','input','swipe',"$($scroll.X)","$fromY","$($scroll.X)","$toY",'400')
        if ($swipe.Code -ne 0) { break }
        Start-Sleep -Milliseconds 700
    }
    if ($dubbingUiStatus -ne 'selected') { Write-Warn2 'DUB_UNVERIFIED: Chua xac nhan duoc muc Tieng Viet dang chon; khong duoc tai phan hinh.' }

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
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($enc in @('h264_nvenc','h264_qsv','h264_amf')) {
            $probe = Invoke-Exe $T.ffmpeg @('-hide_banner','-f','lavfi','-i','color=c=black:s=256x256:d=0.04','-c:v',$enc,'-f','null','-') -TimeoutMs 8000
            if ($probe.Code -eq 0) {
                $script:optimalVideoEncoder = $enc
                return $script:optimalVideoEncoder
            }
            $errLines = @(([string]$probe.Err -split "`r?`n") | Where-Object { $_ -match '\S' })
            $why = if ($errLines.Count -gt 0) { $errLines[$errLines.Count - 1].Trim() } else { 'khong co thong bao loi' }
            if ($why.Length -gt 160) { $why = $why.Substring(0,160) }
            $reasons.Add(("{0}: ma {1}, {2}" -f $enc, $probe.Code, $why))
        }
    } catch {
        $reasons.Add('loi khi thu encoder phan cung: ' + $_.Exception.Message)
    }
    $script:optimalVideoEncoder = 'libx264'
    Write-Warn2 ('Khong dung duoc encoder phan cung, dung CPU libx264. Ly do: ' + ($reasons -join ' | '))
    return $script:optimalVideoEncoder
}

# Tham so encoder video dung chung (CRF/CQ co dinh, High profile, yuv420p).
function Get-VideoEncoderArgs {
    param([string]$Encoder = 'libx264')
    switch ($Encoder) {
        'h264_nvenc' { return @('-c:v','h264_nvenc','-preset','p5','-rc','vbr','-cq','21','-b:v','0','-profile:v','high','-pix_fmt','yuv420p') }
        'h264_qsv'   { return @('-c:v','h264_qsv','-global_quality','21','-profile:v','high','-pix_fmt','yuv420p') }
        'h264_amf'   { return @('-c:v','h264_amf','-rc','cqp','-qp_i','20','-qp_p','22','-profile:v','high','-pix_fmt','yuv420p') }
        default      { return @('-c:v','libx264','-crf','19','-preset','medium','-profile:v','high','-pix_fmt','yuv420p') }
    }
}

# Dong tom tat ly do ffmpeg that bai (dung khi roi ve libx264).
function Get-FfmpegFailureSummary {
    param($Result)
    $errLines = @(([string]$Result.Err -split "`r?`n") | Where-Object { $_ -match '\S' })
    $why = if ($errLines.Count -gt 0) { $errLines[$errLines.Count - 1].Trim() } else { 'khong co thong bao loi' }
    if ($why.Length -gt 200) { $why = $why.Substring(0,200) }
    return ("ma {0}: {1}" -f $Result.Code, $why)
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
          [double]$GifCustomHeight = -1,
          [double]$Duration = 0)
    if ($Width -le 0 -or $Height -le 0) { throw 'Kich thuoc video khong hop le de chen logo.' }

    $coordinates = @{
        TopLeft     = @('(W-w)*0.04','(H-h)*0.04')
        TopRight    = @('(W-w)*0.96','(H-h)*0.04')
        BottomLeft  = @('(W-w)*0.04','(H-h)*0.96')
        BottomRight = @('(W-w)*0.96','(H-h)*0.96')
        Center      = @('(W-w)*0.5','(H-h)*0.5')
    }

    $encArgs = Get-VideoEncoderArgs -Encoder $VideoEncoder
    # Gioi han bang -t (thoi luong video that) thay vi -shortest de khong cat khung cuoi.
    $limitArgs = if ($Duration -gt 0.5) { @('-t', $Duration.ToString('0.###', [cultureinfo]::InvariantCulture)) } else { @('-shortest') }
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
                 @('-c:a','copy') + $limitArgs + @('-movflags','+faststart',$Output)
    } elseif ($hasGif) {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[vbase];" +
                  "[2:v]format=rgba,scale=${gifScale}[gif];" +
                  "[vbase][gif]overlay=x='${gx}':y='${gy}':shortest=1:format=auto[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-stream_loop','-1','-i',$Gif,'-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy') + $limitArgs + @('-movflags','+faststart',$Output)
    } elseif ($hasLogo) {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[vbase];" +
                  "[2:v]format=rgba,scale=${logoScale},colorchannelmixer=aa=${alpha}[logo];" +
                  "[vbase][logo]overlay=x='${x}':y='${y}':eval=frame:shortest=1:format=auto[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-loop','1','-i',$Logo,'-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy') + $limitArgs + @('-movflags','+faststart',$Output)
    } else {
        $filter = "[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[v]"
        return @('-hide_banner','-loglevel','error','-y','-i',$Video,'-i',$Audio,
                 '-filter_complex',$filter,'-map','[v]','-map','1:a:0?') +
                 $encArgs +
                 @('-c:a','copy') + $limitArgs + @('-movflags','+faststart',$Output)
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
                -CustomX $CustomX -CustomY $CustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder $activeEncoder -Duration $duration
        } else {
            $editArgs = @('-hide_banner','-loglevel','error','-y','-i',$source,'-i',$audio,'-map','0:v:0','-map','1:a:0?','-c','copy','-t',$duration.ToString('0.###',[cultureinfo]::InvariantCulture),'-movflags','+faststart',$staged)
        }
        Write-Note 'Sua tu video goc va audio da luu; khong tai video, khong thu am lai.'
        $result = Invoke-Exe $T.ffmpeg $editArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        if ($result.Code -ne 0 -and $activeEncoder -ne 'libx264' -and ($resolvedLogo -or $resolvedGif)) {
            Write-Warn2 "Hardware encoder ($activeEncoder) that bai ($(Get-FfmpegFailureSummary $result)), tu dong chuyen sang CPU libx264..."
            $script:optimalVideoEncoder = 'libx264'
            $editArgs = Get-MovingLogoMuxArgs -Video $source -Audio $audio -Logo $resolvedLogo -Output $staged `
                -Width $sizeInfo.W -Height $sizeInfo.H -Fade $Fade -Size $Size -Motion $Motion -Position $Position `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $CustomWidth -CustomHeight $CustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $CustomX -CustomY $CustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder 'libx264' -Duration $duration
            $result = Invoke-Exe $T.ffmpeg $editArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        }
        if ($result.Code -ne 0) { throw "Sua video that bai: $($result.Err)" }
        if (-not (Test-ValidReelOutput $T $staged -ReferenceVideo $source)) { throw 'Video sua khong qua kiem tra. Giu nguyen ban cu.' }
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
    param($T, [string]$File, [switch]$AllowSilent, [string]$ReferenceVideo = '')
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

        # So do dai stream video voi file tham chieu (-1): lech > 0.10 s => khong hop le (mat khung cuoi).
        if ($ReferenceVideo) {
            if (-not (Test-Path -LiteralPath $ReferenceVideo -PathType Leaf)) { return $false }
            $outVideoDur = Get-VideoDuration $T $File
            $refVideoDur = Get-VideoDuration $T $ReferenceVideo
            if ($outVideoDur -le 0.5 -or $refVideoDur -le 0.5) { return $false }
            if ([Math]::Abs($outVideoDur - $refVideoDur) -gt 0.10) {
                Write-Warn2 ("Do dai video khong khop: ban hoan chinh {0:0.000}s, video goc {1:0.000}s (lech > 0.10s)" -f $outVideoDur, $refVideoDur)
                return $false
            }
        }

        # Kiem tra giai ma toan bo stream de loai bo file bi cat / thieu frame (M4)
        if ($T -and $T.ffmpeg) {
            $decode = Invoke-Exe $T.ffmpeg @('-hide_banner','-v','error','-i',$File,'-f','null','-') -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
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
function Stop-ReelForLanguage {
    param([string]$VideoId, [string[]]$Urls, [string]$Dest, [string]$Reason, [string]$Evidence = '')
    # Luu lich su loai (kem bang chung). KHONG xoa file -1/-2/-3 da co trong thu muc xuat (hop dong GUI muc 4).
    $null = Save-RejectedReel -Root $script:Here -VideoId $VideoId -Urls $Urls -Reason $Reason -Language '' -Probability 0 -Evidence $Evidence
    Write-Note ('REEL_REJECTED: id='+$VideoId+' reason='+$Reason)
}

function Stop-KnownRejectedReel {
    param($Entry, [string]$Dest)
    $id = [string]$Entry.VideoId
    if ($id -notmatch '^\d+$') { throw 'Lich su loai co ID khong hop le.' }
    # Khong xoa file da co: nguoi dung quyet dinh (Bo loai & thu lai).
    Write-Note ('REEL_REJECTED: id='+$id+' reason=already-rejected')
}

# Doc khong chan stdout/stderr cua scrcpy theo tung dong (ReadLineAsync, tham do tu luong chinh)
# de khong deadlock pipe va ghi moc "Recording started" (tRec) tinh bang giay tu luc process start.
function Receive-ProcLines {
    param($Pump)
    foreach ($k in @('Out','Err')) {
        $reader = if ($k -eq 'Out') { $Pump.Proc.StandardOutput } else { $Pump.Proc.StandardError }
        while ($true) {
            $task = $Pump.Tasks[$k]
            if ($null -eq $task) {
                if ($Pump.Eof[$k]) { break }
                $task = $reader.ReadLineAsync()
                $Pump.Tasks[$k] = $task
            }
            if (-not $task.IsCompleted) { break }
            $Pump.Tasks[$k] = $null
            if ($task.IsFaulted) { $Pump.Eof[$k] = $true; break }
            $line = $task.Result
            if ($null -eq $line) { $Pump.Eof[$k] = $true; break }
            [void]$Pump.Text[$k].AppendLine($line)
            if ($null -eq $Pump.TRec -and $line -match '(?i)recording started') { $Pump.TRec = $Pump.Sw.Elapsed.TotalSeconds }
        }
    }
}

function Invoke-OneLink {
    param($T, [string]$Url, [string]$Dest, [switch]$KeepFiles, [switch]$GifFullFrame,
          [double]$LogoCustomWidth = -1, [double]$LogoCustomHeight = -1,
          [double]$GifCustomWidth = -1, [double]$GifCustomHeight = -1,
          [switch]$ForceRetryRejected)

    # Ket qua may doc, phat dung 1 lan trong finally (hop dong GUI muc 1).
    $res = [ordered]@{ v = 1; status = 'failed'; id = ''; url = $Url; video = ''; source = ''; audio = ''
                       reason = 'unknown'; message = ''; t0 = $null; tOpen = $null; tRec = $null; gapFilledSec = $null; encoder = ''; durationSec = $null
                       syncMethod = $null; syncConfidence = $null; t0Onset = $null; syncDriftMs = $null; captureAttempts = $null }
    $inv = [cultureinfo]::InvariantCulture
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $rejectedForLanguage = $false
    $tOpen = $null
    $encoderUsed = ''
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        # ---------- 3. tai video goc va do thoi luong ----------
        Write-Step 3 'Doc ID va thoi luong; chua tai video'
        $originalUrl = $Url
        $knownId = Get-FacebookVideoId -Url $Url
        if ($ForceRetryRejected) { Write-Note 'FORCE_RETRY_REJECTED: bo qua lich su loai cho lan nay.' }
        $knownRejection = if ($ForceRetryRejected) { $null } else { Find-RejectedReel -Root $script:Here -VideoId $knownId -Url $Url }
        if ($knownRejection) {
            $rejectedForLanguage = $true
            $res.id = [string]$knownId
            Stop-KnownRejectedReel -Entry $knownRejection -Dest $Dest
            Set-KidResultState $res 'rejected' 'already-rejected' 'Video da nam trong lich su loai.'
            return $null
        }
        if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) {
            $cleanLinks = @(Get-FacebookInputLinks -Text $Url)
            if ($cleanLinks.Count -ne 1) {
                Show-Fail -Message 'Can mot link video Facebook hop le cho moi tac vu.' -Fix @('Dan URL Facebook/share/Reel, khong dan nhieu link vao mot tac vu.')
                Set-KidResultState $res 'failed' 'invalid-link' 'Can mot link video Facebook hop le cho moi tac vu.'
                return $null
            }
            $Url = $cleanLinks[0]
            $resolvedUrl = Resolve-FacebookShareUrl -Url $Url
            if ($resolvedUrl -ne $Url) { Write-Note "Link chia se -> $resolvedUrl"; $Url = $resolvedUrl }
        }
        $idr = Invoke-Exe $T.ytdlp @('--ignore-config','--no-playlist','--no-warnings','--skip-download','--print','%(id)s',$Url) -TimeoutMs 120000
        $vid = ($idr.Out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        if ($vid) { $vid = $vid.Trim() }
        if ($idr.Code -ne 0 -or -not $vid) {
            Show-Fail -Message 'Chua doc duoc video tu link Facebook.' -Fix @('Xem loi yt-dlp ben duoi; neu video can dang nhap, rieng tu hoac bi gioi han thi thu link cong khai.', 'Neu bao Unsupported URL, tai lai yt-dlp tai tab cong cu.', $idr.Err)
            Set-KidResultState $res 'failed' 'metadata-failed' 'Chua doc duoc video tu link Facebook (yt-dlp).'
            return $null
        }
        if ($vid -match '^\d+$') { $res.id = [string]$vid }
        if (Get-Command Get-FacebookCanonicalVideoUrl -CommandType Function -ErrorAction SilentlyContinue) {
            $Url = Get-FacebookCanonicalVideoUrl -Url $Url -VideoId $vid
        }

        $knownRejection = if ($ForceRetryRejected) { $null } else { Find-RejectedReel -Root $script:Here -VideoId $vid -Url $originalUrl }
        if ($knownRejection) {
            $rejectedForLanguage = $true
            Stop-KnownRejectedReel -Entry $knownRejection -Dest $Dest
            Set-KidResultState $res 'rejected' 'already-rejected' 'Video da nam trong lich su loai.'
            return $null
        }
        if ($vid -notmatch '^\d+$') { throw 'Facebook returned an invalid video ID.' }
        $durationMetadata = Invoke-Exe $T.ytdlp @('--ignore-config','--no-playlist','--no-warnings','--skip-download','--print','%(duration)s',$Url) -TimeoutMs 120000
        $dur = 0.0
        if ($durationMetadata.Code -ne 0 -or -not [double]::TryParse(([string]$durationMetadata.Out).Trim(),[Globalization.NumberStyles]::Float,[cultureinfo]::InvariantCulture,[ref]$dur) -or [double]::IsNaN($dur) -or [double]::IsInfinity($dur) -or $dur -le 0.5 -or $dur -gt 3600) { Set-KidResultState $res 'failed' 'invalid-duration' 'Khong doc duoc thoi luong Reel hop le; chua tai video.'; throw 'Khong doc duoc thoi luong Reel hop le; chua tai video.' }
        $res.durationSec = [Math]::Round($dur, 3)

        # ---------- 4. dam bao Facebook da bat tieng Viet ----------
        $dubbingUiStatus = Ensure-VietnameseDubbing -T $T -Url $Url
        if ($dubbingUiStatus -eq 'unavailable') {
            $rejectedForLanguage = $true
            try {
                Stop-ReelForLanguage -VideoId $vid -Urls @($originalUrl,$Url) -Dest $Dest -Reason 'vietnamese-unavailable' -Evidence ([string]$script:LastDubbingEvidence)
            } catch {
                Show-Fail -Message ('Khong luu duoc lich su loai: ' + $_.Exception.Message) -Fix @('Kiem tra file data\rejected-videos.json (khoa/hong).')
                Set-KidResultState $res 'failed' 'history-save-failed' ('Khong luu duoc lich su loai: ' + $_.Exception.Message)
                return $null
            }
            Set-KidResultState $res 'rejected' 'vietnamese-unavailable' 'Meta khong co ban long tieng Viet cho video nay.'
            return $null
        }
        if ((Get-ReelLanguageDecision -DubbingStatus $dubbingUiStatus) -ne 'accept') {
            Set-KidResultState $res 'unverified' 'dub-unverified' 'Chua xac minh duoc Tieng Viet dang chon tren Reel; khong loai vinh vien.'
            throw 'Chua xac minh duoc Tieng Viet dang duoc chon tren Reel. Dung truoc khi thu/tai; khong loai vinh vien khi giao dien chua ro.'
        }

        Write-Note 'DUB_UI_ACCEPTED: Meta da xac nhan Tieng Viet dang chon; khong chay nhan dien ngon ngu audio.'

        # ---------- 5. thu am sach tu Giay 0 ----------
        # Thu them 10 giay de du phong thoi gian ket noi va nap Reel
        $recLen = [int][Math]::Ceiling($dur + 10)
        Write-Step 5 "Thu am thanh tu Giay 0 (thoi luong video $([Math]::Round($dur, 2))s, ghi buffer ${recLen}s)"
        Write-Host '       DUNG THAO TAC TREN MAN HINH KHI DANG THU' -ForegroundColor Yellow

        $vf = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $res.captureAttempts = $attempt
            $res.tOpen = $null; $res.tRec = $null; $tOpen = $null
            $withVideo = $false; $rec = $null; $swScrcpy = $null
            # Lan 1 thu kem hinh; neu scrcpy khong chay duoc voi video thi lan 2 chi thu am thanh (dong bo bang onset).
            foreach ($capMode in @('video','audio')) {
                $withVideo = ($capMode -eq 'video')
                $swScrcpy = $null
                # Dung Facebook de dua ve trang thai moi
                $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
                Start-Sleep -Milliseconds 600

                $rec = Join-Path $tmp $(if ($withVideo) { 'rec.mkv' } else { 'rec.m4a' })

                # Khoi dong scrcpy thu am truoc trong background (an hoan toan cua so va icon)
                $captureArgs = @(
                    '--serial', $T.Serial,
                    '--no-window',
                    '--no-audio-playback',
                    '--audio-codec=aac',
                    '--require-audio',
                    "--time-limit=$recLen",
                    "--record=$rec"
                )
                if ($withVideo) {
                    # Thu kem hinh man hinh do phan giai thap cung dong ho voi audio (dung de khop khung hinh voi video goc).
                    $captureArgs += @('--max-size=480','--video-bit-rate=2M','--max-fps=30','--video-codec=h264')
                } else {
                    $captureArgs += '--no-video'
                }
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
                $captureOut = ''; $captureErr = ''; $captureCode = -1; $captureTimedOut = $false
                $pump = $null
                try {
                    [void]$proc.Start()
                    $swScrcpy = [Diagnostics.Stopwatch]::StartNew()
                    $procStarted = $true
                    if ($procRegistry) { $procRegistry[$proc.Id] = $proc }
                    $pump = @{ Proc = $proc; Sw = $swScrcpy; TRec = $null
                               Tasks = @{ Out = $null; Err = $null }; Eof = @{ Out = $false; Err = $false }
                               Text = @{ Out = (New-Object Text.StringBuilder); Err = (New-Object Text.StringBuilder) } }

                    # Cho 1.8 giay de scrcpy ket noi am thanh Android HAL (van doc output de bat moc ghi am)
                    while ($swScrcpy.ElapsedMilliseconds -lt 1800) { Receive-ProcLines $pump; Start-Sleep -Milliseconds 40 }

                    # Mo lai Reel sau khi recorder san sang; onset am thanh duoc uoc tinh o buoc sau
                    $tOpen = $swScrcpy.Elapsed.TotalSeconds
                    $res.tOpen = [Math]::Round($tOpen, 3)
                    Receive-ProcLines $pump
                    if ($null -ne $pump.TRec) { $res.tRec = [Math]::Round([double]$pump.TRec, 3) }
                    $null = Open-Reel $T $Url

                    # Cho scrcpy thu am dung thoi han va tu dong dong file hoan chinh (van doc output, khong chan pipe).
                    $captureWaitMs = [int][Math]::Min([int]::MaxValue, ([double]($recLen + 30) * 1000))
                    $swWait = [Diagnostics.Stopwatch]::StartNew()
                    while (-not $proc.HasExited -and $swWait.ElapsedMilliseconds -lt $captureWaitMs) {
                        Receive-ProcLines $pump
                        Start-Sleep -Milliseconds 50
                    }
                    if (-not $proc.HasExited) {
                        $captureTimedOut = $true
                        try { $proc.Kill() } catch { Write-Warn2 ('Khong dung duoc scrcpy: ' + $_.Exception.Message) }
                        try { $null = $proc.WaitForExit(5000) } catch { Write-Warn2 ('Cho scrcpy thoat loi: ' + $_.Exception.Message) }
                    }
                    $swDrain = [Diagnostics.Stopwatch]::StartNew()
                    while (($swDrain.ElapsedMilliseconds -lt 10000) -and -not ($pump.Eof.Out -and $pump.Eof.Err)) {
                        Receive-ProcLines $pump
                        Start-Sleep -Milliseconds 50
                    }
                    Receive-ProcLines $pump
                    if ($null -ne $pump.TRec -and $null -eq $res.tRec) { $res.tRec = [Math]::Round([double]$pump.TRec, 3) }
                    $captureOut = $pump.Text.Out.ToString()
                    $captureErr = $pump.Text.Err.ToString()
                    if ($proc.HasExited -and -not $captureTimedOut) { $captureCode = $proc.ExitCode }
                } finally {
                    if ($procStarted -and -not $proc.HasExited) {
                        try { $proc.Kill() } catch { }
                        try { $null = $proc.WaitForExit(5000) } catch { }
                    }
                    if ($procRegistry -and $procStarted) {
                        try { $procRegistry.Remove($proc.Id) } catch { }
                    }
                    if ($procStarted) {
                        # Dong stream truoc Dispose de task ReadLineAsync dang treo khong giu handle.
                        try { $proc.StandardOutput.Close() } catch { Write-Warn2 ('Dong stdout scrcpy loi: ' + $_.Exception.Message) }
                        try { $proc.StandardError.Close() } catch { Write-Warn2 ('Dong stderr scrcpy loi: ' + $_.Exception.Message) }
                    }
                    $proc.Dispose()
                }

                # Dung Facebook
                $null = Invoke-Adb $T @('shell','am','force-stop',$script:Fb)
                $capFast = ($captureTimedOut -or $captureCode -ne 0) -and $swScrcpy -and ($swScrcpy.Elapsed.TotalSeconds -lt 15)
                if ($withVideo -and $capFast) {
                    $why = ((([string]$captureErr) + ' ' + ([string]$captureOut)).Trim())
                    if ($why.Length -gt 300) { $why = $why.Substring($why.Length - 300) }
                    Write-Warn2 ('scrcpy khong thu duoc hinh man hinh (ma ' + $captureCode + '); thu lai chi voi am thanh, dong bo bang onset. ' + $why)
                    $res.tOpen = $null; $res.tRec = $null; $tOpen = $null
                    continue
                }
                break
            }

            if ($captureTimedOut -or $captureCode -ne 0) {
                Show-Fail -Message 'Thu am that bai.' -Fix @('scrcpy bi qua thoi gian hoac ket thuc voi loi.', $captureErr, $captureOut)
                Set-KidResultState $res 'failed' 'capture-failed' 'Thu am that bai: scrcpy qua thoi gian hoac ket thuc voi loi.'
                return $null
            }
            if (-not (Test-Path -LiteralPath $rec) -or (Get-Item -LiteralPath $rec).Length -lt 1000) {
                Show-Fail -Message 'Thu am that bai.' -Fix @('Kiem tra ket noi thiet bi.', $captureErr, $captureOut)
                Set-KidResultState $res 'failed' 'capture-failed' 'Thu am that bai: file thu rong hoac khong ton tai.'
                return $null
            }

            if ($KeepFiles) { Write-Note ('KEEP_RAW_CAPTURE: ' + $rec) }

            # Chuan hoa mot lan: lap khoang trong pts bang im lang => truc mau = truc pts (dong ho that).
            $recFixedPath = Join-Path $tmp 'rec-fixed.wav'
            $fixedInfo = ConvertTo-FixedRecording -T $T -Rec $rec -Out $recFixedPath
            if (-not $fixedInfo) {
                Show-Fail -Message 'Chuan hoa ban thu (lap khoang trong pts) that bai.' -Fix @('Chay lai thu.')
                Set-KidResultState $res 'failed' 'audio-failed' 'Chuan hoa ban thu that bai.'
                return $null
            }
            $res.gapFilledSec = [Math]::Round([double]$fixedInfo.GapFilledSec, 3)
            Write-Ok ([string]::Format($inv, 'Lap khoang trong pts: {0:0.000} s', [double]$fixedInfo.GapFilledSec))
            if ($fixedInfo.Warning) { Write-Warn2 $fixedInfo.Warning }
            if ($KeepFiles) { Write-Note ('KEEP_FIXED_CAPTURE: ' + $recFixedPath) }
            $analysisFile = $recFixedPath
            # ---------- 6. do onset t0 va cat am thanh chuan ----------
            Write-Step 6 'Xac dinh diem khoi dau Giay 0 va cat am thanh'
            $tOpenValue = if ($null -ne $tOpen) { [double]$tOpen } else { 0.0 }
            # Moc 0 cua file thu = luc recorder that su bat dau (tRec tinh tu luc scrcpy start); Reel mo tai ~ tOpen - tRec.
            if ($null -ne $res.tRec) {
                $tRecValue = [double]$res.tRec
                $searchFrom = [Math]::Max(0.0, $tOpenValue - $tRecValue - 0.3)
            } else {
                $tRecValue = $null
                $searchFrom = [Math]::Max(0.0, $tOpenValue - 1.5)
                Write-Warn2 'Khong bat duoc dong "Recording started" cua scrcpy; dung SearchFrom du phong = tOpen - 1.5s.'
            }
            $onsetInfo = Get-AudioOnsetInfo -T $T -File $analysisFile -SearchFrom $searchFrom
            $t0Onset = $null
            if ($null -ne $onsetInfo.Onset) {
                $t0Onset = [double]$onsetInfo.Onset
                $res.t0Onset = [Math]::Round($t0Onset, 3)
                Write-Ok ([string]::Format($inv, 'Onset am thanh = {0:0.000}s (tOpen {1:0.000}s, tRec {2}, nen {3:0.0} dB, noi dung L {4:0.0} dB, nguong {5:0.0} dB)', $t0Onset, $tOpenValue, $(if ($null -ne $tRecValue) { $tRecValue.ToString('0.000', $inv) + 's' } else { 'n/a' }), [double]$onsetInfo.NoiseFloorDb, [double]$onsetInfo.ContentDb, [double]$onsetInfo.ThresholdDb))
            } else {
                Write-Warn2 ('Khong xac dinh duoc onset am thanh (ly do: ' + [string]$onsetInfo.Reason + ').')
            }
            Write-Ok 'Da chap nhan lua chon Tieng Viet tu UI Meta; bat dau tai phan hinh HD.'

            if ($null -eq $vf) {
            # Uu tien do phan giai, fps, bitrate trong cac dinh dang yt-dlp doc duoc
            # Loi tai video: thu lai toi da 2 lan, cach 3 s va 8 s.
            $retryDelays = @(3, 8)
            $dlr = $null; $vf = $null
            for ($dlAttempt = 0; $dlAttempt -le $retryDelays.Count; $dlAttempt++) {
                if ($dlAttempt -gt 0) {
                    Write-Warn2 ("Tai video loi (ma {0}); thu lai lan {1}/{2} sau {3} giay..." -f $dlr.Code, $dlAttempt, $retryDelays.Count, $retryDelays[$dlAttempt - 1])
                    Start-Sleep -Seconds $retryDelays[$dlAttempt - 1]
                }
                $dlr = Invoke-Exe $T.ytdlp @('--ignore-config','--no-playlist','-S','res,fps,br','-f','bestvideo/best','--no-warnings','-o',"$tmp\v.%(ext)s",$Url) -TimeoutMs 600000
                $vf = Get-ChildItem -LiteralPath $tmp -File -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -like 'v.*' -and $_.Name -notmatch '\.(part|ytdl|tmp)$' -and $_.Extension.ToLowerInvariant() -notin @('.part','.ytdl','.tmp')
                } | Select-Object -First 1
                if ($dlr.Code -eq 0 -and $vf) { break }
            }
            if ($dlr.Code -ne 0 -or -not $vf) {
                Show-Fail -Message 'Tai video that bai.' -Fix @('Kiem tra mang.','Video co the da bi xoa hoac rieng tu.', $dlr.Err)
                Set-KidResultState $res 'failed' 'download-failed' 'Tai video that bai sau 3 lan thu.'
                return $null
            }

            $actualDuration = Get-VideoDuration $T $vf.FullName
            if ($actualDuration -le 0.5) {
                Show-Fail -Message "Do dai video bat thuong ($actualDuration giay)." -Fix @('Chay lai thu.')
                Set-KidResultState $res 'failed' 'invalid-duration' 'Do dai video tai ve bat thuong.'
                return $null
            }
            if ([Math]::Abs($actualDuration - $dur) -gt 0.5) {
                Set-KidResultState $res 'failed' 'duration-mismatch' 'Do dai video doi sau khi thu am; khong xuat ban.'
                throw 'Video duration changed after language capture; no output was published.'
            }
            $dur = $actualDuration
            $res.durationSec = [Math]::Round($dur, 3)
            $sz = Get-VideoSize $T $vf.FullName
            $cv = Get-VideoCodec -T $T -File $vf.FullName
            Write-Ok "$($sz.W)x$($sz.H)  $cv  |  $([Math]::Round($dur, 2)) giay  |  $([Math]::Round($vf.Length/1MB, 1)) MB"
            }

            # t0 theo hinh: khop khung hinh man hinh (cung dong ho voi audio) voi video goc vua tai.
            # Khong dat (start-missing / do tin cay thap) => lan 1 thu lai 1 lan; onset chi dung khi khong thu duoc video va co -AllowOnsetSync.
            $t0 = $null
            $syncMethod = ''
            $syncDriftMs = $null
            $okMessage = 'Hoan tat.'
            $syncFinalFail = ''
            if ($withVideo) {
                Write-Note 'Khop khung hinh man hinh voi video goc de xac dinh t0...'
                $sync = Find-VideoSyncOffset -T $T -RefVideo $vf.FullName -RecFile $rec -Work $tmp
                if ($null -ne $sync.Peak) { $res.syncConfidence = [double]$sync.Peak }
                Write-Note ([string]::Format($inv, 'Khop hinh: ket qua {0}, hinh hoc {1}, dinh {2}, ty le {3}, dinh dau video {4}, d toan cuc {5} s, bac d (khung) [{6}], 3 doan (ms so voi t0) {7}, mat {8:0.0} s', $sync.Reason, $sync.Geometry, $sync.Peak, $sync.Ratio, $sync.StartPeak, $sync.DGlobalSec, $sync.Plateaus, $sync.SegText, [double]$sync.ElapsedSec))
                if ($sync.Ok) {
                    $t0 = [double]$sync.T0
                    $syncMethod = 'video'
                    $syncDriftMs = $sync.DriftMs
                    $res.syncDriftMs = $syncDriftMs
                    $diffTxt = if ($null -ne $t0Onset) { [string]::Format($inv, '{0:0} ms', ($t0 - $t0Onset) * 1000.0) } else { 'n/a' }
                    Write-Ok ([string]::Format($inv, 't0 theo hinh = {0:0.000}s (do tin cay {1:0.000}, ty le {2:0.00}, lech onset {3})', $t0, [double]$sync.Peak, [double]$sync.Ratio, $diffTxt))
                    if ($null -ne $syncDriftMs -and $syncDriftMs -gt 80.0) {
                        Write-Warn2 ([string]::Format($inv, 'sync-drift: hinh man hinh dung/tre {0:0} ms giua cac doan (player Facebook); t0 lay theo doan som nhat (audio la dong ho chu); van xuat ban.', $syncDriftMs))
                        $okMessage = [string]::Format($inv, 'Hoan tat (canh bao sync-drift: hinh man hinh dung/tre {0:0} ms giua cac doan; t0 theo doan som nhat).', $syncDriftMs)
                    }
                    break
                }
                $syncCode = if ($sync.Reason -eq 'start-missing') { 'start-missing' } elseif ($sync.Reason -like 'low-confidence*' -or $sync.Reason -like 'match-*') { 'low-confidence' } else { 'no-video-sync' }
                if ($syncCode -ne 'no-video-sync' -and $attempt -lt 2) {
                    Write-Note ('SYNC_RETRY: ' + $syncCode + ' (' + [string]$sync.Reason + '); thu lai lan 2: force-stop Facebook, mo lai Reel tu dau; khong tai lai video goc, khong chay lai buoc chon Tieng Viet (lua chon da luu trong Facebook).')
                    if ($KeepFiles -and (Test-Path -LiteralPath $rec)) { Move-Item -LiteralPath $rec -Destination (Join-Path $tmp 'rec-attempt1.mkv') -Force -ErrorAction SilentlyContinue }
                    continue
                }
                $syncFinalFail = $syncCode
                Write-Warn2 ('Khop khung hinh khong dat (' + [string]$sync.Reason + ') sau ' + $attempt + ' lan thu.')
            } else {
                Write-Warn2 'Ban thu khong co hinh man hinh (scrcpy video loi).'
                $syncFinalFail = 'no-video-sync'
            }
            break
        }
        if ($null -eq $t0) {
            if ($syncFinalFail -eq 'start-missing') {
                Show-Fail -Message 'Dau video goc khong co trong ban thu sau 2 lan thu: Reel chay tiep tu giua, khong bat dau tu giay 0.' -Fix @('Thu lai sau.', 'Cat theo onset se lech am thanh so voi hinh nen khong xuat ban.')
                Set-KidResultState $res 'unverified' 'start-missing' 'Reel khong bat dau tu giay 0 trong ban thu sau 2 lan thu (khop hinh); khong xuat ban.'
                return $null
            }
            if ($syncFinalFail -eq 'low-confidence') {
                Show-Fail -Message 'Khop khung hinh khong du tin cay sau 2 lan thu.' -Fix @('Thu lai sau.', 'Khong xac nhan duoc audio khop hinh nen khong xuat ban.')
                Set-KidResultState $res 'unverified' 'low-confidence' 'Khop khung hinh khong du tin cay sau 2 lan thu; khong xuat ban.'
                return $null
            }
            # no-video-sync: thiet bi khong thu duoc video man hinh. Chi dung onset khi co -AllowOnsetSync.
            if (-not $AllowOnsetSync) {
                Show-Fail -Message 'Khong thu duoc hinh man hinh de dong bo; khong xuat ban.' -Fix @('Kiem tra scrcpy/thiet bi co thu video duoc khong.', 'Co the bat -AllowOnsetSync de dong bo theo am thanh (co the lech 0.5-1.2 s).')
                Set-KidResultState $res 'unverified' 'no-video-sync' 'Khong thu duoc hinh man hinh de dong bo; khong xuat ban (can -AllowOnsetSync de dung onset).'
                return $null
            }
            if ($null -eq $t0Onset) {
                Show-Fail -Message 'Khong xac dinh duoc diem bat dau tieng trong ban thu.' -Fix @(('Ly do: ' + [string]$onsetInfo.Reason), 'Kiem tra Reel co phat tieng khong, roi thu lai.')
                Set-KidResultState $res 'unverified' 'no-onset' 'Khong xac dinh duoc diem bat dau tieng trong ban thu; khong xuat ban.'
                return $null
            }
            $t0 = $t0Onset
            $syncMethod = 'onset'
            $okMessage = 'Hoan tat. Dong bo theo am thanh, co the lech 0.5-1.2 s.'
            Write-Warn2 'Dong bo theo am thanh, co the lech 0.5-1.2 s (onset khong chinh xac, khong co khop hinh).'
            Write-Ok ([string]::Format($inv, 't0 = {0:0.000}s (theo onset am thanh)', $t0))
        }
        $res.t0 = [Math]::Round($t0, 3)
        $res.syncMethod = $syncMethod
        # Kiem tra thoi luong thuc te dam bao video da phat tron ven; thieu => khong xuat ban
        $recDur = [double]$fixedInfo.FixedSec
        if (($recDur - $t0) -lt ($dur - 0.5)) {
            Show-Fail -Message ([string]::Format($inv, 'Ban thu qua ngan: nghe duoc {0:0.0}s nhung video dai {1:0.0}s.', ($recDur - $t0), $dur)) -Fix @('Facebook co the khoi dong cham hoac Reel bi ngat; thu lai.')
            Set-KidResultState $res 'unverified' 'short-capture' 'Ban thu ngan hon video; khong xuat ban.'
            return $null
        }
        Write-Ok ("Kiem tra phat tron ven: thoi gian nghe thuc te {0:0.0}s >= {1:0.0}s" -f ($recDur - $t0), $dur)

        $durStr = $dur.ToString([cultureinfo]::InvariantCulture)
        $t0Str  = $t0.ToString([cultureinfo]::InvariantCulture)
        $cut    = Join-Path $tmp 'dub.m4a'

        # Chuan hoa am luong loudnorm phat thanh (-16 LUFS, Peak -1.5)
        # Cat tren rec-fixed.wav (truc mau = truc pts, cung truc voi onset).
        $sliceFilter = "atrim=start=${t0Str}:duration=${durStr},asetpts=PTS-STARTPTS"
        $r1 = Invoke-Exe $T.ffmpeg @('-hide_banner','-nostats','-y','-i',$analysisFile,'-vn',
                                     '-af',($sliceFilter + ',loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json'),'-f','null','-') -TimeoutMs 300000
        if ($r1.Code -ne 0) {
            Show-Fail -Message 'Phan tich am thanh that bai.' -Fix @($r1.Err)
            Set-KidResultState $res 'failed' 'audio-failed' 'Phan tich am thanh that bai.'
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

        $cutResult = Invoke-Exe $T.ffmpeg @('-hide_banner','-loglevel','error','-y','-i',$analysisFile,'-vn',
                                            '-af',($sliceFilter + ',' + $flt),'-c:a','aac','-b:a','192k',$cut) -TimeoutMs 300000

        if ($cutResult.Code -ne 0 -or -not (Test-Path -LiteralPath $cut -PathType Leaf) -or (Get-Item -LiteralPath $cut).Length -le 0) {
            Show-Fail -Message 'Cat am thanh that bai.' -Fix @('Chay lai thu.', $cutResult.Err)
            Set-KidResultState $res 'failed' 'audio-failed' 'Cat am thanh that bai.'
            return $null
        }

        $cutMean = Get-MeanVolume -T $T -File $cut
        Write-Ok ("Am thanh da cat va chuan hoa xong ({0:0.0}s, muc am {1} dB)" -f $dur, $cutMean)
        if ($null -eq $cutMean -or $cutMean -lt -50.0) {
            Show-Fail -Message 'Ban thu gan nhu im lang; khong xuat ban.' -Fix @('Reel co the khong phat tieng (mang cham, hop thoai, chua dang nhap); thu lai.')
            Set-KidResultState $res 'unverified' 'silent-capture' 'Ban thu im lang hoac khong doc duoc muc am; khong xuat ban.'
            return $null
        }

        # ---------- 7. ghep video HD va xuat file ----------
        Write-Step 7 'Ghep video HD va xuat file'
        $fGoc = Join-Path $tmp "$vid-1-video-goc.mp4"
        $fAm  = Join-Path $tmp "$vid-2-am-thanh-tho.m4a"
        $out  = Join-Path $tmp "$vid-3-hoan-chinh.mp4"
        $finalGoc = Join-Path $Dest "$vid-1-video-goc.mp4"
        $finalAm  = Join-Path $Dest "$vid-2-am-thanh-tho.m4a"
        $finalOut = Join-Path $Dest "$vid-3-hoan-chinh.mp4"

        # Chuyen AV1/VP9 sang H.264 yuv420p de tang kha nang tuong thich trinh phat
        $muxDur = [Math]::Ceiling($dur * 1000.0) / 1000.0
        $vCodecOpt = if ($cv -match 'av1|av01|vp9|vp09') {
            Write-Note "Phat hien codec $cv (chuyen ma H.264 tuong thich Player/CapCut/Premiere, giu nguyen do phan giai $($sz.W)x$($sz.H))..."
            $encoderUsed = 'libx264'
            Get-VideoEncoderArgs -Encoder 'libx264'
        } else {
            $encoderUsed = 'copy'
            @('-c:v', 'copy')
        }

        # Ghep video goc + audio long tieng; gioi han bang -t (thoi luong video that), khong dung -shortest.
        $muxArgs = @('-hide_banner','-loglevel','error','-y','-i',$vf.FullName,'-i',$cut,
                     '-map','0:v:0','-map','1:a:0') + $vCodecOpt + @('-c:a','copy','-t',$muxDur.ToString('0.###',$inv),'-movflags','+faststart',$out)

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
            $encoderUsed = $chosenEncoder
            $muxArgs = Get-MovingLogoMuxArgs -Video $vf.FullName -Audio $cut -Logo $resolvedLogo -Output $out `
                -Width $sz.W -Height $sz.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder $chosenEncoder -Duration $muxDur
        }
        $muxResult = Invoke-Exe $T.ffmpeg $muxArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        if ($muxResult.Code -ne 0 -and $chosenEncoder -ne 'libx264' -and ($resolvedLogo -or $resolvedGif)) {
            Write-Warn2 "Hardware encoder ($chosenEncoder) that bai ($(Get-FfmpegFailureSummary $muxResult)), tu dong chuyen sang CPU libx264..."
            $script:optimalVideoEncoder = 'libx264'
            $encoderUsed = 'libx264'
            $muxArgs = Get-MovingLogoMuxArgs -Video $vf.FullName -Audio $cut -Logo $resolvedLogo -Output $out `
                -Width $sz.W -Height $sz.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
                -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY -VideoEncoder 'libx264' -Duration $muxDur
            $muxResult = Invoke-Exe $T.ffmpeg $muxArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        }
        if ($muxResult.Code -ne 0 -or -not (Test-Path -LiteralPath $out -PathType Leaf) -or (Get-Item -LiteralPath $out).Length -le 0) {
            Show-Fail -Message 'Ghep video that bai.' -Fix @('Chay lai thu.', $muxResult.Err)
            Set-KidResultState $res 'failed' 'mux-failed' 'Ghep video that bai.'
            return $null
        }

        # Luu video goc khong tieng (-1) truoc de so do dai voi ban hoan chinh (-3)
        $gocArgs = @('-hide_banner','-loglevel','error','-y','-i',$vf.FullName,'-map','0:v:0','-an') + $vCodecOpt + @($fGoc)
        $gocResult = Invoke-Exe $T.ffmpeg $gocArgs -TimeoutMs (Get-ReelProcessTimeoutMs $dur)
        if ($gocResult.Code -ne 0 -or -not (Test-Path -LiteralPath $fGoc -PathType Leaf) -or (Get-Item -LiteralPath $fGoc).Length -le 0) {
            Show-Fail -Message 'Xuat video goc that bai.' -Fix @($gocResult.Err)
            Set-KidResultState $res 'failed' 'mux-failed' 'Xuat video goc that bai.'
            return $null
        }
        if (-not (Test-ValidReelOutput -T $T -File $out -ReferenceVideo $fGoc)) {
            Show-Fail -Message 'File da ghep nhung khong qua kiem tra dau ra.' -Fix @('FFmpeg da ket thuc thanh cong; ffprobe can doc du stream video/audio, thoi luong hop le va do dai video khop video goc (lech <= 0.10s).','Kiem tra lai ffprobe hoac giu file tam bang -Keep de doi chieu.')
            Set-KidResultState $res 'failed' 'invalid-output' 'File hoan chinh khong qua kiem tra dau ra (hoac do dai khong khop video goc).'
            return $null
        }
        Copy-Item -LiteralPath $cut -Destination $fAm -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $fAm -PathType Leaf) -or (Get-Item -LiteralPath $fAm).Length -le 0) {
            Show-Fail -Message 'Luu am thanh that bai.' -Fix @('Chay lai thu.')
            Set-KidResultState $res 'failed' 'publish-failed' 'Luu am thanh that bai.'
            return $null
        }
        Publish-ReelFiles -Dest $Dest -Pairs @(
            @{ Source = $fGoc; Destination = $finalGoc },
            @{ Source = $fAm; Destination = $finalAm },
            @{ Source = $out; Destination = $finalOut }
        )

        $res.id = [string]$vid
        $res.video = $finalOut; $res.source = $finalGoc; $res.audio = $finalAm
        $res.encoder = $encoderUsed
        $res.durationSec = [Math]::Round($dur, 3)
        Set-KidResultState $res 'ok' 'ok' $okMessage
        if ($ForceRetryRejected -and (Get-Command Remove-RejectedReel -CommandType Function -ErrorAction SilentlyContinue)) {
            try {
                if (Remove-RejectedReel -Root $script:Here -VideoId $vid) { Write-Note ('REEL_REJECTED_CLEARED: id=' + $vid) }
            } catch {
                Write-Warn2 ('Khong go duoc muc loai sau khi thanh cong: ' + $_.Exception.Message)
            }
        }

        Write-Host ''
        Write-Host '  XONG  ' -ForegroundColor White -BackgroundColor DarkGreen
        Write-Host ''
        Write-Host "  Video : $finalOut" -ForegroundColor Green
        Write-Host "          $($sz.W)x$($sz.H)  |  $([Math]::Round($dur,1)) giay  |  $([Math]::Round((Get-Item -LiteralPath $finalOut).Length/1MB,1)) MB"
        Write-Host "  Goc   : $finalGoc" -ForegroundColor DarkGray
        Write-Host "  Tieng : $finalAm" -ForegroundColor DarkGray
        Write-Host ''
        return [pscustomobject]@{ File = $finalOut; Duration = $dur; DubbingUiStatus = $dubbingUiStatus }
    }
    catch {
        $stopRequested = $false
        for ($ex = $_.Exception; $null -ne $ex; $ex = $ex.InnerException) {
            if ($ex -is [System.Management.Automation.PipelineStoppedException]) { $stopRequested = $true }
        }
        if ($res.reason -eq 'unknown') {
            if ($stopRequested) { Set-KidResultState $res 'cancelled' 'stopped' 'Bi dung boi nguoi dung.' }
            else { Set-KidResultState $res 'failed' 'exception' ([string]$_.Exception.Message) }
        }
        throw
    }
    finally {
        # Chua co ly do nao ma khoi finally van chay => tien trinh bi dung giua chung.
        if ($res.reason -eq 'unknown') { Set-KidResultState $res 'cancelled' 'stopped' 'Bi dung boi nguoi dung.' }
        Write-KidResult -Result $res
        if ($rejectedForLanguage -or -not $KeepFiles) {
            $fullTmp = [IO.Path]::GetFullPath($tmp)
            $tempBoundary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
            if (-not $fullTmp.StartsWith($tempBoundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fullTmp) -notmatch '^kidfby-[0-9a-f]{8}$') { throw 'Unsafe reel temporary cleanup path.' }
            try { Remove-Item -LiteralPath $fullTmp -Recurse -Force -ErrorAction Stop }
            catch { Write-Warn2 ('REEL_CLEANUP_PENDING: temporary files at '+$fullTmp+'; '+$_.Exception.Message) }
        }
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
            -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight -VideoEncoder $chosenEncoder -Duration $duration
        $result = Invoke-Exe $logoTools.ffmpeg $logoArgs -TimeoutMs (Get-ReelProcessTimeoutMs $duration)
        if ($result.Code -ne 0 -and $chosenEncoder -ne 'libx264') {
            Write-Warn2 "Hardware encoder ($chosenEncoder) that bai ($(Get-FfmpegFailureSummary $result)), tu dong chuyen sang CPU libx264..."
            $script:optimalVideoEncoder = 'libx264'
            $logoArgs = Get-MovingLogoMuxArgs -Video $sourceVideo -Audio $sourceVideo -Logo $resolvedLogo -Output $stagedVideo `
                -Width $size.W -Height $size.H -Fade $LogoFade -Size $LogoSize -Motion $LogoMotion -Position $LogoPosition `
                -Gif $resolvedGif -GifSize $GifSize -GifFullFrame:$GifFullFrame -GifPosition $GifPosition `
                -CustomX $LogoCustomX -CustomY $LogoCustomY -GifCustomX $GifCustomX -GifCustomY $GifCustomY `
                -CustomWidth $LogoCustomWidth -CustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight -VideoEncoder 'libx264' -Duration $duration
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

# yt-dlp: kiem tra cap nhat toi da 14 ngay/lan. Moc luu o data\ytdlp-update-check.txt (ISO UTC); chi ghi khi -U thanh cong.
try {
    $ytMarker = Join-Path $script:Here 'data\ytdlp-update-check.txt'
    $needUpdate = $true
    if (Test-Path -LiteralPath $ytMarker -PathType Leaf) {
        $markerText = ([IO.File]::ReadAllText($ytMarker)).Trim()
        $markerTime = [datetime]::MinValue
        if ([datetime]::TryParse($markerText, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$markerTime)) {
            if (((Get-Date).ToUniversalTime() - $markerTime.ToUniversalTime()).TotalDays -le 14) { $needUpdate = $false }
        }
    }
    if ($needUpdate -and $tools.ytdlp) {
        Write-Note 'Kiem tra cap nhat yt-dlp (yt-dlp -U, toi da 45 giay)...'
        $upd = Invoke-Exe $tools.ytdlp @('-U') -TimeoutMs 45000
        $updText = (([string]$upd.Out + ' ' + [string]$upd.Err) -replace '\s+', ' ').Trim()
        if ($updText.Length -gt 300) { $updText = $updText.Substring(0,300) }
        if ($upd.Code -eq 0) {
            Write-Note "yt-dlp -U: $updText"
            [void][IO.Directory]::CreateDirectory((Split-Path $ytMarker -Parent))
            [IO.File]::WriteAllText($ytMarker, (Get-Date).ToUniversalTime().ToString('o'), [Text.UTF8Encoding]::new($false))
        } else {
            Write-Warn2 "yt-dlp -U that bai (ma $($upd.Code)): $updText"
        }
    }
} catch {
    Write-Warn2 ('Khong kiem tra/cap nhat duoc yt-dlp: ' + $_.Exception.Message)
}
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
        -LogoCustomWidth $LogoCustomWidth -LogoCustomHeight $LogoCustomHeight -GifCustomWidth $GifCustomWidth -GifCustomHeight $GifCustomHeight `
        -ForceRetryRejected:$ForceRetryRejected }
    catch { Show-Fail -Message "Loi: $($_.Exception.Message)" -Fix @('Chay lai thu.') }
    if ($kq) { $xong++ } else { $loi++ }
}
if ($links.Count -gt 1) {
    Write-Host ''
    Write-Host "  Tong ket: xong $xong  |  loi $loi" -ForegroundColor White
    Write-Host ''
}



