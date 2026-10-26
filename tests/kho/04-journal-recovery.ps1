# Move journal (data\kho-moves) and crash recovery: a crash at every point of a move, then recovery must reach exactly the state of an
# uninterrupted move. Conflicts and failures keep the journal and block both folders. Corrupt journals block and are never deleted.
. (Join-Path $PSScriptRoot '_load.ps1')

function New-CrashState {
    # Builds, with the product's own planner and journal writer, the exact on-disk state of a move of one video A -> B that was
    # interrupted: the first $Done renames done; -Phase renaming | meta-target-done | meta-source-done.
    param($w, [int]$Done, [string]$Phase = 'renaming', [switch]$ReceiptsRewritten)
    $id = NextId
    $req = New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id))
    $groups = Get-KhoReceiptGroups $w.A.path
    $plan = @(New-KhoMovePlan $id $w.A.path $w.B.path $groups)
    $snapshot = Copy-ReupEntry (Get-ReupMetadata -OutDir $w.A.path).$id
    $j = [ordered]@{ version = 1; txid = [Guid]::NewGuid().ToString('N'); id = $id; from = $w.A.path; to = $w.B.path; phase = 'renaming'; reason = 'manual'
                     createdAt = [DateTime]::UtcNow.ToString('o'); renames = @($plan); sourceEntrySnapshot = $snapshot }
    $path = Write-KhoJournal $j
    for ($i = 0; $i -lt [Math]::Min($Done, $plan.Count); $i++) {
        $state = Invoke-KhoMoveRename $plan[$i]
        if ($state -ne 'moved') { throw "fixture: rename $i gave $state" }
        $plan[$i].status = 'moved'
    }
    if ($Phase -ne 'renaming') {
        foreach ($r in $plan) { if ($r.kind -eq 'receipt') { Update-KhoReceiptPaths $r.dst $w.B.path $id } }
        [void](Update-ReupMetadata -OutDir $w.B.path -Change { param($meta) return (Merge-KhoMoveEntry $meta $id $snapshot) })
        $j.phase = 'meta-target-done'
        if ($Phase -eq 'meta-source-done') {
            [void](Update-ReupMetadata -OutDir $w.A.path -Change { param($meta) [void]$meta.PSObject.Properties.Remove($id); return $true })
            $j.phase = 'meta-source-done'
        }
    }
    $j.renames = @($plan)
    [void](Write-KhoJournal $j)
    return @{ Id = $id; Req = $req; Path = $path; Plan = $plan }
}

Test-Case 'journal file: lives in data\kho-moves OUTSIDE every kho, atomic (no temp left), lists every file with -3 LAST, carries the source entry snapshot' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 0
    $dir = Get-KhoMovesDir
    Assert-Equal $dir (Join-Path $script:root 'data\kho-moves')
    foreach ($lib in Get-KhoList) { Assert-True (-not $c.Path.StartsWith(([string]$lib.path).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) "journal inside kho $($lib.name)" }
    Assert-Equal @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -notmatch '^[0-9a-f]{32}\.json$' }).Count 0 'only <txid>.json files, no temp'
    $j = Read-TestJson $c.Path
    Assert-Equal $j.phase 'renaming'; Assert-Equal $j.id $c.Id; Assert-Equal $j.from $w.A.path; Assert-Equal $j.to $w.B.path; Assert-True ($j.txid -match '^[0-9a-f]{32}$') 'txid'
    Assert-Equal @($j.renames).Count 7 '2 companions + 2 thumbs + receipt + archived receipt + final'
    Assert-Equal $j.renames[-1].kind 'final' '-3 is renamed last'
    Assert-Equal (@($j.renames | ForEach-Object { $_.kind }) -join ',') 'companion,companion,thumb,thumb,receipt,receipt-archive,final'
    Assert-Equal (@($j.renames | Where-Object { $_.optional } | ForEach-Object { $_.kind } | Sort-Object -Unique) -join ',') 'thumb' 'only thumbs are optional'
    Assert-Equal $j.sourceEntrySnapshot.History[0].username 'anna' 'snapshot has the history'
    # Write-KhoJournal over an existing journal (phase update) replaces it atomically
    $j2 = [ordered]@{ txid = $j.txid; from = $j.from; to = $j.to; id = $j.id; phase = 'meta-target-done' }
    [void](Write-KhoJournal $j2)
    Assert-Equal (Read-TestJson $c.Path).phase 'meta-target-done'; Assert-Equal @(Get-TestJournalFiles).Count 1
}

