param([ValidateSet('main', 'recovery')][string]$Phase = 'main',
      [string]$Work = ('C:\Users\hp\AppData\Local\Temp\claude\D--reup-video-fb-meta\907a531c-3a1e-4f3a-b228-0f0a3741c294\scratchpad\p1\smoke-' + $Phase),
      [string]$Shots = 'C:\Users\hp\AppData\Local\Temp\claude\D--reup-video-fb-meta\907a531c-3a1e-4f3a-b228-0f0a3741c294\scratchpad\p1-shots',
      [string]$Repo = 'D:\kidfby-wt\kho')
# Real WPF smoke of the physical kho on a TEMP COPY of the app (Windows PowerShell 5.1 -STA). Two khos with tiny ffmpeg-made videos.
# Never touches D:\reup video fb meta (ffmpeg is only copied from it), the real data\, output\ or logs\. Never calls the TikTok backend.
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
$app = Join-Path $Work 'app'
New-Item -ItemType Directory -Force -Path $app, (Join-Path $app 'data'), (Join-Path $app 'tools\ffmpeg') | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'core') -Destination (Join-Path $app 'core') -Recurse
foreach ($n in 'ffmpeg.exe', 'ffprobe.exe') { Copy-Item -LiteralPath (Join-Path 'D:\reup video fb meta\tools\ffmpeg' $n) -Destination (Join-Path $app "tools\ffmpeg\$n") }
$ff = Join-Path $app 'tools\ffmpeg\ffmpeg.exe'
$A = Join-Path $Work 'khoA'; $B = Join-Path $Work 'khoB'
New-Item -ItemType Directory -Force -Path $A, $B | Out-Null
$seed = Join-Path $Work 'seed.mp4'
& $ff -v error -y -f lavfi -i 'testsrc=size=270x480:rate=15' -f lavfi -i 'sine=frequency=440' -t 2 -pix_fmt yuv420p -c:v libx264 -preset ultrafast -c:a aac -shortest $seed
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $seed)) { throw 'ffmpeg failed' }
$utf8 = New-Object Text.UTF8Encoding($false)
function Hist($req, $user) { return [ordered]@{ key = "request:$req"; request_id = $req; username = $user; status = 'succeeded'; publish_uncertain = $false; prior_uncertain = $false; planned_for = ''; accepted_at = '2026-10-20T10:00:00Z'; created_at = '2026-10-20T09:00:00Z'; time_source = 'backend'; sha256 = ''; post_url = ''; post_id = ''; link_state = ''; tiktok_schedule_time = ''; schedule_mode = 'now' } }
function Entry($req) { return [ordered]@{ Posted = $true; Date = '20/10 10:00'; Source = 'autotok-history'; History = @((Hist $req 'anna')); ManualPosted = $false; ManualDate = ''; FileSha256 = 'sha-' + $req } }
function MkVideo($dir, $id, [switch]$Entry) {
    Copy-Item -LiteralPath $seed -Destination (Join-Path $dir "$id-3-hoan-chinh.mp4")
    $c = Join-Path $dir '.cache'; New-Item -ItemType Directory -Force -Path (Join-Path $c 'thumbs'), (Join-Path $c 'tiktok-posts') | Out-Null
    [IO.File]::WriteAllText((Join-Path $c "$id-1-video-goc.mp4"), "source $id"); [IO.File]::WriteAllText((Join-Path $c "$id-2-am-thanh-tho.m4a"), "audio $id")
    return ('{0:x32}' -f [long]$id)
}
$metaA = [ordered]@{}; $metaB = [ordered]@{}
if ($Phase -eq 'main') {
    foreach ($n in 101..103) { $id = "1000000000$n"; $req = MkVideo $A $id; if ($n -le 102) { $metaA[$id] = Entry $req } }
    foreach ($n in 201..203) { $id = "1000000000$n"; $req = MkVideo $B $id; if ($n -eq 201) { $metaB[$id] = Entry $req } }
    # a finished receipt for 201 so the receipt rewrite is exercised in the real app
    $rid = '{0:x32}' -f 1000000000201
    $rec = [ordered]@{ RequestId = $rid; VideoId = '1000000000201'; Username = 'anna'; ScheduledFor = ''; Status = 'posted'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; OutDir = $B; SourcePath = (Join-Path $B '1000000000201-3-hoan-chinh.mp4'); SourceSha256 = ''; UploadSha256 = '' }
    [IO.File]::WriteAllText((Join-Path $B ".cache\tiktok-posts\$rid.json"), (ConvertTo-Json $rec -Depth 5), $utf8)
}
[IO.File]::WriteAllText((Join-Path $A 'reup-status.json'), (ConvertTo-Json $metaA -Depth 12), $utf8)
[IO.File]::WriteAllText((Join-Path $B 'reup-status.json'), (ConvertTo-Json $metaB -Depth 12), $utf8)
function Lib($id, $name, $path) { return [ordered]@{ id = $id; name = $name; path = $path; account = ''; caption = ''; hashtags = @(); lowStock = 3; slots = @(); createdByApp = $false } }
$ka = 'k-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; $kb = 'k-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$reg = [ordered]@{ version = 2; libraries = @((Lib $ka 'Kho Alpha' $A), (Lib $kb 'Kho Beta' $B)); downloadTarget = $ka; autoMoveSince = [DateTime]::UtcNow.ToString('o') }
[IO.File]::WriteAllText((Join-Path $app 'data\kho.json'), (ConvertTo-Json $reg -Depth 6), $utf8)

