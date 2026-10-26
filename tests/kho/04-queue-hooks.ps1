# A4 (download target hook in Register-QueueOutcome / queue starts) and A5 (importBusy refusals), with the real functions and stubbed UI.
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$root = $tmp
$ui = @{ TxtOut = [pscustomobject]@{ Text = $tmp } }
$guid = 'c-0123456789abcdef0123456789abcdef'

# stubs for everything UI / engine the functions under test touch
$script:rowUpdates = New-Object System.Collections.Generic.List[object]
function Get-SyncInfo { return [pscustomobject]@{ Text = ''; Warn = $false } }
function Update-QueueRow { param($QueueIdx, $Changes) $script:rowUpdates.Add($Changes); return $true }
function Update-ActionBar { }
function Update-RejectedDashboard { }
function Show-Page { param($Name) }
function Initialize-QueueRows { param($Links, $Skipped, $Origin, $RedoFile) }
function Clear-LogBatch { }
function Get-RejectedReels { param($Root) return @() }
function Get-RejectedLinkMatches { param($Links, $Rejected) return @() }
function Get-FacebookVideoId { param($Url) if ($Url -match '/reel/(\d+)') { return $Matches[1] } return '' }
$script:linkStarted = 0
function Start-Link { $script:linkStarted++ }
function Start-Engine { throw 'Start-Engine must not run in these tests' }
$script:runLog = New-Object System.Collections.ArrayList

function Reset-State {
    $script:khoRegistry = New-KhoRegistryObject; $script:khoRegistry.libraries = @($script:khoRegistry.libraries) + (New-KhoLibrary -Id $guid -Name 'Test')   # the target kho is registered (unregistered ids are skipped)
    $script:khoRegistryReady = $true; $script:khoDownloadTarget = 'default'; $script:importBusy = $false
    $script:queueKhoId = $null; $script:queue = @(); $script:idx = 0; $script:ps = $null; $script:stopping = $false; $script:cancelRequested = $false
    $script:giu = 0; $script:bo = 0; $script:loi = 0; $script:chuaXN = 0; $script:boTruoc = 0; $script:failedLinks = @(); $script:currentResult = $null
    $script:redoRestoreOutDir = $null; $script:lastOut = ''; $script:settingsLoading = $false; $script:lastCompletedOut = ''
    $script:rowUpdates.Clear(); $script:TestLog.Clear(); $script:linkStarted = 0
    Remove-Item -LiteralPath (Join-Path $root 'data') -Recurse -Force -ErrorAction SilentlyContinue   # fresh kho.json per case
}
function New-Out { $d = New-TestDir; $ui.TxtOut.Text = $d; return $d }
function Invoke-Outcome {
    param([hashtable]$Outcome)
    $script:queue = @('https://www.facebook.com/reel/1/'); $script:idx = 0; $script:queueFinalizedIdx = -1
    Register-QueueOutcome $Outcome
}
function Test-NoEntry { param($Out, $Id) $f = Join-Path $Out 'reup-status.json'; return (-not [IO.File]::Exists($f) -or $null -eq (Read-TestJson $f).PSObject.Properties[$Id]) }

Test-Case 'saved outcome with a custom target creates a minimal entry with that Kho' {
    Reset-State; $out = New-Out
    $script:queueKhoId = $guid
    Invoke-Outcome @{ Kind = 'saved'; Video = (Join-Path $out '111-3-hoan-chinh.mp4') }
    $e = (Read-TestJson (Join-Path $out 'reup-status.json')).'111'
    Assert-Equal $e.Kho $guid; Assert-Equal $e.Posted $false; Assert-Equal $e.Date ''
    Assert-True ($null -eq $e.PSObject.Properties['KhoManual']) 'download assignment is not a manual choice'
    Assert-Equal $script:giu 1 'queue counter still advanced'
    Assert-Equal $script:rowUpdates[0].Status 'ok'
}

