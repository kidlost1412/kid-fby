# D10: per-account slots (add/remove helpers) and the editable rows of the spread preview (time text validation, row warning, per-row caption submitted exactly).
. (Join-Path $PSScriptRoot '_load.ps1')
function Local { param([string]$s) return [DateTime]::SpecifyKind([DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), 'Local') }
$now = Local '2026-10-26 10:00'   # bounds: 10:20 today .. 11-05 10:00

Test-Case 'time text: valid "dd/MM HH:mm" gives that local time' {
    $r = ConvertFrom-SpreadTimeText -Text '28/10 19:00' -Now $now
    Assert-True $r.Ok; Assert-Equal $r.When.ToString('yyyy-MM-dd HH:mm') '2026-10-28 19:00'
}
Test-Case 'time text: single-digit parts and surrounding spaces are accepted' {
    $r = ConvertFrom-SpreadTimeText -Text ' 7/11 9:30 ' -Now (Local '2026-11-01 10:00')
    Assert-True $r.Ok; Assert-Equal $r.When.ToString('yyyy-MM-dd HH:mm') '2026-11-07 09:30'
}
Test-Case 'time text: lower bound now+20 min is allowed, one minute earlier is not' {
    Assert-True (ConvertFrom-SpreadTimeText -Text '26/10 10:20' -Now $now).Ok
    $r = ConvertFrom-SpreadTimeText -Text '26/10 10:19' -Now $now
    Assert-True (-not $r.Ok); Assert-True ($r.Error -like 'Chọn giờ từ 10:20 26/10*') $r.Error
}
Test-Case 'time text: upper bound now+10 days is allowed, one minute later is not' {
    Assert-True (ConvertFrom-SpreadTimeText -Text '05/11 10:00' -Now $now).Ok
    Assert-True (-not (ConvertFrom-SpreadTimeText -Text '05/11 10:01' -Now $now).Ok)
}
Test-Case 'time text: garbage, impossible dates and impossible clock values are rejected with a message' {
    foreach ($bad in '', 'abc', '28/10', '28-10 19:00', '31/02 10:00', '28/13 10:00', '28/10 24:00', '28/10 19:60', '0/10 10:00') {
        $r = ConvertFrom-SpreadTimeText -Text $bad -Now $now
        Assert-True (-not $r.Ok) "should reject '$bad'"; Assert-True ([bool]$r.Error) "message for '$bad'"; Assert-True ($null -eq $r.When) "no time for '$bad'"
    }
}
Test-Case 'time text: a date that already passed this year means next year (December -> January)' {
    $dec = Local '2026-12-30 10:00'
    $r = ConvertFrom-SpreadTimeText -Text '02/01 08:00' -Now $dec
    Assert-True $r.Ok; Assert-Equal $r.When.ToString('yyyy-MM-dd HH:mm') '2027-01-02 08:00'
}
Test-Case 'row warning: too close to another row (90 min is fine, 30 min is not) and to a busy time' {
    Assert-Equal (Get-SpreadRowWarning -When (Local '2026-10-27 12:00') -Others @((Local '2026-10-27 12:30'))) 'Cách một bài khác chỉ 30 phút (nên từ 60 phút).'
    Assert-Equal (Get-SpreadRowWarning -When (Local '2026-10-27 12:00') -Busy @((Local '2026-10-27 11:10'))) 'Cách một bài khác chỉ 50 phút (nên từ 60 phút).'
    Assert-Equal (Get-SpreadRowWarning -When (Local '2026-10-27 12:00') -Others @((Local '2026-10-27 13:30'))) ''
}
Test-Case 'row warning: exactly 60 min is fine; a far-away day is fine; the nearest post is the one reported' {
    Assert-Equal (Get-SpreadRowWarning -When (Local '2026-10-27 12:00') -Others @((Local '2026-10-27 13:00'))) ''
    Assert-Equal (Get-SpreadRowWarning -When (Local '2026-10-27 12:00') -Others @((Local '2026-10-28 12:30'))) ''
    Assert-Equal (Get-SpreadRowWarning -When (Local '2026-10-27 12:00') -Others @((Local '2026-10-27 12:40'), (Local '2026-10-27 11:45'))) 'Cách một bài khác chỉ 15 phút (nên từ 60 phút).'
}
Test-Case 'slots: add normalises, sorts, de-duplicates; bad input throws a Vietnamese message' {
    Assert-Equal ((Get-KhoSlotsWith -Slots @('19:00') -Text '7:30') -join ',') '07:30,19:00'
    Assert-Equal ((Get-KhoSlotsWith -Slots @('07:30', '19:00') -Text '19:00') -join ',') '07:30,19:00'
    Assert-Equal ((Get-KhoSlotsWith -Slots @() -Text '08h05') -join ',') '08:05'
    foreach ($bad in '24:00', '12:60', 'abc', '', '1230') { Assert-Throws { Get-KhoSlotsWith -Slots @() -Text $bad } '*Giờ không hợp lệ*' }
}
Test-Case 'slots: remove keeps the others; removing an absent slot changes nothing' {
    Assert-Equal ((Get-KhoSlotsWithout -Slots @('08:00', '12:00', '19:00') -Slot '12:00') -join ',') '08:00,19:00'
    Assert-Equal ((Get-KhoSlotsWithout -Slots @('08:00') -Slot '09:00') -join ',') '08:00'
    Assert-Equal @(Get-KhoSlotsWithout -Slots @('08:00') -Slot '08:00').Count 0
}
Test-Case 'slots: stored in kho.slots through Set-KhoOptions and read back by the registry' {
    $w = New-TestWorld -Names @('B')
    Set-KhoOptions -Id $w.B.id -Slots (Get-KhoSlotsWith -Slots @() -Text '19:00')
    Set-KhoOptions -Id $w.B.id -Slots (Get-KhoSlotsWith -Slots @((Get-KhoById $w.B.id).slots) -Text '8:15')
    $script:khoRegistry = $null
    Assert-Equal ((Get-KhoById $w.B.id).slots -join ',') '08:15,19:00'
}
function New-RowsC {
    param($Root, $Captions, $Times)
    $rows = @()
    for ($i = 0; $i -lt $Captions.Count; $i++) {
        $id = NextId; [void](New-TestVideo -Root $Root -Id $id -NoReceipt)
        $rows += [pscustomobject]@{ Id = $id; Path = (Join-Path $Root "$id-3-hoan-chinh.mp4"); Root = $Root; Kho = ''; Warn = ''; Include = $true; When = $Times[$i]; Other = $null; History = @(); Caption = $Captions[$i] }
    }
    return $rows
}
Test-Case 'runner: each row is submitted with ITS caption and ITS edited time; an empty row caption falls back to the run caption' {
    $w = New-TestWorld -Names @(); $script:spreadRun = $null
    $times = @((Local '2026-10-27 08:05'), (Local '2026-10-27 21:40'), (Local '2026-10-28 12:00'))
    $rows = New-RowsC $w.A.path @('Một #a', 'Hai #b', '') $times
    $script:sent = New-Object System.Collections.Generic.List[object]
    $launcher = { param($r, $p) $script:sent.Add(@{ Title = $p.title; When = $p.scheduled_for }); [pscustomobject]@{ HasExited = $true; ExitCode = 0 } }
    [void](Start-TikTokSpreadBackground -Rows $rows -Account 'anna' -Caption 'Chung' -Launcher $launcher -Verifier { @{ Sent = $true; Message = '' } } -HistoryReader { [pscustomobject]@{ History = @(); Posted = $false; TransferActive = $false } } -NoTimer)
    1..8 | ForEach-Object { Invoke-SpreadRunTick -Now $now }
    Assert-Equal $script:sent.Count 3
    Assert-Equal (($script:sent | ForEach-Object { $_.Title }) -join '|') 'Một #a|Hai #b|Chung'
    for ($i = 0; $i -lt 3; $i++) { Assert-Equal $script:sent[$i].When $times[$i].ToUniversalTime().ToString('o') "time $i" }
}
Complete-Tests
