# Physical move between khos: happy path with every companion + receipts + metadata, preflight refusals, S2 job blocking, S1 quiet-state
# (busy flags, TikTok sync suspension, actors refusing while a batch runs), KhoPinned, auto-move candidates and end to end (account kho, auto-created kho).
. (Join-Path $PSScriptRoot '_load.ps1')
$ids = @{ }   # per-test ids come from here so a leftover file of one test can never satisfy another
$script:seq = 1000000000100
function NextId { $script:seq++; return [string]$script:seq }
function Item { param($Root, [string]$Id) return [pscustomobject]@{ Id = $Id; Path = (Join-Path $Root "$Id-3-hoan-chinh.mp4") } }
function Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Posts { param($Root) return (Join-Path $Root '.cache\tiktok-posts') }
function Write-Job {
    # A retained / live job file of a request: <req>.job with Record.VideoId, plus optional <req>.lock.
    param($Root, [string]$Req, [string]$VideoId, [switch]$Lock, [string]$Raw = '')
    $d = Posts $Root; [void][IO.Directory]::CreateDirectory($d)
    $text = $(if ($Raw) { $Raw } else { ConvertTo-Json @{ Record = @{ VideoId = $VideoId; RequestId = $Req } } -Depth 4 })
    [IO.File]::WriteAllText((Join-Path $d "$Req.job"), $text, [Text.UTF8Encoding]::new($false))
    if ($Lock) { [IO.File]::WriteAllText((Join-Path $d "$Req.lock"), '', [Text.UTF8Encoding]::new($false)) }
}
function Assert-Moved {
    # The complete end state of a finished move of $Id from $From to $To (shared with the journal-recovery tests).
    param($From, $To, [string]$Id, [string]$Req)
    foreach ($rel in @("$Id-3-hoan-chinh.mp4", ".cache\$Id-1-video-goc.mp4", ".cache\$Id-2-am-thanh-tho.m4a", ".cache\thumbs\$Id.jpg", ".cache\thumbs\$Id.json", ".cache\tiktok-posts\$Req.json")) {
        Assert-True (-not [IO.File]::Exists((Join-Path $From $rel))) "still in source: $rel"
        Assert-True ([IO.File]::Exists((Join-Path $To $rel))) "missing in target: $rel"
    }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $To "$Id-3-hoan-chinh.mp4"))) "final $Id" 'final bytes'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $To ".cache\$Id-1-video-goc.mp4"))) "source $Id"
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $To ".cache\$Id-2-am-thanh-tho.m4a"))) "audio $Id"
    $rec = Read-TestJson (Join-Path $To ".cache\tiktok-posts\$Req.json")
    Assert-Equal $rec.OutDir $To 'receipt OutDir'; Assert-Equal $rec.SourcePath (Join-Path $To "$Id-3-hoan-chinh.mp4") 'receipt SourcePath'
    $meta = Get-ReupMetadata -OutDir $To
    Assert-True ($null -ne $meta.PSObject.Properties[$Id]) 'target entry'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $From).PSObject.Properties[$Id]) 'source entry removed'
    Assert-Equal @(Get-TestJournalFiles).Count 0 'journal gone'
}