# ---------------- a crash after every rename ----------------
foreach ($done in 0..7) {
    Test-Case "crash after $done of 7 renames (phase renaming): recovery reaches the state of an uninterrupted move" {
        $w = New-TestWorld @('B')
        $c = New-CrashState $w $done
        $r = Resume-KhoMoves
        Assert-Equal $r.Done 1 "recovery result: $($r.Pending -join '; ')"; Assert-Equal @($r.Pending).Count 0
        Assert-Moved $w.A.path $w.B.path $c.Id $c.Req
        Assert-Equal @((Get-ReupMetadata -OutDir $w.B.path).($c.Id).History).Count 1 'history exactly once'
    }
}
Test-Case 'crash after the renames and the receipt rewrite but BEFORE the target metadata step (phase still renaming, target entry already merged): the merge is idempotent' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 7 -Phase meta-target-done
    $j = Read-TestJson $c.Path; $j.phase = 'renaming'
    [IO.File]::WriteAllText($c.Path, (ConvertTo-Json $j -Depth 14), [Text.UTF8Encoding]::new($false))
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 1; Assert-Moved $w.A.path $w.B.path $c.Id $c.Req
    Assert-Equal @((Get-ReupMetadata -OutDir $w.B.path).($c.Id).History).Count 1 'no duplicated history entry'
}
Test-Case 'crash in phase meta-target-done (target has the entry, source entry still there): recovery removes the source entry and the journal' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 7 -Phase meta-target-done
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$c.Id]) 'precondition: source entry present'
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 1; Assert-Moved $w.A.path $w.B.path $c.Id $c.Req
}
Test-Case 'crash in phase meta-source-done (only the journal is left): recovery just deletes it' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 7 -Phase meta-source-done
    Assert-Equal @(Get-TestJournalFiles).Count 1
    $before = Get-TestTree $w.B.path
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 1; Assert-Moved $w.A.path $w.B.path $c.Id $c.Req
    Assert-Equal (Get-TestTree $w.B.path) $before 'target folder unchanged by the final cleanup'
}
Test-Case 'recovery is repeatable: a second Resume-KhoMoves finds nothing; two pending journals are both finished in one call' {
    $w = New-TestWorld @('B')
    $c1 = New-CrashState $w 3; $c2 = New-CrashState $w 7 -Phase meta-target-done
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 2 ($r.Pending -join '; ')
    Assert-Moved $w.A.path $w.B.path $c1.Id $c1.Req; Assert-Moved $w.A.path $w.B.path $c2.Id $c2.Req
    $again = Resume-KhoMoves; Assert-Equal $again.Done 0; Assert-Equal @($again.Pending).Count 0
}
Test-Case 'Initialize-KhoStartup (the startup entry, before gallery and sync) finishes an interrupted move and tells the owner' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 4
    $script:TestLog.Clear()
    Initialize-KhoStartup
    Assert-Moved $w.A.path $w.B.path $c.Id $c.Req
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*Đã hoàn tất 1 lần chuyển video dở dang*' }).Count -eq 1) 'owner told'
    Assert-Equal @(Get-KhoList).Count 2 'registry loaded'
}

