# T3: TikTok post dialog helpers - prefs file, time chips, per-account hashtag ranking, caption template, repost warning, next free slot.
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$vi = { param([int[]]$codes) -join ($codes | ForEach-Object { [char]$_ }) }
function Local { param([string]$s) return [DateTime]::SpecifyKind([DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), 'Local') }
function Utc { param([DateTime]$d) return $d.ToUniversalTime().ToString('o') }

# ---------------- prefs ----------------
Test-Case 'prefs: missing file -> empty, not unreadable, nothing written' {
    $p = Join-Path $tmp 'a\tiktok-prefs.json'; $un = $true
    $r = Read-TikTokPrefs -Path $p -Unreadable ([ref]$un)
    Assert-Equal $r.lastAccount ''; Assert-Equal $r.times.Count 0; Assert-True (-not $un) 'unreadable'
    Assert-True (-not [IO.File]::Exists($p)) 'no file created by read'
}
Test-Case 'prefs: submit remembers lastAccount and counts HH:mm per account (lowercase key), two submits -> 2' {
    $p = Join-Path $tmp 'b\tiktok-prefs.json'
    Register-TikTokPrefsSubmit -Username '@Anna' -Time '19:30' -Path $p
    Register-TikTokPrefsSubmit -Username 'anna' -Time '19:30' -Path $p
    Register-TikTokPrefsSubmit -Username 'bob' -Time '' -Path $p
    $r = Read-TikTokPrefs -Path $p
    Assert-Equal $r.lastAccount 'bob'
    Assert-Equal $r.times['anna']['19:30'] 2
    Assert-True (-not $r.times.ContainsKey('bob')) 'immediate post must not add a time'
    $j = Read-TestJson $p; Assert-Equal $j.version 1
}
Test-Case 'prefs: corrupt file renamed .corrupt-*, treated as empty, then writable' {
    $p = Join-Path $tmp 'c\tiktok-prefs.json'; [void][IO.Directory]::CreateDirectory((Split-Path $p))
    [IO.File]::WriteAllText($p, '{not json', [Text.UTF8Encoding]::new($false))
    $r = Read-TikTokPrefs -Path $p
    Assert-Equal $r.times.Count 0
    Assert-True (-not [IO.File]::Exists($p)) 'original moved'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $p) -Filter 'tiktok-prefs.json.corrupt-*').Count 1
    Register-TikTokPrefsSubmit -Username 'x' -Time '08:00' -Path $p
    Assert-Equal (Read-TikTokPrefs -Path $p).times['x']['08:00'] 1
}
Test-Case 'prefs: locked file -> Unreadable, nothing overwritten or renamed' {
    $p = Join-Path $tmp 'd\tiktok-prefs.json'
    Register-TikTokPrefsSubmit -Username 'a' -Time '08:00' -Path $p
    $before = (Get-FileHash -LiteralPath $p).Hash
    $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
    try {
        $un = $false; [void](Read-TikTokPrefs -Path $p -Unreadable ([ref]$un)); Assert-True $un 'flag'
        Register-TikTokPrefsSubmit -Username 'b' -Time '09:00' -Path $p
    } finally { $fs.Dispose() }
    Assert-Equal (Get-FileHash -LiteralPath $p).Hash $before 'file untouched'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $p) -Filter '*.corrupt-*').Count 0
}
Test-Case 'prefs: invalid times / counts in file are ignored' {
    $p = Join-Path $tmp 'e\tiktok-prefs.json'; [void][IO.Directory]::CreateDirectory((Split-Path $p))
    [IO.File]::WriteAllText($p, '{"version":1,"lastAccount":"A","times":{"u":{"25:00":3,"12:00":0,"09:15":2,"x":1}}}', [Text.UTF8Encoding]::new($false))
    $r = Read-TikTokPrefs -Path $p
    Assert-Equal $r.lastAccount 'a'; Assert-Equal $r.times['u'].Count 1; Assert-Equal $r.times['u']['09:15'] 2
}

# ---------------- chips ----------------
Test-Case 'chips: nothing remembered -> the four presets' {
    Assert-Equal (@(Get-TikTokTimeChips $null) -join ',') '08:00,12:00,19:00,21:00'
    Assert-Equal (@(Get-TikTokTimeChips @{}) -join ',') '08:00,12:00,19:00,21:00'
}
Test-Case 'chips: one remembered time is topped up from the presets' {
    Assert-Equal (@(Get-TikTokTimeChips @{ '10:00' = 5 }) -join ',') '08:00,10:00,12:00,19:00'
}
Test-Case 'chips: remembered time equal to a preset is not duplicated' {
    Assert-Equal (@(Get-TikTokTimeChips @{ '19:00' = 3 }) -join ',') '08:00,12:00,19:00,21:00'
}
Test-Case 'chips: top 4 by count, ties -> earlier time first, 5th dropped' {
    $t = @{ '20:00' = 5; '09:00' = 5; '10:00' = 5; '11:00' = 5; '07:00' = 5; '23:00' = 9 }
    Assert-Equal (@(Get-TikTokTimeChips $t) -join ',') '07:00,09:00,10:00,23:00'
}
Test-Case 'chips: count beats time' {
    $t = @{ '06:00' = 1; '13:00' = 4; '14:00' = 3; '15:00' = 2; '16:00' = 1 }
    Assert-Equal (@(Get-TikTokTimeChips $t) -join ',') '06:00,13:00,14:00,15:00'
}

