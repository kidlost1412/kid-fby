#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core\kid-fby.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Write-Step','Write-Ok','Write-Note','Write-Warn2','Show-Fail','Quote-Arg','Get-ReelProcessTimeoutMs','Invoke-OneLink')) {
    $fn=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
    if (-not $fn) { throw "Missing engine function: $name" }
    Invoke-Expression $fn.Extent.Text
}
. (Join-Path $Root 'core\whisper-language.ps1')
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$fixture=Join-Path $tempBase ('kidfby-language-integration-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $recorder=Join-Path $fixture 'recorder.exe'
    Add-Type -OutputAssembly $recorder -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class LanguageIntegrationRecorder {
    public static int Main(string[] args) {
        foreach(string arg in args) if(arg.StartsWith("--record=")) { File.WriteAllBytes(arg.Substring(9),new byte[2048]); return 0; }
        return 9;
    }
}
'@
    function Invoke-Exe {
        param([string]$Exe,[string[]]$ExeArgs,[int]$TimeoutMs=15000)
        if($Exe -eq 'ytdlp' -and $ExeArgs -contains '--print') { return [pscustomobject]@{Code=0;Out='integration-id';Err=''} }
        if($Exe -eq 'ytdlp') { $index=[Array]::IndexOf($ExeArgs,'-o'); [IO.File]::WriteAllBytes($ExeArgs[$index+1].Replace('%(ext)s','mp4'),[byte[]]@(1,2,3)) }
        elseif($Exe -eq 'ffprobe') { return [pscustomobject]@{Code=0;Out='h264';Err=''} }
        elseif($Exe -eq 'ffmpeg' -and $ExeArgs[-1] -ne '-') { [IO.File]::WriteAllBytes($ExeArgs[-1],[byte[]]@(4,5,6)) }
        return [pscustomobject]@{Code=0;Out='';Err=''}
    }
    function Invoke-Adb { param($T,[string[]]$AdbArgs) [pscustomobject]@{Code=0;Out='';Err=''} }
    function Ensure-VietnameseDubbing { param($T,[string]$Url) 'unverified' }
    function Open-Reel { param($T,[string]$Url) }
    function Get-VideoDuration { param($T,[string]$File) 10.0 }
    function Get-VideoSize { param($T,[string]$File) [pscustomobject]@{W='640';H='360'} }
    function Get-VideoCodec { param($T,[string]$File) 'h264' }
    function Get-Duration { param($T,[string]$File) 20.0 }
    function Get-AudioOnset { param($T,[string]$File) 1.8 }
    function Get-MeanVolume { param($T,[string]$File) -18.0 }
    function Start-Sleep { param([int]$Milliseconds,[int]$Seconds) }
    function Test-ValidReelOutput { param($T,[string]$File) $true }
    function Get-ReelAudioLanguage {
        param($T,[string]$File,[string]$Root,[string]$WorkDir)
        $script:classificationCalls++
        if(-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Classifier input is not the completed cut audio.' }
        return [pscustomobject]@{Status=$script:fixtureStatus;Language='en';Probability=0.92;Samples=1;ElapsedMs=20;Reason='fixture'}
    }
    function Publish-ReelFiles {
        param([Collections.IDictionary[]]$Pairs,[string]$Dest)
        foreach($pair in $Pairs) { Copy-Item -LiteralPath $pair.Source -Destination $pair.Destination -Force -ErrorAction Stop }
    }
    $tools=@{ytdlp='ytdlp';ffmpeg='ffmpeg';ffprobe='ffprobe';scrcpy=$recorder;Serial='fixture-only'}
    foreach($case in @(@{Skip=$true;Status='detected'},@{Skip=$false;Status='detected'},@{Skip=$false;Status='error'})) {
        $script:SkipLanguageCheck=$case.Skip; $script:fixtureStatus=$case.Status; $script:classificationCalls=0
        $out=Join-Path $fixture ([Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $out | Out-Null
        $result=Invoke-OneLink -T $tools -Url 'https://example.invalid/reel' -Dest $out
        if(-not $result -or -not (Test-Path -LiteralPath $result.File)) { throw 'Language estimate prevented successful video publication.' }
        $expectedCalls=if($case.Skip) {0} else {1}
        $expectedStatus=if($case.Skip) {'skipped'} else {$case.Status}
        if($script:classificationCalls -ne $expectedCalls -or $result.AudioLanguage.Status -ne $expectedStatus) { throw 'Language switch/result integration is incorrect.' }
    }
    Write-Host 'PASS engine integration: disabled skips tiny; other language and model error retain all outputs and review result.'
} finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixture).Path)
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe integration fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
