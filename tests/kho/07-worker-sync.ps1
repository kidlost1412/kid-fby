# The real TikTok worker (full sync + fast status) run in a restricted runspace against a fake local backend:
# kho auto-assignment inside the sync, A2 end to end, and completeness of $script:tikTokWorkerFunctions.
. (Join-Path $PSScriptRoot '_load.ps1')
. (Join-Path $PSScriptRoot 'FakeBackend.ps1')
$out = New-TestDir
$server = Start-FakeBackend
$base = $server.Url
$hex = { param($n) ('{0:x32}' -f [long]$n) }

function New-Mp4 { param([string]$Id) [IO.File]::WriteAllText((Join-Path $out "$Id-3-hoan-chinh.mp4"), "video $Id") }
function New-Payload { param($Last = $null) return @{ out_dir = $out; receipts = @(); last_input_sig = $(if ($Last) { [string]$Last.InputSig } else { '' }); last_file_stamp = $(if ($Last) { [string]$Last.FileStamp } else { '' }); probe_cursor = ''; identity_cache = $null; file = $null } }
function Read-Status { return (Read-TestJson (Join-Path $out 'reup-status.json')) }

try {
    foreach ($id in 101..108) { New-Mp4 "$id" }
    $anna1 = New-TestHistoryEntry -Request (& $hex 1) -User 'Anna' -Accepted '2026-10-20T10:00:00Z' -Created '2026-10-20T09:00:00Z'
    $annaEarly = New-TestHistoryEntry -Request (& $hex 3) -User 'Anna' -Accepted '2026-10-19T10:00:00Z' -Created '2026-10-19T09:00:00Z'
    $bobLate = New-TestHistoryEntry -Request (& $hex 33) -User 'Bob' -Accepted '2026-10-21T10:00:00Z' -Created '2026-10-21T09:00:00Z'
    $server.Rows['101'] = ConvertTo-EntriesJson @($anna1)
    $server.Rows['102'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 2) -User 'Anna' -Status 'pending' -Accepted ''))
    $server.Rows['103'] = ConvertTo-EntriesJson @($bobLate, $annaEarly)
    $server.Rows['104'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 4) -User 'Bob'))
    $server.Rows['105'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 5) -User 'Carl'))
    # 106: no history. 107/108: used below.
    Write-TestMetadata $out @{
        '104' = [ordered]@{ Posted = $false; Date = ''; KhoManual = $true }
        '105' = [ordered]@{ Posted = $false; Date = ''; Kho = 'acct:zed' }
    }

    $script:first = $null
    Test-Case 'full sync: confirmed videos join their account kho inside the same write; others stay untouched' {
        $run = Invoke-Worker 'sync' (New-Payload) $base
        Assert-Equal $run.Errors.Count 0 "worker errors: $($run.Errors -join ' | ')"
        $script:first = $run.Result
        Assert-True $run.Result.Changed 'Changed'
        $m = Read-Status
        Assert-Equal $m.'101'.Kho 'acct:anna'; Assert-Equal $m.'101'.Posted $true
        Assert-True ($null -eq $m.'102'.PSObject.Properties['Kho']) 'pending stays unassigned'; Assert-Equal $m.'102'.Posted $false
        Assert-Equal $m.'103'.Kho 'acct:anna' 'earliest accepted_at wins'
        Assert-True ($null -eq $m.'104'.PSObject.Properties['Kho']) 'KhoManual video not moved'; Assert-Equal $m.'104'.KhoManual $true; Assert-Equal @($m.'104'.History).Count 1 'but its history is stored'
        Assert-Equal $m.'105'.Kho 'acct:zed' 'existing account kho kept'
        Assert-True ($null -eq $m.PSObject.Properties['106']) 'no history -> no entry'
    }

    Test-Case 'steady state: the same pass again is skipped (no write); a backend change is picked up and assigned' {
        $stamp = (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc
        $run = Invoke-Worker 'sync' (New-Payload $script:first) $base
        Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
        Assert-True $run.Result.Skipped 'skipped'
        Assert-Equal (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc $stamp 'file untouched'
        $server.Rows['102'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 2) -User 'Anna' -Accepted '2026-10-22T10:00:00Z'))
        $run = Invoke-Worker 'sync' (New-Payload $script:first) $base
        Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
        Assert-True (-not $run.Result.Skipped) 'not skipped'
        Assert-Equal (Read-Status).'102'.Kho 'acct:anna'
    }

    Test-Case 'A2 end to end: a stale pending answer from the backend does not undo a stored success' {
        Write-TestMetadata $out @{}
        $done = New-TestHistoryEntry -Request (& $hex 8) -User 'Anna' -Accepted '2026-10-20T10:00:00Z'
        $server.Rows['108'] = ConvertTo-EntriesJson @($done)
        [void](Invoke-Worker 'sync' (New-Payload) $base)
        Assert-Equal (Read-Status).'108'.History[0].status 'succeeded' 'precondition'
        $server.Rows['108'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request (& $hex 8) -User 'Anna' -Status 'pending' -Accepted ''))
        $run = Invoke-Worker 'sync' (New-Payload) $base
        Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
        $e = (Read-Status).'108'
        Assert-Equal $e.History[0].status 'succeeded'; Assert-Equal $e.Posted $true; Assert-Equal $e.Kho 'acct:anna'
        # and the receipt of that very request does not add a second "preparing" line
        $receipt = [pscustomobject]@{ RequestId = (& $hex 8); VideoId = '108'; Username = 'Anna'; ScheduledFor = ''; Status = 'preparing'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; SourceSha256 = ''; UploadSha256 = ''; WorkerAlive = $true }
        $payload = New-Payload; $payload.receipts = @($receipt)
        $run = Invoke-Worker 'sync' $payload $base
        Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
        Assert-Equal @((Read-Status).'108'.History).Count 1 'still one entry'
    }

    Test-Case 'fast status: an active entry confirmed by the job endpoint is updated and assigned in one write' {
        Write-TestMetadata $out @{
            '107' = [ordered]@{ Posted = $false; Date = ''; Source = 'autotok-history'; History = @((New-TestHistoryEntry -Request (& $hex 7) -User 'Dana' -Status 'pending' -Accepted '')); ManualPosted = $false; ManualDate = '' }
        }
        $server.Jobs[(& $hex 7)] = (ConvertTo-Json -Compress @{ status = 'succeeded'; publish_uncertain = $false; prior_uncertain = $false; username = 'Dana'; planned_for = ''; accepted_at = '2026-10-23T10:00:00Z'; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now'; time_source = 'backend' })
        $run = Invoke-Worker 'fast' @{ out_dir = $out; last_stamp = ''; active = $null; cursor = '' } $base
        Assert-Equal $run.Errors.Count 0 "worker errors: $($run.Errors -join ' | ')"
        Assert-True $run.Result.Changed 'Changed'
        $e = (Read-Status).'107'
        Assert-Equal $e.History[0].status 'succeeded'; Assert-Equal $e.Posted $true; Assert-Equal $e.Kho 'acct:dana'
        Assert-Equal @($run.Result.Active).Count 0 'no active entries left'
    }

    Test-Case 'fast status never downgrades: the job says running but the stored entry is already succeeded -> nothing is written' {
        # The fast pass only asks about active entries, so make the stored entry active in the poll list the way a race would.
        Write-TestMetadata $out @{
            '107' = [ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = @((New-TestHistoryEntry -Request (& $hex 7) -User 'Dana')); ManualPosted = $false; ManualDate = ''; Kho = 'acct:dana' }
        }
        $server.Jobs[(& $hex 7)] = (ConvertTo-Json -Compress @{ status = 'running'; publish_uncertain = $false; prior_uncertain = $false; username = 'Dana'; planned_for = ''; accepted_at = ''; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' })
        $stamp = (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc
        $active = @(@{ VideoId = '107'; RequestId = (& $hex 7) })
        $run = Invoke-Worker 'fast' @{ out_dir = $out; last_stamp = (Get-FileStamp (Join-Path $out 'reup-status.json')); active = $active; cursor = '' } $base
        Assert-Equal $run.Errors.Count 0 "worker errors: $($run.Errors -join ' | ')"
        Assert-Equal $run.Result.Polled 1 'the job endpoint was asked'
        Assert-True (-not $run.Result.Changed) 'nothing written'
        Assert-Equal (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc $stamp 'file untouched'
        Assert-Equal (Read-Status).'107'.History[0].status 'succeeded'
    }
} finally {
    $server.Stop()
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Tests
