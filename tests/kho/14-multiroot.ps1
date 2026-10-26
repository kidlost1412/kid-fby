# Everything that reads several kho folders at once: duplicate check across khos, account-wide busy times (spread planning), per-root metadata
# reads, S6 (no entry creation for missing files), and cache cleanup that never touches files a move journal refers to.
. (Join-Path $PSScriptRoot '_load.ps1')
. (Join-Path $script:RepoRoot 'core\facebook-links.ps1')
function Local { param([string]$s) return [DateTime]::SpecifyKind([DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), 'Local') }
function Utc { param([DateTime]$d) return $d.ToUniversalTime().ToString('o') }
function Reel { param([string]$Id) return "https://www.facebook.com/reel/$Id" }

# ---------------- duplicate check across khos ----------------
Test-Case 'duplicate check: a video in ANY kho counts as downloaded; zero-byte and -1-only (cache) files do not; the same id in two khos counts once' {
    $w = New-TestWorld @('B')
    $a = '1000000000701'; $b = '1000000000702'; $z = '1000000000703'; $c = '1000000000704'; $n = '1000000000705'; $both = '1000000000706'
    [void](New-TestVideo $w.A.path $a); [void](New-TestVideo $w.B.path $b); [void](New-TestVideo $w.A.path $both); [void](New-TestVideo $w.B.path $both)
    [IO.File]::WriteAllBytes((Join-Path $w.B.path "$z-3-hoan-chinh.mp4"), (New-Object byte[] 0))
    [void][IO.Directory]::CreateDirectory((Join-Path $w.A.path '.cache')); [IO.File]::WriteAllText((Join-Path $w.A.path ".cache\$c-1-video-goc.mp4"), 'x')
    $text = (@($a, $b, $z, $c, $n, $both) | ForEach-Object { Reel $_ }) -join "`r`n"
    $rep = Get-FacebookLinkDuplicateReport -Text $text -OutDir @($w.A.path, $w.B.path)
    Assert-Equal (@($rep.DownloadedIds) | Sort-Object) (@($a, $b, $both) | Sort-Object) 'downloaded in any kho'
    $onlyA = Get-FacebookLinkDuplicateReport -Text $text -OutDir @($w.A.path)
    Assert-True (@($onlyA.DownloadedIds) -notcontains $b) 'looking at A alone would miss the video of B (the bug the multi-kho check prevents)'
}
Test-Case 'Get-LinkSummary over every kho folder: "SkipExisting" removes links already in another kho from the runnable list' {
    $w = New-TestWorld @('B')
    $a = '1000000000711'; $b = '1000000000712'; $fresh = '1000000000713'
    [void](New-TestVideo $w.A.path $a); [void](New-TestVideo $w.B.path $b)
    $text = (@($a, $b, $fresh) | ForEach-Object { Reel $_ }) -join "`r`n"
    $s = Get-LinkSummary -Text $text -OutDir @(Get-KhoRoots) -SkipExisting $true
    Assert-Equal @($s.Downloaded).Count 2; Assert-Equal @($s.Runnable).Count 1
    Assert-True (@($s.Runnable)[0] -like "*$fresh*") 'only the new link runs'
    $again = Get-LinkSummary -Text $text -OutDir @(Get-KhoRoots) -SkipExisting $false
    Assert-Equal @($again.Runnable).Count 3 're-download chosen: all run'
}

# ---------------- per-root metadata ----------------
Test-Case 'Get-GalleryMetaByRoot: one entry per readable kho; an unreadable reup-status.json (corrupt) leaves only THAT kho out, is logged, and is not touched' {
    $w = New-TestWorld @('B', 'C')
    [void](New-TestVideo $w.A.path '1000000000721' -Entry (New-TestPostedEntry 'r1'))
    Write-TestMetadata $w.B.path @{ '1000000000722' = [ordered]@{ Posted = $false; Date = '' } }
    [IO.File]::WriteAllText((Join-Path $w.C.path 'reup-status.json'), '{ broken')
    $script:TestLog.Clear()
    $m = Get-GalleryMetaByRoot
    Assert-True ($m.ContainsKey($w.A.path) -and $m.ContainsKey($w.B.path)) 'readable khos present'
    Assert-True (-not $m.ContainsKey($w.C.path)) 'corrupt kho left out (never treated as empty history)'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $w.C.path 'reup-status.json'))) '{ broken' 'file untouched'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*Không đọc được lịch sử của kho*' }).Count -eq 1) 'logged'
}
Test-Case 'Get-GalleryMetaByRoot skips a kho folder that does not exist (no error, no folder created)' {
    $w = New-TestWorld @('B')
    [IO.Directory]::Delete($w.B.path)
    $m = Get-GalleryMetaByRoot
    Assert-True (-not $m.ContainsKey($w.B.path)); Assert-True (-not [IO.Directory]::Exists($w.B.path)) 'not recreated'
}

