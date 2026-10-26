# Release-review fixes (Codex v3 review): (1) pending journal reserves its ids against metadata writes + null-snapshot recovery, (2) kho delete
# retries incomplete ids, (3) destructive confirmations hold khoExclusive and revalidate, (4) unreadable kho history blocks auto slots,
# (5) clean copy uses the planned non-cover stream, (6) retiring dialog workers keep the mover out.
. (Join-Path $PSScriptRoot '_load.ps1')
. (Join-Path $PSScriptRoot 'FakeBackend.ps1')
function Update-Gallery { }
function Invoke-TikTokSyncStep { }
$server = Start-FakeBackend
$base = $server.Url
$hex = { param($n) ('{0:x32}' -f [long]$n) }
function New-LockedMoveJournal {
    # A move A -> B stopped before anything moved (journal at phase 'renaming'); the -3 is still in A.
    param($w, [string]$Id, $Snapshot = $null)
    $plan = @(New-KhoMovePlan $Id $w.A.path $w.B.path (Get-KhoReceiptGroups $w.A.path))
    return (Write-KhoJournal ([ordered]@{ version = 1; txid = [Guid]::NewGuid().ToString('N'); id = $Id; from = $w.A.path; to = $w.B.path; phase = 'renaming'; reason = 'manual'
        createdAt = [DateTime]::UtcNow.ToString('o'); renames = @($plan); sourceEntrySnapshot = $Snapshot }))
}

# ---------------------------------------------------------------- 1
Test-Case '1: manual mark of a video reserved by a pending journal is refused and writes nothing; other videos still mark' {
    $w = New-TestWorld @('B')
    $id = NextId; $other = NextId
    [void](New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry (& $hex $id))); [void](New-TestVideo $w.A.path $other)
    [void](New-LockedMoveJournal $w $id (Copy-ReupEntry (Get-ReupMetadata -OutDir $w.A.path).$id))
    $before = Sha (Join-Path $w.A.path 'reup-status.json')
    Assert-Throws { Set-ReupMetadata -VideoId $id -Posted $true -OutDir $w.A.path } '*chuyển kho chưa hoàn tất*'
    Assert-Equal (Sha (Join-Path $w.A.path 'reup-status.json')) $before 'metadata file untouched'
    Set-ReupMetadata -VideoId $other -Posted $true -OutDir $w.A.path
    Assert-Equal (Get-ReupMetadata -OutDir $w.A.path).$other.Posted $true 'unreserved video marks fine'
}
Test-Case '1: local receipt insertion is skipped (logged) for a reserved video' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    [void](New-LockedMoveJournal $w $id)
    $rec = [pscustomobject]@{ RequestId = (& $hex 77); VideoId = $id; Username = 'anna'; ScheduledFor = ''; Status = 'preparing'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; SourceSha256 = ''; UploadSha256 = '' }
    $r = Add-TikTokLocalReceiptHistory -OutDir $w.A.path -VideoId $id -Entries @() -Record $rec
    Assert-Equal $r $false 'not inserted'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'no entry written'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*chuyển kho chưa hoàn tất*' }).Count -ge 1) 'logged'
}
Test-Case '1: worker full sync and fast status skip reserved ids (and still process the others)' {
    $w = New-TestWorld @('B')
    $res = '1000000000901'; $free = '1000000000902'
    [void](New-TestVideo $w.A.path $res); [void](New-TestVideo $w.A.path $free)
    $server.Rows[$res] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 901) -User 'Anna'))
    $server.Rows[$free] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 902) -User 'Anna'))
    [void](New-LockedMoveJournal $w $res)
    $reserved = Get-KhoReservedIds $w.A.path
    Assert-True ($reserved.ContainsKey($res) -and -not $reserved.ContainsKey($free)) 'reserved set'
    $run = Invoke-Worker 'sync' @{ out_dir = $w.A.path; receipts = @(); last_input_sig = ''; last_file_stamp = ''; probe_cursor = ''; identity_cache = $null; file = $null; reserved_ids = $reserved } $base
    Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
    $m = Get-ReupMetadata -OutDir $w.A.path
    Assert-True ($null -eq $m.PSObject.Properties[$res]) 'reserved video not written by sync'
    Assert-Equal @($m.$free.History).Count 1 'free video stored'
    # fast: a stored active entry for the reserved id is not updated
    $act = New-TestHistoryEntry -Request (& $hex 903) -User 'Dana' -Status 'pending' -Accepted ''
    [void](Update-ReupMetadata -OutDir $w.A.path -Change { param($meta) $meta | Add-Member -NotePropertyName $res -Force -NotePropertyValue ([pscustomobject]@{ Posted = $false; Date = ''; Source = 'autotok-history'; History = @([pscustomobject]$act); ManualPosted = $false; ManualDate = '' }); return $true })
    $server.Jobs[(& $hex 903)] = (ConvertTo-Json -Compress @{ status = 'succeeded'; publish_uncertain = $false; prior_uncertain = $false; username = 'Dana'; planned_for = ''; accepted_at = '2026-10-23T10:00:00Z'; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' })
    $run = Invoke-Worker 'fast' @{ out_dir = $w.A.path; last_stamp = ''; active = $null; cursor = ''; reserved_ids = $reserved } $base
    Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
    Assert-Equal (Get-ReupMetadata -OutDir $w.A.path).$res.History[0].status 'pending' 'fast pass left the reserved entry alone'
}
Test-Case '1: recovery with a NULL snapshot uses the current source entry (a manual mark made later is not lost); target gets it, source loses it' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $path = New-LockedMoveJournal $w $id $null
    [void](Update-ReupMetadata -OutDir $w.A.path -Change { param($meta) $meta | Add-Member -NotePropertyName $id -Force -NotePropertyValue ([pscustomobject]@{ Posted = $true; Date = '26/10 09:00' }); return $true })
    $r = Resume-KhoMoves
    Assert-Equal @($r.Pending).Count 0 ($r.Pending -join ';')
    $t = (Get-ReupMetadata -OutDir $w.B.path).$id
    Assert-True ($null -ne $t) 'target entry exists'
    Assert-Equal $t.Posted $true 'manual mark carried over'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'source entry removed'
}
# ---- END ----
$server.Stop()
Complete-Tests
