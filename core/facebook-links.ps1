# Chuan hoa URL Facebook truoc khi dedupe: host m./mbasic./web./mobile./touch. -> www., https,
# bo "/" cuoi, bo fragment va tham so theo doi (giu v, story_fbid, id va tham so khac).
function ConvertTo-FacebookNormalizedUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $Url }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $Url }
    $hostName = $uri.Host.ToLowerInvariant()
    if ($hostName -eq 'fb.watch' -or $hostName -eq 'www.fb.watch') {
        $newHost = $hostName
    } elseif ($hostName -eq 'facebook.com' -or $hostName -match '^(?:www|m|mbasic|web|mobile|touch)\.facebook\.com$') {
        $newHost = 'www.facebook.com'
    } elseif ($hostName.EndsWith('.facebook.com', [StringComparison]::Ordinal)) {
        $newHost = $hostName
    } else {
        return $Url
    }
    $path = $uri.AbsolutePath
    if ($path.Length -gt 1) { $path = $path.TrimEnd('/') }
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }
    $trackingNames = @('mibextid','rdid','share_url','__tn__','sfnsn','s','fs','ref')
    $kept = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $name = [Uri]::UnescapeDataString(($pair -split '=', 2)[0]).ToLowerInvariant()
        if ($trackingNames -contains $name -or $name.StartsWith('__cft__', [StringComparison]::Ordinal)) { continue }
        $kept.Add($pair)
    }
    $port = if ($uri.IsDefaultPort) { '' } else { ':' + $uri.Port }
    $result = 'https://' + $newHost + $port + $path
    if ($kept.Count -gt 0) { $result += '?' + ($kept -join '&') }
    return $result
}
function Get-FacebookInputLinks {
    param([string]$Text, [switch]$KeepDuplicates)

    if ([string]::IsNullOrEmpty($Text)) { return }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = New-Object 'System.Collections.Generic.List[string]'
    $fullPattern = 'https?://[^\s<>\[\]{}()"'']+'
    $barePattern = '(?:(?<!\S)|(?<=[\[<("'']))(?:https?://)?(?:[A-Za-z0-9-]+\.)*(?:facebook\.com|(?:www\.)?fb\.watch)(?![A-Za-z0-9.-])(?::\d+)?(?:/[^\s<>\[\]{}()"'']*)?'

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $fullMatches = [regex]::Matches($Text, $fullPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    # Danh dau vung cua URL day du bang mang bool de tranh quet lap O(N*M).
    $insideMask = New-Object 'bool[]' ($Text.Length + 1)
    foreach ($match in $fullMatches) {
        $candidates.Add([pscustomobject]@{ Index = $match.Index; Value = $match.Value; Bare = $false })
        $maskEnd = [Math]::Min($Text.Length, $match.Index + $match.Length)
        for ($mi = $match.Index; $mi -lt $maskEnd; $mi++) { $insideMask[$mi] = $true }
    }
    foreach ($match in [regex]::Matches($Text, $barePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $value = $match.Value.TrimStart()
        if ($value.Length -eq 0) { continue }
        $index = $match.Index + ($match.Value.Length - $value.Length)
        if ($insideMask[$index]) { continue }
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
        $url = ConvertTo-FacebookNormalizedUrl -Url $url
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
    if ($path -match '^/(?:reel|reels|videos)/(\d+)(?:/|$)' -or $path -match '^/[^/]+/videos/(\d+)(?:/|$)' -or $path -match '^/[^/]+/videos/[^/]+/(\d+)(?:/|$)') {
        return $matches[1]
    }
    if ($path -match '^/watch(?:/live)?/?$' -or $path -match '^/video\.php/?$') {
        $idNames = @('v')
        if ($path -match '^/video\.php/?$') { $idNames = @('v','story_fbid') }
        foreach ($idName in $idNames) {
            foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
                $parts = $pair -split '=', 2
                if ($parts.Count -eq 2 -and [Uri]::UnescapeDataString($parts[0]) -eq $idName) {
                    $value = [Uri]::UnescapeDataString($parts[1])
                    if ($value -match '^\d+$') { return $value }
                }
            }
        }
    }
    return $null
}

function Get-RejectedReelPath {
    param([Parameter(Mandatory=$true)][string]$Root)
    return (Join-Path ([IO.Path]::GetFullPath($Root)) 'data/rejected-videos.json')
}

# Ghi file lich su an toan: FileStream + Write + Flush(true) roi moi Replace/Move (mat dien khong de lai file rong).
function Write-HistoryFileDurable {
    param([string]$Stage, [string]$Path, [string]$Backup, [string]$Json)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json)
    $stream = [IO.File]::Open($Stage, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($Stage, $Path, $Backup) } else { [IO.File]::Move($Stage, $Path) }
    if ([IO.File]::Exists($Backup)) { [IO.File]::Delete($Backup) }
}

function Get-RejectedReels {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Get-RejectedReelPath -Root $Root
    if (-not [IO.File]::Exists($path)) { return }
    # Loi DOC (file bi khoa/khong quyen) khac file hong: de nem ra, khong dong vao file.
    $text = [IO.File]::ReadAllText($path)
    $entries = $null; $why = ''
    try {
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if ($null -eq $data -or $data.Schema -ne 1 -or $null -eq $data.Entries) { throw 'Invalid rejected-video history schema.' }
        $list = New-Object Collections.Generic.List[object]
        foreach ($entry in @($data.Entries)) {
            if ([string]$entry.VideoId -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace([string]$entry.Reason)) { throw 'Invalid rejected-video entry.' }
            $list.Add($entry)
        }
        $entries = $list
    } catch { $why = $_.Exception.Message }
    if ($null -eq $entries) {
        # File hong: doi ten giu lai de khoi phuc tay, coi nhu rong (khong lam hong moi link).
        $corrupt = $path + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
        $moved = $false
        try { [IO.File]::Move($path, $corrupt); $moved = $true } catch { $why += ' | khong doi ten duoc: ' + $_.Exception.Message }
        $msg = "Lich su loai bi hong ($why). " + $(if ($moved) { "Da giu ban hong tai $corrupt, coi nhu rong." } else { 'Coi nhu rong trong lan nay.' })
        if (Get-Command Write-Warn2 -ErrorAction SilentlyContinue) { Write-Warn2 $msg } else { Write-Host "    !  $msg" -ForegroundColor Yellow }
        return
    }
    foreach ($e in $entries) { $e }
}

function Find-RejectedReel {
    param([string]$Root, [string]$VideoId, [string]$Url)
    $normalizedUrl = if ($Url) { ConvertTo-FacebookNormalizedUrl -Url $Url } else { '' }
    foreach ($entry in @(Get-RejectedReels -Root $Root)) {
        if ($VideoId -and [string]$entry.VideoId -eq $VideoId) { return $entry }
        if ($Url) {
            foreach ($savedUrl in @($entry.Urls)) {
                if ($savedUrl -and ($Url -ceq [string]$savedUrl -or $normalizedUrl -ceq (ConvertTo-FacebookNormalizedUrl -Url ([string]$savedUrl)))) { return $entry }
            }
        }
    }
}

function Save-RejectedReel {
    param([string]$Root, [string]$VideoId, [string[]]$Urls, [string]$Reason, [string]$Language, [double]$Probability = 0, [string]$Evidence = '')
    if ($VideoId -notmatch '^\d+$') { throw 'Rejected video requires an exact numeric ID.' }
    if ($Reason -notin @('vietnamese-unavailable','audio-not-vietnamese')) { throw 'Only confirmed language rejections can be saved.' }
    if ($Evidence -and $Evidence.Length -gt 2000) { $Evidence = $Evidence.Substring(0,2000) }
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
        $record = [pscustomobject]@{ VideoId=$VideoId; Urls=$allUrls; Reason=$Reason; Language=$Language; Probability=$Probability; RejectedAt=[DateTime]::UtcNow.ToString('o'); Evidence=[string]$Evidence }
        $entries = @($entries | Where-Object { [string]$_.VideoId -ne $VideoId }) + @($record)
        $json = [pscustomobject]@{ Schema=1; Entries=@($entries) } | ConvertTo-Json -Depth 8
        # Ghi ben vung: FileStream + Write + Flush($true) roi Replace/Move (xem Write-HistoryFileDurable).
        Write-HistoryFileDurable -Stage $stage -Path $path -Backup $backup -Json $json
        return $record
    } finally {
        if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Go muc loai theo ID. Cung mutex + ghi file tam roi replace nhu Save-RejectedReel.
# Tra ve $true neu co muc bi go. Nem loi khi file hong / khoa qua han.
function Remove-RejectedReel {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$VideoId)
    if ($VideoId -notmatch '^\d+$') { throw 'Remove-RejectedReel requires an exact numeric ID.' }
    $path = Get-RejectedReelPath -Root $Root
    if (-not [IO.File]::Exists($path)) { return $false }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant())))).Replace('-','') } finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\KidFbyRejected'+$key))
    $locked = $false; $stage = $path+'.writing.'+[guid]::NewGuid().ToString('N')
    $backup = $path+'.previous.'+[guid]::NewGuid().ToString('N')
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Rejected-video history is busy; retry later.' }
        $entries = @(Get-RejectedReels -Root $Root)
        $remaining = @($entries | Where-Object { [string]$_.VideoId -ne $VideoId })
        if ($remaining.Count -eq $entries.Count) { return $false }
        $json = [pscustomobject]@{ Schema=1; Entries=@($remaining) } | ConvertTo-Json -Depth 8
        # Ghi ben vung: FileStream + Write + Flush($true) roi Replace/Move (xem Write-HistoryFileDurable).
        Write-HistoryFileDurable -Stage $stage -Path $path -Backup $backup -Json $json
        return $true
    } finally {
        if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# KHONG con duoc goi tu luong loai video (hop dong GUI muc 4): loai video khong xoa file da co.
# Giu lai de cong cu bao tri/goi tay; thay doi hanh vi nay can nem ro voi nguoi dung.
function Remove-RejectedReelMedia {
    param([string]$OutDir, [string]$VideoId)
    if ($VideoId -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($OutDir)) { throw 'Unsafe rejected-video cleanup arguments.' }
    $boundary = [IO.Path]::GetFullPath($OutDir).TrimEnd('\')+'\'
    $moved = New-Object Collections.Generic.List[object]
    $errors = New-Object Collections.Generic.List[string]
    $token = [guid]::NewGuid().ToString('N')
    try {
        # Dot 4: -1/-2 nam trong .cache (an) hoac o goc (file cu); xet ca hai cho.
        foreach ($rel in @('-1-video-goc.mp4','-2-am-thanh-tho.m4a','-3-hoan-chinh.mp4','-3-hoan-chinh-logo-preview.mp4','.cache\-1-video-goc.mp4','.cache\-2-am-thanh-tho.m4a')) {
            $leafRel = if ($rel.StartsWith('.cache\')) { '.cache\' + $VideoId + $rel.Substring(7) } else { $VideoId + $rel }
            $source = [IO.Path]::GetFullPath((Join-Path $OutDir $leafRel))
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
    param([string]$DubbingStatus)
    if ($DubbingStatus -eq 'unavailable') { return 'reject-ui' }
    # Download policy consumes Meta UI selection, not audio-language inference.
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
            # Dot 4 (F2): "da co trong kho" CHI khi co -3 o goc thu muc xuat. Chi con -1 (trong .cache hoac o goc) = cache-only, khong tinh.
            $candidate = Join-Path $OutDir ($videoId + '-3-hoan-chinh.mp4')
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop) {
                $file = Get-Item -LiteralPath $candidate -ErrorAction Stop
                if ($file -and $file.Length -gt 0) { $downloadedIds.Add($videoId) }
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