# ---------------- happy path ----------------
Test-Case 'quiet world: Test-KhoQuiet is empty, nothing blocks' {
    $w = New-TestWorld @('B')
    Assert-Equal (Test-KhoQuiet) ''; Assert-Equal (Test-KhoImportBlocked) ''
}
Test-Case 'happy path: every companion, thumbs, finished + archived receipts and the history entry move; receipts name the new folder; reedit inputs follow; others untouched' {
    $w = New-TestWorld @('B')
    $id = NextId; $other = NextId
    $req = New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id))
    [void](New-TestVideo $w.A.path $other -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$other) 'bob'))
    $otherTree = (Get-TestTree $w.A.path)
    Assert-True (Test-ReeditInputs (Join-Path $w.A.path "$id-3-hoan-chinh.mp4")) 'precondition: reedit inputs in A'
    $arch = '{0:x32}' -f ([long]$id + 7)
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal $r.Busy ''; Assert-Equal @($r.Moved).Count 1; Assert-Equal @($r.Failed).Count 0
    Assert-Moved $w.A.path $w.B.path $id $req
    Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path ".cache\tiktok-posts\$arch.json.archived-20261021-101010"))) 'archived receipt left the source'
    Assert-True ([IO.File]::Exists((Join-Path $w.B.path ".cache\tiktok-posts\$arch.json.archived-20261021-101010"))) 'archived receipt arrived'
    $recs = @(Get-TikTokReceipts $w.B.path)
    Assert-Equal $recs.Count 1 'the app receipt reader accepts the moved receipt'; Assert-Equal $recs[0].RequestId $req
    Assert-True (Test-ReeditInputs (Join-Path $w.B.path "$id-3-hoan-chinh.mp4")) 'reedit inputs found in B'
    Assert-True (-not (Test-ReeditInputs (Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) 'and gone from A'
    $e = (Get-ReupMetadata -OutDir $w.B.path).$id
    Assert-Equal @($e.History).Count 1; Assert-Equal $e.History[0].username 'anna'; Assert-Equal $e.Posted $true; Assert-Equal $e.FileSha256 ('sha-' + $req)
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'source entry gone'
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$other]) 'the other video keeps its entry'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$other-3-hoan-chinh.mp4"))) 'other video file stays'
    $log = [IO.File]::ReadAllText((Join-Path $script:root 'logs\kho-moves.log'))
    Assert-True ($log -match "OK   #$id ") 'one log line per move'
}
Test-Case 'legacy -1/-2 at the root of the source land at the ROOT of the target (not .cache); a video without receipt or thumbs moves too' {
    $w = New-TestWorld @('B')
    $id = NextId
    [void](New-TestVideo $w.A.path $id -Legacy -NoReceipt -NoThumb)
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 1 (($r.Failed | ForEach-Object { $_.Why }) -join '; ')
    foreach ($f in "$id-3-hoan-chinh.mp4", "$id-1-video-goc.mp4", "$id-2-am-thanh-tho.m4a") {
        Assert-True ([IO.File]::Exists((Join-Path $w.B.path $f))) "target root $f"; Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path $f))) "source root $f"
    }
    Assert-True (Test-ReeditInputs (Join-Path $w.B.path "$id-3-hoan-chinh.mp4")) 'legacy companions still count as reedit inputs'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.B.path).PSObject.Properties[$id]) 'no entry was invented for a video without history'
}
Test-Case 'a receipt of ANOTHER video in the same folder does not move' {
    $w = New-TestWorld @('B')
    $a = NextId; $b = NextId
    [void](New-TestVideo $w.A.path $a); $reqB = New-TestVideo $w.A.path $b
    [void](Invoke-KhoMove -Items @((Item $w.A.path $a)) -TargetId $w.B.id -Reason manual)
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path ".cache\tiktok-posts\$reqB.json"))) 'B receipt still in A'
    Assert-True (-not [IO.File]::Exists((Join-Path $w.B.path ".cache\tiktok-posts\$reqB.json"))) 'and not in B'
}
Test-Case 'a batch: a conflicting video fails alone, the others move; the conflict leaves source and the existing target file byte-identical, no journal' {
    $w = New-TestWorld @('B')
    $i1 = NextId; $i2 = NextId; $i3 = NextId
    foreach ($i in $i1, $i2, $i3) { [void](New-TestVideo $w.A.path $i -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$i))) }
    [IO.File]::WriteAllText((Join-Path $w.B.path "$i2-3-hoan-chinh.mp4"), 'DIFFERENT existing content')
    $srcHash = Sha (Join-Path $w.A.path "$i2-3-hoan-chinh.mp4"); $dstHash = Sha (Join-Path $w.B.path "$i2-3-hoan-chinh.mp4")
    $r = Invoke-KhoMove -Items @((Item $w.A.path $i1), (Item $w.A.path $i2), (Item $w.A.path $i3)) -TargetId $w.B.id -Reason manual
    Assert-Equal (@($r.Moved) -join ',') "$i1,$i3"; Assert-Equal @($r.Failed).Count 1; Assert-Equal $r.Failed[0].Id $i2
    Assert-True ($r.Failed[0].Why -like '*không ghi đè*') "why: $($r.Failed[0].Why)"
    Assert-Equal (Sha (Join-Path $w.A.path "$i2-3-hoan-chinh.mp4")) $srcHash 'source untouched'
    Assert-Equal (Sha (Join-Path $w.B.path "$i2-3-hoan-chinh.mp4")) $dstHash 'existing target file never overwritten'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path ".cache\$i2-1-video-goc.mp4"))) 'companions of the refused video stay'
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$i2]) 'its entry stays'
    Assert-Equal @(Get-TestJournalFiles).Count 0 'preflight refusal writes no journal'
}
Test-Case 'a mandatory companion already in the target (.cache -1) is also a refusal before anything moves' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    [void][IO.Directory]::CreateDirectory((Join-Path $w.B.path '.cache'))
    [IO.File]::WriteAllText((Join-Path $w.B.path ".cache\$id-1-video-goc.mp4"), 'old')
    $before = Get-TestTree $w.A.path
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 0; Assert-Equal @($r.Failed).Count 1
    Assert-Equal (Get-TestTree $w.A.path) $before 'source tree identical'
}
Test-Case 'optional files (thumbs) that already exist in the target do not block and are not overwritten' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $t = Join-Path $w.B.path '.cache\thumbs'; [void][IO.Directory]::CreateDirectory($t)
    [IO.File]::WriteAllText((Join-Path $t "$id.jpg"), 'target thumb')
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 1 (($r.Failed | ForEach-Object { $_.Why }) -join '; ')
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $t "$id.jpg"))) 'target thumb' 'target thumb kept'
    Assert-True ([IO.File]::Exists((Join-Path $w.B.path "$id-3-hoan-chinh.mp4"))) 'video moved'
}
Test-Case 'a locked thumbnail never blocks the move (regenerable); a locked -3 refuses before anything moves' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $fs = [IO.File]::Open((Join-Path $w.A.path ".cache\thumbs\$id.jpg"), 'Open', 'Read', 'None')
    try { $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual } finally { $fs.Dispose() }
    Assert-Equal @($r.Moved).Count 1 (($r.Failed | ForEach-Object { $_.Why }) -join '; ')
    Assert-True ([IO.File]::Exists((Join-Path $w.B.path "$id-3-hoan-chinh.mp4"))) 'video moved'
    Assert-Equal @(Get-TestJournalFiles).Count 0 'journal finished'
    $id2 = NextId; [void](New-TestVideo $w.A.path $id2)
    $before = Get-TestTree $w.A.path
    $fs = [IO.File]::Open((Join-Path $w.A.path "$id2-3-hoan-chinh.mp4"), 'Open', 'Read', 'ReadWrite')
    try { $r = Invoke-KhoMove -Items @((Item $w.A.path $id2)) -TargetId $w.B.id -Reason manual } finally { $fs.Dispose() }
    Assert-Equal @($r.Moved).Count 0; Assert-True ($r.Failed[0].Why -like '*đang được mở*') "why: $($r.Failed[0].Why)"
    Assert-Equal (Get-TestTree $w.A.path) $before 'nothing moved'; Assert-Equal @(Get-TestJournalFiles).Count 0 'no journal'
}
Test-Case 'refusals: same kho, non-numeric id, missing -3, unknown target, empty selection' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.A.id -Reason manual
    Assert-Equal @($r.Moved).Count 0 'already in that kho: filtered out, nothing to do'; Assert-Equal @($r.Failed).Count 0
    $r = Move-KhoVideos -Videos @(@{ Id = 'abc'; From = $w.A.path }) -ToRoot $w.B.path
    Assert-True ($r.Failed[0].Why -like '*ID video không hợp lệ*') $r.Failed[0].Why
    $r = Move-KhoVideos -Videos @(@{ Id = '999'; From = $w.A.path }) -ToRoot $w.B.path
    Assert-True ($r.Failed[0].Why -like '*Không thấy file video hoàn chỉnh*') $r.Failed[0].Why
    $r = Move-KhoVideos -Videos @(@{ Id = $id; From = $w.A.path }) -ToRoot $w.A.path
    Assert-True ($r.Failed[0].Why -like '*đã ở kho này*') $r.Failed[0].Why
    Assert-Throws { [void](Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId 'k-ffffffffffffffffffffffffffffffff') } '*Không tìm thấy kho đích*'
    $r = Invoke-KhoMove -Items @() -TargetId $w.B.id; Assert-Equal @($r.Moved).Count 0
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) 'nothing moved by any refusal'
}
Test-Case 'moving the same id twice: the second attempt is refused (nothing left to move) and corrupts nothing' {
    $w = New-TestWorld @('B', 'C')
    $id = NextId; $req = New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id))
    $r1 = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    $r2 = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual   # stale card still points at A
    Assert-Equal @($r1.Moved).Count 1
    Assert-Equal @($r2.Moved).Count 0 'second attempt moved nothing'
    Assert-Moved $w.A.path $w.B.path $id $req
    $r3 = Invoke-KhoMove -Items @((Item $w.B.path $id)) -TargetId $w.C.id -Reason manual   # B -> C works afterwards
    Assert-Equal @($r3.Moved).Count 1; Assert-Moved $w.B.path $w.C.path $id $req
}
Test-Case 'target already has an entry for the id (e.g. a delete that kept metadata): history united by key, target wins on the same key, manual mark kept if either side has it' {
    $w = New-TestWorld @('B')
    $id = NextId; $req = '{0:x32}' -f [long]$id
    $src = New-TestPostedEntry $req 'anna' '2026-10-25T10:00:00Z'
    [void](New-TestVideo $w.A.path $id -Entry $src)
    # target: same request key (stale copy) with another username, plus its own second request, and a manual mark
    $dupe = New-TestHistoryEntry -Request $req -User 'TARGET-WINS' -Accepted '2026-10-25T10:00:00Z'
    $second = New-TestHistoryEntry -Request ('{0:x32}' -f ([long]$id + 99)) -User 'bob' -Accepted '2026-10-24T10:00:00Z' -Created '2026-10-24T09:00:00Z'
    Write-TestMetadata $w.B.path @{ $id = [ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = @($dupe, $second); ManualPosted = $true; ManualDate = '01/10 09:00'; Extra = 'keep me' } }
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 1 (($r.Failed | ForEach-Object { $_.Why }) -join '; ')
    $e = (Get-ReupMetadata -OutDir $w.B.path).$id
    Assert-Equal @($e.History).Count 2 'union by key'
    Assert-Equal (@($e.History | Where-Object { $_.key -eq "request:$req" })[0].username) 'TARGET-WINS' 'target wins the same key'
    Assert-Equal $e.ManualPosted $true; Assert-Equal $e.ManualDate '01/10 09:00'; Assert-Equal $e.Extra 'keep me' 'target-only field kept'
    Assert-Equal $e.FileSha256 ('sha-' + $req) 'source-only field kept'
}
Test-Case 'Merge-KhoMoveEntry is idempotent (the second call changes nothing) and a manual-only source mark survives onto a plain target entry' {
    $meta = ConvertFrom-Json '{"1":{"Posted":false,"Date":""}}'
    $snap = ConvertFrom-Json '{"Posted":true,"Date":"20/10 10:00"}'
    Assert-True (Merge-KhoMoveEntry $meta '1' $snap) 'first merge changes the entry'
    Assert-Equal $meta.'1'.Posted $true; Assert-Equal $meta.'1'.Date '20/10 10:00'
    Assert-True (-not (Merge-KhoMoveEntry $meta '1' $snap)) 'second merge is a no-op'
    $none = ConvertFrom-Json '{}'
    Assert-True (Merge-KhoMoveEntry $none '5' $snap) 'no target entry -> a copy'
    Assert-Equal $none.'5'.Date '20/10 10:00'
    Assert-True (-not (Merge-KhoMoveEntry $none '6' $null)) 'no snapshot -> nothing'
}