Test-Case 'every non-saved outcome (failed / unverified / rejected / skipped / cancelled) creates no entry' {
    Reset-State; $out = New-Out
    $script:queueKhoId = $guid
    foreach ($o in @(
        @{ Kind = 'failed'; Video = (Join-Path $out '1-3-hoan-chinh.mp4'); Reason = 'x'; Message = 'loi' },
        @{ Kind = 'failed'; Status = 'unverified'; Video = (Join-Path $out '1-3-hoan-chinh.mp4'); Message = 'chua xac nhan' },
        @{ Kind = 'rejected'; Video = '' },
        @{ Kind = 'skipped'; Video = '' },
        @{ Kind = 'cancelled'; Video = (Join-Path $out '1-3-hoan-chinh.mp4') })) {
        Invoke-Outcome $o
    }
    Assert-True (-not [IO.File]::Exists((Join-Path $out 'reup-status.json'))) 'reup-status.json must not even be created'
}

Test-Case 'default target, null target (redo / record again) and unknown shapes assign nothing' {
    Reset-State; $out = New-Out
    foreach ($target in 'default', '', $null) {
        $script:queueKhoId = $target
        Invoke-Outcome @{ Kind = 'saved'; Video = (Join-Path $out '222-3-hoan-chinh.mp4') }
    }
    Assert-True (Test-NoEntry $out '222') 'no entry'
}

Test-Case 'never overrides an account kho, a manual choice or the manual-default tombstone' {
    Reset-State; $out = New-Out
    Write-TestMetadata $out @{
        '1' = [ordered]@{ Posted = $true; Date = ''; Kho = 'acct:anna' }
        '2' = [ordered]@{ Posted = $false; Date = ''; Kho = 'default'; KhoManual = $true }
        '3' = [ordered]@{ Posted = $false; Date = ''; KhoManual = $true }
    }
    $before = [IO.File]::ReadAllText((Join-Path $out 'reup-status.json'))
    $script:queueKhoId = $guid
    foreach ($id in 1..3) { Invoke-Outcome @{ Kind = 'saved'; Video = (Join-Path $out "$id-3-hoan-chinh.mp4") } }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $out 'reup-status.json'))) $before 'file unchanged byte for byte'
}

Test-Case 'normal queue then redo: the redo does not touch the kho; a re-download never overrides' {
    Reset-State; $out = New-Out
    Set-KhoDownloadTarget -Id (New-Kho -Name 'Đích').id
    $first = @((Get-KhoRegistry).libraries)[-1].id
    $script:queue = @(); $script:ps = $null
    Start-QueueFromLinks -Links @('https://www.facebook.com/reel/333/') -SkipExisting $true
    Assert-Equal $script:queueKhoId $first 'normal queue captures the combo value'
    Invoke-Outcome @{ Kind = 'saved'; Video = (Join-Path $out '333-3-hoan-chinh.mp4') }
    Assert-Equal (Read-TestJson (Join-Path $out 'reup-status.json')).'333'.Kho $first
    # the user moves it by hand to another kho, then records it again
    $other = New-Kho -Name 'Khác'
    [void](Set-VideoKho -VideoIds @('333') -KhoId $other.id -Manual -OutDir $out)
    $script:queue = @(); $script:stopping = $false
    $script:lastOut = Join-Path $out '333-3-hoan-chinh.mp4'; [IO.File]::WriteAllText($script:lastOut, 'x')
    Start-RecordingAgain
    Assert-True ($null -eq $script:queueKhoId) 'record again clears the target'
    Invoke-Outcome @{ Kind = 'saved'; Video = $script:lastOut }
    $e = (Read-TestJson (Join-Path $out 'reup-status.json')).'333'
    Assert-Equal $e.Kho $other.id 'manual kho kept'
    # a later normal queue run of the same id (re-download) still does not override
    $script:queueKhoId = $first
    Invoke-Outcome @{ Kind = 'saved'; Video = $script:lastOut }
    Assert-Equal (Read-TestJson (Join-Path $out 'reup-status.json')).'333'.Kho $other.id
}

