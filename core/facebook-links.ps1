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
