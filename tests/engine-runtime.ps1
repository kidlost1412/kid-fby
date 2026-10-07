param([string]$Root=(Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$enginePath = Join-Path $Root 'core/kid-fby.ps1'
$parseTokens = $null; $parseErrors = $null
$engineAst = [System.Management.Automation.Language.Parser]::ParseFile($enginePath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Engine parse failed: $($parseErrors[0].Message)" }
$needed = @('Write-Step','Write-Ok','Write-Note','Write-Warn2','Show-Fail','Quote-Arg','Invoke-Exe','Get-VideoCodec','Get-ReelProcessTimeoutMs','Test-ValidReelOutput','Publish-ReelFiles','Invoke-OneLink')
foreach ($name in $needed) {
    $functionAst = $engineAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Missing function in engine AST: $name" }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Assert-Bytes([string]$Path, [byte[]]$Expected, [string]$Message) {
    $actual = [IO.File]::ReadAllBytes($Path)
    Assert-True ($actual.Length -eq $Expected.Length) "$Message (length)"
    for ($i = 0; $i -lt $actual.Length; $i++) { if ($actual[$i] -ne $Expected[$i]) { throw "ASSERTION FAILED: $Message (byte $i)" } }
}
function New-TestDirectory([string]$Name) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-runtime-$Name-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

$script:ProcessRegistry = [hashtable]::Synchronized(@{})
$windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
$powershellExe = if ($windowsPowerShell) { $windowsPowerShell.Source } else { Join-Path $PSHOME 'pwsh.exe' }
$completed = Invoke-Exe $powershellExe @('-NoProfile','-NonInteractive','-Command','Write-Output complete; [Console]::Error.Write("captured")') -TimeoutMs 10000
Assert-True ($completed.Code -eq 0 -and $completed.Out -match 'complete' -and $completed.Err -match 'captured') 'completed child output is captured before return'
Assert-True ($script:ProcessRegistry.Count -eq 0) 'completed process is removed from registry'
Write-Host 'PASS completed process output and registry cleanup'

$sibling = New-Object System.Diagnostics.Process
$siblingInfo = New-Object System.Diagnostics.ProcessStartInfo
$siblingInfo.FileName = $powershellExe
$siblingInfo.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
$siblingInfo.UseShellExecute = $false
$siblingInfo.CreateNoWindow = $true
$sibling.StartInfo = $siblingInfo
[void]$sibling.Start()
try {
    $timed = Invoke-Exe $powershellExe @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -TimeoutMs 300
    Assert-True ($timed.Code -eq -1 -and $timed.Err -match 'Timed out') 'timed out owned child reports Code -1 and timeout text'
    Assert-True (-not $sibling.HasExited) 'timeout leaves unrelated test-owned sibling alive'
    Assert-True ($script:ProcessRegistry.Count -eq 0) 'timed out process is removed from registry'
} finally {
    if (-not $sibling.HasExited) { $sibling.Kill(); $null = $sibling.WaitForExit(5000) }
    $sibling.Dispose()
}
Write-Host 'PASS bounded timeout kills only the owned process'

$sourceDir = New-TestDirectory 'publish-source'
$destDir = New-TestDirectory 'publish-dest'
$names = @('one.mp4','two.m4a','three.mp4')
$pairs = @()
for ($i = 0; $i -lt 3; $i++) {
    $source = Join-Path $sourceDir $names[$i]
    [IO.File]::WriteAllBytes($source, [byte[]]@([byte](10 + $i), [byte](20 + $i), [byte](30 + $i)))
    $destination = Join-Path $destDir $names[$i]
    [IO.File]::WriteAllBytes($destination, [byte[]]@([byte](90 + $i), [byte](80 + $i)))
    $pairs += @{ Source = $source; Destination = $destination }
}
Publish-ReelFiles -Pairs $pairs -Dest $destDir
for ($i = 0; $i -lt 3; $i++) { Assert-Bytes $pairs[$i].Destination ([byte[]]@([byte](10 + $i),[byte](20 + $i),[byte](30 + $i))) 'successful publish replaces destination' }
Assert-True (@(Get-ChildItem -LiteralPath $destDir -Directory -Filter '.kidfby-publish-*').Count -eq 0) 'successful publish removes its transaction folder'
Write-Host 'PASS successful three-file publish'

# Cause the second staged move to fail after the first destination has changed.
for ($i = 0; $i -lt 3; $i++) { [IO.File]::WriteAllBytes($pairs[$i].Destination, [byte[]]@([byte](70 + $i),[byte](60 + $i))) }
$script:MoveCalls = 0
function Move-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force, [System.Management.Automation.ActionPreference]$ErrorAction='Continue')
    if ($script:MoveCalls -eq 1) { $script:MoveCalls++; throw 'Synthetic second destination failure' }
    $script:MoveCalls++
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction $ErrorAction
}
$publishFailed = $false
try { Publish-ReelFiles -Pairs $pairs -Dest $destDir } catch { $publishFailed = $_.Exception.Message -match 'previous destinations were restored' }
Assert-True $publishFailed 'injected publish error is reported after rollback'
for ($i = 0; $i -lt 3; $i++) { Assert-Bytes $pairs[$i].Destination ([byte[]]@([byte](70 + $i),[byte](60 + $i))) 'failed publish restores every old destination' }
Assert-True (@(Get-ChildItem -LiteralPath $destDir -Directory -Filter '.kidfby-publish-*').Count -eq 0) 'successful rollback removes its transaction folder'
Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
Write-Host 'PASS failed publish restores all previous files'

# Exercise Stop while the first destination move is paused inside a real runspace.
$gateMoved = New-Object System.Threading.ManualResetEvent($false)
$gateContinue = New-Object System.Threading.ManualResetEvent($false)
for ($i = 0; $i -lt 3; $i++) { [IO.File]::WriteAllBytes($pairs[$i].Destination, [byte[]]@([byte](40 + $i),[byte](30 + $i))) }
$publishFunctionText = ($engineAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-ReelFiles' }, $true) | Select-Object -First 1).Extent.Text
$moveWrapper = @'
function Move-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Force, [System.Management.Automation.ActionPreference]$ErrorAction='Continue')
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction $ErrorAction
    if ([IO.Path]::GetFileName($Destination) -eq 'one.mp4') {
        $script:GateMoved.Set() | Out-Null
        $script:GateContinue.WaitOne(15000) | Out-Null
    }
}
'@
$runspace = [RunspaceFactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('GateMoved', $gateMoved)
$runspace.SessionStateProxy.SetVariable('GateContinue', $gateContinue)
$runspace.SessionStateProxy.SetVariable('TestPairs', $pairs)
$runspace.SessionStateProxy.SetVariable('TestDest', $destDir)
$asyncPowerShell = [PowerShell]::Create()
$asyncPowerShell.Runspace = $runspace
$null = $asyncPowerShell.AddScript($moveWrapper + "`n" + $publishFunctionText + "`nPublish-ReelFiles -Pairs `$TestPairs -Dest `$TestDest")
$async = $asyncPowerShell.BeginInvoke()
try {
    Assert-True ($gateMoved.WaitOne(10000)) 'runspace reached the first destination move'
    $stopAsync = $asyncPowerShell.BeginStop($null, $null)
    $gateContinue.Set() | Out-Null
    $null = $asyncPowerShell.EndStop($stopAsync)
} finally {
    $gateContinue.Set() | Out-Null
    $asyncPowerShell.Dispose()
    $runspace.Dispose()
    $gateMoved.Dispose()
    $gateContinue.Dispose()
}
for ($i = 0; $i -lt 3; $i++) { Assert-Bytes $pairs[$i].Destination ([byte[]]@([byte](40 + $i),[byte](30 + $i))) 'runspace cancellation restores every previous destination' }
Assert-True (@(Get-ChildItem -LiteralPath $destDir -Directory -Filter '.kidfby-publish-*').Count -eq 0) 'canceled publish removes transaction directory after rollback'
Write-Host 'PASS runspace cancellation rolls back all three destinations'

# Use a local compiled recorder stub in place of scrcpy; no device or network is used.
$fakeScrcpy = Join-Path ([IO.Path]::GetTempPath()) ("kidfby-recorder-" + [Guid]::NewGuid().ToString('N') + '.exe')
$recorderSource = @'
using System;
using System.IO;
public static class KidFbyTestRecorder {
    public static int Main(string[] args) {
        if (Array.IndexOf(args, "--no-window") < 0 || Environment.GetEnvironmentVariable("SDL_VIDEODRIVER") == "dummy") {
            Console.Error.WriteLine("Recording must request no window and must not force the dummy video driver.");
            return 9;
        }
        foreach (string arg in args) {
            if (arg.StartsWith("--record=", StringComparison.Ordinal)) {
                File.WriteAllBytes(arg.Substring("--record=".Length), new byte[2048]);
                return 0;
            }
        }
        return 8;
    }
}
'@
$csc = Get-Command csc.exe -ErrorAction SilentlyContinue
if (-not $csc) {
    $cscCandidate = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-Path -LiteralPath $cscCandidate) { $csc = [pscustomobject]@{ Source = $cscCandidate } }
}
if (-not $csc) { throw 'A local C# compiler is required for the synthetic scrcpy recorder fixture.' }
$recorderCs = [IO.Path]::ChangeExtension($fakeScrcpy, '.cs')
[IO.File]::WriteAllText($recorderCs, $recorderSource, [Text.Encoding]::UTF8)
& $csc.Source /nologo /target:exe "/out:$fakeScrcpy" $recorderCs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeScrcpy)) { throw 'Could not compile the synthetic scrcpy recorder fixture.' }
Remove-Item -LiteralPath $recorderCs -Force -ErrorAction SilentlyContinue

