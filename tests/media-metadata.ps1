#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core\kid-fby.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Engine parse failed.' }
foreach ($name in @('Quote-Arg','Invoke-Exe','Get-Duration','Get-VideoSize','Get-VideoDuration','Get-VideoCodec','Test-ValidReelOutput')) {
    $fn=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
    if (-not $fn) { throw "Missing engine function: $name" }
    Invoke-Expression $fn.Extent.Text
}
$script:InvokeExeReal=(Get-Item Function:\Invoke-Exe).ScriptBlock
function Invoke-Exe {
    param([string]$Exe,[string[]]$ExeArgs,[int]$TimeoutMs=15000)
    if ($Exe -ne 'mock-ffprobe') { return & $script:InvokeExeReal $Exe $ExeArgs -TimeoutMs $TimeoutMs }
    $index=0
    $counterPath=$script:statePath+'.counter'
    if (Test-Path -LiteralPath $counterPath) { $index=[int][IO.File]::ReadAllText($counterPath) }
    $state=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:statePath))
    if ($index -ge $state.Responses.Count) { $index=$state.Responses.Count-1 }
    [IO.File]::WriteAllText($counterPath,[string]($index+1))
    return $state.Responses[$index]
}

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

$fixtureBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixturePath=Join-Path $fixtureBase ('kidfby-metadata-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixturePath | Out-Null
try {
    $statePath=Join-Path $fixturePath 'response.json'
    $script:statePath=$statePath
    function Set-ProbeResponses {
        param([object[]]$Responses)
        $state=[pscustomobject]@{Responses=@($Responses)}
        [IO.File]::WriteAllText($script:statePath,($state | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText(($script:statePath+'.counter'),'0')
    }
    function New-ProbeResponse {
        param([string]$Out,[int]$Code=0,[string]$Err='')
        return [pscustomobject]@{Out=$Out;Code=$Code;Err=$Err}
    }
    $videoAudio='{"streams":[{"codec_type":"video","width":1440,"height":2560,"codec_name":"av1","duration":"1.25","side_data_list":[{"side_data_type":"Ambient viewing environment"}]},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"1.25"}}'
    $tools=@{ffprobe='mock-ffprobe'}
    $mockFile=Join-Path $fixturePath 'fixture.mp4'
    [IO.File]::WriteAllBytes($mockFile,[byte[]](1,2,3))

    Set-ProbeResponses @((New-ProbeResponse $videoAudio))
    $size=Get-VideoSize $tools $mockFile
    Assert-True ($size.W -is [int] -and $size.H -is [int] -and $size.W -eq 1440 -and $size.H -eq 2560) 'Video dimensions were not returned as positive integers.'
    Set-ProbeResponses @((New-ProbeResponse $videoAudio))
    Assert-True ((Get-VideoCodec $tools $mockFile) -ceq 'av1') 'Video codec did not return normalized av1.'
    Set-ProbeResponses @((New-ProbeResponse '{"streams":[{"codec_name":"av1,"}]}'))
    $codecFailed=$false
    try { $null=Get-VideoCodec $tools $mockFile } catch { $codecFailed=$_.Exception.Message -match 'codec' }
    Assert-True $codecFailed 'Invalid codec metadata did not produce an actionable error.'
    Set-ProbeResponses @((New-ProbeResponse $videoAudio))
    $streamDuration=Get-VideoDuration $tools $mockFile
    Assert-True ([Math]::Abs($streamDuration-1.25) -lt 0.0001) 'Valid stream duration was not parsed from JSON.'
    Set-ProbeResponses @((New-ProbeResponse '{"streams":[{"duration":"NaN"}]}'),(New-ProbeResponse "1.75`n"))
    $fallbackDuration=Get-VideoDuration $tools $mockFile
    Assert-True ([Math]::Abs($fallbackDuration-1.75) -lt 0.0001) 'Invalid stream duration did not fall back to format duration.'

    Set-ProbeResponses @((New-ProbeResponse $videoAudio))
    Assert-True (Test-ValidReelOutput $tools $mockFile) 'Valid video/audio metadata with side_data_list was rejected.'
    Set-ProbeResponses @((New-ProbeResponse '{broken json'))
    Assert-True (-not (Test-ValidReelOutput $tools $mockFile)) 'Malformed probe JSON was accepted.'
    Set-ProbeResponses @((New-ProbeResponse '' 1 'probe failure'))
    Assert-True (-not (Test-ValidReelOutput $tools $mockFile)) 'Nonzero ffprobe exit was accepted.'
    Set-ProbeResponses @((New-ProbeResponse '{"streams":[{"codec_type":"video"}],"format":{"duration":"1"}}'))
    Assert-True (-not (Test-ValidReelOutput $tools $mockFile)) 'Video-only metadata was accepted.'
    Set-ProbeResponses @((New-ProbeResponse '{"streams":[{"codec_type":"audio"}],"format":{"duration":"1"}}'))
    Assert-True (-not (Test-ValidReelOutput $tools $mockFile)) 'Audio-only metadata was accepted.'
    foreach ($badDuration in @('Infinity','-Infinity','NaN','0','0.5','invalid')) {
        $payload='{"streams":[{"codec_type":"video"},{"codec_type":"audio"}],"format":{"duration":"'+$badDuration+'"}}'
        Set-ProbeResponses @((New-ProbeResponse $payload))
        Assert-True (-not (Test-ValidReelOutput $tools $mockFile)) ("Invalid duration '{0}' was accepted." -f $badDuration)
    }
    Write-Host 'PASS metadata JSON: dimensions, codec, duration fallback, side_data_list, stream requirements, and invalid probes.'

    $ffmpeg=Get-Command ffmpeg -ErrorAction SilentlyContinue
    $ffprobe=Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($ffmpeg -and $ffprobe) {
        $both=Join-Path $fixturePath 'rotated.mp4'; $silent=Join-Path $fixturePath 'video-only.mp4'
        $r=& $script:InvokeExeReal $ffmpeg.Source @('-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=blue:s=160x90:r=10:d=1','-f','lavfi','-i','sine=frequency=440:duration=1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-shortest',$both)
        if ($r.Code -ne 0) { throw ("FFmpeg could not encode the real metadata fixture: {0}" -f $r.Err) }
        $rotated=Join-Path $fixturePath 'rotated-with-matrix.mp4'
        $r=& $script:InvokeExeReal $ffmpeg.Source @('-hide_banner','-loglevel','error','-y','-display_rotation:v:0','90','-i',$both,'-c','copy',$rotated)
        if ($r.Code -ne 0) {
            # Older FFmpeg builds may only support the legacy metadata option.
            $r=& $script:InvokeExeReal $ffmpeg.Source @('-hide_banner','-loglevel','error','-y','-i',$both,'-c','copy','-metadata:s:v:0','rotate=90',$rotated)
        }
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $rotated -PathType Leaf)) { throw ("FFmpeg could not add Display Matrix side data: {0}" -f $r.Err) }
        $probe=& $script:InvokeExeReal $ffprobe.Source @('-v','error','-show_entries','stream=codec_type,width,height:stream_side_data','-of','json',$rotated)
        if ($probe.Code -ne 0) { throw ("ffprobe could not inspect the rotated fixture: {0}" -f $probe.Err) }
        $realData=ConvertFrom-Json -InputObject $probe.Out -ErrorAction Stop
        $hasDisplayMatrix=$false
        foreach ($stream in @($realData.streams)) {
            foreach ($sideData in @($stream.side_data_list)) {
                if ([string]$sideData.side_data_type -match '(?i)display matrix') { $hasDisplayMatrix=$true }
            }
        }
        Assert-True $hasDisplayMatrix 'FFmpeg did not emit Display Matrix side data for the rotated fixture.'
        $realTools=@{ffprobe=$ffprobe.Source}
        Assert-True (Test-ValidReelOutput $realTools $rotated) 'Real rotated media with Display Matrix side data was rejected.'
        $realSize=Get-VideoSize $realTools $rotated
        Assert-True ($realSize.W -is [int] -and $realSize.H -is [int] -and $realSize.W -gt 0 -and $realSize.H -gt 0) 'Real rotated media returned invalid dimensions.'
        $r=& $script:InvokeExeReal $ffmpeg.Source @('-hide_banner','-loglevel','error','-y','-i',$rotated,'-map','0:v:0','-c:v','copy','-an',$silent)
        if ($r.Code -ne 0) { throw $r.Err }
        Assert-True (-not (Test-ValidReelOutput $realTools $silent)) 'Real video-only media was accepted.'
        Write-Host 'PASS real FFmpeg rotated fixture: Display Matrix accepted; dimensions valid; video-only rejected.'
    } else { Write-Host 'SKIP real side_data fixture: ffmpeg/ffprobe are not on PATH.' }
} finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixturePath).Path)
    if (-not $resolved.StartsWith(($fixtureBase+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^kidfby-metadata-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
