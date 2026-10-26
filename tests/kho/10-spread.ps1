# T4: "Rải lịch" - slot allocator, per-row warnings, auto-schedule candidates, serial runner (stubbed launcher: Stop, re-validation shift, failures).
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
function Local { param([string]$s) return [DateTime]::SpecifyKind([DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), 'Local') }
function Fmt { param($list) return (@($list) | ForEach-Object { $_.ToString('MM-dd HH:mm') }) -join ',' }
$now = Local '2026-10-26 10:00'    # bounds: min 10:20 today, max 11-05 10:00
$fav = @('08:00', '12:00', '19:00', '21:00')

# ---------------- allocator ----------------
Test-Case 'plan: today partly past -> 08:00 skipped (< now+20 min), cap 3/day, then next day' {
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 5 -Favorites $fav -Now $now)) '10-26 12:00,10-26 19:00,10-26 21:00,10-27 08:00,10-27 12:00'
}
Test-Case 'plan: empty / invalid favourites fall back to the default chips 08:00,12:00,19:00,21:00' {
    $expected = '10-26 12:00,10-26 19:00,10-26 21:00,10-27 08:00,10-27 12:00'
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 5 -Favorites @() -Now $now)) $expected
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 5 -Favorites @('25:00', 'abc', '7:5') -Now $now)) $expected
}
Test-Case 'plan: Count 0 or negative -> empty' {
    Assert-Equal @(Get-TikTokSpreadPlan -Count 0 -Favorites $fav -Now $now).Count 0
    Assert-Equal @(Get-TikTokSpreadPlan -Count -3 -Favorites $fav -Now $now).Count 0
}
Test-Case 'plan: slot exactly at now+20 min is allowed, one minute earlier is not' {
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 1 -Favorites @('10:20') -Now $now -Days 1)) '10-26 10:20'
    Assert-Equal @(Get-TikTokSpreadPlan -Count 1 -Favorites @('10:19') -Now $now -Days 1).Count 0
}
Test-Case 'plan: midnight - now 23:50 pushes the minimum to 00:10 tomorrow, 00:00 tomorrow is then too early' {
    $n = Local '2026-10-26 23:50'
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 2 -Favorites @('00:00', '08:00') -Now $n)) '10-27 08:00,10-28 00:00'
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 2 -Favorites @('23:59') -Now $n)) '10-27 23:59,10-28 23:59'
}
Test-Case 'plan: now just after midnight keeps the same day' {
    $n = Local '2026-10-26 00:00'
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 2 -Favorites @('00:10', '00:30', '08:00') -Now $n)) '10-26 00:30,10-26 08:00'
}
Test-Case 'plan: busy collision within 120 min is skipped; exactly 120 min is allowed' {
    $busy = @((Local '2026-10-26 12:30'))
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 2 -Favorites @('12:00', '19:00', '21:00') -Busy $busy -Now $now -Days 1)) '10-26 19:00,10-26 21:00'
    $edge = @((Local '2026-10-26 17:00'))
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 1 -Favorites @('19:00') -Busy $edge -Now $now -Days 1)) '10-26 19:00'
    $edge2 = @((Local '2026-10-26 17:01'))
    Assert-Equal @(Get-TikTokSpreadPlan -Count 1 -Favorites @('19:00') -Busy $edge2 -Now $now -Days 1).Count 0
}
Test-Case 'plan: spacing is configurable (60 min lets 12:30 coexist with 13:30)' {
    $busy = @((Local '2026-10-26 12:30'))
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 1 -Favorites @('13:30') -Busy $busy -Now $now -Days 1 -MinSpacingMinutes 60)) '10-26 13:30'
    Assert-Equal @(Get-TikTokSpreadPlan -Count 1 -Favorites @('13:30') -Busy $busy -Now $now -Days 1 -MinSpacingMinutes 61).Count 0
}
Test-Case 'plan: daily cap counts existing posts (even past ones) on that day' {
    $busy = @((Local '2026-10-26 03:00'), (Local '2026-10-26 05:00'))   # 2 already today -> only 1 more today
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 3 -Favorites @('12:00', '19:00', '21:00') -Busy $busy -Now $now)) '10-26 12:00,10-27 12:00,10-27 19:00'
    $full = @((Local '2026-10-26 03:00'), (Local '2026-10-26 05:00'), (Local '2026-10-26 07:00'))
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 1 -Favorites @('12:00') -Busy $full -Now $now)) '10-27 12:00'
}
Test-Case 'plan: cap 1 gives one per day' {
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 3 -Favorites $fav -Now $now -DailyCap 1)) '10-26 12:00,10-27 08:00,10-28 08:00'
}
Test-Case 'plan: 10-day bound - Days is clamped to 10 (today + 9), so a daily favourite yields 9 slots' {
    $r = @(Get-TikTokSpreadPlan -Count 50 -Favorites @('09:00') -Now $now -Days 99)
    Assert-Equal $r.Count 9
    Assert-Equal $r[-1].ToString('MM-dd HH:mm') '11-04 09:00'
    Assert-Equal @(Get-TikTokSpreadPlan -Count 50 -Favorites @('09:00') -Now $now -Days 0).Count 0   # clamps to 1 day = today only; 09:00 today is past
}
Test-Case 'plan: Bounds.Max is respected' {
    $b = @{ Min = (Local '2026-10-26 10:20'); Max = (Local '2026-10-27 12:00') }
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 9 -Favorites @('08:00', '12:00', '19:00') -Now $now -Bounds $b)) '10-26 12:00,10-26 19:00,10-27 08:00,10-27 12:00'
}
Test-Case 'plan: not enough room returns fewer, in ascending order' {
    $r = @(Get-TikTokSpreadPlan -Count 10 -Favorites $fav -Now $now -Days 1)
    Assert-Equal (Fmt $r) '10-26 12:00,10-26 19:00,10-26 21:00'
    for ($i = 1; $i -lt $r.Count; $i++) { Assert-True ($r[$i] -gt $r[$i - 1]) 'ascending' }
}
Test-Case 'plan: planned slots keep spacing between themselves (favourites 20 min apart, spacing 120)' {
    Assert-Equal (Fmt (Get-TikTokSpreadPlan -Count 3 -Favorites @('12:00', '12:20', '14:00', '14:20', '16:00') -Now $now -Days 1)) '10-26 12:00,10-26 14:00,10-26 16:00'
}