# ---------------- hashtags per account ----------------
function New-Tag { param([string]$Tag, [int]$Count, [string]$Last, $Acc = $null) $o = [pscustomobject]@{ tag = $Tag; count = $Count; lastUsed = $Last }; if ($null -ne $Acc) { $o | Add-Member accounts $Acc }; return $o }
Test-Case 'suggestions: no account -> old order (count desc, lastUsed desc); old tags without accounts work' {
    $tags = @((New-Tag '#a' 1 '2026-01-01'), (New-Tag '#b' 5 '2026-01-01'), (New-Tag '#c' 5 '2026-02-01'))
    Assert-Equal (@(Get-TikTokHashtagSuggestions -Tags $tags -Text '' -Caret 0) -join ' ') '#c #b #a'
}
Test-Case 'suggestions: account tags first by its count then lastUsed, then global by count' {
    $tags = @((New-Tag '#g' 50 '2026-03-01'), (New-Tag '#x' 1 '2026-01-01' ([ordered]@{ anna = 2 })), (New-Tag '#y' 9 '2026-01-01' ([ordered]@{ anna = 7 })),
        (New-Tag '#z' 1 '2026-05-01' ([ordered]@{ anna = 2 })), (New-Tag '#bobonly' 99 '2026-06-01' ([ordered]@{ bob = 4 })), (New-Tag '#h' 10 '2026-01-01'))
    Assert-Equal (@(Get-TikTokHashtagSuggestions -Tags $tags -Text '' -Caret 0 -Account '@Anna') -join ' ') '#y #z #x #bobonly #g #h'
}
Test-Case 'hashtags file: accounts round-trips; add increments chosen account only; old file loads; old file gains accounts only for the account used' {
    $p = Join-Path $tmp 'f\tiktok-hashtags.json'; [void][IO.Directory]::CreateDirectory((Split-Path $p))
    [IO.File]::WriteAllText($p, '{"version":1,"tags":[{"tag":"#old","count":3,"lastUsed":"2026-01-01T00:00:00Z"}]}', [Text.UTF8Encoding]::new($false))
    $r = @(Read-TikTokHashtags -Path $p); Assert-Equal $r.Count 1; Assert-Equal $r[0].count 3
    Add-TikTokHashtagsFromCaption 'hi #old #New' -Path $p -Account 'Anna'
    Add-TikTokHashtagsFromCaption 'again #new' -Path $p -Account 'anna'
    Add-TikTokHashtagsFromCaption 'bob #new' -Path $p -Account 'bob'
    Add-TikTokHashtagsFromCaption 'no account #plain' -Path $p
    $j = Read-TestJson $p
    $old = @($j.tags | Where-Object tag -eq '#old')[0]; $new = @($j.tags | Where-Object tag -eq '#New')[0]; $plain = @($j.tags | Where-Object tag -eq '#plain')[0]
    Assert-Equal $old.count 4; Assert-Equal $old.accounts.anna 1
    Assert-Equal $new.count 3; Assert-Equal $new.accounts.anna 2; Assert-Equal $new.accounts.bob 1
    Assert-Equal $plain.count 1; Assert-True ($null -eq $plain.PSObject.Properties['accounts']) 'no accounts key when none'
    $back = @(Read-TikTokHashtags -Path $p); Assert-Equal @($back | Where-Object tag -eq '#New')[0].accounts['anna'] 2
}

