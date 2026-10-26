# QA fixes of the physical kho: (a) no registry before settings are loaded, (b) a stuck journal blocks only its own folders + abandon/retry,
# (c) delete refused while a journal reserves the folder, (d) auto-move: cheap checks first, no per-tick retry when busy,
# (e) volumes without a Recycle Bin never delete silently, (f) $Root parameters do not shadow the app root, (g) -3 recycle failure leaves the rest.
. (Join-Path $PSScriptRoot '_load.ps1')
function Update-Gallery { }
function Invoke-TikTokSyncStep { }

function New-StuckJournalFor {
    # A journal for a video of $FromRoot -> $ToRoot left at phase 'renaming' (nothing renamed yet).
    param($FromRoot, $ToRoot, [string]$Id)
    $plan = @(New-KhoMovePlan $Id $FromRoot $ToRoot (Get-KhoReceiptGroups $FromRoot))
    # the target already holds a file of that name: Resume-KhoMove reports a both-exist conflict and keeps the journal (really stuck)
    [void][IO.Directory]::CreateDirectory($ToRoot); [IO.File]::WriteAllText((Join-Path $ToRoot "$Id-3-hoan-chinh.mp4"), 'blocker')
    return (Write-KhoJournal ([ordered]@{ version = 1; txid = [Guid]::NewGuid().ToString('N'); id = $Id; from = $FromRoot; to = $ToRoot; phase = 'renaming'; reason = 'manual'; createdAt = ''; renames = @($plan); sourceEntrySnapshot = $null }))
}

Test-Case 'a: before settings are loaded Get-KhoRegistry creates / caches / saves nothing; after load it uses the saved outDir' {
    $w = New-TestWorld @()
    $kho = Get-KhoPath; if ([IO.File]::Exists($kho)) { [IO.File]::Delete($kho) }
    $script:khoRegistry = $null; $script:khoSettingsLoaded = $false
    $early = Get-KhoRegistry
    Assert-True (-not [IO.File]::Exists($kho)) 'kho.json must not be created before settings are loaded'
    Assert-True ($null -eq $script:khoRegistry) 'transient registry must not be cached'
    Assert-Equal (Save-KhoRegistry -Registry $early) $false 'save refused'
    Assert-Throws { [void](Invoke-KhoRegistryChange { param($r) 1 }) } '*cài đặt*'
    $script:khoSettingsLoaded = $true; $script:khoLegacyOutDir = Join-Path $script:root 'Cũ [xuất] 1'
    $reg = Get-KhoRegistry
    Assert-Equal @($reg.libraries).Count 1; Assert-Equal $reg.libraries[0].path (Join-Path $script:root 'Cũ [xuất] 1') 'Output cũ = saved outDir'
    Assert-True ([IO.File]::Exists($kho)) 'created after load'
}
Test-Case 'a: settings file locked -> the default registry stays in memory only (outDir unknown), never saved' {
    $w = New-TestWorld @()
    $kho = Get-KhoPath; if ([IO.File]::Exists($kho)) { [IO.File]::Delete($kho) }
    $script:khoRegistry = $null; $script:settingsReadLocked = $true
    try { [void](Get-KhoRegistry) } finally { $script:settingsReadLocked = $false }
    Assert-True (-not [IO.File]::Exists($kho)) 'not saved'; Assert-Equal $script:khoRegistryReady $false 'session is read-only'
    $script:khoRegistryReady = $true
}