# ---------------- warnings / rows ----------------
function Ent { param($user, $status, $uncertain = $false) return [pscustomobject]@{ username = $user; status = $status; publish_uncertain = $uncertain } }
Test-Case 'warn: empty history -> none; manual Posted -> posted' {
    Assert-Equal (Get-TikTokSpreadWarn -History @()) ''
    Assert-Equal (Get-TikTokSpreadWarn -History @() -Posted $true) 'posted'
}
Test-Case 'warn: succeeded on any account -> posted; uncertain success is not a confirmed post' {
    Assert-Equal (Get-TikTokSpreadWarn -History @((Ent 'bob' 'succeeded'))) 'posted'
    Assert-Equal (Get-TikTokSpreadWarn -History @((Ent 'bob' 'succeeded' $true))) ''
}
Test-Case 'warn: active/pending job on any account -> active, wins over posted; failed/cancelled ignored' {
    foreach ($s in 'pending', 'queued', 'running', 'preparing') { Assert-Equal (Get-TikTokSpreadWarn -History @((Ent 'bob' 'succeeded'), (Ent 'anna' $s))) 'active' }
    Assert-Equal (Get-TikTokSpreadWarn -History @((Ent 'anna' 'failed'), (Ent 'anna' 'cancelled'))) ''
}
function Row { param($id, $warn = '', $include = $true) return [pscustomobject]@{ Id = $id; Path = "C:\x\$id-3-hoan-chinh.mp4"; Warn = $warn; Include = $include; When = $null } }
Test-Case 'times: active rows and unticked rows get no time; others get consecutive slots; unplaced counted' {
    $rows = @((Row '1'), (Row '2' 'active' $false), (Row '3' 'posted' $false), (Row '4'), (Row '5' 'posted' $true))
    $un = Set-TikTokSpreadTimes -Rows $rows -Favorites $fav -Now $now
    Assert-Equal $un 0
    Assert-Equal (($rows | ForEach-Object { if ($_.When) { $_.When.ToString('MM-dd HH:mm') } else { '-' } }) -join ',') '10-26 12:00,-,-,10-26 19:00,10-26 21:00'
}
Test-Case 'times: an active row that is still ticked is never scheduled' {
    $rows = @((Row '1' 'active' $true), (Row '2'))
    [void](Set-TikTokSpreadTimes -Rows $rows -Favorites $fav -Now $now)
    Assert-True ($null -eq $rows[0].When) 'active row got a time'
    Assert-Equal $rows[1].When.ToString('MM-dd HH:mm') '10-26 12:00'
}
Test-Case 'times: not enough room -> unplaced count, last rows stay without time' {
    $rows = @(1..5 | ForEach-Object { Row "$_" })
    $un = Set-TikTokSpreadTimes -Rows $rows -Favorites $fav -Now $now -Days 1
    Assert-Equal $un 2
    Assert-Equal @($rows | Where-Object { $_.When }).Count 3
    Assert-True ($null -eq $rows[4].When) 'row 5 should be unplaced'
}
Test-Case 'times: re-planning clears old times first' {
    $rows = @((Row '1'), (Row '2'))
    [void](Set-TikTokSpreadTimes -Rows $rows -Favorites $fav -Now $now)
    $rows[0].Include = $false
    [void](Set-TikTokSpreadTimes -Rows $rows -Favorites $fav -Now $now)
    Assert-True ($null -eq $rows[0].When) 'unticked row kept its time'
    Assert-Equal $rows[1].When.ToString('MM-dd HH:mm') '10-26 12:00'
}

