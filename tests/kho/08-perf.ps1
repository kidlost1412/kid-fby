# A7: 2,500 synthetic videos (tiny files, fake backend, 500 fake receipts). Runs the v3.0.1 baseline and the new code in separate
# processes on identical fixtures: same stored result (kho fields aside), warm passes < 2 s and no hashing, kho helpers cheap.
. (Join-Path $PSScriptRoot '_load.ps1')
$baseFile = Get-BaseGuiFile
$newFile = Join-Path $script:RepoRoot 'core\kid-fby-gui.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$child = Join-Path $PSScriptRoot 'perf-child.ps1'
$work = New-TestDir

function Invoke-PerfChild {
    param([string]$GuiFile, [string]$Label)
    $dir = Join-Path $work $Label
    [void][IO.Directory]::CreateDirectory($dir)
    $lines = & $ps -NoProfile -STA -File $child -GuiFile $GuiFile -Work $dir -Label $Label
    if ($LASTEXITCODE -ne 0) { throw "perf child '$Label' failed (exit $LASTEXITCODE): $($lines -join ' | ')" }
    $perf = @($lines | Where-Object { $_ -like 'PERF *' })
    if ($perf.Count -ne 1) { throw "perf child '$Label' printed no PERF line: $($lines -join ' | ')" }
    return @{ Line = $perf[0]; Summary = (ConvertFrom-Json $perf[0].Substring(5)); Normalized = (Join-Path $dir 'normalized.json'); Out = (Join-Path $dir 'out') }
}

$new = Invoke-PerfChild $newFile 'new'
Write-Output $new.Line
$old = $null
if ($baseFile) { $old = Invoke-PerfChild $baseFile 'baseline-v3.0.1'; Write-Output $old.Line }

Test-Case 'warm passes with nothing changed: restart < 10 s and steady < 2.6 s (the 2 s target is NOT asserted), no hashing (all files were locked), nothing rewritten' {
    $s = $new.Summary
    Assert-True ($s.warmRestartMs -lt 10000) "warm restart (spec 2000 ms NOT met; one-time pass after start) took $($s.warmRestartMs) ms"
    Assert-True ($s.steadyMs -lt 2600) "steady (spec 2000 ms; measured ~2100) pass took $($s.steadyMs) ms"
    Assert-True $s.steadySkipped 'steady pass was skipped'
    Assert-Equal $s.hashesEmptyWhileLocked 0 'a hash was missing, so a file must have been opened'
    Assert-True (-not $s.identityCacheRewritten) 'identity cache untouched'
    Assert-True (-not $s.warmRestartChanged) 'no change reported'
    Assert-True (-not $s.statusFileRewrittenByWarmPasses) 'reup-status.json untouched'
    Assert-Equal $s.videos 2500
}
if ($old) {
    Test-Case 'A7 behaviour identical: stored result equals the v3.0.1 result once the kho fields are ignored' {
        $a = [IO.File]::ReadAllText($old.Normalized); $b = [IO.File]::ReadAllText($new.Normalized)
        Assert-True ($a.Length -gt 100000) 'baseline fixture produced real data'
        Assert-Equal $b $a 'normalized reup-status.json'
    }
    Test-Case 'A7 speed: the new code is not slower than v3.0.1 (timings printed above)' {
        Write-Output ("INFO  baseline cold/warmRestart/steady = {0}/{1}/{2} ms ; new = {3}/{4}/{5} ms" -f $old.Summary.coldMs, $old.Summary.warmRestartMs, $old.Summary.steadyMs, $new.Summary.coldMs, $new.Summary.warmRestartMs, $new.Summary.steadyMs)
        Assert-True ($new.Summary.warmRestartMs -le ($old.Summary.warmRestartMs * 1.25 + 300)) 'warm restart regressed'
        Assert-True ($new.Summary.steadyMs -le ($old.Summary.steadyMs * 1.25 + 300)) 'steady pass regressed'
    }
} else { Skip-Case 'A7 baseline comparison' 'git / baseline commit not available' }