# ---------------- caption template ----------------
function New-Lib { param([string]$Id, [string]$Caption, [string[]]$Tags) return [pscustomobject]@{ id = $Id; caption = $Caption; hashtags = $Tags } }
Test-Case 'template: account kho = caption + #tags (adds missing #, trims)' {
    $libs = @((New-Lib 'default' '' @()), (New-Lib 'acct:anna' ' Xem ngay ' @('hai', '#vui', ' ')), (New-Lib 'c-0123456789abcdef0123456789abcdef' 'custom' @('#c')))
    Assert-Equal (Get-TikTokCaptionTemplate -Account '@Anna' -VideoKhoId 'default' -Libraries $libs) 'Xem ngay #hai #vui'
}
Test-Case 'template: no account kho -> video custom kho; default / other account kho / unknown -> empty' {
    $c = 'c-0123456789abcdef0123456789abcdef'
    $libs = @((New-Lib 'default' 'D' @('#d')), (New-Lib 'acct:bob' 'B' @()), (New-Lib $c 'custom' @('#c')))
    Assert-Equal (Get-TikTokCaptionTemplate -Account 'anna' -VideoKhoId $c -Libraries $libs) 'custom #c'
    Assert-Equal (Get-TikTokCaptionTemplate -Account 'anna' -VideoKhoId 'default' -Libraries $libs) ''
    Assert-Equal (Get-TikTokCaptionTemplate -Account 'anna' -VideoKhoId 'acct:bob' -Libraries $libs) ''
    Assert-Equal (Get-TikTokCaptionTemplate -Account 'anna' -VideoKhoId 'c-ffffffffffffffffffffffffffffffff' -Libraries $libs) ''
    Assert-Equal (Get-TikTokCaptionTemplate -Account 'anna' -VideoKhoId $c -Libraries @()) ''
}
Test-Case 'template: Vietnamese text survives' {
    $cap = & $vi 0x58, 0x65, 0x6D, 0x20, 0x68, 0xE0, 0x69   # "Xem hai" with a-grave
    $libs = @((New-Lib 'acct:anna' $cap @('vui')))
    Assert-Equal (Get-TikTokCaptionTemplate -Account 'anna' -VideoKhoId 'default' -Libraries $libs) ($cap + ' #vui')
}

# ---------------- repost warning ----------------
Test-Case 'repost: confirmed entry on ANOTHER account warns; picks the newest; UTC converted' {
    $e = @((New-TestHistoryEntry 'r1' 'bob' 'succeeded' '2026-10-20T10:00:00Z'), (New-TestHistoryEntry 'r2' 'cara' 'succeeded' '2026-10-22T05:30:00Z'))
    $w = Get-TikTokRepostWarning -Entries $e -Account 'anna'
    Assert-Equal $w.Username 'cara'
    $u = $w.When.ToUniversalTime(); Assert-Equal $u.Day 22; Assert-Equal $u.Hour 5; Assert-Equal $u.Minute 30
}
Test-Case 'repost: same account, uncertain, failed, pending, or no username -> no warning' {
    $e = @((New-TestHistoryEntry 'r1' 'Anna' 'succeeded'), (New-TestHistoryEntry 'r2' 'bob' 'succeeded' -Uncertain $true), (New-TestHistoryEntry 'r3' 'bob' 'failed'),
        (New-TestHistoryEntry 'r4' 'bob' 'pending'), (New-TestHistoryEntry 'r5' '' 'succeeded'))
    Assert-True ($null -eq (Get-TikTokRepostWarning -Entries $e -Account 'anna')) 'no warning'
    Assert-True ($null -eq (Get-TikTokRepostWarning -Entries @() -Account 'anna')) 'empty'
    Assert-True ($null -eq (Get-TikTokRepostWarning -Entries $null -Account 'anna')) 'null'
}