# ---------------- auto-schedule candidates ----------------
Test-Case 'auto items: only this kho, Chờ đăng, no history at all, oldest file first' {
    $dir = Join-Path $tmp 'auto'; [void][IO.Directory]::CreateDirectory($dir)
    function Mk { param($id, $kho, $age, $posted = $false, $held = $null) $p = Join-Path $dir "$id-3-hoan-chinh.mp4"; [IO.File]::WriteAllText($p, 'x'); (Get-Item -LiteralPath $p).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-$age); return [pscustomobject]@{ Id = $id; Path = $p; Kho = $kho; Posted = $posted; HeldUntil = $held } }
    $items = @((Mk '11' 'acct:anna' 1), (Mk '12' 'acct:anna' 5), (Mk '13' 'acct:anna' 3), (Mk '14' 'acct:bob' 9), (Mk '15' 'acct:anna' 7 $true),
               (Mk '16' 'acct:anna' 8), (Mk '17' 'acct:anna' 2 $false ([DateTime]::UtcNow.AddHours(5))), (Mk '18' 'acct:anna' 4))
    $meta = [pscustomobject]@{
        '16' = [pscustomobject]@{ Posted = $false; Date = ''; History = @((Ent 'anna' 'failed')) }     # has a history entry -> excluded
        '18' = [pscustomobject]@{ Posted = $false; Date = ''; History = @() }                          # empty history -> still a candidate
    }
    Assert-Equal ((Get-TikTokAutoScheduleItems -Items $items -KhoId 'acct:anna' -Metadata $meta | ForEach-Object { $_.Id }) -join ',') '12,18,13,11'
    Assert-Equal @(Get-TikTokAutoScheduleItems -Items $items -KhoId 'acct:zed' -Metadata $meta).Count 0
    Assert-Equal ((Get-TikTokAutoScheduleItems -Items $items -KhoId 'acct:anna' -Metadata $null | ForEach-Object { $_.Id }) -join ',') '16,12,18,13,11'
}

