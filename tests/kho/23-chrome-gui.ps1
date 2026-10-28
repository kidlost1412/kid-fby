# Chrome publisher in the GUI: status labels, readiness filter (old and new backend), automatic switch to Chrome (default publisher),
# error texts, and the background 'ext' worker action against a FAKE local backend (no real service, no real data).
. (Join-Path $PSScriptRoot '_load.ps1')
function Acct { param([int]$Id, [string]$User, [string]$Publisher = 'cookies', $Ready = $null, [string]$Reason = '', [bool]$Session = $true)
    $o = [ordered]@{ id = $Id; username = $User; has_valid_session = $Session }
    if ($Publisher) { $o.publisher = $Publisher }
    if ($null -ne $Ready) { $o.ready = [bool]$Ready; $o.ready_reason = $Reason }
    return [pscustomobject]$o
}
function Cl { param([int]$Id, [string]$User, [string]$Status = 'ok', [bool]$Identity = $true, [bool]$Conflict = $false)
    return [pscustomobject]@{ id = $Id; label = 'Chrome'; tiktok_username = $User; tiktok_user_id = "u$Id"; status = $Status; has_identity = $Identity; conflict = $Conflict; need_reload = ($Status -eq 'need_reload'); online = ($Status -eq 'ok') }
}

# ---------------------------------------------------------------- status labels ----
Test-Case 'pending_ext / waiting_ext have their own Vietnamese text everywhere (never "Đăng thất bại")' {
    Assert-Equal (Get-TikTokStatusText ([pscustomobject]@{ status = 'pending_ext' })) 'Chờ Chrome: mở Chrome có tiện ích để đăng.'
    Assert-Equal (Get-TikTokStatusText ([pscustomobject]@{ status = 'waiting_ext' })) 'Chrome đang đăng video lên TikTok…'
    $now = [pscustomobject]@{ status = 'pending_ext'; schedule_mode = 'now'; planned_for = '' }
    Assert-Equal (Get-TikTokEntryLabel $now) 'Chờ Chrome'
    Assert-Equal (Get-TikTokEntryLabel ([pscustomobject]@{ status = 'waiting_ext'; schedule_mode = 'now' })) 'Chrome đang đăng…'
    Assert-Equal (Get-TikTokEntryShort ([pscustomobject]@{ status = 'pending_ext' })) 'Chờ Chrome'
    Assert-Equal (Get-TikTokEntryShort ([pscustomobject]@{ status = 'waiting_ext' })) 'Chrome đang đăng'
}
Test-Case 'native schedule: label keeps the planned clock (hand-computed 19:00 25/10 is local time of 2026-10-25T12:00:00Z in UTC+7)' {
    $e = [pscustomobject]@{ status = 'waiting_ext'; schedule_mode = 'native'; tiktok_schedule_time = '2026-10-25T12:00:00Z' }
    $expected = 'Chrome đang đăng · hẹn ' + ([DateTimeOffset]::Parse('2026-10-25T12:00:00Z').ToLocalTime().ToString('HH:mm dd/MM'))
    Assert-Equal (Get-TikTokEntryLabel $e) $expected
}
Test-Case 'the new states are "active": block the account, are asked about by the fast pass, never downgrade a stored success' {
    $act = Get-TikTokActiveStatuses
    foreach ($s in 'pending', 'queued', 'running', 'preparing', 'pending_ext', 'waiting_ext') { Assert-True ($act -contains $s) "missing $s" }
    Assert-True (-not ($act -contains 'succeeded')) 'succeeded is not active'
    Assert-True (Test-TikTokStaleDowngrade ([pscustomobject]@{ status = 'succeeded' }) 'waiting_ext') 'stale waiting_ext after success'
    Assert-True (-not (Test-TikTokStaleDowngrade ([pscustomobject]@{ status = 'failed' }) 'waiting_ext')) 'failed may be retried'
}
Test-Case 'a waiting_ext post counts as a busy slot for the account (same as running)' {
    $today = [DateTime]::Now.Date.AddHours(12)
    $meta = [pscustomobject]@{ v1 = [pscustomobject]@{ History = @([pscustomobject]@{ username = 'anna'; key = 'k1'; status = 'waiting_ext'; planned_for = $today.ToUniversalTime().ToString('o'); tiktok_schedule_time = $today.ToUniversalTime().ToString('o') }) } }
    $busy = @(Get-TikTokBusyTimes -Metadata $meta -Account 'anna' -Now ([DateTime]::Now.Date.AddHours(8)))
    Assert-Equal $busy.Count 1
}

