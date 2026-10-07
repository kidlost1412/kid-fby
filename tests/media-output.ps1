#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$ffmpeg=Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobe=Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffmpeg -or -not $ffprobe) { Write-Host 'SKIP real media fixture: ffmpeg/ffprobe are not on PATH.'; return }
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core\kid-fby.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Engine parse failed.' }
foreach ($name in @('Quote-Arg','Invoke-Exe','Test-ValidReelOutput')) {
    $fn=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
    if (-not $fn) { throw "Missing engine function: $name" }
    Invoke-Expression $fn.Extent.Text
}
$mediaTools=@{ffmpeg=$ffmpeg.Source; ffprobe=$ffprobe.Source}
$fixtureBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixturePath=Join-Path $fixtureBase ('kidfby-media-review-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixturePath | Out-Null
try {
    $both=Join-Path $fixturePath 'both.mp4'; $silent=Join-Path $fixturePath 'video-only.mp4'
    $r=Invoke-Exe $mediaTools.ffmpeg @('-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=blue:s=160x90:r=10:d=1','-f','lavfi','-i','sine=frequency=440:duration=1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-shortest',$both)
    if ($r.Code -ne 0) { throw $r.Err }
    $r=Invoke-Exe $mediaTools.ffmpeg @('-hide_banner','-loglevel','error','-y','-i',$both,'-map','0:v:0','-c:v','copy','-an',$silent)
    if ($r.Code -ne 0) { throw $r.Err }
    if (-not (Test-ValidReelOutput $mediaTools $both)) { throw 'Valid real FFmpeg audio/video fixture rejected.' }
    if (Test-ValidReelOutput $mediaTools $silent) { throw 'Video-only fixture accepted incorrectly.' }
    Write-Host 'PASS real FFmpeg/ffprobe: one-second audio+video accepted; video-only rejected.'
} finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixturePath).Path)
    if (-not $resolved.StartsWith(($fixtureBase+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