Test-Case 'b: a stuck journal A<->B blocks only A and B; C -> D still moves, A -> C is refused per folder (no global Busy)' {
    $w = New-TestWorld @('B', 'C', 'D')
    $stuck = NextId; [void](New-TestVideo $w.A.path $stuck)
    [void](New-StuckJournalFor $w.A.path $w.B.path $stuck)
    $ok = NextId; [void](New-TestVideo $w.C.path $ok)
    $r = Invoke-KhoMove -Items @((Item $w.C.path $ok)) -TargetId $w.D.id -Reason manual
    Assert-Equal $r.Busy '' 'no global refusal'; Assert-Equal @($r.Moved).Count 1 (($r.Failed | ForEach-Object { $_.Why }) -join ';')
    $blockedVideo = NextId; [void](New-TestVideo $w.A.path $blockedVideo)
    $r2 = Invoke-KhoMove -Items @((Item $w.A.path $blockedVideo)) -TargetId $w.C.id -Reason manual
    Assert-Equal @($r2.Moved).Count 0; Assert-True ($r2.Failed[0].Why -like '*chưa hoàn tất*') $r2.Failed[0].Why
}
Test-Case 'b: Get-KhoStuckMoves lists the journal; Move-KhoJournalAside moves it to abandoned\ and leaves every file exactly where it was; the folders unlock' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    $j = New-StuckJournalFor $w.A.path $w.B.path $id
    $treeA = Get-TestTree $w.A.path; $treeB = Get-TestTree $w.B.path
    $stuck = @(Get-KhoStuckMoves)
    Assert-Equal $stuck.Count 1; Assert-True ($stuck[0].Text -like "*$id*") $stuck[0].Text
    Assert-True ([bool](Get-KhoJournalBlock @($w.A.path))) 'blocked before'
    $dest = Move-KhoJournalAside $stuck[0].Path
    Assert-True ([IO.File]::Exists($dest)) 'journal kept in abandoned'; Assert-True ($dest -like '*kho-moves\abandoned\*') $dest
    Assert-Equal @(Get-TestJournalFiles).Count 0 'no journal left at top level'
    Assert-Equal (Get-KhoJournalBlock @($w.A.path, $w.B.path)) '' 'unlocked'
    Assert-Equal (Get-TestTree $w.A.path) $treeA 'source untouched'; Assert-Equal (Get-TestTree $w.B.path) $treeB 'target untouched'
    Assert-Throws { [void](Move-KhoJournalAside (Join-Path $script:root 'data\other.json')) } '*kho-moves*'
}
Test-Case 'b: "Thử hoàn tất" (Resume-KhoMoves) finishes a journal whose renames are all still possible' {
    $w = New-TestWorld @('B')
    $id = NextId; $req = New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id))
    $snapshotEntry = (Get-ReupMetadata -OutDir $w.A.path).$id
    $plan = @(New-KhoMovePlan $id $w.A.path $w.B.path (Get-KhoReceiptGroups $w.A.path))
    [void](Write-KhoJournal ([ordered]@{ version = 1; txid = [Guid]::NewGuid().ToString('N'); id = $id; from = $w.A.path; to = $w.B.path; phase = 'renaming'; reason = 'manual'; createdAt = ''; renames = @($plan); sourceEntrySnapshot = $snapshotEntry }))
    $r = Resume-KhoMoves
    Assert-Equal $r.Done 1; Assert-Equal @($r.Pending).Count 0; Assert-Moved $w.A.path $w.B.path $id $req
}

Test-Case 'c: Remove-ReelFiles refuses while a journal reserves the folder (file stays), and works once it is resolved' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    [void](New-StuckJournalFor $w.A.path $w.B.path $id)
    $script:khoRecycleOverride = { param($p, $f) throw 'recycle must not be called' }
    $r = Remove-ReelFiles (Join-Path $w.A.path "$id-3-hoan-chinh.mp4")
    Assert-Equal $r.Success $false; Assert-True (@($r.Errors)[0] -like '*chưa hoàn tất*') (@($r.Errors) -join ';')
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) 'video untouched'
    $other = NextId; [void](New-TestVideo $w.A.path $other)
    $script:khoRecycleOverride = { param($p, $f) [IO.File]::Delete($p) }
    foreach ($e in @(Get-KhoStuckMoves)) { [void](Move-KhoJournalAside $e.Path) }
    $r2 = Remove-ReelFiles (Join-Path $w.A.path "$other-3-hoan-chinh.mp4")
    Assert-True $r2.Success ($r2.Errors -join ';')
}