# ---------------------------------------------------------------- readiness filter ----
Test-Case 'new backend: filter uses `ready` (a Chrome account with no cookie session is selectable; a cookie account with session but ready=false is not)' {
    $list = @((Acct 1 'chromeonly' 'chrome' $true 'ok' $false), (Acct 2 'offline' 'chrome' $false 'chrome_offline' $false), (Acct 3 'cookie' 'cookies' $true 'ok' $true), (Acct 4 'odd' 'cookies' $false 'no_session' $true))
    Assert-Equal ((Select-TikTokReadyAccounts $list | ForEach-Object username) -join ',') 'chromeonly,cookie'
}
Test-Case 'old backend (no ready/publisher fields): falls back to has_valid_session' {
    $list = @((Acct 1 'a' '' $null '' $true), (Acct 2 'b' '' $null '' $false))
    Assert-Equal ((Select-TikTokReadyAccounts $list | ForEach-Object username) -join ',') 'a'
    Assert-Equal (Get-TikTokAccountNote $list[1]) 'chưa đăng nhập'
    Assert-Equal (Get-TikTokAccountNote $list[0]) ''
}
Test-Case 'edge: empty / null list gives an empty result (not one null element)' {
    Assert-Equal (@(Select-TikTokReadyAccounts @()).Count) 0
    Assert-Equal (@(Select-TikTokReadyAccounts $null).Count) 0
}
Test-Case 'ready_reason texts (Vietnamese) for every Chrome reason' {
    Assert-Equal (Get-TikTokReadyReasonText 'chrome_offline') 'Chrome chưa mở/chưa bật tiện ích'
    Assert-True ((Get-TikTokReadyReasonText 'chrome_conflict') -like 'Có hai hồ sơ Chrome cùng tài khoản này*') 'conflict'
    Assert-True ((Get-TikTokReadyReasonText 'chrome_need_reload') -like 'Cần tải lại tiện ích*') 'need_reload'
    Assert-True ((Get-TikTokReadyReasonText 'chrome_unbound') -like 'Chưa gắn với Chrome nào*') 'unbound'
    Assert-Equal (Get-TikTokAccountNote (Acct 5 'x' 'chrome' $false 'chrome_offline' $false)) 'Chrome chưa mở/chưa bật tiện ích'
    Assert-Equal (Get-TikTokAccountNote (Acct 6 'x' 'chrome' $false 'something_new' $false)) 'Chrome chưa sẵn sàng'
}
Test-Case 'no ready account: the message names each account and its reason' {
    $t = Get-TikTokNoReadyAccountsText @((Acct 1 'anna' 'chrome' $false 'chrome_offline' $false))
    Assert-Equal $t 'Chưa có tài khoản sẵn sàng. @anna: Chrome chưa mở/chưa bật tiện ích'
}

