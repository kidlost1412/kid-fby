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
# ---------------------------------------------------------------- 2
Test-Case '2: delete kho - final video recycled but a locked companion fails; after unlock the retry (final -3 already gone) deletes the companion and only then unregisters' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.B.path $id -NoReceipt)
    $audio = Join-Path $w.B.path ".cache\$id-2-am-thanh-tho.m4a"
    $script:locked = $true
    $script:khoRecycleOverride = { param($Path, $IsFolder) if ($script:locked -and $Path -like '*-2-am-thanh-tho.m4a') { throw 'file đang mở' }; if ($IsFolder) { [IO.Directory]::Delete($Path, $true) } else { [IO.File]::Delete($Path) } }
    try {
        $r1 = Remove-KhoWithVideos -Id $w.B.id
        Assert-Equal $r1.Success $false 'first attempt fails'
        Assert-True (-not [IO.File]::Exists((Join-Path $w.B.path "$id-3-hoan-chinh.mp4"))) 'final video already recycled'
        Assert-True ([IO.File]::Exists($audio)) 'companion still there'
        Assert-True ($null -ne (Get-KhoById $w.B.id)) 'kho kept'
        $script:locked = $false
        $r2 = Remove-KhoWithVideos -Id $w.B.id
        Assert-Equal $r2.Success $true "retry: $($r2.Why)"
        Assert-True (-not [IO.File]::Exists($audio)) 'companion deleted by the retry'
        Assert-True ($null -eq (Get-KhoById $w.B.id)) 'kho unregistered only now'
        Assert-Equal @(Get-KhoPendingDeleteIds $w.B.path).Count 0 'pending list cleared'
    } finally { $script:khoRecycleOverride = $null }
}
Test-Case '2: an unreadable pending-deletes file refuses the delete (nothing recycled, kho kept)' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.B.path $id -NoReceipt)
    [IO.File]::WriteAllText((Get-KhoPendingDeletesPath), '{ not json', [Text.UTF8Encoding]::new($false))
    $script:khoRecycleOverride = { param($Path, $IsFolder) throw 'must not be called' }
    try {
        $r = Remove-KhoWithVideos -Id $w.B.id
        Assert-Equal $r.Success $false; Assert-True ($r.Why -like '*kho-pending-deletes*') $r.Why
        Assert-True ([IO.File]::Exists((Join-Path $w.B.path "$id-3-hoan-chinh.mp4"))) 'video untouched'
    } finally { $script:khoRecycleOverride = $null }
}
# ---------------------------------------------------------------- 3
function New-ConfirmDialog {
    # Test double of the WPF dialog: records what the app state is WHILE the dialog is displayed.
    $d = [pscustomobject]@{ Owner = $null }
    Add-Member -InputObject $d -MemberType ScriptMethod -Name ShowDialog -Value { $script:seenExclusive = $script:khoExclusive; $script:seenQuiet = Test-KhoQuiet; return $true }
    return $d
}
Test-Case '3: video-delete, cleanup and kho-delete confirmations hold khoExclusive while shown (the mover is not quiet) and release it afterwards' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.B.path $id)
    $path = Join-Path $w.B.path "$id-3-hoan-chinh.mp4"
    $script:seenExclusive = -1; $script:seenQuiet = ''
    Assert-Equal (Confirm-GalleryDelete $path) $true
    Assert-Equal $script:seenExclusive 1 'exclusive while the delete dialog is shown'
    Assert-True ($script:seenQuiet -like '*hộp thoại*') "quiet check says: '$($script:seenQuiet)'"
    Assert-Equal $script:khoExclusive 0 'released'
    $script:seenExclusive = -1
    Assert-Equal (Show-ConfirmDialog -Title 'Dọn ổ?' -Message 'x' -Danger -Exclusive) $true
    Assert-Equal $script:seenExclusive 1 'cleanup confirm exclusive'; Assert-Equal $script:khoExclusive 0
    $script:seenExclusive = -1; $script:seenQuiet = ''
    Assert-Equal (Confirm-KhoDelete -Owner $null -Name 'B' -Count 1) $true
    Assert-Equal $script:seenExclusive 1 'kho delete exclusive'; Assert-Equal $script:khoExclusive 0
    # and an auto-move attempted while a dialog is open is refused as busy
    $script:khoExclusive = 1
    $r = Invoke-KhoMove -Items @((Item $w.B.path $id)) -TargetId $w.A.id -Reason auto
    $script:khoExclusive = 0
    Assert-True ($r.Busy -like '*hộp thoại*') "busy: '$($r.Busy)'"; Assert-True ([IO.File]::Exists($path)) 'video did not move'
}
# ---------------------------------------------------------------- 4
Test-Case '4: an unreadable kho history is reported (completeness info + visible message); a complete read has no gap' {
    $w = New-TestWorld @('B')
    $a = NextId; [void](New-TestVideo $w.A.path $a -Entry (New-TestPostedEntry (& $hex $a)))
    $ok = Get-GalleryMetaChecked
    Assert-Equal $ok.Gap '' 'complete read'
    [IO.File]::WriteAllText((Join-Path $w.B.path 'reup-status.json'), '{ broken', [Text.UTF8Encoding]::new($false))
    $bad = Get-GalleryMetaChecked
    Assert-True ($bad.Map.ContainsKey([string]$w.A.path)) 'readable kho still in the map'
    Assert-True (-not $bad.Map.ContainsKey([string]$w.B.path)) 'unreadable kho is NOT presented as empty'
    Assert-True ($bad.Gap -like "Chưa đọc được lịch sử kho 'B'*thử lại*") "message: '$($bad.Gap)'"
    $u = New-Object 'System.Collections.Generic.List[string]'
    [void](Get-GalleryMetaByRoot -Unreadable $u)
    Assert-Equal $u.Count 1; Assert-Equal $u[0] $w.B.path
}
# ---------------------------------------------------------------- 5
$coverFirst = '{"streams":[{"index":0,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"index":1,"codec_type":"video","codec_name":"h264","disposition":{"attached_pic":0}},{"index":2,"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"1.0"}}'
Test-Case '5: stream choice skips the attached cover (index 1 here), is -1 without a real video, and falls back to array position without an index field' {
    Assert-Equal (Get-TikTokVideoStreamIndex (ConvertFrom-Json $coverFirst)) 1
    Assert-Equal (Get-TikTokVideoStreamIndex (ConvertFrom-Json '{"streams":[{"codec_type":"audio","codec_name":"aac"}]}')) -1
    Assert-Equal (Get-TikTokVideoStreamIndex (ConvertFrom-Json '{"streams":[{"codec_type":"audio"},{"codec_type":"video","codec_name":"h264"}]}')) 1 'position fallback'
}
Test-Case '5: New-TikTokCleanCopy maps the planned stream (0:1) and counts frames/keyframes of that stream - never 0:v:0 / v:0 of the cover' {
    $dir = New-TestDir; $src = Join-Path $dir 'cover-first.mp4'; [IO.File]::WriteAllBytes($src, [byte[]](1..64))
    $posts = Join-Path $dir 'posts'; [void][IO.Directory]::CreateDirectory($posts)
    $script:toolCalls = New-Object System.Collections.Generic.List[object]
    function Find-TikTokTool { param([string]$Name, [string]$AppRoot) return "fake-$Name.exe" }
    function Invoke-TikTokTool {
        param([string]$Exe, [string[]]$Arguments, [int]$TimeoutMs = 600000)
        $script:toolCalls.Add(@{ Exe = $Exe; Args = @($Arguments) })
        if ($Exe -like '*ffprobe*' -and $Arguments -contains '-show_streams') { return @{ Code = 0; Out = $coverFirst; Err = '' } }
        if ($Exe -like '*ffprobe*' -and $Arguments -contains '-count_frames') { return @{ Code = 0; Out = '10'; Err = '' } }
        if ($Exe -like '*ffprobe*') { return @{ Code = 0; Out = "K__`nK__`n___`n"; Err = '' } }
        return @{ Code = 1; Out = ''; Err = 'stop after the first ffmpeg call' }   # ffmpeg: end the attempt here
    }
    Assert-Throws { New-TikTokCleanCopy -SourcePath $src -PostsDir $posts -RequestId ('b' * 32) -Root $dir } '*Làm sạch metadata không đạt*'
    $ff = @($script:toolCalls | Where-Object { $_.Exe -like '*ffmpeg*' })
    Assert-Equal $ff.Count 1 'one ffmpeg call'
    $a = @($ff[0].Args); $i = [Array]::IndexOf($a, '-map')
    Assert-Equal $a[$i + 1] '0:1' 'video map = the real video stream'
    Assert-True ($a -notcontains '0:v:0') 'no hard-coded 0:v:0'
    $sel = @($script:toolCalls | Where-Object { $_.Exe -like '*ffprobe*' -and $_.Args -contains '-select_streams' } | ForEach-Object { $_.Args[[Array]::IndexOf($_.Args, '-select_streams') + 1] })
    Assert-True ($sel.Count -ge 2) 'packet + frame counts were requested'
    foreach ($s in $sel) { Assert-Equal $s '1' 'source counts use the planned stream' }
    Remove-Item -LiteralPath $dir -Recurse -Force
}
$ffRoot = 'D:\reup video fb meta'
if ([IO.File]::Exists((Join-Path $ffRoot 'tools\ffmpeg\ffmpeg.exe')) -and [IO.File]::Exists((Join-Path $ffRoot 'tools\ffmpeg\ffprobe.exe'))) {
    # (ffmpeg's mp4 muxer always writes the cover picture LAST, so a cover-FIRST file cannot be produced here; that order is covered by the stub test above.)
Test-Case '5: END TO END with real ffmpeg: a file with an attached cover picture is cleaned from its real video (mapping by planned stream index works with the real tools)' {
        $dir = New-TestDir; $ff = Join-Path $ffRoot 'tools\ffmpeg\ffmpeg.exe'; $fp = Join-Path $ffRoot 'tools\ffmpeg\ffprobe.exe'
        $cover = Join-Path $dir 'cover.jpg'; $main = Join-Path $dir 'main.mp4'; $src = Join-Path $dir 'cover-first.mp4'
        $r = Invoke-TikTokTool $ff @('-hide_banner','-v','error','-y','-f','lavfi','-i','color=c=red:s=64x64','-frames:v','1',$cover) 60000; Assert-Equal $r.Code 0 $r.Err
        $r = Invoke-TikTokTool $ff @('-hide_banner','-v','error','-y','-f','lavfi','-i','testsrc=size=160x120:rate=10:duration=2','-f','lavfi','-i','sine=duration=2','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-t','2',$main) 60000; Assert-Equal $r.Code 0 $r.Err
        $r = Invoke-TikTokTool $ff @('-hide_banner','-v','error','-y','-i',$cover,'-i',$main,'-map','0:v','-map','1:v','-map','1:a','-c','copy','-disposition:v:0','attached_pic',$src) 60000; Assert-Equal $r.Code 0 $r.Err
        $info = Get-TikTokMediaInfo $fp $src
        Assert-Equal @($info.streams | Where-Object { [string]$_.disposition.attached_pic -eq '1' }).Count 1 'fixture: has a cover stream'
        $posts = Join-Path $dir 'posts'; [void][IO.Directory]::CreateDirectory($posts)
        $clean = New-TikTokCleanCopy -SourcePath $src -PostsDir $posts -RequestId ('c' * 32) -Root $ffRoot
        $out = Get-TikTokMediaInfo $fp $clean
        $videos = @($out.streams | Where-Object { $_.codec_type -eq 'video' })
        Assert-Equal $videos.Count 1 'one video stream in the clean copy'
        Assert-Equal $videos[0].codec_name 'h264'; Assert-Equal $videos[0].width 160 'the real 160x120 video, not the 64x64 cover'
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
} else { Skip-Case '5: END TO END with real ffmpeg' 'tools\ffmpeg not available' }
# ---------------------------------------------------------------- 6
Test-Case '6: a retiring (not yet stopped) dialog preparation task keeps the mover out; a finished one does not' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $path = Join-Path $w.A.path "$id-3-hoan-chinh.mp4"
    $script:tikTokReaper = @{ Tasks = New-Object System.Collections.ArrayList; Timer = $null }
    $running = @{ Async = [pscustomobject]@{ IsCompleted = $false }; StopAsync = $null }
    [void]$script:tikTokReaper.Tasks.Add($running)
    try {
        $r = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
        Assert-True ($r.Busy -like '*dừng tác vụ chuẩn bị*') "busy: '$($r.Busy)'"
        Assert-True ([IO.File]::Exists($path)) 'nothing moved while the worker is stopping'
        $running.Async = [pscustomobject]@{ IsCompleted = $true }; $running.StopAsync = [pscustomobject]@{ IsCompleted = $false }
        Assert-True ((Test-KhoQuiet) -like '*dừng tác vụ chuẩn bị*') 'stop request still pending'
        $running.StopAsync = [pscustomobject]@{ IsCompleted = $true }
        Assert-Equal (Test-KhoQuiet) '' 'quiet once invocation and stop have finished'
        $r2 = Invoke-KhoMove -Items @((Item $w.A.path $id)) -TargetId $w.B.id -Reason manual
        Assert-Equal @($r2.Moved).Count 1 (($r2.Failed | ForEach-Object { $_.Why }) -join ';')
    } finally { $script:tikTokReaper = $null }
}
# ---- END ----
$server.Stop()
Complete-Tests
