function Get-FacebookInputLinks {
    param([string]$Text, [switch]$KeepDuplicates)

    if ([string]::IsNullOrEmpty($Text)) { return }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = New-Object 'System.Collections.Generic.List[string]'
    $fullPattern = 'https?://[^\s<>\[\]{}()"'']+'
    $barePattern = '(?:(?<!\S)|(?<=[\[<("'']))(?:https?://)?(?:[A-Za-z0-9-]+\.)*(?:facebook\.com|(?:www\.)?fb\.watch)(?![A-Za-z0-9.-])(?::\d+)?(?:/[^\s<>\[\]{}()"'']*)?'

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $fullMatches = [regex]::Matches($Text, $fullPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $fullMatches) {
        $candidates.Add([pscustomobject]@{ Index = $match.Index; Value = $match.Value; Bare = $false })
    }
    foreach ($match in [regex]::Matches($Text, $barePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $value = $match.Value.TrimStart()
        if ($value.Length -eq 0) { continue }
        $index = $match.Index + ($match.Value.Length - $value.Length)
        $insideFullUrl = $false
        foreach ($fullMatch in $fullMatches) {
            if ($index -ge $fullMatch.Index -and $index -lt ($fullMatch.Index + $fullMatch.Length)) { $insideFullUrl = $true; break }
        }
        if ($insideFullUrl) { continue }
        # A match in the middle of a larger URL or host is never a bare Facebook link.
        if ($index -gt 0 -and $Text[$index - 1] -match '[A-Za-z0-9._/@?=&-]') { continue }
        $candidates.Add([pscustomobject]@{ Index = $index; Value = $value; Bare = ($value -notmatch '^https?://') })
    }

    foreach ($candidate in ($candidates | Sort-Object Index, @{ Expression = { if ($_.Bare) { 1 } else { 0 } } })) {
        $url = [string]$candidate.Value
        $url = $url -replace '[.,;!，。；]+$', ''
        if ($url -match '\?' -and $url -match '&amp;') { $url = $url -replace '&amp;', '&' }
        if ($candidate.Bare -and $url -notmatch '^https?://') { $url = 'https://' + $url }

        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { continue }
        if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { continue }
        $hostName = $uri.Host.ToLowerInvariant()
        $trusted = ($hostName -eq 'facebook.com' -or $hostName.EndsWith('.facebook.com', [StringComparison]::Ordinal))
        if ($hostName -eq 'fb.watch' -or $hostName -eq 'www.fb.watch') { $trusted = $true }
        if (-not $trusted) { continue }
        if ($KeepDuplicates -or $seen.Add($url)) { $found.Add($url) }
    }

    foreach ($url in $found) { Write-Output $url }
}

function Get-FacebookVideoId {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $null }
    $hostName = $uri.Host.ToLowerInvariant()
    if (-not ($hostName -eq 'facebook.com' -or $hostName.EndsWith('.facebook.com', [StringComparison]::Ordinal))) { return $null }

    $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
    if ($path -match '^/(?:reel|reels|videos)/(\d+)(?:/|$)' -or $path -match '^/[^/]+/videos/(\d+)(?:/|$)') {
        return $matches[1]
    }
    if ($path -match '^/watch/?$' -or $path -match '^/video\.php/?$') {
        foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
            $parts = $pair -split '=', 2
            if ($parts.Count -eq 2 -and [Uri]::UnescapeDataString($parts[0]) -eq 'v') {
                $value = [Uri]::UnescapeDataString($parts[1])
                if ($value -match '^\d+$') { return $value }
            }
        }
    }
    return $null
}

function Get-RejectedReelPath {
    param([Parameter(Mandatory=$true)][string]$Root)
    return (Join-Path ([IO.Path]::GetFullPath($Root)) 'data/rejected-videos.json')
}

function Get-RejectedReels {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Get-RejectedReelPath -Root $Root
    if (-not [IO.File]::Exists($path)) { return }
    $data = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop
    if ($null -eq $data -or $data.Schema -ne 1 -or $null -eq $data.Entries) { throw 'Invalid rejected-video history; refusing to ignore it.' }
    foreach ($entry in @($data.Entries)) {
        if ([string]$entry.VideoId -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace([string]$entry.Reason)) { throw 'Invalid rejected-video entry.' }
        $entry
    }
}

function Find-RejectedReel {
    param([string]$Root, [string]$VideoId, [string]$Url)
    foreach ($entry in @(Get-RejectedReels -Root $Root)) {
        if (($VideoId -and [string]$entry.VideoId -eq $VideoId) -or ($Url -and $Url -cin @($entry.Urls))) { return $entry }
    }
}