# ---------------- conflicts and failures keep the journal and block ----------------
Test-Case 'both-exist conflict: nothing is overwritten, the journal stays, BOTH folders are blocked for moves/deletes, others are not; startup warns; after the owner fixes it recovery completes' {
    $w = New-TestWorld @('B', 'C')
    $c = New-CrashState $w 3
    # the interrupted move already took .cache\-1/-2; now a DIFFERENT file with the same name reappears in the source (both exist)
    $src1 = Join-Path $w.A.path ".cache\$($c.Id)-1-video-goc.mp4"
    [IO.File]::WriteAllText($src1, 'a different source file')
    $dstHash = Get-FileHash -LiteralPath (Join-Path $w.B.path ".cache\$($c.Id)-1-video-goc.mp4") | ForEach-Object Hash
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 0; Assert-Equal @($r.Pending).Count 1; Assert-True ($r.Pending[0] -like '*đã có file cùng tên ở đích*') "pending: $($r.Pending[0])"
    Assert-Equal @(Get-TestJournalFiles).Count 1 'journal kept'
    Assert-Equal ([IO.File]::ReadAllText($src1)) 'a different source file' 'source copy untouched'
    Assert-Equal (Get-FileHash -LiteralPath (Join-Path $w.B.path ".cache\$($c.Id)-1-video-goc.mp4")).Hash $dstHash 'target copy untouched'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$($c.Id)-3-hoan-chinh.mp4"))) '-3 is renamed last, so it is still in the source'
    Assert-True ([bool](Get-KhoJournalBlock @($w.A.path))) 'A blocked'; Assert-True ([bool](Get-KhoJournalBlock @($w.B.path))) 'B blocked'
    Assert-Equal (Get-KhoJournalBlock @($w.C.path)) '' 'an unrelated kho is not blocked'
    # other video A -> C: refused because A is reserved; C -> A refused too; the stuck video itself is not touched
    $other = NextId; [void](New-TestVideo $w.A.path $other)
    $m = Move-KhoVideos -Videos @(@{ Id = $other; From = $w.A.path }) -ToRoot $w.C.path
    Assert-Equal @($m.Moved).Count 0; Assert-True ($m.Failed[0].Why -like '*chưa hoàn tất*') "why: $($m.Failed[0].Why)"
    $viaEntry = Invoke-KhoMove -Items @((Item $w.A.path $other)) -TargetId $w.C.id -Reason manual
    Assert-Equal @($viaEntry.Moved).Count 0; Assert-True ([bool]$viaEntry.Busy) "Invoke-KhoMove busy: '$($viaEntry.Busy)'"
    $del = Remove-KhoWithVideos -Id $w.B.id
    Assert-True ($del.Why -like '*chưa hoàn tất*') "delete refused: $($del.Why)"; Assert-True ($null -ne (Get-KhoById $w.B.id)) 'kho B still registered'
    # startup shows the warning
    $script:TestLog.Clear(); Initialize-KhoStartup
    Assert-True (@($script:TestLog | Where-Object { $_ -like '`[Warning`] Chuyển kho dở dang chưa xử lý được*' }).Count -ge 1) 'warning in the log'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '`[toast`] Có lần chuyển video giữa các kho chưa hoàn tất*' }).Count -eq 1) 'toast'
    # the owner removes the stray copy -> recovery completes
    Remove-Item -LiteralPath $src1
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 1 ($r.Pending -join '; '); Assert-Moved $w.A.path $w.B.path $c.Id $c.Req
    Assert-Equal (Get-KhoJournalBlock @($w.A.path, $w.B.path)) '' 'blocks lifted'
}
Test-Case 'an OPTIONAL thumbnail that exists on both sides is skipped, not a conflict' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 0
    $t = Join-Path $w.B.path '.cache\thumbs'; [void][IO.Directory]::CreateDirectory($t); [IO.File]::WriteAllText((Join-Path $t "$($c.Id).jpg"), 'target thumb')
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 1 ($r.Pending -join '; ')
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $t "$($c.Id).jpg"))) 'target thumb'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path ".cache\thumbs\$($c.Id).jpg"))) 'source thumb is left behind (regenerable)'
}
Test-Case 'a MANDATORY file that is in neither folder fails the recovery: the journal stays and blocks' {
    $w = New-TestWorld @('B')
    $c = New-CrashState $w 0
    Remove-Item -LiteralPath (Join-Path $w.A.path ".cache\$($c.Id)-2-am-thanh-tho.m4a")
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 0; Assert-True ($r.Pending[0] -like '*không đổi tên được*') "pending: $($r.Pending[0])"
    Assert-Equal @(Get-TestJournalFiles).Count 1; Assert-True ([bool](Get-KhoJournalBlock @($w.A.path)))
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$($c.Id)-3-hoan-chinh.mp4"))) '-3 (renamed last) never moved ahead of its companions'
}
Test-Case 'a locked MANDATORY companion mid-move: the batch fails, journal stays, both folders block; once unlocked, the next move first completes the old one' {
    $w = New-TestWorld @('B')
    $id = NextId; $req = New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id))
    $lock = [IO.File]::Open((Join-Path $w.A.path ".cache\$id-1-video-goc.mp4"), 'Open', 'Read', 'None')
    try {
        $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
        Assert-Equal @($r.Moved).Count 0; Assert-True ($r.Failed[0].Why -like '*không đổi tên được*') "why: $($r.Failed[0].Why)"
        Assert-Equal @(Get-TestJournalFiles).Count 1 'journal stays'
        Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) '-3 not moved'
        $other = NextId; [void](New-TestVideo $w.A.path $other)
        $r2 = Invoke-KhoMove -Items @((Item $w.A.path $other)) -TargetId $w.B.id -Reason manual
        Assert-Equal @($r2.Moved).Count 0; Assert-True ($r2.Busy -like '*dở dang*') "busy: '$($r2.Busy)'"
    } finally { $lock.Dispose() }
    $r3 = Invoke-KhoMove -Items @((Item $w.A.path $other)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r3.Moved).Count 1 (($r3.Failed | ForEach-Object { $_.Why }) -join '; ')
    Assert-Moved $w.A.path $w.B.path $id $req
    Assert-True ([IO.File]::Exists((Join-Path $w.B.path "$other-3-hoan-chinh.mp4"))) 'the new move ran after the recovery'
}
Test-Case 'corrupt or incomplete journal files block everything, are reported and are NEVER deleted' {
    $w = New-TestWorld @('B')
    $dir = Get-KhoMovesDir; [void][IO.Directory]::CreateDirectory($dir)
    $bad1 = Join-Path $dir 'bad.json'; $bad2 = Join-Path $dir 'nofields.json'
    [IO.File]::WriteAllText($bad1, '{oops'); [IO.File]::WriteAllText($bad2, '{"txid":"x","id":"1"}')
    $es = @(Read-KhoJournals)
    Assert-Equal $es.Count 2; Assert-Equal @($es | Where-Object { $_.Journal }).Count 0 'neither is a usable journal'
    Assert-True ((Get-KhoJournalBlock @($w.A.path)) -like '*không đọc được*') 'blocks every folder'
    Assert-True ($null -eq (Get-KhoJournalPaths)) 'cleanup protection returns $null -> cleanups refuse'
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 0; Assert-Equal @($r.Pending).Count 2
    Assert-True ([IO.File]::Exists($bad1) -and [IO.File]::Exists($bad2)) 'files kept'
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    Assert-Equal @((Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id).Moved).Count 0 'no move while a journal is unreadable'
}

Complete-Tests
