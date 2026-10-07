#Requires -Version 5.1
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'core\whisper-language.ps1')
$paths=Get-WhisperPaths -Root $Root
$ffmpeg=Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobe=Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $paths.Ready -or -not $ffmpeg -or -not $ffprobe) {
    Write-Host 'SKIP real tiny fixtures: optional Whisper/FFmpeg is not installed.'
    return
}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'core\kid-fby.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Quote-Arg','Invoke-Exe','Write-Note','Write-Warn2')) {
    $fn=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
    if (-not $fn) { throw "Missing engine function: $name" }
    Invoke-Expression $fn.Extent.Text
}
$t=@{ffmpeg=$ffmpeg.Source;ffprobe=$ffprobe.Source}
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$work=Join-Path $tempBase ('kidfby-whisper-media-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Add-Type -AssemblyName System.Speech
    $synth=New-Object System.Speech.Synthesis.SpeechSynthesizer
    $english=Join-Path $work 'english.wav'
    try {
        $voice=$synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'en' } | Select-Object -First 1
        if (-not $voice) { throw 'No local English voice available for fixture.' }
        $synth.SelectVoice($voice.VoiceInfo.Name)
        $synth.SetOutputToWaveFile($english)
        $synth.Speak('This is a short English recording. We are testing automatic language detection on this computer with a small model.')
        $synth.SetOutputToNull()
    } finally { $synth.Dispose() }
    $r=Get-ReelAudioLanguage -T $t -File $english -Root $Root -WorkDir $work
    if ($r.Status -ne 'detected' -or $r.Language -ne 'en' -or $r.Samples -ne 1) { throw "English fixture failed: $($r | ConvertTo-Json -Compress)" }
    Write-Host "PASS real tiny: English speech, samples=$($r.Samples), elapsedMs=$($r.ElapsedMs)."

    $silence=Join-Path $work 'silence.wav'
    $made=Invoke-Exe $t.ffmpeg @('-hide_banner','-loglevel','error','-y','-f','lavfi','-i','anullsrc=r=16000:cl=mono','-t','10','-c:a','pcm_s16le',$silence)
    if ($made.Code -ne 0) { throw $made.Err }
    $r=Get-ReelAudioLanguage -T $t -File $silence -Root $Root -WorkDir $work
    if ($r.Status -ne 'unknown') { throw "Silence was classified as a language: $($r | ConvertTo-Json -Compress)" }
    Write-Host "PASS real tiny: silence stays unknown, elapsedMs=$($r.ElapsedMs)."

    $tiny=Join-Path $work 'short.wav'
    $made=Invoke-Exe $t.ffmpeg @('-hide_banner','-loglevel','error','-y','-i',$english,'-t','1','-c:a','pcm_s16le',$tiny)
    if ($made.Code -ne 0) { throw $made.Err }
    $r=Get-ReelAudioLanguage -T $t -File $tiny -Root $Root -WorkDir $work
    if ($r.Status -ne 'unknown' -or $r.Samples -ne 0) { throw 'Sub-two-second fixture must stay unknown without sampling.' }
    Write-Host 'PASS real tiny: insufficient speech duration stays unknown.'
    if (@(Get-ChildItem -LiteralPath $work -Filter 'whisper-sample-*.wav').Count) { throw 'Classifier leaked temporary sample files.' }
} finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $work).Path)
    if (-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe media test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