# ---------------------------------------------------------------- automatic switch to Chrome (default publisher) ----
Test-Case 'auto-switch: a cookie account whose username a healthy Chrome reports is planned, once (Tried blocks the repeat)' {
    $tried = @{}
    $plan = @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'Anna')) -Clients @((Cl 3 'anna')) -CookieChoice @() -Tried $tried)
    Assert-Equal $plan.Count 1; Assert-Equal $plan[0].Client.id 3; Assert-Equal $plan[0].Account.id 7
    $tried['7'] = $true
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'Anna')) -Clients @((Cl 3 'anna')) -CookieChoice @() -Tried $tried).Count 0 'second look'
}
Test-Case 'auto-switch: after the switch the account is publisher=chrome, so a new session plans nothing either' {
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'anna' 'chrome')) -Clients @((Cl 3 'anna'))).Count 0
}
Test-Case 'auto-switch: an account the owner put back on Cookie (id stored) is never switched, others still are' {
    $plan = @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'anna'), (Acct 8 'bob')) -Clients @((Cl 3 'anna'), (Cl 4 'bob')) -CookieChoice @(7))
    Assert-Equal $plan.Count 1; Assert-Equal $plan[0].Account.username 'bob'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'anna')) -Clients @((Cl 3 'anna')) -CookieChoice @('7')).Count 0 'string id from settings.json'
}
Test-Case 'auto-switch: username mismatch is not switched (needs the owner confirmation)' {
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'annalabel')) -Clients @((Cl 3 'anna'))).Count 0
}
Test-Case 'auto-switch: conflict (two profiles, same user), offline, need_reload, no identity and two matching clients are not switched' {
    $a = @((Acct 7 'anna'))
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts $a -Clients @((Cl 3 'anna' 'conflict' $true $true), (Cl 4 'anna' 'conflict' $true $true))).Count 0 'conflict'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts $a -Clients @((Cl 3 'anna' 'ok'), (Cl 4 'anna' 'conflict' $true $true))).Count 0 'one ok one conflict'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts $a -Clients @((Cl 3 'anna' 'offline'))).Count 0 'offline'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts $a -Clients @((Cl 3 'anna' 'need_reload'))).Count 0 'need_reload'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts $a -Clients @((Cl 3 'anna' 'no_identity' $false))).Count 0 'no identity'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts $a -Clients @((Cl 3 'anna'), (Cl 4 'anna'))).Count 0 'two ok clients'
}
Test-Case 'auto-switch: old backend (no publisher field) and accounts without a Chrome stay as they are' {
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'anna' '')) -Clients @((Cl 3 'anna'))).Count 0 'old backend'
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'anna')) -Clients @()).Count 0 'no clients'
}
Test-Case 'manual choice: Chrome by username; mismatch flagged when only one other Chrome; errors in Vietnamese' {
    $p = Select-ChromeClientForAccount (Acct 7 'anna') @((Cl 3 'anna'), (Cl 4 'bob'))
    Assert-Equal $p.Client.id 3; Assert-Equal $p.Mismatch $false
    $p = Select-ChromeClientForAccount (Acct 7 'label') @((Cl 4 'bob'))
    Assert-Equal $p.Client.id 4; Assert-Equal $p.Mismatch $true
    Assert-True ((Select-ChromeClientForAccount (Acct 7 'label') @((Cl 4 'bob'), (Cl 5 'carl'))).Error -like 'Không có Chrome nào đăng nhập TikTok tên @label*') 'two others'
    Assert-True ((Select-ChromeClientForAccount (Acct 7 'x') @()).Error -like 'Chưa có Chrome nào*') 'none'
}

# ---------------------------------------------------------------- client list texts, errors, countdown ----
Test-Case 'client status, last seen, need_reload' {
    Assert-Equal (Get-ChromeClientStatusText (Cl 1 'a' 'offline')) 'Chrome chưa mở'
    Assert-Equal (Get-ChromeClientStatusText (Cl 1 'a' 'conflict')) 'Trùng tài khoản với Chrome khác'
    $now = [DateTime]::Parse('2026-10-27T10:00:00Z').ToUniversalTime()
    Assert-Equal (Format-ChromeLastSeen '2026-10-27T09:59:30Z' $now) 'vừa xong'
    Assert-Equal (Format-ChromeLastSeen '2026-10-27T09:55:00Z' $now) '5 phút trước'
    Assert-Equal (Format-ChromeLastSeen '' $now) 'chưa thấy'
    Assert-True (Test-ChromeNeedReload @((Cl 1 'a'), (Cl 2 'b' 'need_reload'))) 'one old'
    Assert-True (-not (Test-ChromeNeedReload @((Cl 1 'a')))) 'none'
    Assert-True (-not (Test-ChromeNeedReload @())) 'empty'
}
Test-Case 'pairing countdown: 5 min = 300 s, rounds up, never negative' {
    $now = [DateTime]::Parse('2026-10-27T10:00:00Z').ToUniversalTime()
    Assert-Equal (Get-ChromePairCodeRemaining '2026-10-27T10:05:00Z' $now) 300
    Assert-Equal (Get-ChromePairCodeRemaining '2026-10-27T10:00:00.4Z' $now) 1
    Assert-Equal (Get-ChromePairCodeRemaining '2026-10-27T09:00:00Z' $now) 0
    Assert-Equal (Get-ChromePairCodeRemaining 'garbage' $now) 0
}
Test-Case 'backend refusals become Vietnamese (already-Vietnamese detail kept, English mapped, status fallback)' {
    Assert-Equal (Get-ChromeApiErrorText 409 '{"detail":"Chrome này đang không kết nối — mở Chrome rồi thử lại"}') 'Chrome này đang không kết nối — mở Chrome rồi thử lại'
    Assert-Equal (Get-ChromeApiErrorText 409 '{"detail":"account with that username already exists"}') 'Đã có tài khoản trùng tên này.'
    Assert-Equal (Get-ChromeApiErrorText 409 '{"ok":false,"error":"x","message":"Có hai hồ sơ"}') 'Có hai hồ sơ'
    Assert-Equal (Get-ChromeApiErrorText 403 'not json') 'Bộ đăng từ chối yêu cầu này.'
    Assert-Equal (Get-ChromeApiErrorText 500 '') 'Bộ đăng trả về lỗi 500.'
}