# ---------------- account-wide busy times ----------------
Test-Case 'busy times: the account''s scheduled posts on ALL kho folders count; the same request in two folders (mid-move) counts once; other accounts and old posts do not' {
    $w = New-TestWorld @('B')
    $now = Local '2026-10-26 10:00'
    function Ent { param([string]$Req, [string]$User, [string]$When, [string]$Status = 'succeeded') $e = New-TestHistoryEntry -Request $Req -User $User -Status $Status; $e.tiktok_schedule_time = $When; return $e }
    $e1 = Ent 'req1' 'Anna' (Utc (Local '2026-10-27 12:00')); $e2 = Ent 'req2' 'anna' (Utc (Local '2026-10-27 19:00')) 'pending'
    $e3 = Ent 'req3' 'bob' (Utc (Local '2026-10-28 08:00')); $old = Ent 'req4' 'anna' (Utc (Local '2026-10-20 08:00'))
    Write-TestMetadata $w.A.path @{ '1' = [ordered]@{ Posted = $false; Date = ''; History = @($e1, $e3) }; '2' = [ordered]@{ Posted = $false; Date = ''; History = @($old) } }
    Write-TestMetadata $w.B.path @{ '3' = [ordered]@{ Posted = $false; Date = ''; History = @($e2) }; '1' = [ordered]@{ Posted = $false; Date = ''; History = @($e1) } }   # e1 also in B: a move in flight
    $busy = @(Get-TikTokAccountBusyTimes -Account '@Anna' -Now $now)
    Assert-Equal (($busy | Sort-Object | ForEach-Object { $_.ToString('MM-dd HH:mm') }) -join ',') '10-27 12:00,10-27 19:00'
    Assert-Equal @(Get-TikTokAccountBusyTimes -Account 'bob' -Now $now).Count 1
    $extra = @(Ent 'req9' 'anna' (Utc (Local '2026-10-30 08:00')) 'preparing')
    Assert-Equal @(Get-TikTokAccountBusyTimes -Account 'anna' -Now $now -ExtraEntries $extra).Count 3 'extra (in-flight) entries are added'
}
Test-Case 'spread planning avoids the busy times of the account across both roots (60 min) and fills the free slots in order' {
    $w = New-TestWorld @('B')
    $now = Local '2026-10-26 10:00'
    function Ent { param([string]$Req, [string]$When) $e = New-TestHistoryEntry -Request $Req -User 'anna' -Status 'pending'; $e.tiktok_schedule_time = $When; return $e }
    Write-TestMetadata $w.A.path @{ '1' = [ordered]@{ Posted = $false; Date = ''; History = @((Ent 'a1' (Utc (Local '2026-10-26 12:30')))) } }
    Write-TestMetadata $w.B.path @{ '2' = [ordered]@{ Posted = $false; Date = ''; History = @((Ent 'b1' (Utc (Local '2026-10-26 19:30')))) } }
    $busy = @(Get-TikTokAccountBusyTimes -Account 'anna' -Now $now)
    Assert-Equal $busy.Count 2
    $plan = @(Get-TikTokSpreadPlan -Count 3 -Favorites @('12:00', '19:00', '21:00') -Busy $busy -Now $now)
    # 12:00 is 30 min from 12:30 and 19:00 is 30 min from 19:30 -> skipped; 21:00 is 90 min from 19:30 -> free
    Assert-Equal (($plan | ForEach-Object { $_.ToString('MM-dd HH:mm') }) -join ',') '10-26 21:00,10-27 12:00,10-27 19:00'
    $both19 = @(Get-TikTokSpreadPlan -Count 1 -Favorites @('19:00') -Busy $busy -Now $now)
    Assert-Equal $both19[0].ToString('MM-dd HH:mm') '10-27 19:00'
    $onlyA = @(Get-TikTokSpreadPlan -Count 1 -Favorites @('19:00') -Busy @($busy | Where-Object { $_.Hour -eq 12 }) -Now $now)
    Assert-Equal $onlyA[0].ToString('MM-dd HH:mm') '10-26 19:00' 'ignoring the second root would wrongly offer 19:00 today (the multi-root rule prevents that)'
}

