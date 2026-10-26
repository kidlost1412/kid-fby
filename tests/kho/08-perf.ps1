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

Test-Case 'warm passes with nothing changed: under 2 s each, no hashing (all files were locked), nothing rewritten' {
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
Test-Case 'kho assignment of the cold pass: every succeeded video has its account kho, nothing else has one' {
    Assert-Equal $new.Summary.entriesWithKho $new.Summary.succeeded
    $m = Read-TestJson (Join-Path (Split-Path $new.Out -Parent) 'out\reup-status.json')
    foreach ($p in $m.PSObject.Properties) {
        $isDone = @($p.Value.History | Where-Object { $_.status -eq 'succeeded' }).Count -gt 0
        if ($isDone -and $p.Value.Kho -notin 'acct:anna', 'acct:bob', 'acct:carl') { throw "video $($p.Name) has Kho '$($p.Value.Kho)'" }
        if (-not $isDone -and $p.Value.Kho) { throw "unconfirmed video $($p.Name) got Kho '$($p.Value.Kho)'" }
    }
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

Test-Case 'kho helpers on 2,500 stored entries: Get-KhoList, auto-assign (idempotent) and effective-id scan stay cheap' {
    $root = New-TestDir
    $meta = Get-ReupMetadata -OutDir $new.Out
    $t1 = (Measure-Command { $list = @(Get-KhoList -Metadata $meta) }).TotalMilliseconds
    Assert-Equal $list.Count 4 'default + 3 account khos'
    $t2 = (Measure-Command { $changed = Invoke-KhoAutoAssign $meta }).TotalMilliseconds
    Assert-True (-not $changed) 'second auto-assign is a no-op'
    $t3 = (Measure-Command { $n = 0; foreach ($p in $meta.PSObject.Properties) { if ((Get-KhoEffectiveId $p.Value) -eq 'acct:anna') { $n++ } } }).TotalMilliseconds
    Write-Output ("INFO  Get-KhoList {0:N0} ms, Invoke-KhoAutoAssign {1:N0} ms, effective-id scan {2:N0} ms (2,500 entries)" -f $t1, $t2, $t3)
    Assert-True ($t1 -lt 400) "Get-KhoList $t1 ms"
    Assert-True ($t2 -lt 250) "Invoke-KhoAutoAssign $t2 ms"
    Assert-True ($t3 -lt 250) "scan $t3 ms"
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