# ---------------- S2: jobs block a move ----------------
Test-Case 'S2: a retained .job of the video blocks the move with a clear reason; nothing moves, no journal' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    Write-Job $w.A.path ('{0:x32}' -f 4242) $id
    $before = Get-TestTree $w.A.path
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 0
    Assert-True ($r.Failed[0].Why -like '*lệnh đăng chưa xong*') "why: $($r.Failed[0].Why)"
    Assert-Equal (Get-TestTree $w.A.path) $before; Assert-Equal @(Get-TestJournalFiles).Count 0
}
Test-Case 'S2: a .lock (live worker) blocks too; an archived job (.job.archived-*) and a job of ANOTHER video do not' {
    $w = New-TestWorld @('B')
    $id = NextId; $other = NextId
    [void](New-TestVideo $w.A.path $id)
    $req = '{0:x32}' -f 777
    Write-Job $w.A.path $req $id -Lock
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 0 'lock blocks'
    Remove-Item -LiteralPath (Join-Path (Posts $w.A.path) "$req.lock"), (Join-Path (Posts $w.A.path) "$req.job")
    [IO.File]::WriteAllText((Join-Path (Posts $w.A.path) "$req.job.archived-20261021-101010"), (ConvertTo-Json @{ Record = @{ VideoId = $id } }))
    Write-Job $w.A.path ('{0:x32}' -f 888) $other
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 1 "archived job and other video's job must not block: $(($r.Failed | ForEach-Object { $_.Why }) -join '; ')"
    Assert-True ([IO.File]::Exists((Join-Path (Posts $w.B.path) "$req.job.archived-20261021-101010"))) 'the archived job travels with the video'
}
Test-Case 'S2: a job whose video cannot be read blocks every move out of that folder (unknown owner)' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    Write-Job $w.A.path ('{0:x32}' -f 999) '' -Raw '{this is not json'
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 0; Assert-True ($r.Failed[0].Why -like '*không rõ thuộc video nào*') "why: $($r.Failed[0].Why)"
}

