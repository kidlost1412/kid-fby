# D3/A3 Invoke-KhoAutoAssign and A2 (a stored success is never downgraded by stale non-terminal data).
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

# ---------------- D3 / A3 ----------------
Test-Case 'succeeded post -> acct:<username lower-case>; nothing else on the entry changes' {
    $meta = New-Meta @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'TikTokUser'))) }
    $before = ConvertTo-Json $meta.'1' -Depth 8 -Compress
    Assert-True (Invoke-KhoAutoAssign $meta) 'returns true'
    Assert-Equal $meta.'1'.Kho 'acct:tiktokuser'
    $meta.'1'.PSObject.Properties.Remove('Kho')
    Assert-Equal (ConvertTo-Json $meta.'1' -Depth 8 -Compress) $before 'other fields identical'
}

Test-Case 'uncertain / pending / queued / running / preparing / failed / cancelled / missing / preparation_failed stay unassigned' {
    foreach ($status in 'pending', 'queued', 'running', 'preparing', 'failed', 'cancelled', 'missing', 'preparation_failed', 'transfer_failed') {
        $meta = New-Meta @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'anna' -Status $status))) }
        Assert-True (-not (Invoke-KhoAutoAssign $meta)) "status $status returns false"
        Assert-True ($null -eq $meta.'1'.PSObject.Properties['Kho']) "status $status creates no Kho"
    }
    $meta = New-Meta @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'anna' -Uncertain $true))) }
    Assert-True (-not (Invoke-KhoAutoAssign $meta)) 'succeeded but publish_uncertain'
    Assert-True ($null -eq $meta.'1'.PSObject.Properties['Kho'])
}

Test-Case 'KhoManual (also the default tombstone) and already-account entries are never changed' {
    $h = @((New-TestHistoryEntry -Request 'r1' -User 'anna'))
    $meta = New-Meta @{
        'm1' = (New-HistItem $h @{ KhoManual = $true })
        'm2' = (New-HistItem $h @{ KhoManual = $true; Kho = 'default' })
        'm3' = (New-HistItem $h @{ KhoManual = $true; Kho = 'c-0123456789abcdef0123456789abcdef' })
        'a1' = (New-HistItem $h @{ Kho = 'acct:bob' })
    }
    Assert-True (-not (Invoke-KhoAutoAssign $meta)) 'returns false'
    Assert-True ($null -eq $meta.m1.PSObject.Properties['Kho'])
    Assert-Equal $meta.m2.Kho 'default'
    Assert-Equal $meta.m3.Kho 'c-0123456789abcdef0123456789abcdef'
    Assert-Equal $meta.a1.Kho 'acct:bob' 'once an account kho, always'
}

Test-Case 'missing / default / custom Kho (not manual) moves to the account kho' {
    $h = @((New-TestHistoryEntry -Request 'r1' -User 'anna'))
    $meta = New-Meta @{ 'x1' = (New-HistItem $h); 'x2' = (New-HistItem $h @{ Kho = 'default' }); 'x3' = (New-HistItem $h @{ Kho = 'c-0123456789abcdef0123456789abcdef'; KhoManual = $false }) }
    Assert-True (Invoke-KhoAutoAssign $meta)
    foreach ($id in 'x1', 'x2', 'x3') { Assert-Equal $meta.$id.Kho 'acct:anna' $id }
}

Test-Case 'two accounts: the earliest accepted_at wins whatever the list order' {
    $a = New-TestHistoryEntry -Request 'ra' -User 'Anna' -Accepted '2026-10-20T10:00:00Z' -Created '2026-10-20T09:59:00Z'
    $b = New-TestHistoryEntry -Request 'rb' -User 'Bob' -Accepted '2026-10-21T10:00:00Z' -Created '2026-10-21T09:00:00Z'
    foreach ($order in @(@($a, $b), @($b, $a))) {
        $meta = New-Meta @{ '1' = (New-HistItem $order) }
        [void](Invoke-KhoAutoAssign $meta)
        Assert-Equal $meta.'1'.Kho 'acct:anna'
    }
    # an unconfirmed earlier entry does not count
    $early = New-TestHistoryEntry -Request 'rc' -User 'Carl' -Status 'pending' -Accepted '2026-10-19T10:00:00Z'
    $meta = New-Meta @{ '1' = (New-HistItem @($early, $b)) }
    [void](Invoke-KhoAutoAssign $meta)
    Assert-Equal $meta.'1'.Kho 'acct:bob'
}

Test-Case 'idempotent: the second call changes nothing and returns false' {
    $meta = New-Meta @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'anna'))); '2' = (New-HistItem @((New-TestHistoryEntry -Request 'r2' -User 'bob'))) }
    Assert-True (Invoke-KhoAutoAssign $meta)
    $json = ConvertTo-Json $meta -Depth 8 -Compress
    Assert-True (-not (Invoke-KhoAutoAssign $meta)) 'second call'
    Assert-Equal (ConvertTo-Json $meta -Depth 8 -Compress) $json
}