# ---------------- busy times + next free slot ----------------
$bounds = { param($now) Get-TikTokScheduleBounds $now }
$fav = @('08:00', '12:00', '19:00', '21:00')
Test-Case 'slot: earliest favourite >= now+20min today' {
    $now = Local '2026-10-26 10:00'
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @() -Now $now).ToString('yyyy-MM-dd HH:mm') '2026-10-26 12:00'
}
Test-Case 'slot: a favourite inside now+20 is skipped (min = now+20 rounded up)' {
    $now = Local '2026-10-26 11:41'   # min = 12:01, so 12:00 is too soon
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @() -Now $now).ToString('HH:mm') '19:00'
    $now = Local '2026-10-26 11:40'   # min = 12:00 exactly
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @() -Now $now).ToString('HH:mm') '12:00'
}
Test-Case 'slot: busy within +-60 min skips, exactly 60 min apart is free' {
    $now = Local '2026-10-26 10:00'
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @((Local '2026-10-26 12:59')) -Now $now).ToString('HH:mm') '19:00'
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @((Local '2026-10-26 11:01')) -Now $now).ToString('HH:mm') '19:00'
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @((Local '2026-10-26 13:00')) -Now $now).ToString('HH:mm') '12:00'
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy @((Local '2026-10-26 11:00')) -Now $now).ToString('HH:mm') '12:00'
}
Test-Case 'slot: rolls over midnight to the next day' {
    $now = Local '2026-10-26 23:50'
    $s = Get-NextFreeTikTokSlot -Favorites @('00:30', '08:00') -Busy @() -Now $now
    Assert-Equal $s.ToString('yyyy-MM-dd HH:mm') '2026-10-27 00:30'
    $now = Local '2026-10-26 23:40'
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites @('23:50') -Busy @() -Now $now).ToString('yyyy-MM-dd HH:mm') '2026-10-27 23:50'
}
Test-Case 'slot: today fully busy -> tomorrow; all 10 days busy -> $null' {
    $now = Local '2026-10-26 10:00'
    $busy = @((Local '2026-10-26 12:00'), (Local '2026-10-26 19:00'), (Local '2026-10-26 21:00'))
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy $busy -Now $now).ToString('yyyy-MM-dd HH:mm') '2026-10-27 08:00'
    $all = @(0..10 | ForEach-Object { (Local '2026-10-26 12:00').AddDays($_) })
    Assert-True ($null -eq (Get-NextFreeTikTokSlot -Favorites @('12:00') -Busy $all -Now $now)) 'null when every day is taken'
}
Test-Case 'slot: respects the 10-day upper bound (11-05 12:00 > max 11-05 10:00; 08:00 is allowed)' {
    $now = Local '2026-10-26 10:00'
    $busy = @(1..9 | ForEach-Object { (Local '2026-10-26 12:00').AddDays($_) })
    Assert-True ($null -eq (Get-NextFreeTikTokSlot -Favorites @('12:00') -Busy (@($busy) + (Local '2026-10-26 12:00')) -Now $now)) 'noon on the last day is past max'
    $busy8 = @(1..9 | ForEach-Object { (Local '2026-10-26 08:00').AddDays($_) })
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites @('08:00') -Busy $busy8 -Now $now).ToString('yyyy-MM-dd HH:mm') '2026-11-05 08:00'
}
Test-Case 'slot: no favourites / garbage favourites -> $null' {
    $now = Local '2026-10-26 10:00'
    Assert-True ($null -eq (Get-NextFreeTikTokSlot -Favorites @() -Busy @() -Now $now)) 'empty'
    Assert-True ($null -eq (Get-NextFreeTikTokSlot -Favorites @('25:00', 'abc') -Busy @() -Now $now)) 'garbage'
}
Test-Case 'busy: UTC strings -> local; only this account; statuses; planned_for fallback; past succeeded ignored' {
    $now = Local '2026-10-26 10:00'
    function Ent { param($User, $Status, $Sched = '', $Planned = '') $x = New-TestHistoryEntry 'q' $User $Status; $x.tiktok_schedule_time = $Sched; $x.planned_for = $Planned; return $x }
    $meta = [pscustomobject]@{
        '111' = [pscustomobject]@{ Posted = $false; Date = ''; History = @((Ent 'Anna' 'succeeded' (Utc (Local '2026-10-27 12:00'))), (Ent 'anna' 'pending' '' (Utc (Local '2026-10-27 19:00')))) }
        '222' = [pscustomobject]@{ Posted = $false; Date = ''; History = @((Ent 'anna' 'failed' (Utc (Local '2026-10-28 08:00'))), (Ent 'bob' 'pending' (Utc (Local '2026-10-28 09:00'))),
            (Ent 'anna' 'succeeded' (Utc (Local '2026-10-20 08:00'))), (Ent 'anna' 'queued' ''), (Ent 'anna' 'running' (Utc (Local '2026-10-29 21:00')))) }
        '333' = [pscustomobject]@{ Posted = $false; Date = '' }
    }
    $busy = @(Get-TikTokBusyTimes -Metadata $meta -Account '@ANNA' -Now $now)
    Assert-Equal $busy.Count 3
    Assert-Equal (($busy | Sort-Object | ForEach-Object { $_.ToString('MM-dd HH:mm') }) -join ',') '10-27 12:00,10-27 19:00,10-29 21:00'
    Assert-Equal @(Get-TikTokBusyTimes -Metadata $meta -Account 'bob' -Now $now).Count 1
    $extra = @(Ent 'anna' 'preparing' (Utc (Local '2026-10-30 08:00')))
    Assert-Equal @(Get-TikTokBusyTimes -Metadata $null -Account 'anna' -Now $now -ExtraEntries $extra).Count 1
}
Test-Case 'end to end: busy from metadata makes the next free slot skip it' {
    $now = Local '2026-10-26 10:00'
    $x = New-TestHistoryEntry 'q' 'anna' 'succeeded'; $x.tiktok_schedule_time = Utc (Local '2026-10-26 12:30')
    $meta = [pscustomobject]@{ '1' = [pscustomobject]@{ Posted = $false; Date = ''; History = @($x) } }
    $busy = @(Get-TikTokBusyTimes -Metadata $meta -Account 'anna' -Now $now)
    Assert-Equal (Get-NextFreeTikTokSlot -Favorites $fav -Busy $busy -Now $now).ToString('HH:mm') '19:00'
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
