param([string]$Root=(Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $Root 'core/whisper-language.ps1'
$enginePath = Join-Path $Root 'core/kid-fby.ps1'
foreach ($path in @($modulePath,$enginePath)) {
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell parse failed for $path`: $($errors[0].Message)" }
}
$engineTokens=$null; $engineErrors=$null
$engineAst=[System.Management.Automation.Language.Parser]::ParseFile($enginePath,[ref]$engineTokens,[ref]$engineErrors)
foreach ($name in @('Quote-Arg','Invoke-Exe','Write-Note','Write-Warn2')) {
    $functionAst=$engineAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true) | Select-Object -First 1
    if (-not $functionAst) { throw "Missing required engine function in AST: $name" }
    Invoke-Expression $functionAst.Extent.Text
}
. $modulePath

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function New-WhisperFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('kidfby-whisper-' + [Guid]::NewGuid().ToString('N'))
    $release=Join-Path $root 'tools/whisper/bin/Release'
    [void][IO.Directory]::CreateDirectory($release)
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'work'))
    foreach ($name in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll')) {
        [IO.File]::WriteAllBytes((Join-Path $release $name),[byte[]]@(1,2,3))
    }
    [IO.File]::WriteAllBytes((Join-Path $root 'tools/whisper/ggml-tiny.bin'),[byte[]]@(4,5,6))
    $input=Join-Path $root 'input.m4a'
    [IO.File]::WriteAllBytes($input,[byte[]]@(9,8,7))
    return [pscustomobject]@{Root=$root; Work=Join-Path $root 'work'; File=$input; Tools=[pscustomobject]@{ffmpeg='ffmpeg';ffprobe='ffprobe'}}
}
function Remove-WhisperFixture($Fixture) {
    if (-not $Fixture) { return }
    $full=[IO.Path]::GetFullPath($Fixture.Root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove fixture outside temp: $full" }
    if ([IO.Directory]::Exists($full)) { [IO.Directory]::Delete($full,$true) }
}

$script:WhisperMode='FirstHigh'
$script:WhisperCalls=0
$script:Duration=15.0
$script:SampleDuration=6.0
$script:LastWhisperArgs=$null
$script:LastWhisperTimeout=0
$script:Volume='-18.0'
$script:ThrowAt=''
$script:Notes=New-Object 'System.Collections.Generic.List[string]'
function Write-Note($Text) { $script:Notes.Add([string]$Text) }
function Write-Warn2($Text) { $script:Notes.Add([string]$Text) }
function Invoke-Exe {
    param([string]$Exe,[string[]]$ExeArgs,[int]$TimeoutMs=15000)
    if ($Exe -eq 'ffprobe') {
        if ($ExeArgs[-1] -match '\.wav$') {
            if ($script:ThrowAt -eq 'SampleProbe') { throw 'synthetic sample probe failure' }
            return [pscustomobject]@{Code=0;Out=$script:SampleDuration.ToString([Globalization.CultureInfo]::InvariantCulture);Err=''}
        }
        if ($script:ThrowAt -eq 'DurationProbe') { return [pscustomobject]@{Code=-1;Out='';Err='Timed out'} }
        return [pscustomobject]@{Code=0;Out=$script:Duration.ToString([Globalization.CultureInfo]::InvariantCulture);Err=''}
    }
    if ($Exe -eq 'ffmpeg') {
        if ($ExeArgs -contains 'volumedetect') {
            return [pscustomobject]@{Code=0;Out='';Err=("[Parsed_volumedetect_0 @ 00000000] mean_volume: {0} dB" -f $script:Volume)}
        }
        if ($script:ThrowAt -eq 'CancelExtract') { throw ([System.Management.Automation.PipelineStoppedException]::new()) }
        if ($script:ThrowAt -eq 'Extract') { throw 'synthetic extraction failure' }
        [IO.File]::WriteAllBytes($ExeArgs[-1],[byte[]]@(1,2,3,4))
        return [pscustomobject]@{Code=0;Out='';Err=''}
    }
    if ($Exe -match 'whisper-cli\.exe$') {
        $script:WhisperCalls++
        $script:LastWhisperArgs=$ExeArgs
        $script:LastWhisperTimeout=$TimeoutMs
        if ($script:WhisperMode -eq 'CliFailure') { return [pscustomobject]@{Code=5;Out='';Err='auto-detected language: vi (p = 0.999000)'} }
        if ($script:WhisperMode -eq 'WhisperTimeout') { return [pscustomobject]@{Code=-1;Out='';Err='Timed out'} }
        if ($script:WhisperMode -eq 'FirstLowThenHigh' -and $script:WhisperCalls -eq 1) { return [pscustomobject]@{Code=0;Out='';Err='auto-detected language: vi (p = 0.600000)'} }
        if ($script:WhisperMode -eq 'BothLow') { return [pscustomobject]@{Code=0;Out='';Err='auto-detected language: en (p = 0.500000)'} }
        if ($script:WhisperMode -eq 'FirstLowThenHigh' -or $script:WhisperMode -eq 'OtherHigh') { return [pscustomobject]@{Code=0;Out='';Err='auto-detected language: en (p = 0.930000)'} }
        if ($script:WhisperMode -eq 'Malformed') { return [pscustomobject]@{Code=0;Out='';Err='English: 0.99'} }
        return [pscustomobject]@{Code=0;Out='';Err='auto-detected language: vi (p = 0.990000)'}
    }
    throw "Unexpected process requested by test: $Exe"
}

$fixture=New-WhisperFixture
try {
    $validVi=ConvertFrom-WhisperLanguage -Text 'whisper_full_with_state: auto-detected language: vi (p = 0.996762)'
    $validEn=ConvertFrom-WhisperLanguage -Text 'whisper_full_with_state: auto-detected language: en (p = 0.90)'
    Assert-True ($validVi.Language -eq 'vi' -and [Math]::Abs($validVi.Probability-0.996762) -lt 0.000001) 'parser reads the exact Vietnamese diagnostic and invariant probability'
    Assert-True ($validEn.Language -eq 'en' -and $validEn.Probability -eq 0.9) 'parser reads the exact English diagnostic'
    foreach ($badText in @('auto-detected language: english (p = 0.99)','auto-detected language: e (p = 0.99)','auto-detected language: VI (p = 0.99)','auto-detected language: vi (p = 1.01)','auto-detected language: vi (p = NaN)','unrelated words vi (p = 0.99)')) {
        Assert-True ($null -eq (ConvertFrom-WhisperLanguage -Text $badText)) "parser rejects malformed diagnostic: $badText"
    }
    Write-Host 'PASS strict Whisper stderr parser'

    $paths=Get-WhisperPaths -Root $fixture.Root
    Assert-True $paths.Ready 'runtime fixture has a complete local Whisper installation'
    $missingRoot=Join-Path ([IO.Path]::GetTempPath()) ('kidfby-whisper-missing-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($missingRoot)
    try {
        $script:WhisperCalls=0
        $unavailable=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $missingRoot -WorkDir $fixture.Work
        Assert-True ($unavailable.Status -eq 'unavailable' -and $unavailable.Reason -eq 'missing-tool' -and $script:WhisperCalls -eq 0) 'missing local Whisper tools never start a process'
    } finally { [IO.Directory]::Delete($missingRoot,$true) }
    Write-Host 'PASS missing-tool status without process launch'

    $script:WhisperMode='FirstHigh'; $script:WhisperCalls=0; $script:ThrowAt=''; $script:Volume='-18.0'; $script:Duration=15.0
    $first=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($first.Status -eq 'detected' -and $first.Language -eq 'vi' -and $first.Probability -ge 0.85) ("high confidence detects the language; got {0}" -f ($first | ConvertTo-Json -Compress))
    Assert-True ($script:WhisperCalls -eq 1) 'high confidence stops after the first sample'
    Assert-True (($script:LastWhisperArgs -contains '-dl') -and ($script:LastWhisperArgs -contains '-ng') -and ($script:LastWhisperArgs -contains '-t') -and ($script:LastWhisperArgs -contains '4')) 'Whisper uses detect-language CPU arguments'
    Assert-True (-not ($script:LastWhisperArgs -contains '-l') -and -not ($script:LastWhisperArgs -contains '-otxt')) 'classification does not force a language or request transcription output'
    Assert-True ($first.ElapsedMs -ge 0) 'elapsed time is populated'
    Write-Host 'PASS high-confidence one-sample CPU language classification'

    $script:WhisperMode='FirstLowThenHigh'; $script:WhisperCalls=0
    $retry=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($retry.Status -eq 'detected' -and $retry.Language -eq 'en' -and $script:WhisperCalls -eq 2) 'low confidence retries once and accepts a high-confidence second sample'
    Assert-True ($script:LastWhisperArgs -contains '-dl') 'retry uses detect-language mode'
    Write-Host 'PASS low-confidence retry and early stop'

    $script:WhisperMode='BothLow'; $script:WhisperCalls=0
    $low=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($low.Status -eq 'unknown' -and $low.Reason -eq 'low-confidence' -and $low.Language -eq 'en' -and $script:WhisperCalls -eq 2) 'two low scores remain unknown while retaining diagnostic language and score'
    Write-Host 'PASS two low-confidence samples remain unknown'

    $script:Duration=1.5; $script:WhisperCalls=0
    $short=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($short.Status -eq 'unknown' -and $short.Reason -eq 'too-short' -and $script:WhisperCalls -eq 0) 'clips shorter than two seconds are skipped'
    $script:Duration=6.0; $script:Volume='-inf'; $script:WhisperCalls=0
    $silent=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($silent.Status -eq 'unknown' -and $silent.Reason -eq 'silent-sample' -and $script:WhisperCalls -eq 0) 'silent samples are rejected without treating loudness as speech evidence'
    Write-Host 'PASS short and silent inputs stay unknown'

    $script:Duration=6.0; $script:Volume='-18.0'; $script:WhisperMode='CliFailure'; $script:WhisperCalls=0
    $failedCli=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($failedCli.Status -eq 'error' -and $failedCli.Language -eq $null -and $script:WhisperCalls -eq 1) 'nonzero Whisper exit cannot accept a language-looking diagnostic'
    $script:WhisperMode='WhisperTimeout'; $script:WhisperCalls=0
    $timed=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($timed.Status -eq 'error' -and $timed.Language -eq $null -and $script:LastWhisperTimeout -le 10000) 'Whisper timeout stays bounded and cannot return a detected language'
    $script:ThrowAt='SampleProbe'
    $sampleFailed=Get-ReelAudioLanguage -T $fixture.Tools -File $fixture.File -Root $fixture.Root -WorkDir $fixture.Work
    Assert-True ($sampleFailed.Status -eq 'error') 'sample probe errors are reported without throwing'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.Work -Filter 'whisper-sample-*.wav' -File).Count -eq 0) 'sample WAVs are cleaned after operational errors'
    $gateStarted=New-Object System.Threading.ManualResetEvent($false)
    $gateRelease=New-Object System.Threading.ManualResetEvent($false)
    $moduleTokens=$null; $moduleErrors=$null
    $moduleAst=[System.Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$moduleTokens,[ref]$moduleErrors)
    $runspaceFunctions=@()
    foreach ($name in @('Get-WhisperPaths','ConvertFrom-WhisperLanguage','Get-ReelAudioLanguage')) {
        $node=$moduleAst.FindAll({param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true) | Select-Object -First 1
        $runspaceFunctions += $node.Extent.Text
    }
    $blockingMock=@'
function Invoke-Exe {
    param([string]$Exe,[string[]]$ExeArgs,[int]$TimeoutMs=15000)
    if ($Exe -eq 'ffprobe') {
        if ($ExeArgs[-1] -match '\.wav$') { return [pscustomobject]@{Code=0;Out='6.0';Err=''} }
        return [pscustomobject]@{Code=0;Out='6.0';Err=''}
    }
    if ($Exe -eq 'ffmpeg') {
        if ($ExeArgs -contains 'volumedetect') { return [pscustomobject]@{Code=0;Out='';Err='mean_volume: -20.0 dB'} }
        [IO.File]::WriteAllBytes($ExeArgs[-1],[byte[]]@(1,2,3,4))
        $GateStarted.Set() | Out-Null
        $GateRelease.WaitOne(15000) | Out-Null
        return [pscustomobject]@{Code=0;Out='';Err=''}
    }
    return [pscustomobject]@{Code=0;Out='';Err=''}
}
'@
    $runspace=[RunspaceFactory]::CreateRunspace(); $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('GateStarted',$gateStarted)
    $runspace.SessionStateProxy.SetVariable('GateRelease',$gateRelease)
    $runspace.SessionStateProxy.SetVariable('TestTools',$fixture.Tools)
    $runspace.SessionStateProxy.SetVariable('TestFile',$fixture.File)
    $runspace.SessionStateProxy.SetVariable('TestRoot',$fixture.Root)
    $runspace.SessionStateProxy.SetVariable('TestWork',$fixture.Work)
    $cancelPowerShell=[PowerShell]::Create(); $cancelPowerShell.Runspace=$runspace
    $null=$cancelPowerShell.AddScript(($runspaceFunctions -join "`r`n") + "`r`n" + $blockingMock + "`r`nGet-ReelAudioLanguage -T `$TestTools -File `$TestFile -Root `$TestRoot -WorkDir `$TestWork")
    $cancelAsync=$cancelPowerShell.BeginInvoke()
    try {
        Assert-True ($gateStarted.WaitOne(5000)) 'cancellable child reached a bounded in-flight extraction'
        $stopAsync=$cancelPowerShell.BeginStop($null,$null)
        $gateRelease.Set() | Out-Null
        $null=$cancelPowerShell.EndStop($stopAsync)
    } finally {
        $gateRelease.Set() | Out-Null
        $cancelPowerShell.Dispose(); $runspace.Dispose(); $gateStarted.Dispose(); $gateRelease.Dispose()
    }
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.Work -Filter 'whisper-sample-*.wav' -File).Count -eq 0) 'sample WAVs are cleaned after cancellation'
    Write-Host 'PASS failed exit, timeout, operational error and cancellation cleanup'

    $installGateStarted=New-Object System.Threading.ManualResetEvent($false)
    $installGateRelease=New-Object System.Threading.ManualResetEvent($false)
    $installRootFunctions=@()
    foreach ($name in @('Get-WhisperPaths','Install-WhisperTiny')) {
        $node=$moduleAst.FindAll({param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true) | Select-Object -First 1
        $installRootFunctions += $node.Extent.Text
    }
    $installMocks=@'
function Write-Note($Text) { }
function Get-Command { param([string]$Name,[string]$ErrorAction) if ($Name -eq 'curl.exe') { return [pscustomobject]@{Source='curl.exe'} }; return $null }
function Get-FileHash {
    param([string]$LiteralPath,[string]$Algorithm)
    if ($LiteralPath -like '*.zip') { $hash='b1514ebc099765e39fa37eb780b92a140a94c86bb0b3b3d98226b38825979732' }
    elseif ((Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath).Length -eq 77691713) { $hash='be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21' }
    else { $hash='0000000000000000000000000000000000000000000000000000000000000000' }
    return [pscustomobject]@{Algorithm='SHA256';Hash=$hash;Path=$LiteralPath}
}
function Expand-Archive {
    param([string]$LiteralPath,[string]$DestinationPath,[System.Management.Automation.ActionPreference]$ErrorAction='Continue')
    $release=Join-Path $DestinationPath 'Release'; [void][IO.Directory]::CreateDirectory($release)
    foreach ($name in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll')) { [IO.File]::WriteAllBytes((Join-Path $release $name),[byte[]]@(7,7,7)) }
}
function Invoke-Exe {
    param([string]$Exe,[string[]]$ExeArgs,[int]$TimeoutMs=15000)
    if ($Exe -eq 'curl.exe') {
        $index=[Array]::IndexOf($ExeArgs,'--output'); $target=$ExeArgs[$index+1]
        if ($ExeArgs[-1] -like '*ggml-tiny.bin') { $stream=[IO.File]::Create($target); try { $stream.SetLength(77691713) } finally { $stream.Dispose() } }
        else { [IO.File]::WriteAllBytes($target,[byte[]]@(1,2,3)) }
        return [pscustomobject]@{Code=0;Out='';Err=''}
    }
    if ($ExeArgs -contains '--help') {
        $InstallGateStarted.Set() | Out-Null
        $InstallGateRelease.WaitOne(15000) | Out-Null
        return [pscustomobject]@{Code=-1;Out='';Err='Timed out'}
    }
    throw "Unexpected installer process: $Exe"
}
'@
    $installRunspace=[RunspaceFactory]::CreateRunspace(); $installRunspace.Open()
    $installRunspace.SessionStateProxy.SetVariable('InstallGateStarted',$installGateStarted)
    $installRunspace.SessionStateProxy.SetVariable('InstallGateRelease',$installGateRelease)
    $installRunspace.SessionStateProxy.SetVariable('TestRoot',$fixture.Root)
    $installPowerShell=[PowerShell]::Create(); $installPowerShell.Runspace=$installRunspace
    $null=$installPowerShell.AddScript(($installRootFunctions -join "`r`n") + "`r`n" + $installMocks + "`r`nInstall-WhisperTiny -Root `$TestRoot")
    $installAsync=$installPowerShell.BeginInvoke()
    try {
        Assert-True ($installGateStarted.WaitOne(10000)) 'installer reached post-swap CLI validation'
        $installStopAsync=$installPowerShell.BeginStop($null,$null)
        $installGateRelease.Set() | Out-Null
        $null=$installPowerShell.EndStop($installStopAsync)
    } finally {
        $installGateRelease.Set() | Out-Null
        $installPowerShell.Dispose(); $installRunspace.Dispose(); $installGateStarted.Dispose(); $installGateRelease.Dispose()
    }
    $oldCli=Join-Path $fixture.Root 'tools/whisper/bin/Release/whisper-cli.exe'
    $oldModel=Join-Path $fixture.Root 'tools/whisper/ggml-tiny.bin'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($oldCli)) -eq [Convert]::ToBase64String([byte[]]@(1,2,3))) 'installer cancellation restores the original CLI files'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($oldModel)) -eq [Convert]::ToBase64String([byte[]]@(4,5,6))) 'installer cancellation restores the original model'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'tools/whisper') -Directory -Filter '.whisper-install-*').Count -eq 0) 'successful cancellation rollback cleans its owned staging directory'
    Write-Host 'PASS installer cancellation restores prior runtime and model'

    $script:Notes.Clear()
    Write-ReelLanguageResult -Result ([pscustomobject]@{Status='detected';Language='vi';Probability=0.91;Samples=1;ElapsedMs=32;Reason='high-confidence'})
    Write-ReelLanguageResult -Result ([pscustomobject]@{Status='detected';Language='en';Probability=0.91;Samples=2;ElapsedMs=42;Reason='high-confidence'})
    Write-ReelLanguageResult -Result ([pscustomobject]@{Status='unavailable';Language=$null;Probability=$null;Samples=0;ElapsedMs=0;Reason='missing-tool'})
    Assert-True ($script:Notes[0] -match '^AUDIO_LANG_VI: language=vi score=0\.9100 samples=1 elapsedMs=32 reason=high-confidence ' -and $script:Notes[0] -match 'uoc tinh' -and $script:Notes[0] -match 'can nghe nghiem thu') 'Vietnamese log has stable token, reason and cautious ASCII explanation'
    Assert-True ($script:Notes[1] -match '^AUDIO_LANG_OTHER: language=en score=0\.9100 samples=2 elapsedMs=42 ') 'other language log includes language, score, samples and elapsed time'
    Assert-True ($script:Notes[2] -match '^AUDIO_LANG_UNKNOWN:' -and $script:Notes[2] -match '-SetupTool whisper') 'unavailable log suggests the explicit Whisper setup command'
    Write-Host 'PASS stable ASCII language result log tokens'
} finally {
    Remove-WhisperFixture $fixture
}