# ---------------- S1: quiet state ----------------
Test-Case 'S1: every busy flag (download, stopping, queue, import, dialog, move, installer) makes the mover refuse with a reason and move nothing' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $cases = [ordered]@{
        'running download'  = { $script:ps = 'x' }
        'stopping'          = { $script:stopping = $true }
        'queued links'      = { $script:queue = @(1) }
        'import'            = { $script:importBusy = $true }
        'dialog/cleanup'    = { $script:khoExclusive = 1 }
        'move running'      = { $script:khoMoveRunning = $true }
        'backend installer' = { $script:autotokInstall = $true }
    }
    $before = Get-TestTree $w.A.path
    foreach ($name in $cases.Keys) {
        & { $script:ps = $null; $script:stopping = $false; $script:queue = @(); $script:importBusy = $false; $script:khoExclusive = 0; $script:khoMoveRunning = $false; $script:autotokInstall = $false }
        & $cases[$name]
        $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
        Assert-True ([bool]$r.Busy) "$name -> Busy reason"
        Assert-Equal @($r.Moved).Count 0 "$name moved nothing"
        Assert-Equal (Get-TestTree $w.A.path) $before "$name left the source untouched"
    }
    & { $script:ps = $null; $script:stopping = $false; $script:queue = @(); $script:importBusy = $false; $script:khoExclusive = 0; $script:khoMoveRunning = $false; $script:autotokInstall = $false }
    Assert-Equal @((Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual).Moved).Count 1 'quiet again -> moves'
}
Test-Case 'S1: while a move batch runs every other actor refuses (move, delete kho, folder import); the flag is cleared afterwards' {
    $w = New-TestWorld @('B', 'C')
    $id = NextId; $other = NextId
    [void](New-TestVideo $w.A.path $id); [void](New-TestVideo $w.A.path $other)
    $script:probe = $null
    $origLog = (Get-Item function:Add-KhoMoveLog).ScriptBlock
    function Add-KhoMoveLog {
        param([string]$Text)
        if (-not $script:probe) {
            $script:probe = @{
                Move   = (Invoke-KhoMove -Items @((Item $w.A.path $other)) -TargetId $w.C.id -Reason manual)
                Delete = (Remove-KhoWithVideos -Id $w.C.id)
                Import = (Test-KhoImportBlocked)
                Flag   = $script:khoMoveRunning
            }
        }
    }
    try { $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual }
    finally { Set-Item function:Add-KhoMoveLog $origLog }
    Assert-Equal @($r.Moved).Count 1 'outer move completed'
    Assert-True $script:probe.Flag 'flag set during the batch'
    Assert-Equal $script:probe.Move.Busy 'đang chuyển kho'; Assert-Equal @($script:probe.Move.Moved).Count 0
    Assert-True ($script:probe.Delete.Why -like 'Đang bận (đang chuyển kho)*') "delete why: $($script:probe.Delete.Why)"
    Assert-True ($script:probe.Import -like '*Đang chuyển kho*') "import: $($script:probe.Import)"
    Assert-True (-not $script:khoMoveRunning) 'flag cleared after the batch'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$other-3-hoan-chinh.mp4"))) 'the refused video did not move'
    Assert-True ($null -ne (Get-KhoById $w.C.id)) 'kho C was not deleted by the refused call'
}
Test-Case 'S1: the TikTok sync is suspended; a pass that is still running is WAITED for (never cancelled), then the move runs and the sync resumes' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $script:ticks = 0
    $script:tikTokSync = @{ Paused = $false; Task = 'in flight'; Fast = $null }
    function Invoke-TikTokSyncTick { $script:ticks++; if ($script:ticks -ge 3) { $script:tikTokSync.Task = $null } }
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 1 'moved after the pass finished'
    Assert-True ($script:ticks -ge 3) "waited for the in-flight pass (ticks=$($script:ticks))"
    Assert-Equal $script:tikTokSync.Paused $false 'sync resumed'
}
Test-Case 'S1: a sync pass that never finishes within the wait makes the move refuse (Busy), nothing moved, sync resumed, flag cleared' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $script:tikTokSync = @{ Paused = $false; Task = 'stuck'; Fast = $null }
    function Invoke-TikTokSyncTick { }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
    Assert-Equal $r.Busy 'đang đồng bộ TikTok'; Assert-Equal @($r.Moved).Count 0
    Assert-True ($sw.ElapsedMilliseconds -ge 7000 -and $sw.ElapsedMilliseconds -lt 20000) "waited about 8 s, not forever ($($sw.ElapsedMilliseconds) ms)"
    Assert-Equal $script:tikTokSync.Paused $false; Assert-True (-not $script:khoMoveRunning) 'flag cleared'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) 'video still in A'
    $script:tikTokSync = $null
}