function Save-RejectedReel {
    param([string]$Root, [string]$VideoId, [string[]]$Urls, [string]$Reason, [string]$Language, [double]$Probability = 0)
    if ($VideoId -notmatch '^\d+$') { throw 'Rejected video requires an exact numeric ID.' }
    if ($Reason -notin @('vietnamese-unavailable','audio-not-vietnamese')) { throw 'Only confirmed language rejections can be saved.' }
    $path = Get-RejectedReelPath -Root $Root
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant())))).Replace('-','') } finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\KidFbyRejected'+$key))
    $locked = $false; $stage = $path+'.writing.'+[guid]::NewGuid().ToString('N')
    $backup = $path+'.previous.'+[guid]::NewGuid().ToString('N')
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Rejected-video history is busy; retry later.' }
        $entries = @(Get-RejectedReels -Root $Root)
        $previous = @($entries | Where-Object { [string]$_.VideoId -eq $VideoId })
        $allUrls = @(@($Urls) + @($previous | ForEach-Object { $_.Urls }) | Where-Object { $_ } | Select-Object -Unique)
        $record = [pscustomobject]@{ VideoId=$VideoId; Urls=$allUrls; Reason=$Reason; Language=$Language; Probability=$Probability; RejectedAt=[DateTime]::UtcNow.ToString('o') }
        $entries = @($entries | Where-Object { [string]$_.VideoId -ne $VideoId }) + @($record)
        $json = [pscustomobject]@{ Schema=1; Entries=@($entries) } | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($stage,$json,[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($stage,$path,$backup) } else { [IO.File]::Move($stage,$path) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        return $record
    } finally {
        if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Remove-RejectedReelMedia {
    param([string]$OutDir, [string]$VideoId)
    if ($VideoId -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($OutDir)) { throw 'Unsafe rejected-video cleanup arguments.' }
    $boundary = [IO.Path]::GetFullPath($OutDir).TrimEnd('\')+'\'
    $moved = New-Object Collections.Generic.List[object]
    $errors = New-Object Collections.Generic.List[string]
    $token = [guid]::NewGuid().ToString('N')
    try {
        foreach ($suffix in @('-1-video-goc.mp4','-2-am-thanh-tho.m4a','-3-hoan-chinh.mp4','-3-hoan-chinh-logo-preview.mp4')) {
            $source = [IO.Path]::GetFullPath((Join-Path $OutDir ($VideoId+$suffix)))
            if (-not $source.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup escaped the output directory.' }
            if ([IO.File]::Exists($source)) {
                $stage = $source+'.rejected.'+$token
                [IO.File]::Move($source,$stage)
                $moved.Add([pscustomobject]@{Source=$source;Stage=$stage})
            }
        }
    } catch {
        $errors.Add($_.Exception.Message)
        foreach ($item in @($moved.ToArray()) | Sort-Object Source -Descending) {
            try { [IO.File]::Move($item.Stage,$item.Source) } catch { $errors.Add('Recovery file: '+$item.Stage+'; '+$_.Exception.Message) }
        }
        return [pscustomobject]@{Success=$false;Errors=@($errors.ToArray())}
    }
    foreach ($item in $moved) { try { [IO.File]::Delete($item.Stage) } catch { $errors.Add('Cleanup pending: '+$item.Stage+'; '+$_.Exception.Message) } }
    return [pscustomobject]@{Success=($errors.Count -eq 0);Errors=@($errors.ToArray())}
}

function Get-ReelLanguageDecision {
    param([string]$DubbingStatus, $AudioLanguage)
    if ($DubbingStatus -eq 'unavailable') { return 'reject-ui' }
    # Meta's checked language selection is the download policy; audio analysis is optional.
    if ($DubbingStatus -eq 'selected') { return 'accept' }
    return 'defer'
}

function Get-FacebookLinkDuplicateReport {
    param([string]$Text, [string]$OutDir)

    $inputLinks = @(Get-FacebookInputLinks -Text $Text -KeepDuplicates)
    $uniqueLinks = New-Object 'System.Collections.Generic.List[string]'
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $allIds = New-Object 'System.Collections.Generic.List[string]'
    $allIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $duplicateIds = New-Object 'System.Collections.Generic.List[string]'
    $duplicateIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)

    foreach ($url in $inputLinks) {
        $videoId = Get-FacebookVideoId -Url $url
        if ($videoId) {
            if (-not $allIdSet.Add($videoId)) {
                if ($duplicateIdSet.Add($videoId)) { $duplicateIds.Add($videoId) }
                continue
            }
            $allIds.Add($videoId)
            $uniqueLinks.Add($url)
            continue
        }

        $uri = $null
        $key = if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { $uri.AbsoluteUri } else { $url }
        if ($seenKeys.Add($key)) { $uniqueLinks.Add($url) }
    }

    $downloadedIds = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
        foreach ($videoId in $allIds) {
            foreach ($suffix in @('-1-video-goc.mp4', '-3-hoan-chinh.mp4')) {
                $candidate = Join-Path $OutDir ($videoId + $suffix)
                if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop) {
                    $file = Get-Item -LiteralPath $candidate -ErrorAction Stop
                    if ($file -and $file.Length -gt 0) {
                        $downloadedIds.Add($videoId)
                        break
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Links = @($uniqueLinks.ToArray())
        DuplicateIds = @($duplicateIds.ToArray())
        DownloadedIds = @($downloadedIds.ToArray())
    }
}
function Get-FacebookCanonicalVideoUrl {
    param([string]$Url, [string]$VideoId)

    if ([string]::IsNullOrEmpty($Url) -or $VideoId -notmatch '^\d+$') { return $Url }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $Url }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $Url }
    $hostName = $uri.Host.ToLowerInvariant()
    $facebookHost = ($hostName -eq 'facebook.com' -or $hostName.EndsWith('.facebook.com', [StringComparison]::Ordinal))
    $watchHost = ($hostName -eq 'fb.watch' -or $hostName -eq 'www.fb.watch')
    if (-not ($facebookHost -or $watchHost)) { return $Url }

    $path = $uri.AbsolutePath
    if ($watchHost) { return ('https://www.facebook.com/watch/?v=' + $VideoId) }
    if ($path -match '^/share/r(?:/|$)' -or $path -match '^/reels?(?:/|$)') {
        return ('https://www.facebook.com/reel/' + $VideoId + '/')
    }
    if ($path -match '^/share/v(?:/|$)') {
        return ('https://www.facebook.com/watch/?v=' + $VideoId)
    }
    return $Url
}

function Resolve-FacebookShareUrl {
    param([string]$Url)

    if ([string]::IsNullOrEmpty($Url)) { return $Url }
    $inputUri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$inputUri)) { return $Url }
    if ($inputUri.Scheme -ne 'http' -and $inputUri.Scheme -ne 'https') { return $Url }
    $inputHost = $inputUri.Host.ToLowerInvariant()
    $isFacebook = ($inputHost -eq 'facebook.com' -or $inputHost.EndsWith('.facebook.com', [StringComparison]::Ordinal))
    $isFbWatch = ($inputHost -eq 'fb.watch' -or $inputHost -eq 'www.fb.watch')
    $isSharePath = ($isFacebook -and ($inputUri.AbsolutePath -match '^/share/r(?:/|$)' -or $inputUri.AbsolutePath -match '^/share/v(?:/|$)'))
    if (-not ($isSharePath -or $isFbWatch)) { return $Url }

    try {
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $curl -or -not $curl.Source) { return $Url }
        $result = Invoke-Exe $curl.Source @('--location','--max-redirs','5','--silent','--show-error','--connect-timeout','5','--max-time','15','--output','NUL','--write-out','%{url_effective}','--user-agent','facebookexternalhit/1.1',$Url) -TimeoutMs 20000
        if (-not $result -or $result.Code -ne 0 -or [string]::IsNullOrWhiteSpace($result.Out)) { return $Url }
        $effectiveUrl = ([string]$result.Out).Trim()
        $effectiveUri = $null
        if (-not [Uri]::TryCreate($effectiveUrl, [UriKind]::Absolute, [ref]$effectiveUri)) { return $Url }
        if ($effectiveUri.Scheme -ne 'http' -and $effectiveUri.Scheme -ne 'https') { return $Url }
        $effectiveHost = $effectiveUri.Host.ToLowerInvariant()
        $effectiveFacebook = ($effectiveHost -eq 'facebook.com' -or $effectiveHost.EndsWith('.facebook.com', [StringComparison]::Ordinal))
        $effectiveFbWatch = ($effectiveHost -eq 'fb.watch' -or $effectiveHost -eq 'www.fb.watch')
        if (-not ($effectiveFacebook -or $effectiveFbWatch)) { return $Url }

        $videoId = $null
        if ($effectiveUri.AbsolutePath -match '^/reels?/(\d+)(?:/|$)' -or $effectiveUri.AbsolutePath -match '^/.+/videos/(\d+)(?:/|$)') {
            $videoId = $matches[1]
        } elseif ($effectiveUri.AbsolutePath -match '^/watch/?$') {
            foreach ($pair in ($effectiveUri.Query.TrimStart('?') -split '&')) {
                $parts = $pair -split '=', 2
                if ($parts.Count -eq 2 -and $parts[0] -eq 'v' -and $parts[1] -match '^\d+$') { $videoId = $parts[1]; break }
            }
        }
        if (-not $videoId) { return $Url }
        return (Get-FacebookCanonicalVideoUrl -Url $Url -VideoId $videoId)
    } catch {
        $caughtException = $_.Exception
        while ($caughtException) {
            if ($caughtException -is [System.Management.Automation.PipelineStoppedException]) { throw }
            $caughtException = $caughtException.InnerException
        }
        return $Url
    }
}