$script:InvokeMode = 'DownloadExit'
function Invoke-Exe {
    param([string]$Exe, [string[]]$ExeArgs, [int]$TimeoutMs=15000)
    if ($Exe -eq 'ytdlp' -and $ExeArgs -contains '--print') { return [pscustomobject]@{ Code=0; Out='synthetic-id'; Err='' } }
    if ($Exe -eq 'ytdlp') {
        $outputIndex = [Array]::IndexOf($ExeArgs, '-o')
        $outputFile = $ExeArgs[$outputIndex + 1].Replace('%(ext)s','mp4')
        [IO.File]::WriteAllBytes($outputFile, [byte[]]@(1,2,3,4))
        return [pscustomobject]@{ Code=$(if ($script:InvokeMode -eq 'DownloadExit') { 7 } else { 0 }); Out=''; Err='synthetic download failure' }
    }
    if ($Exe -eq 'ffprobe') {
        if ($ExeArgs -contains 'json') { return [pscustomobject]@{Code=0;Out='{"streams":[{"codec_name":"h264","codec_type":"video","width":640,"height":360,"duration":"3.0"},{"codec_type":"audio"}],"format":{"duration":"3.0"}}';Err=''} }
        $joined = $ExeArgs -join ' '
        if ($joined -match 'stream=duration') { return [pscustomobject]@{ Code=0; Out='3.0'; Err='' } }
        if ($joined -match 'stream=width') { return [pscustomobject]@{ Code=0; Out='640'; Err='' } }
        if ($joined -match 'stream=height') { return [pscustomobject]@{ Code=0; Out='360'; Err='' } }
        if ($joined -match 'codec_name') { return [pscustomobject]@{ Code=0; Out='h264'; Err='' } }
        return [pscustomobject]@{ Code=0; Out="video`naudio`n3.0"; Err='' }
    }
    if ($Exe -eq 'ffmpeg') {
        if ($ExeArgs -contains '192k') { $script:CutCalls++ }
        $target = $ExeArgs[-1]
        if ($target -ne '-') { [IO.File]::WriteAllBytes($target, [byte[]]@(5,6,7)) }
        if ($script:InvokeMode -eq 'FfmpegExit' -and $ExeArgs -contains '192k') { return [pscustomobject]@{ Code=19; Out=''; Err='synthetic ffmpeg failure' } }
        return [pscustomobject]@{ Code=0; Out=''; Err='' }
    }
    return [pscustomobject]@{ Code=0; Out=''; Err='' }
}
function Invoke-Adb { param($T,[string[]]$AdbArgs) [pscustomobject]@{ Code=0; Out=''; Err='' } }
function Ensure-VietnameseDubbing { param($T,[string]$Url) 'unverified' }
function Open-Reel { param($T,[string]$Url) [pscustomobject]@{ Code=0; Out=''; Err='' } }
function Get-VideoDuration { param($T,[string]$File) 3.0 }
function Get-VideoSize { param($T,[string]$File) [pscustomobject]@{ W='640'; H='360' } }
function Get-Duration { param($T,[string]$File) 3.0 }
function Get-AudioOnset { param($T,[string]$File) 0.0 }
function Get-MeanVolume { param($T,[string]$File) -18.0 }
function Start-Sleep { param([int]$Milliseconds,[int]$Seconds) }