Test-Case 'legacy manual entries, entries without history, empty usernames and non-object noise are skipped' {
    $meta = New-Meta @{
        'l1' = [ordered]@{ Posted = $true; Date = '19/10 08:00' }
        'l2' = (New-HistItem @())
        'l3' = (New-HistItem @((New-TestHistoryEntry -Request 'r3' -User '')))
        'l4' = (New-HistItem @((New-TestHistoryEntry -Request 'r4' -User 'two words')))
        'l5' = [ordered]@{ Posted = $false; Date = ''; Source = 'autotok-history' }
    }
    Assert-True (-not (Invoke-KhoAutoAssign $meta))
    foreach ($id in 'l1', 'l2', 'l3', 'l4', 'l5') { Assert-True ($null -eq $meta.$id.PSObject.Properties['Kho']) $id }
}

Test-Case 'A -> B: a video confirmed on A and later also on B stays in A''s kho' {
    $a = New-TestHistoryEntry -Request 'ra' -User 'Anna' -Accepted '2026-10-20T10:00:00Z'
    $b = New-TestHistoryEntry -Request 'rb' -User 'Bob' -Accepted '2026-10-25T10:00:00Z' -Created '2026-10-25T09:00:00Z'
    $meta = New-Meta @{ '1' = (New-HistItem @($a)) }
    [void](Invoke-KhoAutoAssign $meta)
    Assert-Equal $meta.'1'.Kho 'acct:anna'
    $meta.'1'.History = @($b, $meta.'1'.History[0])
    Assert-True (-not (Invoke-KhoAutoAssign $meta)) 'repost does not move it'
    Assert-Equal $meta.'1'.Kho 'acct:anna'
}

Test-Case 'B observed first: later-seen earlier post on A does not move it (accepted edge case)' {
    $a = New-TestHistoryEntry -Request 'ra' -User 'Anna' -Accepted '2026-10-20T10:00:00Z'
    $b = New-TestHistoryEntry -Request 'rb' -User 'Bob' -Accepted '2026-10-25T10:00:00Z' -Created '2026-10-25T09:00:00Z'
    $meta = New-Meta @{ '1' = (New-HistItem @($b)) }
    [void](Invoke-KhoAutoAssign $meta)
    Assert-Equal $meta.'1'.Kho 'acct:bob'
    $meta.'1'.History = @($meta.'1'.History[0], $a)
    Assert-True (-not (Invoke-KhoAutoAssign $meta))
    Assert-Equal $meta.'1'.Kho 'acct:bob'
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
        $b = Invoke-KhoAutoAssign $meta
        return ($a -or $b)
    })
    Assert-Equal (Read-TestJson (Join-Path $out 'reup-status.json')).'1'.History[0].status 'succeeded' 'precondition'
    # the full sync then writes with its stale snapshot, exactly as the worker's Change block does
    [void](Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $old = $meta.PSObject.Properties['1']
        $history = @(Merge-TikTokVideoHistory '1' $staleBackend @() $old.Value)
        $a = Set-TikTokItemHistory $meta '1' $history ''
        $b = Invoke-KhoAutoAssign $meta
        return ($a -or $b)
    })
    $final = (Read-TestJson (Join-Path $out 'reup-status.json')).'1'
    Assert-Equal $final.History[0].status 'succeeded'; Assert-Equal $final.Posted $true; Assert-Equal $final.Kho 'acct:anna'
}

Test-Case 'A2 interleaving 2: the full sync confirms first, then a stale fast-path poll writes -> stays succeeded' {
    $out = New-TestDir
    Write-TestMetadata $out @{ '1' = (New-HistItem @((New-TestHistoryEntry -Request 'r1' -User 'anna' -Status 'pending' -Accepted ''))) }
    $fresh = @([pscustomobject](New-TestHistoryEntry -Request 'r1' -User 'anna'))
    [void](Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $old = $meta.PSObject.Properties['1']
        $a = Set-TikTokItemHistory $meta '1' @(Merge-TikTokVideoHistory '1' $fresh @() $old.Value) ''
        $b = Invoke-KhoAutoAssign $meta
        return ($a -or $b)
    })
    $stalePoll = [pscustomobject]@{ status = 'running'; publish_uncertain = $false; prior_uncertain = $false; username = 'anna'; planned_for = ''; accepted_at = ''; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' }
    $update = Update-ReupMetadata -OutDir $out -Change {
        param($meta)
        $h = @(foreach ($x in @($meta.'1'.History)) { Update-TikTokEntryFromJob $x $stalePoll })
        $a = Set-TikTokItemHistory $meta '1' $h ''
        $b = Invoke-KhoAutoAssign $meta
        return ($a -or $b)
    }
    Assert-True (-not $update.Changed) 'the stale poll changes nothing on disk'
    $final = (Read-TestJson (Join-Path $out 'reup-status.json')).'1'
    Assert-Equal $final.History[0].status 'succeeded'; Assert-Equal $final.Kho 'acct:anna'
}

Remove-Item -LiteralPath $tmp -Recurse -Force
Complete-Tests