if ($Phase -eq 'recovery') {
    # fabricate a journal in phase "renaming" with 3 of the renames done (A -> B), using the product functions
    $script:root = $app
    . (Join-Path $Repo 'tests\kho\_load.ps1')
    $script:root = $app; $script:khoRegistry = $null; $script:khoRegistryReady = $true; $script:reelCacheName = '.cache'
    $id = '1000000000301'
    $req = MkVideo $A $id
    $rec = [pscustomobject]@{ RequestId = $req; VideoId = $id; Username = 'anna'; ScheduledFor = ''; Status = 'posted'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; OutDir = $A; SourcePath = (Join-Path $A "$id-3-hoan-chinh.mp4"); SourceSha256 = ''; UploadSha256 = '' }
    Save-TikTokReceipt $rec
    [void](Update-ReupMetadata -OutDir $A -Change { param($meta) $meta | Add-Member -MemberType NoteProperty -Name $id -Force -Value ([pscustomobject](Entry $req)); return $true })
    # three more videos so the gallery has 4 in total (301 + 2 in A + 1 in B), none of them in the journal
    foreach ($n in 302, 303) { [void](MkVideo $A "1000000000$n") }
    [void](MkVideo $B '1000000000401')
    $plan = @(New-KhoMovePlan $id $A $B (Get-KhoReceiptGroups $A))
    $snapshot = Copy-ReupEntry (Get-ReupMetadata -OutDir $A).$id
    $j = [ordered]@{ version = 1; txid = [Guid]::NewGuid().ToString('N'); id = $id; from = $A; to = $B; phase = 'renaming'; reason = 'manual'; createdAt = [DateTime]::UtcNow.ToString('o'); renames = @($plan); sourceEntrySnapshot = $snapshot }
    [void](Write-KhoJournal $j)
    for ($i = 0; $i -lt 3; $i++) { [void](Invoke-KhoMoveRename $plan[$i]) }
    Write-Output "fabricated journal for $id with 3 of $($plan.Count) renames done"
}

Remove-Item -LiteralPath $seed
$gui = Join-Path $app 'core\kid-fby-gui.ps1'
$text = [IO.File]::ReadAllText($gui, [Text.Encoding]::UTF8)
$marker = '[void]$win.ShowDialog()'
$idx = $text.LastIndexOf($marker)
if ($idx -lt 0) { throw 'ShowDialog marker not found' }
$text = $text.Substring(0, $idx) + ". '" + (Join-Path $Repo 'tests\kho\smoke\harness-p1.ps1') + "'`r`n    " + $text.Substring($idx)
$harnessGui = Join-Path $app 'core\kid-fby-gui-harness.ps1'
[IO.File]::WriteAllText($harnessGui, $text, (New-Object Text.UTF8Encoding($true)))
$out = Join-Path $Work 'harness-out.txt'
$env:KHO_HARNESS_OUT = $out; $env:KHO_SHOTS = $Shots; $env:KHO_PHASE = $Phase; $env:KHO_SMOKE_DIR = $Work; $env:KID_FBY_NO_MSGBOX = '1'
$p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-STA', '-File', $harnessGui) -PassThru -RedirectStandardError (Join-Path $Work 'stderr.txt') -RedirectStandardOutput (Join-Path $Work 'stdout.txt')
[void]$p.Handle
if (-not $p.WaitForExit(420000)) { $p.Kill(); Write-Output 'TIMEOUT: killed' }
Write-Output "exit=$($p.ExitCode)"
if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Encoding UTF8 }
Get-Content -LiteralPath (Join-Path $Work 'stderr.txt') -ErrorAction SilentlyContinue | Select-Object -First 20