$oldEnv = @()
$standardNames = @('synthetic-id-1-video-goc.mp4','synthetic-id-2-am-thanh-tho.m4a','synthetic-id-3-hoan-chinh.mp4')
$oldPaths = @()
for ($i = 0; $i -lt 3; $i++) {
    $old = [byte[]]@([byte](11 + $i),[byte](21 + $i))
    $oldEnv += ,$old
    $oldPath = Join-Path $destDir $standardNames[$i]
    $oldPaths += $oldPath
    [IO.File]::WriteAllBytes($oldPath, $old)
}
$testTools = [pscustomobject]@{ ytdlp='ytdlp'; ffmpeg='ffmpeg'; ffprobe='ffprobe'; scrcpy=$fakeScrcpy; Serial='test-only' }
$script:InvokeMode = 'DownloadExit'
$downloadResult = Invoke-OneLink -T $testTools -Url 'https://example.invalid/reel' -Dest $destDir
Assert-True ($null -eq $downloadResult) 'nonzero yt-dlp download cannot return success'
for ($i = 0; $i -lt 3; $i++) { Assert-Bytes $oldPaths[$i] $oldEnv[$i] 'download failure leaves old destinations untouched' }
Write-Host 'PASS nonzero download cannot report success or alter outputs'

$script:InvokeMode = 'FfmpegExit'
$script:CutCalls = 0
$ffmpegResult = Invoke-OneLink -T $testTools -Url 'https://example.invalid/reel' -Dest $destDir
Assert-True ($script:CutCalls -eq 1) 'windowless recorder completes and reaches the FFmpeg cut stage without a dummy renderer'
Assert-True ($null -eq $ffmpegResult) 'nonzero FFmpeg cut cannot return success'
for ($i = 0; $i -lt 3; $i++) { Assert-Bytes $oldPaths[$i] $oldEnv[$i] 'FFmpeg failure leaves old destinations untouched' }
Write-Host 'PASS nonzero FFmpeg cannot report success or alter outputs'

Remove-Item -LiteralPath $fakeScrcpy -Force -ErrorAction SilentlyContinue
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
foreach ($testPath in @($sourceDir,$destDir)) {
    $resolvedPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testPath).Path)
    if (-not $resolvedPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove test directory outside temp root: $resolvedPath" }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction SilentlyContinue
}
