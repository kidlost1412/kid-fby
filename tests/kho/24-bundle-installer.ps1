# Bundle allowlist for the Chrome extension (a key file fails the build) and the installer's extension stage / verify / swap / rollback /
# busy-postpone, using temp folders and a FAKE local /health. Nothing here touches the real integrations\, data\ or output\.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_load.ps1')
$repo = $script:RepoRoot
$u8 = New-Object Text.UTF8Encoding($false)
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ------------------------------------------------------------------ bundle ----
function New-ExtCopy {
    $d = New-TestDir; $e = Join-Path $d 'ext'
    Copy-Item -LiteralPath (Join-Path $repo 'integrations\autotok-extension') -Destination $e -Recurse
    return $e
}
function Invoke-Build { param([string]$Ext, [string]$Out) $ErrorActionPreference = 'Continue'; $o = (& $psExe -NoProfile -File (Join-Path $repo 'build-autotok-bundle.ps1') -OutFile $Out -ExtensionDir $Ext 2>&1 | Out-String); return @{ Exit = $LASTEXITCODE; Text = $o } }
function Get-ZipNames { param([string]$Zip) $z = [IO.Compression.ZipFile]::OpenRead($Zip); try { return @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() } }

Test-Case 'bundle: only the allowlist of the extension goes in (manifest, js/html/css, icons, the guide); devserver, tests, *.md and stray files stay out' {
    $e = New-ExtCopy; $out = Join-Path (Split-Path $e) 'b.zip'
    [void][IO.Directory]::CreateDirectory((Join-Path $e 'icons'))
    [IO.File]::WriteAllBytes((Join-Path $e 'icons\a.png'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllText((Join-Path $e 'notes-private.txt'), 'x'); [IO.File]::WriteAllText((Join-Path $e 'data.json'), '{}')
    $r = Invoke-Build $e $out
    Assert-Equal $r.Exit 0 "build failed: $($r.Text)"
    $names = Get-ZipNames $out | Where-Object { $_ -like 'extension/*' }
    foreach ($want in 'extension/manifest.json', 'extension/sw.js', 'extension/popup.html', 'extension/icons/a.png', 'extension/HUONG-DAN-CAI-TIEN-ICH.md') { Assert-True ($names -contains $want) "missing $want" }
    foreach ($bad in $names) {
        Assert-True ($bad -notlike 'extension/devserver/*' -and $bad -notlike 'extension/tests/*' -and $bad -notlike '*PROTOCOL.md' -and $bad -notlike '*DESIGN*' -and $bad -ne 'extension/notes-private.txt' -and $bad -ne 'extension/data.json') "leaked $bad"
    }
}
foreach ($case in @(@('key.pem', 'top-level .pem'), @('tests\old\signing.key', 'a .key hidden in tests/'), @('devserver\id_rsa', 'id_rsa in devserver/'), @('update-signing-1.xml', 'signing xml'), @('x.crx', 'packed .crx'))) {
    Test-Case "bundle: key material in the extension folder FAILS the build and writes no zip ($($case[1]))" {
        $e = New-ExtCopy; $out = Join-Path (Split-Path $e) 'b.zip'
        $p = Join-Path $e $case[0]; [void][IO.Directory]::CreateDirectory((Split-Path $p)); [IO.File]::WriteAllText($p, 'secret')
        $r = Invoke-Build $e $out
        Assert-True ($r.Exit -ne 0) 'build must fail'
        Assert-True ($r.Text -match 'Key material') "message: $($r.Text)"
        Assert-True (-not [IO.File]::Exists($out)) 'no zip may be written'
    }
}

# --------------------------------------------------------------- installer ----
$installFile = Join-Path $repo 'integrations\autotok\kid-install.ps1'
$tk = $null; $pe = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installFile, [ref]$tk, [ref]$pe)
if ($pe.Count) { throw "kid-install.ps1 does not parse: $($pe[0].Message)" }
$want = 'Get-ExtActive', 'Remove-ExtTree', 'Test-ExtFolder', 'Install-Extension', 'Invoke-ExtensionInstall', 'Remove-TreeNoFollow', 'Get-Sha256Hex', 'Test-FailAt', 'Stop-Install',
    'Get-LocalJson', 'Get-FakeState', 'Read-JsonFile', 'Get-BundleTarget', 'Test-EntryName'
$fns = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $false)
Assert-Equal $fns.Count $want.Count 'installer functions found'
$tmpFns = Join-Path ([IO.Path]::GetTempPath()) ('kho-inst-' + [Guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($tmpFns, (($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n"), (New-Object Text.UTF8Encoding($true)))
. $tmpFns; Remove-Item -LiteralPath $tmpFns -Force
function Write-Log([string]$Text) { [IO.File]::AppendAllText($script:LogPath, $Text + "`r`n", $u8) }

function New-InstallWorld {
    # Fresh Integrations folder + a "release" folder holding the new extension files + the matching manifest info.
    param([hashtable]$Files = @{ 'manifest.json' = '{"v":2}'; 'sw.js' = 'new sw'; 'popup.html' = '<p>new</p>' })
    $root = New-TestDir
    $script:Integrations = Join-Path $root 'integrations'; $script:ExtDir = Join-Path $script:Integrations 'autotok-extension'
    $script:LogPath = Join-Path $root 'install.log'; $script:Utf8 = $u8; $script:Fake = ''; $script:FailAt = ''; $script:DrainTimeoutSec = 2
    $script:HealthUrl = 'http://127.0.0.1:1/health'
    $src = Join-Path $root 'release\.kid\extension'; [void][IO.Directory]::CreateDirectory($src)
    $info = @{ Files = @{} }
    foreach ($k in $Files.Keys) {
        [IO.File]::WriteAllText((Join-Path $src $k), $Files[$k], $u8)
        $info.Files["extension/$k"] = @{ Sha = (Get-FileHash -LiteralPath (Join-Path $src $k) -Algorithm SHA256).Hash.ToLowerInvariant(); Size = $Files[$k].Length }
    }
    $db = Join-Path $root 'data\autotok.db'; [void][IO.Directory]::CreateDirectory((Split-Path $db)); [IO.File]::WriteAllBytes($db, [byte[]](9, 8, 7, 6))
    return @{ Root = $root; Release = (Join-Path $root 'release'); Info = $info; Db = $db; DbHash = (Get-FileHash -LiteralPath $db).Hash }
}
function New-OldExt { [void][IO.Directory]::CreateDirectory($script:ExtDir); [IO.File]::WriteAllText((Join-Path $script:ExtDir 'manifest.json'), '{"v":1}', $u8); [IO.File]::WriteAllText((Join-Path $script:ExtDir 'old.js'), 'old', $u8) }
function Read-Ext { param([string]$Name) return [IO.File]::ReadAllText((Join-Path $script:ExtDir $Name), $u8) }
function Start-FakeHealth {
    # /health answers {"ext_active": N}; after FlipAfter requests it answers 0. Runs in its own runspace.
    param([int]$Active, [int]$FlipAfter = 0, [switch]$NoField)
    $tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start(); $port = $tcp.LocalEndpoint.Port; $tcp.Stop()
    $state = [hashtable]::Synchronized(@{ Active = $Active; Stop = $false; Hits = 0; FlipAfter = $FlipAfter; NoField = [bool]$NoField; Port = $port })
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $rs.SessionStateProxy.SetVariable('state', $state)
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        $l = [Net.HttpListener]::new(); $l.Prefixes.Add("http://127.0.0.1:$($state.Port)/"); $l.Start()
        try {
            $t = $null
            while (-not $state.Stop) {
                if (-not $t) { $t = $l.BeginGetContext($null, $null) }   # keep ONE pending accept: an abandoned one would swallow the next request
                if (-not $t.AsyncWaitHandle.WaitOne(100)) { continue }
                $c = $l.EndGetContext($t); $t = $null; $state.Hits++
                if ($state.FlipAfter -gt 0 -and $state.Hits -gt $state.FlipAfter) { $state.Active = 0 }
                $json = if ($state.NoField) { '{"status":"ok","native_schedule":1}' } else { '{"status":"ok","chrome_ext":1,"ext_active":' + $state.Active + '}' }
                $b = [Text.Encoding]::UTF8.GetBytes($json); $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
            }
        } finally { $l.Close() }
    })
    $async = $ps.BeginInvoke()
    $script:HealthUrl = "http://127.0.0.1:$port/health"
    return @{ State = $state; PS = $ps; Async = $async; RS = $rs }
}
function Stop-FakeHealth { param($H) $H.State.Stop = $true; try { [void]$H.PS.EndInvoke($H.Async) } finally { $H.PS.Dispose(); $H.RS.Dispose() } }

function Install-Idle { param($W) $h = Start-FakeHealth -Active 0; try { return (Install-Extension $W.Info (Join-Path $W.Release '.kid\extension')) } finally { Stop-FakeHealth $h } }
Test-Case 'bundle target: extension/<file> lands in <release>\.kid\extension\; traversal and absolute names are refused' {
    $dest = 'C:\x\rel'
    Assert-Equal (Get-BundleTarget 'extension/popup.html' $dest) 'C:\x\rel\.kid\extension\popup.html'
    Assert-Equal (Get-BundleTarget 'extension/icons/a.png' $dest) 'C:\x\rel\.kid\extension\icons\a.png'
    Assert-True ([bool](Test-EntryName 'extension/../evil.js')) 'Test-EntryName refuses ..'
}
Test-Case 'install: first install (no folder yet) stages, verifies and swaps; no .new / .bak left' {
    $w = New-InstallWorld
    Assert-Equal (Install-Idle $w) 'installed'
    Assert-Equal (Read-Ext 'sw.js') 'new sw'
    Assert-True (-not (Test-Path -LiteralPath ($script:ExtDir + '.new'))) '.new left'; Assert-True (-not (Test-Path -LiteralPath ($script:ExtDir + '.bak'))) '.bak without an old folder'
}
Test-Case 'install: upgrade swaps by rename, old folder kept as .bak, stale files of the old version are gone from the live folder' {
    $w = New-InstallWorld; New-OldExt
    Assert-Equal (Install-Idle $w) 'installed'
    Assert-Equal (Read-Ext 'manifest.json') '{"v":2}'; Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:ExtDir 'old.js'))) 'old.js must not survive'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path ($script:ExtDir + '.bak') 'old.js'), $u8)) 'old'
    Assert-Equal (Get-FileHash -LiteralPath $w.Db).Hash $w.DbHash 'database file touched'
}
Test-Case 'install: same content again is "current" and changes nothing (.bak of the previous swap stays)' {
    $w = New-InstallWorld; New-OldExt
    [void](Install-Idle $w)
    Assert-Equal (Install-Idle $w) 'current'
    Assert-True (Test-Path -LiteralPath (Join-Path ($script:ExtDir + '.bak') 'old.js')) '.bak must stay'
}
Test-Case 'install: a corrupted staged file (hash differs from the manifest) is refused; the live folder and the DB stay as they were' {
    $w = New-InstallWorld; New-OldExt
    [IO.File]::WriteAllText((Join-Path $w.Release '.kid\extension\sw.js'), 'TAMPERED', $u8)
    Assert-Throws { Install-Extension $w.Info (Join-Path $w.Release '.kid\extension') } '*does not match the bundle manifest*'
    Assert-Equal (Read-Ext 'manifest.json') '{"v":1}'; Assert-True (-not (Test-Path -LiteralPath ($script:ExtDir + '.new'))) '.new left behind'
    Assert-Equal (Get-FileHash -LiteralPath $w.Db).Hash $w.DbHash 'database file touched'
}
foreach ($phase in 'ext-stage', 'ext-swap', 'ext-verify') {
    Test-Case "install: failure at $phase restores the old folder byte-identical, leaves no .new, never touches the DB" {
        $w = New-InstallWorld; New-OldExt
        $script:Fake = 'services'; $script:FailAt = $phase
        $state = Join-Path $w.Root 'fake.json'; [IO.File]::WriteAllText($state, '{"ext_active":0}', $u8); $env:KID_AUTOTOK_FAKE_STATE = $state
        Assert-Throws { Install-Extension $w.Info (Join-Path $w.Release '.kid\extension') } '*Lỗi giả lập*'
        Assert-Equal (Read-Ext 'manifest.json') '{"v":1}'; Assert-Equal (Read-Ext 'old.js') 'old'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:ExtDir 'sw.js'))) 'new file leaked into the old folder'
        Assert-True (-not (Test-Path -LiteralPath ($script:ExtDir + '.new'))) '.new left behind'
        Assert-Equal (Get-FileHash -LiteralPath $w.Db).Hash $w.DbHash 'database file touched'
        Remove-Item Env:\KID_AUTOTOK_FAKE_STATE
    }
}
Test-Case 'install: Invoke-ExtensionInstall turns a failed swap into a Vietnamese note instead of failing the backend install' {
    $w = New-InstallWorld; New-OldExt
    $script:Fake = 'services'; $script:FailAt = 'ext-swap'
    $state = Join-Path $w.Root 'fake.json'; [IO.File]::WriteAllText($state, '{"ext_active":0}', $u8); $env:KID_AUTOTOK_FAKE_STATE = $state
    $note = Invoke-ExtensionInstall $w.Info $w.Release
    Remove-Item Env:\KID_AUTOTOK_FAKE_STATE
    Assert-True ($note -like '*Tiện ích Chrome chưa cập nhật được*') "note: $note"; Assert-Equal (Read-Ext 'manifest.json') '{"v":1}'
}
foreach ($busy in -1, 1, 3) {
    Test-Case "install: /health ext_active=$busy -> waits, then POSTPONES (nothing swapped, no .new, logged)" {
        $w = New-InstallWorld; New-OldExt; $h = Start-FakeHealth -Active $busy
        try { $r = Install-Extension $w.Info (Join-Path $w.Release '.kid\extension') } finally { Stop-FakeHealth $h }
        Assert-Equal $r 'postponed'; Assert-True ($h.State.Hits -ge 1) 'asked /health'
        Assert-Equal (Read-Ext 'manifest.json') '{"v":1}'; Assert-True (-not (Test-Path -LiteralPath ($script:ExtDir + '.new'))) '.new left'
        Assert-True ([IO.File]::ReadAllText($script:LogPath, $u8) -match 'POSTPONED') 'postpone must be logged'
    }
}
Test-Case 'install: busy first, idle a moment later -> swaps after waiting (not postponed)' {
    $w = New-InstallWorld; New-OldExt; $script:DrainTimeoutSec = 30; $h = Start-FakeHealth -Active -1 -FlipAfter 2
    try { $r = Install-Extension $w.Info (Join-Path $w.Release '.kid\extension') } finally { Stop-FakeHealth $h }
    Assert-Equal $r 'installed'; Assert-True ($h.State.Hits -ge 3) 'polled until idle'; Assert-Equal (Read-Ext 'manifest.json') '{"v":2}'
}
Test-Case 'install: backend without the ext_active field (older backend) swaps at once' {
    $w = New-InstallWorld; New-OldExt; $h = Start-FakeHealth -Active 0 -NoField
    try { $r = Install-Extension $w.Info (Join-Path $w.Release '.kid\extension') } finally { Stop-FakeHealth $h }
    Assert-Equal $r 'installed'
}
Test-Case 'install: fake-state mode reads ext_active from the state file (-1 = busy -> postponed)' {
    $w = New-InstallWorld; New-OldExt; $script:Fake = 'services'
    $state = Join-Path $w.Root 'fake.json'; [IO.File]::WriteAllText($state, '{"ext_active":-1}', $u8); $env:KID_AUTOTOK_FAKE_STATE = $state
    $r = Install-Extension $w.Info (Join-Path $w.Release '.kid\extension'); Remove-Item Env:\KID_AUTOTOK_FAKE_STATE
    Assert-Equal $r 'postponed'
}
Test-Case 'install: /health not answering = unknown = busy: postponed, never guessed idle' {
    $w = New-InstallWorld; New-OldExt
    Assert-Equal (Install-Extension $w.Info (Join-Path $w.Release '.kid\extension')) 'postponed'; Assert-Equal (Read-Ext 'manifest.json') '{"v":1}'
}
Test-Case 'install: a bundle without extension files (older bundle) is "none" and leaves the folder alone' {
    $w = New-InstallWorld; New-OldExt; $w.Info.Files = @{ 'autotok/start.ps1' = @{ Sha = 'a'; Size = 1 } }
    Assert-Equal (Install-Extension $w.Info (Join-Path $w.Release '.kid\extension')) 'none'; Assert-Equal (Read-Ext 'manifest.json') '{"v":1}'
}
Test-Case 'Remove-ExtTree refuses any folder other than the three extension folders' {
    $w = New-InstallWorld
    Assert-Throws { Remove-ExtTree $w.Root } '*Refusing to delete*'
    Assert-Throws { Remove-ExtTree (Join-Path $script:Integrations 'autotok-releases') } '*Refusing to delete*'
}
Complete-Tests