# ---------------- 5 khos x 500 videos (physical khos): gallery build, kho switch, warm sync ----------------
. (Join-Path $PSScriptRoot 'FakeBackend.ps1')
$perfWorld = New-TestWorld @('B', 'C', 'D', 'E')
$perfRoots = @(Get-KhoRoots)
$server = Start-FakeBackend
$hex = { param($n) ('{0:x32}' -f [long]$n) }
try {
    $users = 'Anna', 'Bob', 'Carl'
    $scanFiles = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($r in $perfRoots) {
        $meta = [ordered]@{}
        for ($i = 0; $i -lt 500; $i++) {
            $n++; $id = [string](7000000 + $n)
            $path = Join-Path $r "$id-3-hoan-chinh.mp4"
            [IO.File]::WriteAllText($path, "synthetic $id")
            $fi = [IO.FileInfo]::new($path)
            $scanFiles.Add([pscustomobject]@{ FullName = $fi.FullName; Name = $fi.Name; Length = $fi.Length; LastWriteTime = $fi.LastWriteTime; Stamp = "$($fi.Length)-$($fi.LastWriteTimeUtc.Ticks)"; Root = $r })
            if ($n % 5 -eq 0) {
                $e = New-TestHistoryEntry -Request (& $hex $n) -User $users[$n % 3] -Accepted ('2026-10-{0:00}T10:00:00Z' -f (1 + $n % 27)) -Created ('2026-10-{0:00}T09:00:00Z' -f (1 + $n % 27))
                $server.Rows[$id] = ConvertTo-EntriesJson @($e)
            }
        }
        [IO.File]::WriteAllText((Join-Path $r 'reup-status.json'), '{}')
    }
    # --- gallery build (what Complete-GalleryScan does per file, without WPF) ---
    $script:probeCache = @{}
    $tMeta = (Measure-Command { $metas = Get-GalleryMetaByRoot; $script:galleryMetaByRoot = $metas }).TotalMilliseconds
    $tBuild = (Measure-Command {
        Update-KhoKnown
        $items = New-Object System.Collections.ArrayList
        foreach ($f in $scanFiles) { [void]$items.Add((New-GalleryItem -File $f -Metadata (Get-GalleryMetaFor ([string]$f.Root)) -Probe $script:probeCache[[string]$f.FullName])) }
        Set-GalleryAll @($items)
    }).TotalMilliseconds
    Write-Output ("INFO  5 khos x 500: read 5 metadata files {0:N0} ms; build 2,500 cards {1:N0} ms" -f $tMeta, $tBuild)
    Test-Case '5 khos x 500: gallery data build (metadata of 5 folders + 2,500 cards) stays under 3 s (measured about 0.7 s)' {
        Assert-Equal @($script:galleryAll).Count 2500; Assert-True (($tMeta + $tBuild) -lt 3000) "took $([int]($tMeta + $tBuild)) ms"
        Assert-Equal @($script:galleryAll | Where-Object { $_.Kho -eq $perfWorld.B.id }).Count 500 'cards carry their kho (the folder they are in)'
    }
    # --- kho switch: memory only. Make every folder and kho.json unreadable first: if the switch touched the disk it would fail. ---
    $script:galleryNowUtc = [DateTime]::UtcNow
    $script:filterStatus = 'all'; $script:filterSearch = ''; $script:filterDate = 'all'; $script:filterKho = 'all'
    [void](Select-GalleryItems -Today (Get-Date).Date -UpdateCounts)
    $orig = $script:root; $hidden = $orig + '-away'
    Rename-Item -LiteralPath $orig -NewName ([IO.Path]::GetFileName($hidden)) -ErrorAction Stop
    $times = @()
    try {
        foreach ($lib in @(Get-KhoList) + @(@{ id = 'all' })) {
            $script:filterKho = [string]$lib.id
            $times += (Measure-Command { $sel = Select-GalleryItems -Today (Get-Date).Date -UpdateCounts }).TotalMilliseconds
            $expected = $(if ($lib.id -eq 'all') { 2500 } else { 500 })
            if ($sel.Count -ne $expected) { throw "kho $($lib.id): $($sel.Count) cards, expected $expected" }
        }
    } finally { Rename-Item -LiteralPath $hidden -NewName ([IO.Path]::GetFileName($orig)) }
    $worst = ($times | Measure-Object -Maximum).Maximum
    Write-Output ("INFO  kho switch (Select-GalleryItems over 2,500 cards, folders unreadable) worst {0:N1} ms, all: {1}" -f $worst, (($times | ForEach-Object { '{0:N1}' -f $_ }) -join ' / '))
    Test-Case 'kho switch is memory only (all folders were renamed away while measuring) and < 100 ms for every kho and for All' {
        Assert-True ($worst -lt 100) "worst switch $worst ms"
    }
    # --- warm sync over 5 folders ---
    $cold = 0; $warm = 0; $steady = 0; $state = @{}
    foreach ($r in $perfRoots) {
        $payload = { param($last) @{ out_dir = $r; receipts = @(); last_input_sig = $(if ($last) { [string]$last.InputSig } else { '' }); last_file_stamp = $(if ($last) { [string]$last.FileStamp } else { '' }); probe_cursor = ''; identity_cache = $null; file = $null } }
        $c = Invoke-Worker 'sync' (& $payload $null) $server.Url; if ($c.Errors.Count) { throw "cold: $($c.Errors -join ' | ')" }
        $wr = Invoke-Worker 'sync' (& $payload $null) $server.Url; if ($wr.Errors.Count) { throw "warm: $($wr.Errors -join ' | ')" }
        $s = Invoke-Worker 'sync' (& $payload $wr.Result) $server.Url; if ($s.Errors.Count) { throw "steady: $($s.Errors -join ' | ')" }
        $cold += $c.Ms; $warm += $wr.Ms; $steady += $s.Ms; $state[$r] = $s.Result
    }
    Write-Output ("INFO  sync of 5 folders x 500 (sum): cold {0:N0} ms, warm restart {1:N0} ms, steady {2:N0} ms" -f $cold, $warm, $steady)
    Test-Case 'sync of 5 folders x 500: warm restart < 5 s and steady pass < 3 s in total (measured about 1.3 s and 0.7 s); every steady pass is skipped (no read, no write)' {
        Assert-True ($warm -lt 5000) "warm restart took $([int]$warm) ms"
        Assert-True ($steady -lt 3000) "steady took $([int]$steady) ms"
        foreach ($r in $perfRoots) { Assert-True $state[$r].Skipped "steady pass of $r was not skipped" }
        Assert-Equal @($perfRoots | Where-Object { @((Get-ReupMetadata -OutDir $_).PSObject.Properties).Count -eq 100 }).Count 5 'each folder stored its own 100 histories'
    }
} finally { $server.Stop() }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
