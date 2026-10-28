# Independent QA (kiem-dinh) round 2: the GUI's Chrome profile picker (Local State) and its automatic save.
# Requirement: the app opens the RIGHT Chrome profile for a due job; reading Chrome's Local State never blocks or crashes the UI.
# Temp files and the real WPF list builder only; no backend, no real Chrome data.
. (Join-Path $PSScriptRoot '_load.ps1')
Add-Type -AssemblyName PresentationFramework
function Start-ChromeTimer { }   # the queue is inspected, never run
$script:win = New-Object Windows.Window   # styles the list builder looks up (empty: no theme needed here)
foreach ($k in 'TextMutedStyle', 'BtnGhost', 'BtnPrimary') { $script:win.Resources[$k] = New-Object Windows.Style }
function New-QaLocalState {
    param([string]$Json)
    $d = Join-Path ([IO.Path]::GetTempPath()) ('kd-ls-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $d)
    $p = Join-Path $d 'Local State'
    [IO.File]::WriteAllText($p, $Json, (New-Object Text.UTF8Encoding($false)))
    return $p
}
function New-QaClient { param([int]$Id, [string]$User)
    return [pscustomobject]@{ id = $Id; label = 'Chrome'; tiktok_username = $User; tiktok_user_id = "u$Id"; status = 'ok'; has_identity = $true
        conflict = $false; need_reload = $false; online = $true; last_seen_at = ''; ext_version = '1.0.0'; chrome_profile_dir = $null }
}
function Invoke-QaBuild {
    # The real Update-ChromeLists with two paired Chromes whose profile is not saved yet.
    param([object[]]$Clients, [string]$LocalState)
    $script:qaLocalState = $LocalState
    $script:ui = @{ ListChromeClients = (New-Object Windows.Controls.StackPanel); ListChromeAccounts = (New-Object Windows.Controls.StackPanel) }
    $script:chromeUi = @{ Task = $null; Op = $null; Ops = (New-Object System.Collections.ArrayList); Timer = $null; LastPoll = [DateTime]::MinValue
        Clients = $Clients; Accounts = @(); ChromeOk = $true; Tried = @{}; ProfileTried = @{}; Deferred = @{}; ReloadToasted = $false; PairExpires = ''; PairClients = 0; Building = $false }
    $null = Update-ChromeLists
    return @($script:chromeUi.Ops | Where-Object { $_.Kind -eq 'set-profile' })
}
function Get-ChromeLocalStatePath { return $script:qaLocalState }

$twoProfiles = '{"profile":{"last_used":"Profile 1","info_cache":{"Profile 1":{"name":"Shop A"},"Profile 2":{"name":"Shop B"}}}}'

Test-Case 'two paired Chromes (two profiles), nothing saved yet: the guess "last_used" is NOT saved for both - one of them is certainly wrong' {
    $ops = @(Invoke-QaBuild @((New-QaClient 1 'shop.a'), (New-QaClient 2 'shop.b')) (New-QaLocalState $twoProfiles))
    $dirs = @($ops | ForEach-Object { [string]$_.Payload.chrome_profile_dir })
    Assert-True (@($dirs | Where-Object { $_ -eq 'Profile 1' }).Count -le 1) "both Chromes were saved as 'Profile 1': $($dirs -join ',')"
}
Test-Case 'one paired Chrome, one profile: the only profile is saved automatically (normal single-profile owner)' {
    $ops = @(Invoke-QaBuild @((New-QaClient 1 'shop.a')) (New-QaLocalState '{"profile":{"last_used":"Default","info_cache":{"Default":{"name":"Me"}}}}'))
    Assert-Equal $ops.Count 1
    Assert-Equal ([string]$ops[0].Payload.chrome_profile_dir) 'Default'
}
Test-Case 'Local State that is not valid UTF-8 JSON / huge / deeply odd: the list still builds, no exception reaches the UI' {
    $big = '{"profile":{"last_used":"Default","info_cache":{"Default":{"name":"Me"}}},"pad":"' + ('x' * 3000000) + '"}'
    foreach ($json in @($big, '{"profile":{"info_cache":{"Default":null,"Profile 1":"str","Profile 2":[1,2]}}}', '{"profile":{"info_cache":[]}}', ([string][char]0xFFFD * 10))) {
        [void](Invoke-QaBuild @((New-QaClient 1 'shop.a')) (New-QaLocalState $json))
        Assert-True ($script:ui.ListChromeClients.Children.Count -ge 1) 'list built'
    }
}
Complete-Tests
