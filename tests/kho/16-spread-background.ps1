# D9: "Rải lịch" runs in the background after Confirm: one run at a time, quiet-state guard, per-failure toast, final summary, Stop.
. (Join-Path $PSScriptRoot '_load.ps1')
function Local { param([string]$s) return [DateTime]::SpecifyKind([DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), 'Local') }
$now = Local '2026-10-26 10:00'
function New-Rows {
    param($Root, [int]$N)
    $rows = @(); $ids = @()
    foreach ($i in 1..$N) {
        $id = NextId; $ids += $id
        [void](New-TestVideo -Root $Root -Id $id -NoReceipt)
        $rows += [pscustomobject]@{ Id = $id; Path = (Join-Path $Root "$id-3-hoan-chinh.mp4"); Root = $Root; Kho = ''; Warn = ''; Include = $true; When = $now.AddHours(2 + 3 * $i); Other = $null; History = @() }
    }
    return $rows
}
function New-Proc { param([bool]$Exited = $true, [int]$Code = 0) $p = [pscustomobject]@{ HasExited = $Exited; ExitCode = $Code }; return $p }
$okVerifier = { param($row, $job, $proc) @{ Sent = $true; Message = '' } }
$noHistory = { param($row) [pscustomobject]@{ History = @(); Posted = $false; TransferActive = $false } }

Test-Case 'background run: start marks the app busy for the quiet guard; finishing releases it' {
    $w = New-TestWorld -Names @(); $script:spreadRun = $null
    Assert-Equal (Test-KhoQuiet) '' 'quiet before'
    $rows = New-Rows $w.A.path 2
    $launcher = { param($r, $p) New-Proc }
    [void](Start-TikTokSpreadBackground -Rows $rows -Account 'anna' -Caption 'c' -Launcher $launcher -Verifier $okVerifier -HistoryReader $noHistory -NoTimer)
    Assert-True (Test-SpreadRunActive) 'active'
    Assert-Equal (Test-KhoQuiet) 'đang rải lịch đăng TikTok' 'busy while running'
    Assert-Throws { Invoke-KhoMove -Items @((Item $w.A.path $rows[0].Id)) -TargetId $w.A.id -Reason manual | ForEach-Object { if ($_.Busy) { throw 'busy:' + $_.Busy } } } '*busy:đang rải lịch*'
    1..6 | ForEach-Object { Invoke-SpreadRunTick -Now $now }
    Assert-True (-not (Test-SpreadRunActive)) 'finished'
    Assert-Equal (Test-KhoQuiet) '' 'quiet after'
    Assert-True ($null -eq $script:spreadRun) 'state cleared'
}
Test-Case 'background run: only one run at a time' {
    $w = New-TestWorld -Names @(); $script:spreadRun = $null
    $rows = New-Rows $w.A.path 1
    [void](Start-TikTokSpreadBackground -Rows $rows -Account 'anna' -Caption 'c' -Launcher { param($r, $p) New-Proc $false } -Verifier $okVerifier -HistoryReader $noHistory -NoTimer)
    Assert-Throws { Start-TikTokSpreadBackground -Rows (New-Rows $w.A.path 1) -Account 'anna' -Caption 'c' -NoTimer } '*Đang có một lượt rải lịch*'
    Stop-SpreadBackground
}
Test-Case 'background run: a failed video raises its own toast once, final toast reads "Đã gửi X, lỗi Y, chưa gửi Z"' {
    $w = New-TestWorld -Names @(); $script:spreadRun = $null
    $rows = New-Rows $w.A.path 3
    $bad = $rows[1].Id
    $verifier = { param($row, $job, $proc) if ($row.Id -eq $bad) { @{ Sent = $false; Message = 'TikTok từ chối' } } else { @{ Sent = $true; Message = '' } } }.GetNewClosure()
    [void](Start-TikTokSpreadBackground -Rows $rows -Account 'anna' -Caption 'c' -Launcher { param($r, $p) New-Proc } -Verifier $verifier -HistoryReader $noHistory -NoTimer)
    $script:TestLog.Clear()
    1..8 | ForEach-Object { Invoke-SpreadRunTick -Now $now }
    $toasts = @($script:TestLog | Where-Object { $_ -like '[[]toast]*' })
    Assert-Equal @($toasts | Where-Object { $_ -like "*$bad*" -or $_ -like '*TikTok từ chối*' }).Count 1 'one failure toast'
    Assert-Equal @($toasts | Where-Object { $_ -like '*Đã gửi 2, lỗi 1, chưa gửi 0*' }).Count 1 'final toast'
}
Test-Case 'background run: Stop sends nothing more and reports what is left' {
    $w = New-TestWorld -Names @(); $script:spreadRun = $null
    $rows = New-Rows $w.A.path 3
    $script:launched = 0
    [void](Start-TikTokSpreadBackground -Rows $rows -Account 'anna' -Caption 'c' -Launcher { param($r, $p) $script:launched++; New-Proc } -Verifier $okVerifier -HistoryReader $noHistory -NoTimer)
    Invoke-SpreadRunTick -Now $now
    $script:TestLog.Clear()
    Stop-SpreadBackground
    1..3 | ForEach-Object { Invoke-SpreadRunTick -Now $now }
    Assert-Equal $script:launched 1 'only the first video was launched'
    Assert-True ($null -eq $script:spreadRun) 'cleared'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*Đã dừng rải lịch. Đã gửi 1, lỗi 0, chưa gửi 2*' }).Count -eq 1) 'stop toast'
}
Complete-Tests