# ---------------------------------------------------------------- the background 'ext' action against a fake backend ----
function Start-FakeBackend {
    # Serves $Routes (key "METHOD /path" -> @{Status; Body}) on a free port; records every request. Returns @{ Listener; Port; Seen }.
    param([hashtable]$Routes, [int]$Count)
    $tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start(); $port = $tcp.LocalEndpoint.Port; $tcp.Stop()
    $l = [Net.HttpListener]::new(); $l.Prefixes.Add("http://127.0.0.1:$port/"); $l.Start()
    return @{ Listener = $l; Port = $port; Seen = (New-Object System.Collections.ArrayList); Routes = $Routes; Count = $Count }
}
function Invoke-ExtAction {
    # Runs the real worker script block with Action 'ext' in a background runspace while this thread serves the fake backend.
    param($Fake, [hashtable]$Payload)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:WorkerBlock.ToString()).AddArgument('ext').AddArgument("http://127.0.0.1:$($Fake.Port)").AddArgument('').AddArgument($Payload).AddArgument('').AddArgument('')
    $async = $ps.BeginInvoke()
    $served = 0
    while ($served -lt $Fake.Count) {
        $ctxTask = $Fake.Listener.BeginGetContext($null, $null)
        if (-not $ctxTask.AsyncWaitHandle.WaitOne(15000)) { break }
        $ctx = $Fake.Listener.EndGetContext($ctxTask)
        $req = $ctx.Request
        $body = ''; if ($req.HasEntityBody) { $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() }
        [void]$Fake.Seen.Add(@{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath; Body = $body; Origin = $req.Headers['Origin']; Csrf = $req.Headers['X-Requested-With'] })
        $route = $Fake.Routes["$($req.HttpMethod) $($req.Url.AbsolutePath)"]
        if (-not $route) { $route = @{ Status = 404; Body = '{"detail":"not found"}' } }
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$route.Body)
        $ctx.Response.StatusCode = [int]$route.Status; $ctx.Response.ContentType = 'application/json; charset=utf-8'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
        $served++
    }
    $result = $null; $err = ''
    try { $result = @($ps.EndInvoke($async)); if ($ps.Streams.Error.Count) { $err = [string]$ps.Streams.Error[0] } } catch { $err = $_.Exception.Message } finally { $ps.Dispose(); $Fake.Listener.Close() }
    return @{ Result = $result; Error = $err }
}
$healthNew = '{"status":"ok","chrome_ext":1,"ext_active":0}'
Test-Case 'ext/set-publisher chrome: PATCH /api/accounts/7 with client_id and confirm=false, no Origin header, CSRF header present' {
    $fake = Start-FakeBackend @{ 'PATCH /api/accounts/7' = @{ Status = 200; Body = '{"id":7,"publisher":"chrome"}' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'set-publisher'; account_id = 7; publisher = 'chrome'; client_id = 3; confirm = $false }
    Assert-Equal $r.Error ''
    Assert-Equal $r.Result[0].ok $true; Assert-Equal $r.Result[0].status 200
    $seen = $fake.Seen[0]
    Assert-Equal $seen.Method 'PATCH'
    $b = $seen.Body | ConvertFrom-Json
    Assert-Equal $b.publisher 'chrome'; Assert-Equal $b.client_id 3; Assert-Equal $b.confirm_username_mismatch $false
    Assert-True ($null -eq $seen.Origin) 'an Origin header would be refused (403) by the backend'
    Assert-Equal $seen.Csrf 'autotok'
}
Test-Case 'ext/set-publisher cookies: body is only {"publisher":"cookies"}' {
    $fake = Start-FakeBackend @{ 'PATCH /api/accounts/7' = @{ Status = 200; Body = '{}' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'set-publisher'; account_id = 7; publisher = 'cookies' }
    $b = $fake.Seen[0].Body | ConvertFrom-Json
    Assert-Equal $b.publisher 'cookies'; Assert-True ($null -eq $b.PSObject.Properties['client_id']) 'no client_id'
}
Test-Case 'ext: a 409 refusal is RETURNED (status + body), not thrown, so the UI can show the Vietnamese reason' {
    $fake = Start-FakeBackend @{ 'POST /api/accounts/from-chrome' = @{ Status = 409; Body = '{"detail":"Chrome này đang không kết nối — mở Chrome rồi thử lại"}' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'from-chrome'; client_id = 3 }
    Assert-Equal $r.Error ''
    Assert-Equal $r.Result[0].ok $false; Assert-Equal $r.Result[0].status 409
    Assert-Equal (Get-ChromeApiErrorText ([int]$r.Result[0].status) ([string]$r.Result[0].text)) 'Chrome này đang không kết nối — mở Chrome rồi thử lại'
    Assert-Equal ($fake.Seen[0].Body | ConvertFrom-Json).client_id 3
}
Test-Case 'ext/refresh on a NEW backend reads /health, clients and accounts' {
    $fake = Start-FakeBackend @{ 'GET /health' = @{ Status = 200; Body = $healthNew }; 'GET /api/ext/clients' = @{ Status = 200; Body = '[{"id":3,"tiktok_username":"anna","status":"ok"}]' }
        'GET /api/accounts' = @{ Status = 200; Body = '[{"id":7,"username":"anna","publisher":"cookies","ready":false,"ready_reason":"chrome_offline"}]' } } 3
    $r = Invoke-ExtAction $fake @{ op = 'refresh' }
    Assert-Equal $r.Error ''
    $x = $r.Result[0]
    Assert-Equal $x.ok $true; Assert-Equal $x.chrome $true
    Assert-Equal @($x.clients | ConvertFrom-Json)[0].tiktok_username 'anna'
    Assert-Equal @($x.accounts | ConvertFrom-Json)[0].ready_reason 'chrome_offline'
}
Test-Case 'ext/refresh on an OLD backend (no chrome_ext in /health): no clients call at all, chrome=false, accounts still read' {
    $fake = Start-FakeBackend @{ 'GET /health' = @{ Status = 200; Body = '{"status":"ok","native_schedule":1}' }; 'GET /api/accounts' = @{ Status = 200; Body = '[{"id":1,"username":"a","has_valid_session":true}]' } } 2
    $r = Invoke-ExtAction $fake @{ op = 'refresh' }
    Assert-Equal $r.Error ''
    Assert-Equal $r.Result[0].chrome $false
    Assert-True (-not (@($fake.Seen | Where-Object { $_.Path -like '/api/ext/*' }).Count)) 'must not call /api/ext on an old backend'
    Assert-True (Test-TikTokAccountReady (@($r.Result[0].accounts | ConvertFrom-Json))[0]) 'falls back to has_valid_session'
}
Test-Case 'ext: remove-client sends DELETE; pair-code sends POST' {
    $fake = Start-FakeBackend @{ 'DELETE /api/ext/clients/5' = @{ Status = 204; Body = '' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'remove-client'; client_id = 5 }
    Assert-Equal $fake.Seen[0].Method 'DELETE'; Assert-Equal $r.Result[0].status 204
    $fake = Start-FakeBackend @{ 'POST /api/ext/pair-code' = @{ Status = 200; Body = '{"code":"123456","expires_at":"2026-10-27T10:05:00Z","valid_s":300}' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'pair-code' }
    Assert-Equal ($r.Result[0].text | ConvertFrom-Json).code '123456'
}
Test-Case 'the background runspace is given Get-TikTokActiveStatuses (the worker calls it; a missing function broke the fast status pass)' {
    Assert-True ($script:tikTokWorkerFunctions -contains 'Get-TikTokActiveStatuses') 'not in tikTokWorkerFunctions'
    foreach ($n in $script:tikTokWorkerFunctions) { Assert-True (Test-Path "function:$n") "worker function $n is not defined" }
}
function Complete-TikTokTask { param($Task) return $script:stubResult }
function Start-ChromeTimer { }
function Invoke-CompleteWith409 {
    # Real worker -> fake backend answering 409 to the PATCH, then the real Complete-ChromeOp with that result.
    param([hashtable]$Ctx, [string]$Body)
    $fake = Start-FakeBackend @{ 'PATCH /api/accounts/7' = @{ Status = 409; Body = $Body } } 1
    $r = Invoke-ExtAction $fake @{ op = 'set-publisher'; account_id = 7; publisher = 'chrome'; client_id = 3; confirm = $false }
    $script:ui = @{}; $script:TestLog.Clear()
    $script:chromeUi = @{ Task = 1; Op = $null; Ops = (New-Object System.Collections.ArrayList); Tried = @{ '7' = $true }; Deferred = @{}; Building = $false }
    $script:chromeUi.Op = @{ Kind = 'set-publisher'; Ctx = $Ctx }
    $script:stubResult = $r.Result[0]
    Complete-ChromeOp
    return $script:chromeUi
}
Test-Case 'manual toggle refused with 409 (account has work): backend Vietnamese message in a toast, list rebuilt to the real publisher, nothing remembered' {
    $s = Invoke-CompleteWith409 @{ AccountId = '7'; Username = '@anna'; Publisher = 'chrome' } '{"detail":"Tài khoản còn việc đang chờ — đợi xong"}'
    Assert-True (@($script:TestLog | Where-Object { $_ -eq '[toast] Tài khoản còn việc đang chờ — đợi xong' }).Count -eq 1) "toast: $($script:TestLog -join '|')"
    Assert-True ($s.Ops.Count -eq 1 -and $s.Ops[0].Kind -eq 'refresh') 'refresh queued so the combo reverts'
}
Test-Case 'manual toggle 409 with an English/unknown body uses the fallback Vietnamese text' {
    [void](Invoke-CompleteWith409 @{ AccountId = '7'; Username = '@anna'; Publisher = 'chrome' } '{"detail":"busy"}')
    Assert-True (@($script:TestLog | Where-Object { $_ -eq ('[toast] ' + (Get-ChromePublisherBusyText)) }).Count -eq 1) "toast: $($script:TestLog -join '|')"
}
Test-Case 'auto-switch 409: account is NOT marked handled (Tried cleared, so the next poll retries); one toast per account per session' {
    $ctx = @{ Auto = $true; AccountId = '7'; Username = '@anna'; Publisher = 'chrome' }
    $s = Invoke-CompleteWith409 $ctx '{"detail":"busy"}'
    Assert-True (-not $s.Tried.ContainsKey('7')) 'Tried must be cleared'
    Assert-Equal @($script:TestLog | Where-Object { $_ -like '*sẽ chuyển sang Chrome khi hết việc đang chờ*' }).Count 1
    Assert-Equal @(Get-ChromeAutoSwitchPlan -Accounts @((Acct 7 'anna')) -Clients @((Cl 3 'anna')) -CookieChoice @() -Tried $s.Tried).Count 1 'retried'
    # second refusal in the same session: still retried, no second toast
    $script:TestLog.Clear(); $s.Tried['7'] = $true; $s.Op = @{ Kind = 'set-publisher'; Ctx = $ctx }; $s.Task = 1; $script:ui = @{}
    Complete-ChromeOp
    Assert-Equal @($script:TestLog | Where-Object { $_ -like '*sẽ chuyển sang Chrome*' }).Count 0 'no second toast'
    Assert-True (-not $s.Tried.ContainsKey('7')) 'still retriable'
}
# ---------------------------------------------------------------- Chrome profile per client ----
function New-LocalState {
    param([string]$Json, [switch]$Bom)
    $p = Join-Path (New-TestDir) 'Local State'
    [IO.File]::WriteAllText($p, $Json, (New-Object Text.UTF8Encoding([bool]$Bom)))
    return $p
}
$localJson = '{"profile":{"last_used":"Profile 1","info_cache":{"Default":{"name":"Anh Ba","user_name":"ba@gmail.com","gaia_name":"Ba Nguyen"},"Profile 1":{"name":"Shop Bé","user_name":"shop@gmail.com"},"Profile 2":{"name":""},"Bad\\Name":{"name":"x"},"..":{"name":"y"}}}}'
Test-Case 'Local State: names, gaia_name beats user_name, empty name falls back to the directory, path-like keys are dropped, last_used read' {
    $r = Read-ChromeProfiles (New-LocalState $localJson)
    Assert-True $r.Ok 'ok'
    Assert-Equal (($r.Profiles | ForEach-Object { $_.Dir }) -join ',') 'Default,Profile 1,Profile 2'
    Assert-Equal $r.Profiles[0].Label 'Anh Ba (Ba Nguyen)'
    Assert-Equal $r.Profiles[1].Label 'Shop Bé (shop@gmail.com)'
    Assert-Equal $r.Profiles[2].Label 'Profile 2'
    Assert-Equal $r.LastUsed 'Profile 1'
}
Test-Case 'Local State: UTF-8 BOM is accepted; a file held open by another writer is still readable' {
    Assert-True (Read-ChromeProfiles (New-LocalState $localJson -Bom)).Ok 'BOM'
    $p = New-LocalState $localJson
    $hold = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { Assert-True (Read-ChromeProfiles $p).Ok 'open by Chrome' } finally { $hold.Dispose() }
}
Test-Case 'Local State: missing file, empty file, garbage and no info_cache give the Vietnamese error, not an exception' {
    foreach ($path in @((Join-Path (New-TestDir) 'nope'), (New-LocalState ''), (New-LocalState 'not json {'), (New-LocalState '{"profile":{}}'), (New-LocalState '[]'))) {
        $r = Read-ChromeProfiles $path
        Assert-True (-not $r.Ok) "should fail: $path"; Assert-Equal $r.Error 'Không đọc được danh sách profile Chrome'; Assert-Equal @($r.Profiles).Count 0
    }
}
Test-Case 'default selection: saved dir wins; else last_used (only if it is a known profile); old backend (no field) hides the combo' {
    $profiles = Read-ChromeProfiles (New-LocalState $localJson)
    $c = Cl 1 'a'; $c | Add-Member -NotePropertyName chrome_profile_dir -NotePropertyValue $null
    $x = Get-ChromeProfileChoice $c $profiles
    Assert-Equal $x.Dir 'Profile 1'; Assert-True $x.Default 'suggestion to save'; Assert-True (-not $x.Hidden) 'visible'
    $c.chrome_profile_dir = 'Default'
    $x = Get-ChromeProfileChoice $c $profiles
    Assert-Equal $x.Dir 'Default'; Assert-True (-not $x.Default) 'saved value is not re-saved'
    Assert-True (Get-ChromeProfileChoice (Cl 2 'b') $profiles).Hidden 'old backend'
    $c2 = Cl 3 'c'; $c2 | Add-Member -NotePropertyName chrome_profile_dir -NotePropertyValue ''
    $bad = Read-ChromeProfiles (New-LocalState '{"profile":{"last_used":"Ghost","info_cache":{"Default":{"name":"x"},"Profile 1":{"name":"y"}}}}')   # two profiles: the single-profile rule does not apply
    $x = Get-ChromeProfileChoice $c2 $bad
    Assert-Equal $x.Dir ''; Assert-True (-not $x.Default) 'unknown last_used is not saved'
    $x = Get-ChromeProfileChoice $c2 (Read-ChromeProfiles (Join-Path (New-TestDir) 'nope'))
    Assert-Equal $x.Dir ''; Assert-True (-not $x.Default) 'unreadable Local State saves nothing'
}
Test-Case 'set-profile: PATCH /api/ext/clients/5 with {"chrome_profile_dir":"Profile 1"}, CSRF header, no Origin' {
    $fake = Start-FakeBackend @{ 'PATCH /api/ext/clients/5' = @{ Status = 200; Body = '{"id":5,"chrome_profile_dir":"Profile 1"}' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'set-profile'; client_id = 5; chrome_profile_dir = 'Profile 1' }
    Assert-Equal $r.Error ''; Assert-Equal $r.Result[0].status 200
    $seen = $fake.Seen[0]
    Assert-Equal $seen.Method 'PATCH'; Assert-Equal ($seen.Body | ConvertFrom-Json).chrome_profile_dir 'Profile 1'
    Assert-True ($null -eq $seen.Origin) 'no Origin'; Assert-Equal $seen.Csrf 'autotok'
}
Test-Case 'set-profile refused by the backend (400): returned with status, UI toasts the error and refreshes' {
    $fake = Start-FakeBackend @{ 'PATCH /api/ext/clients/5' = @{ Status = 422; Body = '{"detail":"tên profile không hợp lệ"}' } } 1
    $r = Invoke-ExtAction $fake @{ op = 'set-profile'; client_id = 5; chrome_profile_dir = 'a/b' }
    Assert-Equal $r.Result[0].ok $false
    $script:ui = @{}; $script:TestLog.Clear()
    $script:chromeUi = @{ Task = 1; Op = @{ Kind = 'set-profile'; Ctx = @{ ClientId = '5'; Dir = 'a/b' } }; Ops = (New-Object System.Collections.ArrayList); Tried = @{}; Deferred = @{}; ProfileTried = @{}; Building = $false }
    $script:stubResult = $r.Result[0]
    Complete-ChromeOp
    Assert-True (@($script:TestLog | Where-Object { $_ -eq '[toast] tên profile không hợp lệ' }).Count -eq 1) "toast: $($script:TestLog -join '|')"
    Assert-Equal $script:chromeUi.Ops[0].Kind 'refresh'
}
Test-Case 'the refresh keeps chrome_profile_dir from an old/new backend untouched (field passes through the clients JSON)' {
    $fake = Start-FakeBackend @{ 'GET /health' = @{ Status = 200; Body = $healthNew }; 'GET /api/ext/clients' = @{ Status = 200; Body = '[{"id":3,"chrome_profile_dir":null}]' }; 'GET /api/accounts' = @{ Status = 200; Body = '[]' } } 3
    $r = Invoke-ExtAction $fake @{ op = 'refresh' }
    $c = @(($r.Result[0].clients | ConvertFrom-Json) | Where-Object { $_ })[0]   # same unrolling as Complete-ChromeOp (PS 5.1 returns the array as one object)
    Assert-True (@($c.PSObject.Properties.Name) -contains 'chrome_profile_dir') 'field present (null)'
    Assert-True (-not (Get-ChromeProfileChoice $c (Read-ChromeProfiles (New-LocalState $localJson))).Hidden) 'combo shown'
}
Test-Case 'backend 400 bad_request for a bad profile name: its Vietnamese message is shown; a bare 400 gets the generic text' {
    Assert-Equal (Get-ChromeApiErrorText 400 '{"ok":false,"error":"bad_request","message":"Tên profile Chrome không hợp lệ (ví dụ: Default, Profile 1)"}') 'Tên profile Chrome không hợp lệ (ví dụ: Default, Profile 1)'
    Assert-Equal (Get-ChromeApiErrorText 400 '{"error":"bad_request","message":"invalid JSON"}') 'Thông tin gửi lên chưa đúng.'
    Assert-Equal (Get-ChromeApiErrorText 404 '{"error":"unknown_client","message":"x"}') 'Không tìm thấy (có thể đã bị gỡ).'
}
Test-Case 'profile guess: two clients lacking a profile get nothing; one lacking + last_used used by another gets nothing; a profile saved for another client is never taken' {
    $two = Read-ChromeProfiles (New-LocalState '{"profile":{"last_used":"Profile 1","info_cache":{"Profile 1":{"name":"A"},"Profile 2":{"name":"B"}}}}')
    $a = Cl 1 'a'; $a | Add-Member -NotePropertyName chrome_profile_dir -NotePropertyValue $null
    $b = Cl 2 'b'; $b | Add-Member -NotePropertyName chrome_profile_dir -NotePropertyValue $null
    Assert-Equal (Get-ChromeProfileChoice $a $two @($a, $b)).Dir '' 'two lacking'
    $b.chrome_profile_dir = 'Profile 1'
    Assert-Equal (Get-ChromeProfileChoice $a $two @($a, $b)).Dir '' 'last_used already taken'
    $b.chrome_profile_dir = 'Profile 2'
    $x = Get-ChromeProfileChoice $a $two @($a, $b); Assert-Equal $x.Dir 'Profile 1'; Assert-True $x.Default 'the only lacking one gets last_used'
    $one = Read-ChromeProfiles (New-LocalState '{"profile":{"last_used":"Default","info_cache":{"Default":{"name":"Me"}}}}')
    $b.chrome_profile_dir = $null
    Assert-Equal (Get-ChromeProfileChoice $a $one @($a, $b)).Dir 'Default' 'single profile in Local State'
    $b.chrome_profile_dir = 'Default'
    Assert-Equal (Get-ChromeProfileChoice $a $one @($a, $b)).Dir '' 'single profile but another client owns it'
}
Test-Case 'Local State cache: unchanged file is parsed once (same object back); a changed file is re-read; the unreadable warning is logged once' {
    $p = New-LocalState $localJson
    $r1 = Read-ChromeProfiles $p; $r2 = Read-ChromeProfiles $p
    Assert-True ([object]::ReferenceEquals($r1, $r2)) 'second call must come from the cache'
    [IO.File]::WriteAllText($p, '{"profile":{"last_used":"Default","info_cache":{"Default":{"name":"Only"}}}}', (New-Object Text.UTF8Encoding($false)))
    $r3 = Read-ChromeProfiles $p
    Assert-Equal @($r3.Profiles).Count 1 'changed file re-read'
    $script:chromeProfilesWarned = $false; $script:TestLog.Clear()
    $missing = Join-Path (New-TestDir) 'nope'
    1..5 | ForEach-Object { [void](Read-ChromeProfiles $missing) }
    [void](Read-ChromeProfiles (New-LocalState 'garbage'))
    Assert-Equal @($script:TestLog | Where-Object { $_ -like '*Chrome Local State*' }).Count 1 'warning once per session'
}
Complete-Tests
