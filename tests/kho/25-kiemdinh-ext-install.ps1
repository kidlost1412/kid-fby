# Independent QA (kiem-dinh): power loss in the middle of the installer's extension swap, then the next run.
# Requirement C5: "a failure or power loss at each switch step (simulated)" must never leave Chrome without an extension
# folder. Temp folders and a FAKE /health only; nothing touches the real integrations\, data\ or output\.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_load.ps1')
$repo = $script:RepoRoot
$u8 = New-Object Text.UTF8Encoding($false)
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

function Set-PowerLossAfterOldMoved {
    # State on disk when the power went out right after "autotok-extension -> autotok-extension.bak" and before
    # "autotok-extension.new -> autotok-extension": no live folder, the old one in .bak, the staged new one in .new.
    param($W)
    New-OldExt
    $new = $script:ExtDir + '.new'; [void][IO.Directory]::CreateDirectory($new)
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $W.Release '.kid\extension') -File)) { [IO.File]::Copy($f.FullName, (Join-Path $new $f.Name)) }
    [IO.Directory]::Move($script:ExtDir, $script:ExtDir + '.bak')
}

Test-Case 'power loss between the two renames, next run finds the backend busy (postponed): Chrome must still have an extension folder' {
    $w = New-InstallWorld; Set-PowerLossAfterOldMoved $w
    Assert-True (-not (Test-Path -LiteralPath $script:ExtDir)) 'setup: live folder gone'
    $h = Start-FakeHealth -Active 1
    try { $r = Install-Extension $w.Info (Join-Path $w.Release '.kid\extension') } finally { Stop-FakeHealth $h }
    Assert-True (Test-Path -LiteralPath (Join-Path $script:ExtDir 'manifest.json')) "after '$r' there is no autotok-extension\manifest.json: Chrome cannot load the extension"
    Assert-Equal (Get-FileHash -LiteralPath $w.Db).Hash $w.DbHash 'database file touched'
}
Test-Case 'power loss between the two renames, next run swaps but fails at ext-swap: the old version must come back, not nothing' {
    $w = New-InstallWorld; Set-PowerLossAfterOldMoved $w
    $script:Fake = 'services'; $script:FailAt = 'ext-swap'
    $state = Join-Path $w.Root 'fake.json'; [IO.File]::WriteAllText($state, '{"ext_active":0}', $u8); $env:KID_AUTOTOK_FAKE_STATE = $state
    try { try { [void](Install-Extension $w.Info (Join-Path $w.Release '.kid\extension')) } catch { } } finally { Remove-Item Env:\KID_AUTOTOK_FAKE_STATE }
    Assert-True (Test-Path -LiteralPath (Join-Path $script:ExtDir 'manifest.json')) 'no extension folder left after a failed swap'
}
Test-Case 'power loss between the two renames, next run idle: the new version is installed' {
    $w = New-InstallWorld; Set-PowerLossAfterOldMoved $w
    Assert-Equal (Install-Idle $w) 'installed'
    Assert-Equal (Read-Ext 'sw.js') 'new sw'
}
Complete-Tests