# ---------------- job shape ----------------
Test-Case 'job: record and payload have the single-post shape; scheduled_for is the UTC form of the local time' {
    $when = Local '2026-10-27 19:00'
    $j = New-TikTokSpreadJob -Path 'C:\out dir\1000000000011-3-hoan-chinh.mp4' -Account 'anna' -Caption 'Cap #a' -When $when
    Assert-Equal $j.Record.VideoId '1000000000011'; Assert-Equal $j.Record.Username 'anna'; Assert-Equal $j.Record.Status 'submitted'
    Assert-Equal $j.Record.OutDir 'C:\out dir'; Assert-Equal $j.Record.SourcePath 'C:\out dir\1000000000011-3-hoan-chinh.mp4'
    Assert-True ($j.Record.RequestId -match '^[a-f0-9]{32}$') 'request id'
    Assert-Equal $j.Payload.username 'anna'; Assert-Equal $j.Payload.title 'Cap #a'; Assert-Equal $j.Payload.reel_id '1000000000011'
    Assert-Equal $j.Payload.scheduled_for $j.Record.ScheduledFor
    Assert-Equal ([DateTime]::Parse($j.Payload.scheduled_for, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()) $when
    $o = $j.Payload.options_json | ConvertFrom-Json
    Assert-Equal "$($o.allow_comment)$($o.allow_duet)$($o.allow_stitch)$($o.visibility_type)$($o.ai_label)" '10000'
}

# ---------------- serial runner ----------------
function MkRun {
    param([int]$n, [datetime[]]$whens = @(), [int]$days = 7)
    $rows = @(1..$n | ForEach-Object { $r = Row ('10000000000{0:D2}' -f $_); $r.Path = "C:\out\$($r.Id)-3-hoan-chinh.mp4"; $r.When = $(if ($whens.Count -ge $_) { $whens[$_ - 1] } else { (Local '2026-10-27 08:00').AddHours(3 * $_) }); $r })
    return New-TikTokSpreadRun -Rows $rows -Account 'anna' -Caption 'cap' -Favorites $fav -Days $days
}
Test-Case 'runner: strictly one child at a time; next job starts only after the previous process exits' {
    $run = MkRun 3
    $script:procs = New-Object System.Collections.Generic.List[object]
    $launcher = { param($rec, $pay) $p = [pscustomobject]@{ HasExited = $false; Rec = $rec }; $script:procs.Add($p); return $p }
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'launched'
    for ($i = 0; $i -lt 5; $i++) { Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'waiting' }
    Assert-Equal $script:procs.Count 1
    $script:procs[0].HasExited = $true
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'launched'
    Assert-Equal $script:procs.Count 2
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'waiting'
    $script:procs[1].HasExited = $true
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'launched'
    $script:procs[2].HasExited = $true
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'finished'
    Assert-Equal $run.Sent 3
    # scheduled_for of every launched job equals the planned time of its row (11:00, 14:00, 17:00 on 10-27)
    $got = $script:procs | ForEach-Object { [DateTime]::Parse($_.Rec.ScheduledFor, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('MM-dd HH:mm') }
    Assert-Equal ($got -join ',') '10-27 11:00,10-27 14:00,10-27 17:00'
    Assert-Equal (($script:procs | ForEach-Object { $_.Rec.VideoId }) -join ',') '1000000000001,1000000000002,1000000000003'
}
Test-Case 'runner: Stop prevents further launches; the already-launched job is left alone' {
    $run = MkRun 4
    $script:procs = New-Object System.Collections.Generic.List[object]
    $launcher = { param($rec, $pay) $p = [pscustomobject]@{ HasExited = $false }; $script:procs.Add($p); return $p }
    [void](Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now)
    $script:procs[0].HasExited = $true
    [void](Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now)
    $run.Stopped = $true
    $script:procs[1].HasExited = $true
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'finished'
    Assert-Equal $script:procs.Count 2
    Assert-Equal $run.Sent 2
    Assert-Equal @($run.Rows | Where-Object { $_.State -eq 'planned' }).Count 2
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'finished'
}
Test-Case 'runner: Stop while a child is still running -> still waits for it, then finishes without launching' {
    $run = MkRun 3
    $script:procs = New-Object System.Collections.Generic.List[object]
    $launcher = { param($rec, $pay) $p = [pscustomobject]@{ HasExited = $false }; $script:procs.Add($p); return $p }
    [void](Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now)
    $run.Stopped = $true
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'waiting'
    $script:procs[0].HasExited = $true
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'finished'
    Assert-Equal $script:procs.Count 1
}
Test-Case 're-validation: a time that became too close is shifted to the next free slot, never posted now' {
    # row 1 planned 10:25 (valid at 10:00-ish) but "now" has moved to 10:30 -> < +20 min; row 2 holds 12:00
    $run = MkRun 2 @((Local '2026-10-26 10:25'), (Local '2026-10-26 12:00'))
    $run.Busy = @((Local '2026-10-26 21:00'))
    $script:procs = New-Object System.Collections.Generic.List[object]
    $launcher = { param($rec, $pay) $p = [pscustomobject]@{ HasExited = $true; Rec = $rec; Pay = $pay }; $script:procs.Add($p); return $p }
    $late = Local '2026-10-26 10:30'
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $late) 'launched'
    $shifted = [DateTime]::Parse($script:procs[0].Rec.ScheduledFor, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    # 12:00 is held by row 2 (spacing 120) -> 12:00 clash; 19:00 is free (21:00 busy is exactly 120 away)
    Assert-Equal $shifted.ToString('MM-dd HH:mm') '10-26 19:00'
    Assert-True ($shifted -ge $late.AddMinutes(20)) 'shifted slot is not at least 20 min ahead'
    Assert-Equal $run.Shifted 1; Assert-True $run.Rows[0].Shifted 'row flag'
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $late) 'launched'
    Assert-Equal ([DateTime]::Parse($script:procs[1].Rec.ScheduledFor, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('MM-dd HH:mm')) '10-26 12:00'
}
Test-Case 're-validation: still valid time is untouched' {
    $run = MkRun 1 @((Local '2026-10-26 11:00'))
    $script:procs = New-Object System.Collections.Generic.List[object]
    $launcher = { param($rec, $pay) $p = [pscustomobject]@{ HasExited = $true; Rec = $rec }; $script:procs.Add($p); return $p }
    [void](Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now)
    Assert-Equal $run.Shifted 0
    Assert-Equal ([DateTime]::Parse($script:procs[0].Rec.ScheduledFor, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('HH:mm')) '11:00'
}
Test-Case 're-validation: no free slot left -> row skipped (logged), launcher NOT called, never posts now' {
    $run = MkRun 1 @((Local '2026-10-26 10:25')) 1
    $run.Busy = @((Local '2026-10-26 12:00'), (Local '2026-10-26 19:00'), (Local '2026-10-26 21:00'))   # day full (cap 3)
    $script:called = 0
    $launcher = { param($rec, $pay) $script:called++; return [pscustomobject]@{ HasExited = $true } }
    $script:TestLog.Clear()
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now (Local '2026-10-26 10:30')) 'skipped'
    Assert-Equal $script:called 0
    Assert-Equal $run.Skipped 1
    Assert-Equal $run.Rows[0].State 'skipped'
    Assert-True (@($script:TestLog | Where-Object { $_ -like 'WARN Rải lịch: bỏ qua*' }).Count -eq 1) 'skip not logged'
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now) 'finished'
}
Test-Case 'runner: a launcher failure is logged, counted, and the run continues with the next video' {
    $run = MkRun 3
    $script:n = 0
    $launcher = { param($rec, $pay) $script:n++; if ($script:n -eq 2) { throw 'boom' }; return [pscustomobject]@{ HasExited = $true } }
    $script:TestLog.Clear()
    $res = 1..4 | ForEach-Object { Step-TikTokSpreadRun -Run $run -Launcher $launcher -Now $now }
    Assert-Equal ($res -join ',') 'launched,failed,launched,finished'
    Assert-Equal $run.Sent 2; Assert-Equal $run.Failed 1; Assert-Equal $run.Rows[1].State 'failed'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*boom*' }).Count -ge 1) 'failure not logged'
}
Test-Case 'runner: AfterLaunch is called once per launched job with the row and the job; its failure does not stop the run' {
    $run = MkRun 2
    $script:after = New-Object System.Collections.Generic.List[string]
    $launcher = { param($rec, $pay) return [pscustomobject]@{ HasExited = $true } }
    $after = { param($row, $job) $script:after.Add($row.Id + '|' + $job.Record.Username); throw 'after-fail' }
    $r = 1..3 | ForEach-Object { Step-TikTokSpreadRun -Run $run -Launcher $launcher -AfterLaunch $after -Now $now }
    Assert-Equal ($r -join ',') 'launched,launched,finished'
    Assert-Equal ($script:after -join ',') '1000000000001|anna,1000000000002|anna'
}
Test-Case 'runner: empty run finishes at once' {
    $run = New-TikTokSpreadRun -Rows @() -Account 'anna' -Caption 'c'
    Assert-Equal (Step-TikTokSpreadRun -Run $run -Launcher { throw 'x' } -Now $now) 'finished'
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
