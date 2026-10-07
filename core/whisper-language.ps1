function Get-WhisperPaths {
    param([string]$Root)

    $whisperRoot = Join-Path $Root 'tools\whisper'
    $bin = Join-Path $whisperRoot 'bin\Release'
    $cli = Join-Path $bin 'whisper-cli.exe'
    $model = Join-Path $whisperRoot 'ggml-tiny.bin'
    $required = @($cli, $model)
    $ready = $true
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $ready = $false; continue }
        try { if ((Get-Item -LiteralPath $path).Length -le 0) { $ready = $false } } catch { $ready = $false }
    }
    foreach ($name in @('whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll')) {
        $dllPath = Join-Path $bin $name
        if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) { $ready = $false; continue }
        try { if ((Get-Item -LiteralPath $dllPath).Length -le 0) { $ready = $false } } catch { $ready = $false }
    }
    return [pscustomobject]@{ Cli = $cli; Model = $model; Ready = [bool]$ready }
}

function Install-WhisperTiny {
    param([string]$Root)

    $archiveUrl = 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.2/whisper-bin-x64.zip'
    $archiveHash = 'b1514ebc099765e39fa37eb780b92a140a94c86bb0b3b3d98226b38825979732'
    $modelUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin'
    $modelHash = 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21'
    $modelSize = [long]77691713
    $whisperRoot = [IO.Path]::GetFullPath((Join-Path $Root 'tools\whisper'))
    $whisperRootPrefix = $whisperRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $paths = Get-WhisperPaths -Root $Root

    if ($paths.Ready) {
        $existingModel = Get-Item -LiteralPath $paths.Model -ErrorAction Stop
        $existingHash = (Get-FileHash -LiteralPath $paths.Model -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($existingModel.Length -eq $modelSize -and $existingHash -eq $modelHash) {
            $help = Invoke-Exe $paths.Cli @('--help') -TimeoutMs 10000
            if ($help.Code -ne 0) { throw 'Installed whisper-cli.exe did not pass --help.' }
            Write-Note 'Whisper CPU runtime and tiny model are ready.'
            return $paths
        }
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl -or -not $curl.Source) { throw 'Windows curl.exe is required to install Whisper. Install or enable the Windows curl command, then run setup again.' }
    if (-not (Test-Path -LiteralPath $whisperRoot -PathType Container)) { [void][IO.Directory]::CreateDirectory($whisperRoot) }

    $stage = Join-Path $whisperRoot ('.whisper-install-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $archive = Join-Path $stage 'whisper-bin-x64.zip'
    $modelDownload = Join-Path $stage 'ggml-tiny.download.bin'
    $extractRoot = Join-Path $stage 'bin'
    $newBin = Join-Path $stage 'new-bin'
    $binTarget = Join-Path $whisperRoot 'bin'
    $binBackup = Join-Path $stage 'old-bin'
    $modelTarget = Join-Path $whisperRoot 'ggml-tiny.bin'
    $modelBackup = Join-Path $stage 'old-model.bin'
    $stageFull = [IO.Path]::GetFullPath($stage)
    $binTargetFull = [IO.Path]::GetFullPath($binTarget)
    $binBackupFull = [IO.Path]::GetFullPath($binBackup)
    $modelTargetFull = [IO.Path]::GetFullPath($modelTarget)
    $modelBackupFull = [IO.Path]::GetFullPath($modelBackup)
    $installCommitted = $false
    $binInstallStarted = $false
    $modelInstallStarted = $false
    try {
        foreach ($ownedPath in @($stageFull,$binTargetFull,$binBackupFull,$modelTargetFull,$modelBackupFull)) {
            if (-not $ownedPath.StartsWith($whisperRootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing Whisper install path outside tools/whisper: $ownedPath" }
        }

        $downloadModel = $true
        if (Test-Path -LiteralPath $modelTarget -PathType Leaf) {
            try {
                $current = Get-Item -LiteralPath $modelTarget -ErrorAction Stop
                if ($current.Length -eq $modelSize) {
                    $currentHash = (Get-FileHash -LiteralPath $modelTarget -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    if ($currentHash -eq $modelHash) { $downloadModel = $false }
                }
            } catch { $downloadModel = $true }
        }

        Write-Note 'Downloading Whisper CPU runtime...'
        $archiveResult = Invoke-Exe $curl.Source @('--fail','--location','--retry','2','--connect-timeout','20','--max-time','300','--silent','--show-error','--output',$archive,$archiveUrl) -TimeoutMs 330000
        if ($archiveResult.Code -ne 0) { throw 'Whisper runtime download failed.' }
        $gotArchiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($gotArchiveHash -ne $archiveHash) { throw 'Whisper runtime archive SHA256 did not match the pinned release.' }

        if ($downloadModel) {
            Write-Note 'Downloading Whisper tiny model...'
            $modelResult = Invoke-Exe $curl.Source @('--fail','--location','--retry','2','--connect-timeout','20','--max-time','300','--silent','--show-error','--output',$modelDownload,$modelUrl) -TimeoutMs 330000
            if ($modelResult.Code -ne 0) { throw 'Whisper model download failed.' }
            $newModel = Get-Item -LiteralPath $modelDownload -ErrorAction Stop
            if ($newModel.Length -ne $modelSize) { throw 'Whisper tiny model size did not match the pinned model.' }
            $gotModelHash = (Get-FileHash -LiteralPath $modelDownload -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($gotModelHash -ne $modelHash) { throw 'Whisper tiny model SHA256 did not match the pinned model.' }
        }

        Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -ErrorAction Stop
        $candidateCli = Join-Path $extractRoot 'Release\whisper-cli.exe'
        foreach ($name in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll')) {
            $candidate = Join-Path (Join-Path $extractRoot 'Release') $name
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or (Get-Item -LiteralPath $candidate).Length -le 0) {
                throw "Pinned Whisper archive is missing a required Release file: $name"
            }
        }
        $candidateHash = (Get-FileHash -LiteralPath $candidateCli -Algorithm SHA256 -ErrorAction Stop).Hash
        if ([string]::IsNullOrWhiteSpace($candidateHash)) { throw 'Whisper CLI verification failed.' }

        Copy-Item -LiteralPath $extractRoot -Destination $newBin -Recurse -ErrorAction Stop | Out-Null
        $binInstallStarted = $true
        if (Test-Path -LiteralPath $binTarget -PathType Container) {
            [IO.Directory]::Move($binTarget,$binBackup)
        } elseif (Test-Path -LiteralPath $binTarget) { throw 'Whisper bin target exists but is not a directory.' }
        [IO.Directory]::Move($newBin,$binTarget)

        if ($downloadModel) {
            $modelInstallStarted = $true
            if (Test-Path -LiteralPath $modelTarget -PathType Leaf) {
                [IO.File]::Move($modelTarget,$modelBackup)
            } elseif (Test-Path -LiteralPath $modelTarget) { throw 'Whisper model target exists but is not a file.' }
            [IO.File]::Move($modelDownload,$modelTarget)
        }

        $installed = Get-WhisperPaths -Root $Root
        if (-not $installed.Ready) { throw 'Whisper installation is incomplete.' }
        $actualModel = Get-Item -LiteralPath $installed.Model -ErrorAction Stop
        $actualModelHash = (Get-FileHash -LiteralPath $installed.Model -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualModel.Length -ne $modelSize -or $actualModelHash -ne $modelHash) { throw 'Installed Whisper tiny model verification failed.' }
        $help = Invoke-Exe $installed.Cli @('--help') -TimeoutMs 10000
        if ($help.Code -ne 0) { throw 'Installed whisper-cli.exe did not pass --help.' }
        $installCommitted = $true
        Write-Note 'Whisper CPU runtime and tiny model are ready.'
        return $installed
    } catch {
        throw
    } finally {
        $cleanupSafe = $true
        if (-not $installCommitted) {
            try {
                if ($modelInstallStarted) {
                    if (-not $modelTargetFull.StartsWith($whisperRootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not $modelBackupFull.StartsWith($whisperRootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Model rollback path escaped tools/whisper.' }
                    $backupExists = Test-Path -LiteralPath $modelBackupFull -PathType Leaf
                    $downloadStillExists = Test-Path -LiteralPath $modelDownload -PathType Leaf
                    if ($backupExists) {
                        if (Test-Path -LiteralPath $modelTargetFull -PathType Leaf) { [IO.File]::Delete($modelTargetFull) }
                        [IO.File]::Move($modelBackupFull,$modelTargetFull)
                    } elseif (-not $downloadStillExists -and (Test-Path -LiteralPath $modelTargetFull -PathType Leaf)) {
                        [IO.File]::Delete($modelTargetFull)
                    }
                }
                if ($binInstallStarted) {
                    if (-not $binTargetFull.StartsWith($whisperRootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not $binBackupFull.StartsWith($whisperRootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Bin rollback path escaped tools/whisper.' }
                    $backupExists = Test-Path -LiteralPath $binBackupFull -PathType Container
                    $newBinStillExists = Test-Path -LiteralPath $newBin -PathType Container
                    if ($backupExists) {
                        if (Test-Path -LiteralPath $binTargetFull -PathType Container) { [IO.Directory]::Delete($binTargetFull,$true) }
                        [IO.Directory]::Move($binBackupFull,$binTargetFull)
                    } elseif (-not $newBinStillExists -and (Test-Path -LiteralPath $binTargetFull -PathType Container)) {
                        [IO.Directory]::Delete($binTargetFull,$true)
                    }
                }
            } catch {
                $cleanupSafe = $false
                throw "Whisper installation failed and rollback could not finish. Recovery files were preserved at $stageFull. $($_.Exception.Message)"
            }
        }
        if ($cleanupSafe -and $stageFull.StartsWith($whisperRootPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stageFull -PathType Container)) {
            [IO.Directory]::Delete($stageFull,$true)
        }
    }
}
function ConvertFrom-WhisperLanguage {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $pattern = '(?m)^\s*(?:[A-Za-z0-9_]+:\s*)?auto-detected language:\s*([a-z]{2,3})\s+\(p\s*=\s*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\)\s*$'
    $match = [regex]::Match($Text, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $null }
    $probability = 0.0
    $style = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($match.Groups[2].Value, $style, $culture, [ref]$probability)) { return $null }
    if ([double]::IsNaN($probability) -or [double]::IsInfinity($probability) -or $probability -lt 0.0 -or $probability -gt 1.0) { return $null }
    return [pscustomobject]@{ Language = $match.Groups[1].Value; Probability = $probability }
}

function Get-ReelAudioLanguage {
    param($T, [string]$File, [string]$Root, [string]$WorkDir)

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{ Status='unknown'; Language=$null; Probability=$null; Samples=0; ElapsedMs=0; Reason='no-usable-sample' }
    $tempFiles = New-Object 'System.Collections.Generic.List[string]'
    try {
        $paths = Get-WhisperPaths -Root $Root
        if (-not $paths.Ready) {
            $result.Status = 'unavailable'; $result.Reason = 'missing-tool'
            $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result
        }
        if (-not $T -or [string]::IsNullOrWhiteSpace([string]$T.ffmpeg) -or [string]::IsNullOrWhiteSpace([string]$T.ffprobe)) {
            $result.Status = 'unavailable'; $result.Reason = 'missing-media-tool'
            $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result
        }
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { $result.Status='error'; $result.Reason='missing-input'; $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result }

        $remaining = [Math]::Max(1, 20000 - [int]$clock.ElapsedMilliseconds)
        $durationResult = Invoke-Exe $T.ffprobe @('-v','error','-show_entries','format=duration','-of','csv=p=0',$File) -TimeoutMs ([Math]::Min(3000,$remaining))
        if ($durationResult.Code -ne 0) { $result.Status='error'; $result.Reason='duration-probe-failed'; $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result }
        $duration = 0.0
        if (-not [double]::TryParse(([string]$durationResult.Out).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -or [double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or $duration -le 0) {
            $result.Status='error'; $result.Reason='invalid-duration'; $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result
        }
        if ($duration -lt 2.0) { $result.Status='unknown'; $result.Reason='too-short'; $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result }

        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { [void][IO.Directory]::CreateDirectory($WorkDir) }
        $sampleOffsets = New-Object 'System.Collections.Generic.List[double]'
        $sampleOffsets.Add(0.0)
        if ($duration -ge 8.0) { $sampleOffsets.Add([Math]::Max(6.0, $duration / 2.0)) }
        $lastReason = 'no-usable-sample'
        $whisperInvoked = 0
        foreach ($offset in $sampleOffsets) {
            $remaining = 20000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -lt 2000) { $lastReason='budget-exhausted'; break }
            $sampleDuration = [Math]::Min(6.0, $duration - $offset)
            if ($sampleDuration -lt 2.0) { continue }
            $sample = Join-Path $WorkDir ('whisper-sample-' + [Guid]::NewGuid().ToString('N') + '.wav')
            $tempFiles.Add($sample)
            $result.Samples++
            $offsetText = $offset.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
            $durationText = $sampleDuration.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
            $remaining = 20000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { $lastReason='budget-exhausted'; break }
            $extract = Invoke-Exe $T.ffmpeg @('-hide_banner','-loglevel','error','-y','-ss',$offsetText,'-t',$durationText,'-i',$File,'-vn','-af','silenceremove=start_periods=1:start_duration=0.15:start_threshold=-40dB','-ar','16000','-ac','1','-c:a','pcm_s16le',$sample) -TimeoutMs ([Math]::Min(5000,$remaining))
            if ($extract.Code -ne 0 -or -not (Test-Path -LiteralPath $sample -PathType Leaf)) { $lastReason='sample-extract-failed'; continue }

            $remaining = 20000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { $lastReason='budget-exhausted'; break }
            $sampleProbe = Invoke-Exe $T.ffprobe @('-v','error','-show_entries','format=duration','-of','csv=p=0',$sample) -TimeoutMs ([Math]::Min(3000,$remaining))
            $sampleSeconds = 0.0
            if ($sampleProbe.Code -ne 0 -or -not [double]::TryParse(([string]$sampleProbe.Out).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sampleSeconds) -or [double]::IsNaN($sampleSeconds) -or [double]::IsInfinity($sampleSeconds) -or $sampleSeconds -lt 2.0) {
                $lastReason='sample-too-short'; continue
            }

            $remaining = 20000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { $lastReason='budget-exhausted'; break }
            $volume = Invoke-Exe $T.ffmpeg @('-hide_banner','-i',$sample,'-af','volumedetect','-f','null','-') -TimeoutMs ([Math]::Min(3000,$remaining))
            if ($volume.Code -ne 0) { $lastReason='volume-probe-failed'; continue }
            $volumeMatch = [regex]::Match(([string]$volume.Err + "`n" + [string]$volume.Out), '(?m)(?:^|\s)mean_volume:\s*(-inf|-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))\s*dB(?:\s|$)')
            $mean = 0.0
            if (-not $volumeMatch.Success) { $lastReason='invalid-volume'; continue }
            if ($volumeMatch.Groups[1].Value -eq '-inf') { $mean = -[double]::MaxValue }
            elseif (-not [double]::TryParse($volumeMatch.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mean) -or [double]::IsNaN($mean) -or [double]::IsInfinity($mean)) { $lastReason='invalid-volume'; continue }
            if ($mean -lt -50.0) { $lastReason='silent-sample'; continue }

            $remaining = 20000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0 -or $whisperInvoked -ge 2) { $lastReason='budget-exhausted'; break }
            $whisperInvoked++
            $recognition = Invoke-Exe $paths.Cli @('-m',$paths.Model,'-f',$sample,'-dl','-ng','-t','4') -TimeoutMs ([Math]::Min(10000,$remaining))
            if ($recognition.Code -ne 0) { $lastReason='whisper-run-failed'; continue }
            $parsed = ConvertFrom-WhisperLanguage -Text ([string]$recognition.Err)
            if (-not $parsed) { $lastReason='language-parse-failed'; continue }
            $result.Language = $parsed.Language
            $result.Probability = $parsed.Probability
            if ($parsed.Probability -ge 0.85) {
                $result.Status='detected'; $result.Reason='high-confidence'; break
            }
            $lastReason='low-confidence'
        }
        $result.Reason = if ($result.Status -eq 'detected') { 'high-confidence' } else { $lastReason }
        if ($result.Status -ne 'detected') { $result.Status = if ($lastReason -in @('low-confidence','silent-sample','sample-too-short','no-usable-sample','budget-exhausted')) { 'unknown' } else { 'error' } }
        $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $result.Status='error'
        $result.Reason='runtime-error'
        $result.ElapsedMs = [int]$clock.ElapsedMilliseconds
            return [pscustomobject]$result
    } finally {
        foreach ($temp in $tempFiles) {
            try { if (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) } } catch { }
        }
        $clock.Stop()
        $result.ElapsedMs = [int][Math]::Min([int]::MaxValue,$clock.ElapsedMilliseconds)
    }
}

function Write-ReelLanguageResult {
    param($Result)

    $status = [string]$Result.Status
    $language = [string]$Result.Language
    $probability = $null
    if ($null -ne $Result.Probability) { $probability = [double]$Result.Probability }
    $score = if ($null -ne $probability) { $probability.ToString('0.0000',[Globalization.CultureInfo]::InvariantCulture) } else { 'na' }
    $samples = [int]$Result.Samples
    $elapsed = [int]$Result.ElapsedMs
    $code = if ($language -match '^[a-z]{2,3}$') { $language } else { 'na' }
    $reason = [string]$Result.Reason
    if ($reason -notmatch '^[a-z0-9-]+$') { $reason = 'unknown' }
    if ($status -eq 'detected' -and $language -eq 'vi') {
        Write-Note ("AUDIO_LANG_VI: language={0} score={1} samples={2} elapsedMs={3} reason={4} uoc tinh tu mau am thanh; can nghe nghiem thu." -f $code,$score,$samples,$elapsed,$reason)
    } elseif ($status -eq 'detected') {
        Write-Note ("AUDIO_LANG_OTHER: language={0} score={1} samples={2} elapsedMs={3} reason={4} uoc tinh tu mau am thanh; can nghe nghiem thu." -f $code,$score,$samples,$elapsed,$reason)
    } else {
        $setup = if ([string]$Result.Reason -eq 'missing-tool' -or $status -eq 'unavailable') { ' Chay lai voi -SetupTool whisper de cai cong cu.' } else { '' }
        Write-Note ("AUDIO_LANG_UNKNOWN: language={0} score={1} samples={2} elapsedMs={3} reason={4} ket qua chua xac dinh; can nghe nghiem thu.{5}" -f $code,$score,$samples,$elapsed,$reason,$setup)
    }
}