function New-AutoMoveCandidate {
    param($w)
    [void](Set-KhoAccount -Id $w.B.id -Account 'anna')
    $id = NextId
    $h = New-TestHistoryEntry -Request ('{0:x32}' -f [long]$id) -User 'anna' -Accepted ([DateTime]::UtcNow.AddMinutes(1).ToString('o'))
    $entry = [ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = @($h); ManualPosted = $false; ManualDate = ''; FileSha256 = '' }
    [void](New-TestVideo $w.A.path $id -Entry $entry)
    return $id
}
function Watch-MetaReads {
    $script:metaReads = 0
    $script:origGetMeta = ${function:Get-ReupMetadata}
    Set-Item -Path function:Get-ReupMetadata -Value ({ param([Parameter(Mandatory)][string]$OutDir) $script:metaReads++; & $script:origGetMeta -OutDir $OutDir })
}
function Unwatch-MetaReads { Set-Item -Path function:Get-ReupMetadata -Value $script:origGetMeta }

Test-Case 'd: busy app -> Invoke-KhoAutoMoveNow reads NO metadata, defers; ticks do not retry; the busy -> quiet transition re-arms it once and the video moves' {
    $w = New-TestWorld @('B')
    $id = New-AutoMoveCandidate $w
    $script:tikTokSync = @{ Task = $null; Fast = $null; Roots = @{}; Notified = @{}; Stale = ''; StaleRoots = @{}; FastRoot = 0; Paused = $false }
    $script:ps = 'engine running'; $script:khoAutoMoveWanted = $true
    Watch-MetaReads
    try {
        for ($t = 0; $t -lt 8; $t++) { Invoke-TikTokSyncTick }
        Assert-Equal $script:metaReads 0 'no reup-status.json read while busy'
        Assert-True $script:khoAutoMoveDeferred 'deferred'; Assert-Equal $script:khoAutoMoveWanted $false
        $script:ps = $null
        Invoke-TikTokSyncTick
        Assert-True ($script:metaReads -ge 1) 'quiet transition re-armed it'
    } finally { Unwatch-MetaReads }
    Assert-True ([IO.File]::Exists((Join-Path $w.B.path "$id-3-hoan-chinh.mp4"))) 'moved to the account kho'
    Assert-Equal $script:khoAutoMoveDeferred $false
}
Test-Case 'd: a folder reserved by a stuck journal is not read by the auto-move and nothing is retried per tick' {
    $w = New-TestWorld @('B')
    $id = New-AutoMoveCandidate $w
    $stuck = NextId; [void](New-TestVideo $w.A.path $stuck); [void](New-StuckJournalFor $w.A.path $w.B.path $stuck)
    $script:tikTokSync = @{ Task = $null; Fast = $null; Roots = @{}; Notified = @{}; Stale = ''; StaleRoots = @{}; FastRoot = 0; Paused = $false }
    $script:khoAutoMoveWanted = $true
    Watch-MetaReads
    try { for ($t = 0; $t -lt 5; $t++) { Invoke-TikTokSyncTick } } finally { Unwatch-MetaReads }
    Assert-Equal $script:metaReads 0 'blocked folders are not read'; Assert-Equal $script:khoAutoMoveWanted $false
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) 'candidate stays'
}