# ---------------- KhoPinned + auto-move ----------------
Test-Case 'S5: a MANUAL move of a confirmed video pins it (KhoPinned travels with the entry); an unconfirmed one and an AUTO move are not pinned' {
    $w = New-TestWorld @('B', 'C')
    $pinned = NextId; $plain = NextId; $auto = NextId
    [void](New-TestVideo $w.A.path $pinned -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$pinned)))
    [void](New-TestVideo $w.A.path $plain -Entry ([ordered]@{ Posted = $false; Date = '' }))
    [void](New-TestVideo $w.A.path $auto -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$auto)))
    [void](Invoke-KhoMove -Items @((Item $w.A.path $pinned), (Item $w.A.path $plain)) -TargetId $w.B.id -Reason manual)
    [void](Invoke-KhoMove -Items @((Item $w.A.path $auto)) -TargetId $w.C.id -Reason auto)
    $mb = Get-ReupMetadata -OutDir $w.B.path; $mc = Get-ReupMetadata -OutDir $w.C.path
    Assert-Equal $mb.$pinned.KhoPinned $true 'confirmed + manual = pinned'
    Assert-True ($null -eq $mb.$plain.PSObject.Properties['KhoPinned']) 'unconfirmed manual move is not pinned'
    Assert-True ($null -eq $mc.$auto.PSObject.Properties['KhoPinned']) 'auto move is not pinned'
}

