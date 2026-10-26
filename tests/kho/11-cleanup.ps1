# T5: "Don o" - Get-KhoCleanupCandidates (date math, uncertain / future / manual / legacy root / scope) and Remove-KhoCleanupFiles end-to-end in a temp folder.
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$script:reelCacheName = '.cache'    # script-level constant of the GUI (the harness loads functions only)
$now = [DateTime]::SpecifyKind([DateTime]::new(2026, 10, 26, 12, 0, 0), 'Local')   # cutoff for 30 days = 2026-09-26 12:00
function Utc { param([DateTime]$d) return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Entry { param($History = @(), [string]$Manual = '')
    $e = [ordered]@{ Source = 'autotok-history'; Posted = ($History.Count -gt 0); Date = ''; History = @($History) }
    if ($Manual) { $e.ManualPosted = $true; $e.ManualDate = $Manual }
    return [pscustomobject]$e
}
function Hist { param([string]$Status = 'succeeded', [bool]$Uncertain = $false, [string]$Accepted = '', [string]$Sched = '')
    return [pscustomobject]@{ status = $Status; publish_uncertain = $Uncertain; accepted_at = $Accepted; tiktok_schedule_time = $Sched }
}
function MkFiles { param([string]$Dir, [string]$Id, [switch]$Cache, [switch]$Legacy, [int]$Size = 1000)
    [void][IO.Directory]::CreateDirectory($Dir)
    [IO.File]::WriteAllBytes((Join-Path $Dir "$Id-3-hoan-chinh.mp4"), (New-Object byte[] 10))
    if ($Cache) {
        $c = Join-Path $Dir '.cache'; [void][IO.Directory]::CreateDirectory($c)
        [IO.File]::WriteAllBytes((Join-Path $c "$Id-1-video-goc.mp4"), (New-Object byte[] $Size))
        [IO.File]::WriteAllBytes((Join-Path $c "$Id-2-am-thanh-tho.m4a"), (New-Object byte[] $Size))
    }
    if ($Legacy) {
        [IO.File]::WriteAllBytes((Join-Path $Dir "$Id-1-video-goc.mp4"), (New-Object byte[] $Size))
        [IO.File]::WriteAllBytes((Join-Path $Dir "$Id-2-am-thanh-tho.m4a"), (New-Object byte[] $Size))
    }
}
function Ids { param($c) return (@($c | ForEach-Object { $_.Id } | Sort-Object) -join ',') }

$out = Join-Path $tmp 'Xuất [thử] 1'     # spaces, brackets, Vietnamese -> LiteralPath must hold
$old = Utc $now.AddDays(-40); $recent = Utc $now.AddDays(-20); $future = Utc $now.AddDays(10)
$meta = [pscustomobject]@{
    old1      = Entry @(Hist -Accepted $old)
    recent    = Entry @(Hist -Accepted $recent)
    uncertain = Entry @(Hist -Uncertain $true -Accepted $old)
    failed    = Entry @(Hist -Status 'failed' -Accepted $old)
    schedFut  = Entry @(Hist -Accepted $old -Sched $future)               # accepted long ago but TikTok publishes in the future
    schedOld  = Entry @(Hist -Accepted $recent -Sched (Utc $now.AddDays(-35)))
    mixed     = Entry @((Hist -Accepted $old), (Hist -Accepted $recent))   # newest post decides
    manualOld = Entry -Manual '01/08 09:00'                                # 2026-08-01
    manualNew = Entry -Manual '20/10 09:00'
    manualFut = Entry -Manual '27/12 09:00'                                # would be the future this year -> last year (2025) -> old
    legacyOld = [pscustomobject]@{ Posted = $true; Date = '05/07 10:00' }  # pre-integration shape
    noTime    = Entry @(Hist -Accepted '')                                 # succeeded, time unknown -> not guessed
    noFiles   = Entry @(Hist -Accepted $old)
    other     = Entry @(Hist -Accepted $old)
}
foreach ($id in 'old1','recent','uncertain','failed','schedFut','schedOld','mixed','manualOld','manualNew','manualFut','noTime','other') { MkFiles -Dir $out -Id $id -Cache }
MkFiles -Dir $out -Id 'legacyOld' -Legacy
MkFiles -Dir $out -Id 'noFiles'
$items = foreach ($id in 'old1','recent','uncertain','failed','schedFut','schedOld','mixed','manualOld','manualNew','manualFut','legacyOld','noTime','noFiles','other') {
    [pscustomobject]@{ Id = $id; Path = (Join-Path $out "$id-3-hoan-chinh.mp4"); Kho = $(if ($id -eq 'other') { 'k2' } else { 'default' }) }
}

Test-Case 'candidates: exactly the old confirmed / manual / legacy videos that still have -1/-2' {
    $c = Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out
    Assert-Equal (Ids $c) 'legacyOld,manualFut,manualOld,old1,other,schedOld'
}
Test-Case 'candidates: 20-day-old post excluded at 30 days, included at 7 days; 40-day-old excluded at 60' {
    Assert-True (@(Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 7 -Now $now -OutDir $out | Where-Object Id -eq 'recent').Count -eq 1)
    Assert-Equal @(Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 60 -Now $now -OutDir $out | Where-Object Id -eq 'old1').Count 0
}
Test-Case 'uncertain, failed, future schedule, mixed(newest recent), unknown time are never candidates' {
    $c = Ids (Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out)
    foreach ($bad in 'uncertain','failed','schedFut','mixed','noTime','noFiles','recent','manualNew') { Assert-True ($c -notmatch "(^|,)$bad(,|$)") "$bad must not be a candidate" }
}
Test-Case 'schedule time wins over accepted_at (accepted 20d ago but scheduled 35d ago -> candidate)' {
    Assert-True (@(Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out | Where-Object Id -eq 'schedOld').Count -eq 1)
}
Test-Case 'manual date without year: future date this year resolves to last year' {
    $d = ConvertFrom-ManualPostedDate -Text '27/12 09:00' -Now $now
    Assert-Equal $d.ToString('yyyy-MM-dd HH:mm') '2025-12-27 09:00'
    Assert-Equal (ConvertFrom-ManualPostedDate -Text '20/10 09:00' -Now $now).ToString('yyyy-MM-dd') '2026-10-20'
    Assert-True ($null -eq (ConvertFrom-ManualPostedDate -Text 'abc' -Now $now))
    Assert-True ($null -eq (ConvertFrom-ManualPostedDate -Text '31/02 10:00' -Now $now))
}
Test-Case 'legacy root files counted; cache + root both listed; bytes = sum of existing -1/-2 only' {
    $c = Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out
    $l = $c | Where-Object Id -eq 'legacyOld'
    Assert-Equal $l.Files.Count 2; Assert-Equal $l.Bytes 2000
    $o = $c | Where-Object Id -eq 'old1'
    Assert-Equal $o.Files.Count 2; Assert-Equal $o.Bytes 2000
    Assert-True (-not ($c.Files.Leaf -match '-3-hoan-chinh'))
}
Test-Case 'scope: kho filter keeps only that kho; all keeps both' {
    Assert-Equal (Ids (Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out -KhoId 'k2')) 'other'
    Assert-True ((Ids (Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out -KhoId 'all')) -match 'other')
    Assert-True ((Ids (Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out -KhoId 'default')) -notmatch 'other')
}
Test-Case 'empty items / null metadata -> empty' {
    Assert-Equal @(Get-KhoCleanupCandidates -Items @() -Metadata $meta -Days 30 -Now $now -OutDir $out).Count 0
    Assert-Equal @(Get-KhoCleanupCandidates -Items $items -Metadata $null -Days 30 -Now $now -OutDir $out).Count 0
}

# ---------------- end-to-end delete in a temp folder ----------------
Test-Case 'delete: removes exactly the -1/-2 of candidates; -3, thumbs, publish dirs, non-candidates intact' {
    $thumbs = Join-Path $out '.cache\thumbs'; [void][IO.Directory]::CreateDirectory($thumbs)
    [IO.File]::WriteAllBytes((Join-Path $thumbs 'old1.jpg'), (New-Object byte[] 5))
    $pub = Join-Path $out '.kidfby-publish-abc'; [void][IO.Directory]::CreateDirectory($pub); [IO.File]::WriteAllBytes((Join-Path $pub 'old1-3-hoan-chinh.mp4.stage'), (New-Object byte[] 5))
    $before = @(Get-ChildItem -LiteralPath $out -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($out.Length) })
    $c = Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out
    $expectedGone = @($c | ForEach-Object { $_.Files.Path | ForEach-Object { $_.Substring($out.Length) } })
    Assert-Equal $expectedGone.Count 12      # 6 candidates x 2 files
    $r = Remove-KhoCleanupFiles -Candidates $c
    Assert-Equal $r.Deleted 12; Assert-Equal $r.Failed 0; Assert-Equal $r.Skipped 0; Assert-Equal $r.Freed 12000
    $after = @(Get-ChildItem -LiteralPath $out -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($out.Length) })
    $gone = @($before | Where-Object { $after -notcontains $_ } | Sort-Object)
    Assert-Equal ($gone -join '|') (($expectedGone | Sort-Object) -join '|')
    foreach ($id in 'old1','recent','uncertain','legacyOld') { Assert-True ([IO.File]::Exists((Join-Path $out "$id-3-hoan-chinh.mp4"))) "-3 of $id" }
    Assert-True ([IO.File]::Exists((Join-Path $thumbs 'old1.jpg')))
    Assert-True ([IO.File]::Exists((Join-Path $pub 'old1-3-hoan-chinh.mp4.stage')))
    Assert-True ([IO.File]::Exists((Join-Path $out '.cache\recent-1-video-goc.mp4')))
    Assert-Equal @(Get-KhoCleanupCandidates -Items $items -Metadata $meta -Days 30 -Now $now -OutDir $out).Count 0
}
Test-Case 'delete: a locked file is reported as an error and the rest still go; active transfer skips the video' {
    $d2 = Join-Path $tmp 'two'; MkFiles -Dir $d2 -Id 'a' -Cache; MkFiles -Dir $d2 -Id 'b' -Cache
    $its = @('a','b') | ForEach-Object { [pscustomobject]@{ Id = $_; Path = (Join-Path $d2 "$_-3-hoan-chinh.mp4"); Kho = 'default' } }
    $m2 = [pscustomobject]@{ a = Entry @(Hist -Accepted $old); b = Entry @(Hist -Accepted $old) }
    $c = Get-KhoCleanupCandidates -Items $its -Metadata $m2 -Days 30 -Now $now -OutDir $d2
    $fs = [IO.File]::Open((Join-Path $d2 '.cache\a-1-video-goc.mp4'), 'Open', 'Read', 'None')
    try { $r = Remove-KhoCleanupFiles -Candidates $c } finally { $fs.Dispose() }
    Assert-Equal $r.Failed 1; Assert-Equal $r.Deleted 3
    Assert-True ([IO.File]::Exists((Join-Path $d2 '.cache\a-1-video-goc.mp4')))
    Assert-True (-not [IO.File]::Exists((Join-Path $d2 '.cache\a-2-am-thanh-tho.m4a')))
    MkFiles -Dir $d2 -Id 'b' -Cache
    function Test-TikTokTransferActive { param([string]$FilePath) return ($FilePath -like '*\b-3-*') }
    $c = Get-KhoCleanupCandidates -Items $its -Metadata $m2 -Days 30 -Now $now -OutDir $d2
    $r = Remove-KhoCleanupFiles -Candidates $c
    Assert-Equal $r.Skipped 1
    Assert-True ([IO.File]::Exists((Join-Path $d2 '.cache\b-1-video-goc.mp4')))
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