function Use-SubstDir {
    # Runs $Body with the path of a folder on a REAL subst drive (no Recycle Bin there); the drive is removed afterwards.
    param([scriptblock]$Body)
    $tmp = New-TestDir
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $letter = @('Y', 'X', 'W', 'V', 'U') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $letter) { throw 'no free drive letter for subst' }
    & subst.exe ($letter + ':') $tmp
    try { & $Body ($letter + ':') } finally { & subst.exe ($letter + ':') /d }
}
Test-Case 'e: a volume without a Recycle Bin (real subst drive): Invoke-KhoRecycle refuses (file stays); -AllowPermanent deletes only when asked' {
    $w = New-TestWorld @()
    Use-SubstDir {
        param($drive)
        $f = Join-Path $drive 'x.mp4'; [IO.File]::WriteAllText($f, 'x')
        Assert-Throws { Invoke-KhoRecycle $f } '*không có Thùng rác*'
        Assert-True ([IO.File]::Exists($f)) 'still there'
        Invoke-KhoRecycle $f -AllowPermanent
        Assert-True (-not [IO.File]::Exists($f)) 'deleted after explicit permission'
    }
}
Test-Case 'e: Remove-ReelToRecycleBin on a no-bin volume: refused without -AllowPermanent (all files stay, entry stays); with it everything is deleted' {
    $w = New-TestWorld @()
    Use-SubstDir {
        param($drive)
        $kho = Join-Path $drive 'kho'; $id = NextId
        [void](New-TestVideo $kho $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id)))
        $before = Get-TestTree $kho
        $r = Remove-ReelToRecycleBin -Root $kho -Id $id
        Assert-Equal $r.Success $false; Assert-Equal (Get-TestTree $kho) $before 'nothing deleted'
        Assert-True ($null -ne (Get-ReupMetadata -OutDir $kho).PSObject.Properties[$id]) 'entry stays'
        $r2 = Remove-ReelToRecycleBin -Root $kho -Id $id -AllowPermanent
        Assert-True $r2.Success ($r2.Errors -join ';'); Assert-True (-not [IO.File]::Exists((Join-Path $kho "$id-3-hoan-chinh.mp4"))) 'deleted'
        Assert-True ($null -eq (Get-ReupMetadata -OutDir $kho).PSObject.Properties[$id]) 'entry removed'
    }
}
Test-Case 'e: detection - UNC and a REAL subst drive have no bin, the temp folder (fixed drive) has one; reason text for the dialog' {
    Assert-Equal (Test-KhoRecycleBin ([string]([char]92) + [string]([char]92) + 'server' + [string]([char]92) + 'share')).Ok $false
    Assert-Equal (Test-KhoRecycleBin (New-TestDir)).Ok $true 'fixed local drive has a Recycle Bin'
    Assert-Equal (Get-KhoNoRecycleReason (New-TestDir)) ''
    Use-SubstDir { param($drive) $b = Test-KhoRecycleBin $drive; Assert-Equal $b.Ok $false; Assert-True ($b.Reason -like '*subst*') $b.Reason; Assert-True ([bool](Get-KhoNoRecycleReason $drive)) 'reason for the dialog' }
}

Test-Case 'f: a function with a $Root parameter / a foreach ($root ...) does not redirect the app-root helpers into a kho folder' {
    $w = New-TestWorld @()
    $expect = Join-Path $script:root 'data\kho-moves'
    function Probe-Param { param($Root) return (Get-KhoMovesDir) }
    function Probe-Foreach { foreach ($root in @('Z:\kho x')) { return (Get-KhoMovesDir) } }
    function Probe-Path { param([string]$Root) return (Get-KhoPath) }
    Assert-Equal (Probe-Param -Root 'Z:\kho x') $expect; Assert-Equal (Probe-Foreach) $expect
    Assert-Equal (Probe-Path -Root 'Z:\kho x') (Join-Path $script:root 'data\kho.json')
    # and the product's own functions with a kho root parameter accept the old -Root name
    $id = NextId; [void](New-TestVideo $w.A.path $id)
    Assert-Equal @(Get-KhoVideoFiles -Root $w.A.path).Count 1
}

Test-Case 'g: when the -3 cannot be recycled nothing else is touched (-1/-2, receipts, thumbs, entry stay)' {
    $w = New-TestWorld @()
    $id = NextId; [void](New-TestVideo $w.A.path $id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$id)))
    $before = Get-TestTree $w.A.path
    $script:khoRecycleOverride = { param($p, $f) if ($p -like '*-3-hoan-chinh.mp4') { throw 'file đang mở' } else { [IO.File]::Delete($p) } }
    $r = Remove-ReelToRecycleBin -Root $w.A.path -Id $id
    Assert-Equal $r.Success $false; Assert-Equal @($r.Recycled).Count 0 'nothing recycled'
    Assert-Equal (Get-TestTree $w.A.path) $before 'folder byte-identical'
}
Test-Case 'script header: the GUI file declares param([switch]$SelfTest, [string]$TikTokJobFile) (the background TikTok worker and -SelfTest depend on it)' {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'core\kid-fby-gui.ps1'), [ref]$t, [ref]$e)
    $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-Equal ($names -join ',') 'SelfTest,TikTokJobFile'
}
Complete-Tests
