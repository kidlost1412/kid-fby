# A2: a stored success is never downgraded by stale non-terminal data (merge, fast path, interleavings).
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$root = $tmp

function New-Meta {
    # Parsed-JSON-shaped metadata from id -> entry hashtable (so property types match what Get-ReupMetadata returns).
    param($Entries)
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Entries -Depth 12))
}
function New-HistItem {
    param($History, $Extra = @{})
    $e = [ordered]@{ Posted = $false; Date = ''; Source = 'autotok-history'; History = @($History); ManualPosted = $false; ManualDate = '' }
    foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
    return $e
}

# ---------------- A2 ----------------
function New-TestReceipts { param($Rows) return @($Rows | ForEach-Object { [pscustomobject]$_ }) }

Test-Case 'A2 merge: a stored success is not downgraded by any stale non-terminal entry for the same request' {
    $stored = [pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna'); $stored.post_url = 'https://www.tiktok.com/@anna/video/1'; $stored.post_id = '1'
    $old = [pscustomobject]@{ Source = 'autotok-history'; History = @($stored) }
    foreach ($status in 'preparing', 'pending', 'queued', 'running') {
        $stale = New-TestHistoryEntry -Request 'r1' -User 'anna' -Status $status -Accepted ''
        $merged = @(Merge-TikTokVideoHistory '1' @([pscustomobject]$stale) @() $old)
        Assert-Equal $merged.Count 1 "$status count"
        Assert-Equal $merged[0].status 'succeeded' "$status kept succeeded"
        Assert-Equal $merged[0].accepted_at '2026-10-20T10:00:00Z' "$status accepted_at"
        Assert-Equal $merged[0].post_id '1' "$status post_id"
    }
}

Test-Case 'A2 merge: matching by request_id works when the keys differ' {
    $stored = [pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna'); $stored.key = 'history:abc'
    $old = [pscustomobject]@{ Source = 'autotok-history'; History = @($stored) }
    $stale = New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'pending' -Accepted ''
    $merged = @(Merge-TikTokVideoHistory '1' @([pscustomobject]$stale) @() $old)
    Assert-Equal $merged.Count 1
    Assert-Equal $merged[0].status 'succeeded'
}

Test-Case 'A2 merge: upgrades and unrelated requests behave as before' {
    $pending = [pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'pending' -Accepted '')
    $old = [pscustomobject]@{ Source = 'autotok-history'; History = @($pending) }
    $done = New-TestHistoryEntry -Request 'r1' -User 'anna'
    $merged = @(Merge-TikTokVideoHistory '1' @([pscustomobject]$done) @() $old)
    Assert-Equal $merged[0].status 'succeeded' 'pending -> succeeded'
    # terminal statuses from the backend still win (a success the backend now reports as failed is the backend's call)
    $oldDone = [pscustomobject]@{ Source = 'autotok-history'; History = @([pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna')) }
    $failed = New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'failed'
    Assert-Equal @(Merge-TikTokVideoHistory '1' @([pscustomobject]$failed) @() $oldDone)[0].status 'failed'
    # another request pending next to a stored success: both kept
    $newer = New-TestHistoryEntry -Request 'r2' -User 'anna' -Status 'pending' -Accepted '' -Created '2026-10-21T09:00:00Z'
    $both = @(Merge-TikTokVideoHistory '1' @([pscustomobject]$newer) @() $oldDone)
    Assert-Equal ($both.status -join ',') 'pending,succeeded'
}

Test-Case 'A2 merge: a local receipt of an already confirmed request is not listed next to the stored success' {
    $old = [pscustomobject]@{ Source = 'autotok-history'; History = @([pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna')) }
    $receipt = New-TestReceipts @(@{ RequestId = 'r1'; VideoId = '1'; Username = 'anna'; ScheduledFor = ''; Status = 'preparing'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; WorkerAlive = $true })
    $merged = @(Merge-TikTokVideoHistory '1' @() $receipt $old)
    Assert-Equal $merged.Count 1 'one entry'
    Assert-Equal $merged[0].status 'succeeded'
}

Test-Case 'A2 fast path: Update-TikTokEntryFromJob keeps a stored success against a stale pending job, upgrades otherwise' {
    $stored = [pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna')
    $stale = [pscustomobject]@{ status = 'pending'; publish_uncertain = $false; prior_uncertain = $false; username = 'anna'; planned_for = ''; accepted_at = ''; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' }
    foreach ($status in 'preparing', 'pending', 'queued', 'running') {
        $stale.status = $status
        $e = Update-TikTokEntryFromJob $stored $stale
        Assert-Equal $e.status 'succeeded' "$status"
        Assert-Equal $e.accepted_at '2026-10-20T10:00:00Z' "$status accepted_at kept"
    }
    $pendingStored = [pscustomobject](New-TestHistoryEntry -Request 'r2' -User 'anna' -Status 'pending' -Accepted '')
    $job = [pscustomobject]@{ status = 'succeeded'; publish_uncertain = $false; prior_uncertain = $false; username = 'Anna'; planned_for = ''; accepted_at = '2026-10-21T10:00:00Z'; post_url = 'u'; post_id = '9'; link_state = 'ok'; tiktok_schedule_time = ''; schedule_mode = 'now'; time_source = 'backend' }
    $up = Update-TikTokEntryFromJob $pendingStored $job
    Assert-Equal $up.status 'succeeded'; Assert-Equal $up.accepted_at '2026-10-21T10:00:00Z'; Assert-Equal $up.post_id '9'; Assert-Equal $up.username 'Anna'
    $running = [pscustomobject](New-TestHistoryEntry -Request 'r3' -User 'anna' -Status 'running' -Accepted '')
    $job.status = 'pending'
    Assert-Equal (Update-TikTokEntryFromJob $running $job).status 'pending' 'non-success stored entries follow the job'
}

Test-Case 'A2 interleaving 1: full sync snapshot is stale, the fast path confirms first, then the full sync writes -> stays succeeded' {
    $out = New-TestDir
    Write-TestMetadata $out @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'pending' -Accepted ''))) }
    $staleBackend = @([pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'pending' -Accepted ''))   # fetched before the confirmation
    $job = [pscustomobject]@{ status = 'succeeded'; publish_uncertain = $false; prior_uncertain = $false; username = 'anna'; planned_for = ''; accepted_at = '2026-10-20T10:00:00Z'; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' }
    # fast path writes the success
    [void](Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $h = @(foreach ($x in @($meta.'1'.History)) { Update-TikTokEntryFromJob $x $job })
        $a = Set-TikTokItemHistory $meta '1' $h ''
        return $a
    })
    Assert-Equal (Read-TestJson (Join-Path $out 'reup-status.json')).'1'.History[0].status 'succeeded' 'precondition'
    # the full sync then writes with its stale snapshot, exactly as the worker's Change block does
    [void](Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $old = $meta.PSObject.Properties['1']
        $history = @(Merge-TikTokVideoHistory '1' $staleBackend @() $old.Value)
        $a = Set-TikTokItemHistory $meta '1' $history ''
        return $a
    })
    $final = (Read-TestJson (Join-Path $out 'reup-status.json')).'1'
    Assert-Equal $final.History[0].status 'succeeded'; Assert-Equal $final.Posted $true
}

Test-Case 'A2 interleaving 2: the full sync confirms first, then a stale fast-path poll writes -> stays succeeded' {
    $out = New-TestDir
    Write-TestMetadata $out @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'pending' -Accepted ''))) }
    $fresh = @([pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna'))
    [void](Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $old = $meta.PSObject.Properties['1']
        $a = Set-TikTokItemHistory $meta '1' @(Merge-TikTokVideoHistory '1' $fresh @() $old.Value) ''
        return $a
    })
    $stalePoll = [pscustomobject]@{ status = 'running'; publish_uncertain = $false; prior_uncertain = $false; username = 'anna'; planned_for = ''; accepted_at = ''; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' }
    $update = Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $h = @(foreach ($x in @($meta.'1'.History)) { Update-TikTokEntryFromJob $x $stalePoll })
        $a = Set-TikTokItemHistory $meta '1' $h ''
        return $a
    }
    Assert-True (-not $update.Changed) 'the stale poll changes nothing on disk'
    $final = (Read-TestJson (Join-Path $out 'reup-status.json')).'1'
    Assert-Equal $final.History[0].status 'succeeded'
}


Remove-Item -LiteralPath $tmp -Recurse -Force
Complete-Tests