# ---------------- S6: no entry creation for a missing file ----------------
Test-Case 'S6 manual mark: marking a video whose -3 is not in the folder throws and creates NO entry; an existing file creates it; an existing entry of a missing file still updates' {
    $w = New-TestWorld @('B')
    $id = '1000000000731'
    Assert-Throws { Set-ReupMetadata -VideoId $id -Posted $true -OutDir $w.A.path } '*không còn trong thư mục kho này*'
    Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path 'reup-status.json')) -or $null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'no entry'
    [void](New-TestVideo $w.A.path $id -NoReceipt)
    Set-ReupMetadata -VideoId $id -Posted $true -OutDir $w.A.path
    Assert-Equal (Get-ReupMetadata -OutDir $w.A.path).$id.Posted $true
    Remove-Item -LiteralPath (Join-Path $w.A.path "$id-3-hoan-chinh.mp4")
    Set-ReupMetadata -VideoId $id -Posted $false -OutDir $w.A.path
    Assert-Equal (Get-ReupMetadata -OutDir $w.A.path).$id.Posted $false 'existing entries keep updating (current behaviour)'
}
Test-Case 'S6 local receipt history right after a submit: no NEW entry when the -3 left the folder; an existing entry is still updated' {
    $w = New-TestWorld @('B')
    $id = '1000000000741'
    $rec = [pscustomobject]@{ RequestId = ('{0:x32}' -f 741); VideoId = $id; Username = 'anna'; ScheduledFor = ''; Status = 'submitted'; CreatedAt = [DateTime]::UtcNow.ToString('o'); LaunchedAt = ''; SourceSha256 = ''; UploadSha256 = ''; OutDir = $w.A.path }
    $changed = Add-TikTokLocalReceiptHistory -OutDir $w.A.path -VideoId $id -Entries @() -Record $rec
    Assert-True (-not $changed) 'nothing changed'
    Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path 'reup-status.json')) -or $null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'no entry created'
    [void](New-TestVideo $w.A.path $id -NoReceipt)
    Assert-True (Add-TikTokLocalReceiptHistory -OutDir $w.A.path -VideoId $id -Entries @() -Record $rec) 'file present: entry created'
    Assert-Equal @((Get-ReupMetadata -OutDir $w.A.path).$id.History).Count 1
}