function Set-AutoSince { param([string]$When) Invoke-KhoRegistryChange { param($r) $r.autoMoveSince = $When } }
function MetaOf { return (Get-GalleryMetaByRoot) }
Test-Case 'auto-move candidates: only unaccounted-kho videos with a confirmed post after autoMoveSince, not pinned, -3 present; earliest confirmed account wins; account khos never move' {
    $w = New-TestWorld @('B')
    Set-KhoAccount -Id $w.B.id -Account 'anna'
    Set-AutoSince '2026-10-01T00:00:00Z'
    function Hist2 { param($req, $user, $when, $status = 'succeeded', $unc = $false) return (New-TestHistoryEntry -Request $req -User $user -Status $status -Accepted $when -Created $when -Uncertain $unc) }
    function Ent { param($history, $extra = @{}) $e = [ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = @($history); ManualPosted = $false; ManualDate = '' }; foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }; return $e }
    $v = @{}; foreach ($n in 1..12) { $v[$n] = NextId }
    [void](New-TestVideo $w.A.path $v[1] -NoReceipt -Entry (Ent @((Hist2 'r1' 'anna' '2026-10-20T10:00:00Z'))))
    [void](New-TestVideo $w.A.path $v[2] -NoReceipt -Entry (Ent @((Hist2 'r2' 'anna' '2026-10-20T10:00:00Z')) @{ KhoPinned = $true }))
    [void](New-TestVideo $w.A.path $v[3] -NoReceipt -Entry (Ent @((Hist2 'r3' 'anna' '2026-09-01T10:00:00Z'))))                    # before the cut-off
    [void](New-TestVideo $w.A.path $v[4] -NoReceipt -Entry (Ent @((Hist2 'r4' 'anna' '' 'pending'))))                              # not confirmed
    [void](New-TestVideo $w.A.path $v[5] -NoReceipt -Entry (Ent @((Hist2 'r5' 'anna' '2026-10-20T10:00:00Z' 'succeeded' $true)))) # uncertain
    [void](New-TestVideo $w.A.path $v[6] -NoReceipt -Entry (Ent @((Hist2 'r6a' 'anna' '2026-10-22T10:00:00Z'), (Hist2 'r6b' 'bob' '2026-10-20T10:00:00Z'))))   # bob first
    [void](New-TestVideo $w.A.path $v[7] -NoReceipt -Entry (Ent @((Hist2 'r7' 'anna' '2026-10-20T10:00:00Z')))); Remove-Item -LiteralPath (Join-Path $w.A.path "$($v[7])-3-hoan-chinh.mp4")   # file gone
    [void](New-TestVideo $w.A.path $v[8] -NoReceipt -Entry ([ordered]@{ Posted = $true; Date = '19/10 08:00' }))                  # legacy manual mark
    [void](New-TestVideo $w.A.path $v[9] -NoReceipt -Entry (Ent @((Hist2 'r9' '' '2026-10-20T10:00:00Z'))))                        # no username
    [void](New-TestVideo $w.B.path $v[10] -NoReceipt -Entry (Ent @((Hist2 'r10' 'anna' '2026-10-20T10:00:00Z'))))                  # already in an account kho
    [void](New-TestVideo $w.B.path $v[11] -NoReceipt -Entry (Ent @((Hist2 'r11a' 'anna' '2026-10-20T10:00:00Z'), (Hist2 'r11b' 'bob' '2026-10-25T10:00:00Z'))))   # repost stays
    $c = @(Get-KhoAutoMoveCandidates (Get-KhoRegistry) (MetaOf))
    Assert-Equal (@($c | ForEach-Object { $_.Id }) | Sort-Object) (@($v[1], $v[6]) | Sort-Object) 'candidates'
    Assert-Equal (($c | Where-Object Id -eq $v[1]).Username) 'anna'; Assert-Equal (($c | Where-Object Id -eq $v[6]).Username) 'bob' 'earliest confirmed account wins'
    Assert-Equal (($c | Where-Object Id -eq $v[1]).From) $w.A.path
}
Test-Case 'a fresh registry never auto-moves posts confirmed BEFORE it was created (autoMoveSince = now)' {
    $w = New-TestWorld @('B')
    $id = NextId
    $h = New-TestHistoryEntry -Request 'old' -User 'anna' -Accepted '2020-01-01T10:00:00Z' -Created '2020-01-01T09:00:00Z'
    [void](New-TestVideo $w.A.path $id -NoReceipt -Entry ([ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = @($h); ManualPosted = $false; ManualDate = '' }))
    Assert-Equal @(Get-KhoAutoMoveCandidates (Get-KhoRegistry) (MetaOf)).Count 0
}
Test-Case 'auto-move end to end: account kho exists -> moved there unpinned; account WITHOUT kho -> "Kho @user" auto-created next to the download kho on the same volume, registered, video moved' {
    $w = New-TestWorld @('B')
    Set-KhoAccount -Id $w.B.id -Account 'anna'
    Set-AutoSince '2026-10-01T00:00:00Z'
    $va = NextId; $vb = NextId
    $ra = New-TestVideo $w.A.path $va -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$va) 'anna')
    $rb = New-TestVideo $w.A.path $vb -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$vb) 'bob')
    $n = Invoke-KhoAutoMove (MetaOf)
    Assert-Equal $n 2 'two videos moved'
    Assert-Moved $w.A.path $w.B.path $va $ra
    $bob = Get-KhoForAccount 'bob'
    Assert-True ($null -ne $bob) 'kho for @bob registered'
    Assert-Equal $bob.path (Join-Path $script:root 'Kho @bob'); Assert-Equal $bob.createdByApp $true
    Assert-Equal ([IO.Path]::GetPathRoot($bob.path)) ([IO.Path]::GetPathRoot($w.A.path)) 'same volume'
    Assert-Moved $w.A.path $bob.path $vb $rb
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.B.path).$va.PSObject.Properties['KhoPinned']) 'auto = not pinned'
    $script:khoRegistry = $null; Assert-True ($null -ne (Get-KhoForAccount 'bob')) 'the new kho was saved to kho.json'
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 0 'second run: nothing left'
}
Test-Case 'auto-move: failing to create the account kho (a FILE holds the folder name) is logged, not retried for 10 minutes, and does not stop other accounts' {
    $w = New-TestWorld @('B')
    Set-KhoAccount -Id $w.B.id -Account 'anna'
    Set-AutoSince '2026-10-01T00:00:00Z'
    $vc = NextId; $va = NextId
    [void](New-TestVideo $w.A.path $vc -NoReceipt -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$vc) 'cara'))
    [void](New-TestVideo $w.A.path $va -NoReceipt -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$va) 'anna'))
    [IO.File]::WriteAllText((Join-Path $script:root 'Kho @cara'), 'i am a file')
    $n = Invoke-KhoAutoMove (MetaOf)
    Assert-Equal $n 1 'anna still moved'
    Assert-True ($null -eq (Get-KhoForAccount 'cara')) 'no kho for cara'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$vc-3-hoan-chinh.mp4"))) 'cara video stays'
    Assert-True ($script:khoAutoMoveFailed.ContainsKey('cara')) 'failure remembered'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*Không tự tạo được kho cho @cara*' }).Count -eq 1) 'logged once'
    Remove-Item -LiteralPath (Join-Path $script:root 'Kho @cara') -Force
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 0 'within 10 minutes: not retried'
    $script:khoAutoMoveFailed['cara'] = [DateTime]::UtcNow.AddMinutes(-11)
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 1 'after 10 minutes: retried and works'
}
Test-Case 'auto-move waits for a quiet app (flag stays wanted, nothing moved) and does nothing when kho.json is unreadable' {
    $w = New-TestWorld @('B')
    Set-KhoAccount -Id $w.B.id -Account 'anna'
    Set-AutoSince '2026-10-01T00:00:00Z'
    $id = NextId; [void](New-TestVideo $w.A.path $id -NoReceipt -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id) 'anna'))
    $script:queue = @(1); $script:khoAutoMoveWanted = $false
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 0; Assert-True $script:khoAutoMoveWanted 'deferred to the next quiet sync completion'
    $script:queue = @()
    $script:khoRegistryReady = $false
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 0 'read-only registry: no auto-move'
    $script:khoRegistryReady = $true
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) 'still in A'
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 1 'quiet again -> moved'
}
Test-Case 'S5 end to end: a video the owner moved by hand to a kho (pinned) is not pulled into the account kho by a later auto-move' {
    $w = New-TestWorld @('B', 'C')
    Set-KhoAccount -Id $w.B.id -Account 'anna'
    Set-AutoSince '2026-10-01T00:00:00Z'
    $id = NextId; $req = New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id) 'anna')
    [void](Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.C.id -Reason manual)     # owner puts it in C (no account)
    Assert-Equal (Invoke-KhoAutoMove (MetaOf)) 0 'pinned: stays in C'
    Assert-True ([IO.File]::Exists((Join-Path $w.C.path "$id-3-hoan-chinh.mp4"))) 'still in C'
}

Complete-Tests