Test-Case 'a failing assignment (corrupt reup-status.json) is logged and the queue outcome still registers' {
    Reset-State; $out = New-Out
    [IO.File]::WriteAllText((Join-Path $out 'reup-status.json'), '{ broken')
    $script:queueKhoId = $guid
    Invoke-Outcome @{ Kind = 'saved'; Video = (Join-Path $out '444-3-hoan-chinh.mp4') }
    Assert-Equal $script:giu 1; Assert-Equal $script:rowUpdates[0].Status 'ok'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '[[]Warning]*chưa gán được*' }).Count -eq 1) 'one visible warning'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $out 'reup-status.json'))) '{ broken' 'corrupt file untouched'
}

Test-Case 'a video file name that is not <id>-3-hoan-chinh.mp4 is logged, not thrown' {
    Reset-State; $out = New-Out
    $script:queueKhoId = $guid
    Invoke-Outcome @{ Kind = 'saved'; Video = (Join-Path $out 'weird.mp4') }
    Assert-Equal $script:giu 1
    Assert-True (@($script:TestLog | Where-Object { $_ -like '[[]Warning]*' }).Count -eq 1)
}

Test-Case 'queue start (Start-QueueFromLinks) records the combo value; default target gives ''default''' {
    Reset-State; $out = New-Out
    Start-QueueFromLinks -Links @('https://www.facebook.com/reel/555/') -SkipExisting $true
    Assert-Equal $script:queueKhoId 'default'
    Assert-Equal $script:linkStarted 1
}

Test-Case 'A5: importBusy makes queue start, record again, re-edit and kho delete refuse; Start-Link never runs' {
    Reset-State; $out = New-Out
    $k = New-Kho -Name 'Không xóa lúc nhập'
    $script:importBusy = $true
    $script:queueKhoId = 'c-sentinel'
    Start-QueueFromLinks -Links @('https://www.facebook.com/reel/666/') -SkipExisting $true
    Assert-Equal @($script:queue).Count 0 'queue stays empty'
    Assert-Equal $script:queueKhoId 'c-sentinel' 'target untouched'
    $script:lastOut = Join-Path $out '666-3-hoan-chinh.mp4'; [IO.File]::WriteAllText($script:lastOut, 'x')
    Start-RecordingAgain
    Assert-Equal @($script:queue).Count 0
    Assert-True ($null -eq $script:redoRestoreOutDir) 'record again changed nothing'
    Start-Reedit   # would call Start-Engine (stub throws) if it did not refuse
    Assert-Equal $script:linkStarted 0
    Assert-Throws { Remove-Kho -Id $k.id -OutDir $out } '*Đang thêm video*'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '[[]toast]*Đang thêm video từ thư mục*' }).Count -eq 3) 'three refusals told the owner'
}

Test-Case 'A5: busy predicates and Test-KhoImportBlocked' {
    Reset-State
    Assert-True (-not (Test-GalleryActionsBusy)); Assert-True (-not (Test-AppBusy)); Assert-Equal (Test-KhoImportBlocked) ''
    $script:importBusy = $true
    Assert-True (Test-GalleryActionsBusy) 'gallery actions busy'; Assert-True (Test-AppBusy) 'app busy'
    Assert-True ((Test-KhoImportBlocked) -like '*khác*') 'second import refused'
    $script:importBusy = $false
    $script:ps = [pscustomobject]@{}
    Assert-True ((Test-KhoImportBlocked) -like '*hàng đợi*') 'engine running'
    $script:ps = $null; $script:queue = @('x')
    Assert-True ((Test-KhoImportBlocked) -like '*hàng đợi*') 'queue running'
    $script:queue = @(); $script:stopping = $true
    Assert-True ((Test-KhoImportBlocked) -like '*hàng đợi*') 'stopping'
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
