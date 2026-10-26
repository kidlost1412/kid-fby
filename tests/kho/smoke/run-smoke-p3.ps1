param([string]$Work = ('C:\Users\hp\AppData\Local\Temp\claude\D--reup-video-fb-meta\907a531c-3a1e-4f3a-b228-0f0a3741c294\scratchpad\p3\smoke'),
      [string]$Shots = 'C:\Users\hp\AppData\Local\Temp\claude\D--reup-video-fb-meta\907a531c-3a1e-4f3a-b228-0f0a3741c294\scratchpad\p3-shots',
      [string]$Repo = 'D:\kidfby-wt\kho')
# Real WPF smoke of the P3 features on a TEMP COPY of the app (Windows PowerShell 5.1 -STA): background spread run against a FAKE TikTok backend
# (127.0.0.1, this repo's smoke-fake-backend.ps1; real worker child processes + real ffmpeg clean copy), editable spread rows, slot chips,
# rubber-band selection (pointer injected), an external .MOV dropped into a kho, moved and deleted.
# Never touches D:\reup video fb meta (ffmpeg is only copied from it), the real data\, output\ or logs\. Never calls the real TikTok backend.
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
$app = Join-Path $Work 'app'
New-Item -ItemType Directory -Force -Path $app, (Join-Path $app 'data'), (Join-Path $app 'tools\ffmpeg'), (Join-Path $app 'integrations\tiktok') | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'core') -Destination (Join-Path $app 'core') -Recurse
foreach ($n in 'ffmpeg.exe', 'ffprobe.exe') { Copy-Item -LiteralPath (Join-Path 'D:\reup video fb meta\tools\ffmpeg' $n) -Destination (Join-Path $app "tools\ffmpeg\$n") }
$ff = Join-Path $app 'tools\ffmpeg\ffmpeg.exe'
$A = Join-Path $Work 'khoA'; $B = Join-Path $Work 'khoB'; $drop = Join-Path $Work 'drop'
New-Item -ItemType Directory -Force -Path $A, $B, $drop | Out-Null
$seed = Join-Path $Work 'seed.mp4'
& $ff -v error -y -f lavfi -i 'testsrc=size=270x480:rate=15' -f lavfi -i 'sine=frequency=440' -t 2 -pix_fmt yuv420p -c:v libx264 -preset ultrafast -c:a aac -shortest $seed
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $seed)) { throw 'ffmpeg failed' }
# an external video: a .MOV with a Vietnamese name and spaces (H.264 + AAC -> remux path)
& $ff -v error -y -i $seed -c copy (Join-Path $drop 'Clip ngoài (1).MOV')
if ($LASTEXITCODE -ne 0) { throw 'ffmpeg mov failed' }
$utf8 = New-Object Text.UTF8Encoding($false)
function MkVideo($dir, $id) {
    Copy-Item -LiteralPath $seed -Destination (Join-Path $dir "$id-3-hoan-chinh.mp4")
    $c = Join-Path $dir '.cache'; New-Item -ItemType Directory -Force -Path (Join-Path $c 'thumbs'), (Join-Path $c 'tiktok-posts') | Out-Null
    [IO.File]::WriteAllText((Join-Path $c "$id-1-video-goc.mp4"), "source $id"); [IO.File]::WriteAllText((Join-Path $c "$id-2-am-thanh-tho.m4a"), "audio $id")
}
foreach ($n in 101..103) { MkVideo $A "1000000000$n" }
foreach ($n in 201..202) { MkVideo $B "1000000000$n" }
function Lib($id, $name, $path, $account) { return [ordered]@{ id = $id; name = $name; path = $path; account = $account; caption = ''; hashtags = @(); lowStock = 3; slots = @(); createdByApp = $false } }
$ka = 'k-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; $kb = 'k-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$libB = Lib $kb 'Kho Beta' $B 'anna'; $libB.caption = 'Mẫu của Anna'; $libB.hashtags = @('anna')
$reg = [ordered]@{ version = 2; libraries = @((Lib $ka 'Kho Alpha' $A ''), $libB); downloadTarget = $ka; autoMoveSince = [DateTime]::UtcNow.ToString('o') }
[IO.File]::WriteAllText((Join-Path $app 'data\kho.json'), (ConvertTo-Json $reg -Depth 6), $utf8)
[IO.File]::WriteAllText((Join-Path $app 'data\settings.json'), (ConvertTo-Json ([ordered]@{ outDir = $A }) -Depth 4), $utf8)
[IO.File]::WriteAllText((Join-Path $app 'integrations\tiktok\start.ps1'), '# dummy starter: the smoke uses the fake backend')
Remove-Item -LiteralPath $seed

# fake backend
$state = Join-Path $Work 'backend-state.json'
[IO.File]::WriteAllText($state, '{"rows":{}}', $utf8)
$port = 18700 + (Get-Random -Maximum 200)
$be = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-File', (Join-Path $Repo 'tests\kho\smoke\smoke-fake-backend.ps1'), '-Port', $port, '-State', $state) -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath ($state + '.ready')); $i++) { Start-Sleep -Milliseconds 250 }
if (-not (Test-Path -LiteralPath ($state + '.ready'))) { $be.Kill(); throw 'fake backend did not start' }

$gui = Join-Path $app 'core\kid-fby-gui.ps1'
$text = [IO.File]::ReadAllText($gui, [Text.Encoding]::UTF8)
$marker = '[void]$win.ShowDialog()'
$idx = $text.LastIndexOf($marker); if ($idx -lt 0) { throw 'ShowDialog marker not found' }
$text = $text.Substring(0, $idx) + ". '" + (Join-Path $Repo 'tests\kho\smoke\harness-p3.ps1') + "'`r`n    " + $text.Substring($idx)
$harnessGui = Join-Path $app 'core\kid-fby-gui-harness.ps1'
[IO.File]::WriteAllText($harnessGui, $text, (New-Object Text.UTF8Encoding($true)))
$out = Join-Path $Work 'harness-out.txt'
$env:KHO_HARNESS_OUT = $out; $env:KHO_SHOTS = $Shots; $env:KHO_SMOKE_DIR = $Work; $env:KHO_BACKEND_STATE = $state; $env:KID_FBY_NO_MSGBOX = '1'
$env:KID_FBY_AUTOTOK_STARTER = (Join-Path $app 'integrations\tiktok\start.ps1'); $env:KID_FBY_TIKTOK_URL = "http://127.0.0.1:$port"
try {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-STA', '-File', $harnessGui) -PassThru -RedirectStandardError (Join-Path $Work 'stderr.txt') -RedirectStandardOutput (Join-Path $Work 'stdout.txt')
    [void]$p.Handle
    if (-not $p.WaitForExit(420000)) { $p.Kill(); Write-Output 'TIMEOUT: killed' }
    Write-Output "exit=$($p.ExitCode)"
} finally { try { Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/quit" | Out-Null } catch { try { $be.Kill() } catch { } } }
if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Encoding UTF8 }
Get-Content -LiteralPath (Join-Path $Work 'stderr.txt') -ErrorAction SilentlyContinue | Select-Object -First 20