# ---------------- cache cleanup vs journals ----------------
function New-CleanupFixture {
    $w = New-TestWorld @('B')
    $keepSrc = Join-Path $w.A.path '.cache\100-1-video-goc.mp4'; $keepDst = Join-Path $w.B.path '.cache\100-1-video-goc.mp4'
    foreach ($d in (Join-Path $w.A.path '.cache'), (Join-Path $w.B.path '.cache'), (Join-Path $w.A.path '.cache\tiktok-posts')) { [void][IO.Directory]::CreateDirectory($d) }
    [IO.File]::WriteAllText($keepSrc, 'journal src'); [IO.File]::WriteAllText($keepDst, 'journal dst')
    [IO.File]::WriteAllText((Join-Path $w.A.path '.cache\200-1-video-goc.mp4'), 'free to clean')
    [IO.File]::WriteAllText((Join-Path $w.A.path ('.cache\tiktok-posts\{0:x32}.json' -f 5)), 'receipt')
    $dir = Get-KhoMovesDir; [void][IO.Directory]::CreateDirectory($dir)
    $j = [ordered]@{ version = 1; txid = 'b' * 32; id = '100'; from = $w.A.path; to = $w.B.path; phase = 'renaming'; renames = @([ordered]@{ src = $keepSrc; dst = $keepDst; optional = $false; kind = 'companion'; status = 'pending' }) }
    [IO.File]::WriteAllText((Join-Path $dir ('b' * 32 + '.json')), (ConvertTo-Json $j -Depth 6), [Text.UTF8Encoding]::new($false))
    return @{ W = $w; Src = $keepSrc; Dst = $keepDst; Journal = (Join-Path $dir ('b' * 32 + '.json')) }
}
Test-Case 'cleanup protection: files named by a journal (source AND destination) are excluded from the cache summary and kept by Clear-KhoCacheDir; receipts and the journal itself are never touched' {
    $f = New-CleanupFixture; $w = $f.W
    $protected = Get-KhoJournalPaths
    Assert-True ($protected.Contains($f.Src) -and $protected.Contains($f.Dst)) 'both sides protected'
    $s = Get-CacheSummary @($w.A.path, $w.B.path)
    Assert-Equal $s.CacheFiles 1 'only the unprotected file is counted (receipts excluded by design)'
    $r = Clear-KhoCacheDir -CacheDir (Join-Path $w.A.path '.cache') -Protected $protected
    Assert-Equal $r.Deleted 1; Assert-Equal $r.Kept 1
    Assert-True ([IO.File]::Exists($f.Src)) 'journal source kept'; Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path '.cache\200-1-video-goc.mp4'))) 'free file cleaned'
    $r2 = Clear-KhoCacheDir -CacheDir (Join-Path $w.B.path '.cache') -Protected $protected
    Assert-Equal $r2.Deleted 0; Assert-True ([IO.File]::Exists($f.Dst)) 'journal destination kept'
    Assert-True ([IO.File]::Exists($f.Journal)) 'data\kho-moves untouched'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path ('.cache\tiktok-posts\{0:x32}.json' -f 5)))) 'receipts untouched'
}
Test-Case 'cleanup protection: an unreadable journal makes Get-KhoJournalPaths return $null (callers must refuse); Dọn ổ skips protected files' {
    $f = New-CleanupFixture
    [IO.File]::WriteAllText((Join-Path (Get-KhoMovesDir) 'broken.json'), '{x')
    Assert-True ($null -eq (Get-KhoJournalPaths)) 'null'
    Remove-Item -LiteralPath (Join-Path (Get-KhoMovesDir) 'broken.json')
    $protected = Get-KhoJournalPaths
    $cand = [pscustomobject]@{ Id = '100'; Path = (Join-Path $f.W.A.path '100-3-hoan-chinh.mp4'); Files = @([pscustomobject]@{ Path = $f.Src; Leaf = '100-1-video-goc.mp4'; Length = 11 }) }
    $r = Remove-KhoCleanupFiles -Candidates @($cand) -Protected $protected
    Assert-Equal $r.Deleted 0; Assert-Equal $r.Skipped 1; Assert-True ([IO.File]::Exists($f.Src)) 'kept'
}
Test-Case 'Test-CacheActionBlocked-style rule: a journal naming a root blocks it (Get-KhoJournalBlock), another root is free' {
    $f = New-CleanupFixture; $w = $f.W
    Assert-True ([bool](Get-KhoJournalBlock @($w.A.path))); Assert-True ([bool](Get-KhoJournalBlock @($w.B.path)))
    Assert-Equal (Get-KhoJournalBlock @((Join-Path $script:root 'elsewhere'))) ''
}
Test-Case 'Get-CacheScope: one selected kho -> its folder only; all -> every kho folder; unknown filter falls back to all' {
    $w = New-TestWorld @('B')
    $script:filterKho = $w.B.id
    $s = Get-CacheScope; Assert-Equal (@($s.Roots) -join '|') $w.B.path; Assert-True $s.Single
    $script:filterKho = 'all'
    $s = Get-CacheScope; Assert-Equal (@($s.Roots) -join '|') ($w.A.path + '|' + $w.B.path); Assert-True (-not $s.Single)
    $script:filterKho = 'k-ffffffffffffffffffffffffffffffff'
    Assert-Equal @((Get-CacheScope).Roots).Count 2
}

Complete-Tests
