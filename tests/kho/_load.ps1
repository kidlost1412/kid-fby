# Test harness (dot-source it): loads every top-level function of core\kid-fby-gui.ps1 through the PowerShell AST
# (no WPF, no script-level code runs), replaces the logging/toast functions with recorders, and offers tiny assert helpers.
# Optional before dot-sourcing: $KhoGuiFile = another copy of kid-fby-gui.ps1 (used to load the v3.0.1 baseline).
$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$khoGuiPath = if ($KhoGuiFile) { $KhoGuiFile } else { Join-Path $script:RepoRoot 'core\kid-fby-gui.ps1' }
$khoTokens = $null; $khoParseErrors = $null
$khoAst = [System.Management.Automation.Language.Parser]::ParseFile($khoGuiPath, [ref]$khoTokens, [ref]$khoParseErrors)
if ($khoParseErrors.Count) { throw "Parse errors in ${khoGuiPath}: $($khoParseErrors[0].Message)" }
$khoFunctions = $khoAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
$khoFunctionFile = Join-Path ([IO.Path]::GetTempPath()) ('kho-funcs-' + [Guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($khoFunctionFile, (($khoFunctions | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n"), [Text.UTF8Encoding]::new($true))
. $khoFunctionFile
Remove-Item -LiteralPath $khoFunctionFile -Force
# The TikTok background worker is a script block assigned to $script:tikTokWorker.
$khoWorkerAssign = $khoAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:tikTokWorker' }, $false) | Select-Object -First 1
if ($khoWorkerAssign) {
    $khoWorkerText = $khoWorkerAssign.Right.Extent.Text
    $script:WorkerBlock = [scriptblock]::Create($khoWorkerText.Substring(1, $khoWorkerText.Length - 2))
}

# Function-name lists defined by script-level assignments (runspace session states are built from them).
foreach ($listName in '$script:tikTokWorkerFunctions', '$script:khoImportFunctions') {
    $assign = $khoAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $listName }, $false) | Select-Object -First 1
    if ($assign) { Invoke-Expression $assign.Extent.Text }
}

# Recorders instead of the real log / toast functions (the real ones write into the install's logs folder or need WPF).
$script:TestLog = New-Object System.Collections.Generic.List[string]
function Write-FileLog { param([string]$Text, [switch]$Immediate) $script:TestLog.Add($Text) }
function Add-Log { param([string]$Text, [string]$Level = 'Info') $script:TestLog.Add("[$Level] $Text") }
function Show-Toast { param([string]$Text, $Kind) $script:TestLog.Add("[toast] $Text") }

# ---- v3.0.1 baseline (git) for comparisons ----
$script:BaseCommit = 'c29c066'
$script:BaseAst = $null
function Get-BaseGuiFile {
    # Path of a temp copy of the baseline kid-fby-gui.ps1, or $null when git / the commit is not available.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('kho-base-' + $script:BaseCommit + '.ps1')
    if (-not [IO.File]::Exists($tmp) -or (Get-Item -LiteralPath $tmp).Length -lt 1000) {
        $partial = $tmp + '.' + [Guid]::NewGuid().ToString('N')
        & cmd.exe /c ('git -C "' + $script:RepoRoot + '" show ' + $script:BaseCommit + ':core/kid-fby-gui.ps1 > "' + $partial + '" 2>nul')
        if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($partial) -or (Get-Item -LiteralPath $partial).Length -lt 1000) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue; return $null }
        Move-Item -LiteralPath $partial -Destination $tmp -Force
    }
    return $tmp
}
function Get-BaseGuiFunction {
    # Text of a baseline function renamed to $AsName; $null when the baseline is not available.
    param([string]$Name, [string]$AsName)
    $file = Get-BaseGuiFile
    if (-not $file) { return $null }
    if (-not $script:BaseAst) {
        $t = $null; $e = $null
        $script:BaseAst = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$t, [ref]$e)
    }
    $fn = $script:BaseAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $false) | Select-Object -First 1
    if (-not $fn) { throw "Baseline has no function $Name" }
    return ($fn.Extent.Text -replace ('^function\s+' + [regex]::Escape($Name)), ('function ' + $AsName))
}

# ---- tiny test framework ----
$script:TestPass = 0; $script:TestFail = 0; $script:TestSkip = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:TestPass++; Write-Output "PASS  $Name" }
    catch { $script:TestFail++; Write-Output "FAIL  $Name :: $($_.Exception.Message)" }
}
function Skip-Case { param([string]$Name, [string]$Why) $script:TestSkip++; Write-Output "SKIP  $Name :: $Why" }
function Assert-True { param($Value, [string]$Message = 'expected true') if (-not $Value) { throw $Message } }
function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if ("$Actual" -cne "$Expected") { throw "$Message expected '$Expected' but got '$Actual'" }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Like = '*')
    $threw = $false
    try { & $Body } catch { $threw = $true; if ($_.Exception.Message -notlike $Like) { throw "threw '$($_.Exception.Message)', expected like '$Like'" } }
    if (-not $threw) { throw 'expected an exception but none was thrown' }
}
function New-TestDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('kho-test-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($d)
    return $d
}
function Read-TestJson { param([string]$Path) return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))) }
function Write-TestMetadata {
    # Writes reup-status.json from a hashtable of id -> entry hashtable (real shape: Posted/Date + optional fields).
    param([string]$Dir, $Entries)
    [void][IO.Directory]::CreateDirectory($Dir)
    [IO.File]::WriteAllText((Join-Path $Dir 'reup-status.json'), (ConvertTo-Json -InputObject $Entries -Depth 12), [Text.UTF8Encoding]::new($false))
}
function New-TestHistoryEntry {
    param([string]$Request, [string]$User, [string]$Status = 'succeeded', [string]$Accepted = '2026-10-20T10:00:00Z', [string]$Created = '2026-10-20T09:00:00Z', [bool]$Uncertain = $false)
    return [ordered]@{ key = "request:$Request"; request_id = $Request; username = $User; status = $Status; publish_uncertain = $Uncertain; prior_uncertain = $false
        planned_for = ''; accepted_at = $Accepted; created_at = $Created; time_source = 'backend'; sha256 = ''; post_url = ''; post_id = ''; link_state = ''
        tiktok_schedule_time = ''; schedule_mode = 'now' }
}
# ---- physical kho world (temp root, registry v2, complete videos) ----
function New-TestWorld {
    # Fresh $script:root (temp) with data\, registry reset, every busy flag cleared. Kho "Output cũ" = <root>\kho-A (the legacy outDir);
    # every name in -Names becomes a kho at <root>\kho-<name> made by the product's New-Kho. Returns @{ A; <name> = library }.
    param([string[]]$Names = @('B'))
    $script:root = New-TestDir
    [void][IO.Directory]::CreateDirectory((Join-Path $script:root 'data'))
    $script:khoRegistry = $null; $script:khoRegistryReady = $true
    $script:khoLegacyOutDir = Join-Path $script:root 'kho-A'
    $script:khoMoveRunning = $false; $script:importBusy = $false; $script:stopping = $false; $script:autotokInstall = $false
    $script:khoExclusive = 0; $script:ps = $null; $script:queue = @(); $script:tikTokSync = $null; $script:khoRecycleOverride = $null
    $script:khoAutoMoveFailed = @{}; $script:khoAutoMoveWanted = $false; $script:reelCacheName = '.cache'
    $script:TestLog.Clear()
    [void][IO.Directory]::CreateDirectory($script:khoLegacyOutDir)
    $reg = Get-KhoRegistry
    $world = @{ A = $reg.libraries[0] }
    foreach ($n in $Names) { $world[$n] = New-Kho -Name $n -Path (Join-Path $script:root ('kho-' + $n)) }
    return $world
}
function Get-TestBytes { param([string]$Text) return [Text.Encoding]::UTF8.GetBytes($Text) }
function New-TestVideo {
    # A complete Reel in a kho folder: -3, .cache\-1/-2 (or legacy root -1/-2 with -Legacy), thumbs jpg+json, a finished receipt and an
    # archived copy of it (VideoId inside), plus -Entry (a metadata entry hashtable) written through Update-ReupMetadata.
    param([string]$Root, [string]$Id, [switch]$Legacy, [switch]$NoReceipt, [switch]$NoThumb, $Entry = $null, [string]$User = 'anna')
    [void][IO.Directory]::CreateDirectory($Root)
    $cache = Join-Path $Root '.cache'
    [IO.File]::WriteAllBytes((Join-Path $Root "$Id-3-hoan-chinh.mp4"), (Get-TestBytes "final $Id"))
    $dir = $(if ($Legacy) { $Root } else { $cache })
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllBytes((Join-Path $dir "$Id-1-video-goc.mp4"), (Get-TestBytes "source $Id"))
    [IO.File]::WriteAllBytes((Join-Path $dir "$Id-2-am-thanh-tho.m4a"), (Get-TestBytes "audio $Id"))
    if (-not $NoThumb) {
        $t = Join-Path $cache 'thumbs'; [void][IO.Directory]::CreateDirectory($t)
        [IO.File]::WriteAllBytes((Join-Path $t "$Id.jpg"), (Get-TestBytes "thumb $Id"))
        [IO.File]::WriteAllBytes((Join-Path $t "$Id.json"), (Get-TestBytes "{}"))
    }
    $req = '{0:x32}' -f [long]$Id
    if (-not $NoReceipt) {
        $rec = [pscustomobject]@{ RequestId = $req; VideoId = $Id; Username = $User; ScheduledFor = ''; Status = 'posted'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''
                                  OutDir = $Root; SourcePath = (Join-Path $Root "$Id-3-hoan-chinh.mp4"); SourceSha256 = ''; UploadSha256 = '' }
        Save-TikTokReceipt $rec
        $posts = Join-Path $cache 'tiktok-posts'
        $arch = '{0:x32}' -f ([long]$Id + 7)
        $rec2 = $rec.PSObject.Copy(); $rec2.RequestId = $arch
        [IO.File]::WriteAllText((Join-Path $posts "$arch.json.archived-20261021-101010"), (ConvertTo-Json $rec2 -Depth 5), [Text.UTF8Encoding]::new($false))
    }
    if ($null -ne $Entry) {
        [void](Update-ReupMetadata -OutDir $Root -Change { param($meta) $meta | Add-Member -MemberType NoteProperty -Name $Id -Force -Value ([pscustomobject]$Entry); return $true })
    }
    return $req
}
function New-TestPostedEntry {
    # Metadata entry with one confirmed TikTok post (history shape of the sync).
    param([string]$Request, [string]$User = 'anna', [string]$Accepted = '2026-10-25T10:00:00Z')
    $h = New-TestHistoryEntry -Request $Request -User $User -Accepted $Accepted
    return [ordered]@{ Posted = $true; Date = '25/10 17:00'; Source = 'autotok-history'; History = @($h); ManualPosted = $false; ManualDate = ''; FileSha256 = 'sha-' + $Request }
}
function Get-TestTree {
    # relative path -> sha256 for every file under a folder (proves "untouched"); journals / temp excluded by the caller.
    param([string]$Dir)
    if (-not [IO.Directory]::Exists($Dir)) { return '' }
    $base = (Get-Item -LiteralPath $Dir -Force).FullName.TrimEnd('\')
    return ((Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($base.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|')
}
function Get-TestJournalFiles { return @(if ([IO.Directory]::Exists((Join-Path $script:root 'data\kho-moves'))) { Get-ChildItem -LiteralPath (Join-Path $script:root 'data\kho-moves') -Force -File }) }

# Unique ids per call, so a leftover file of one test can never satisfy another.
$script:seq = [long](1000000000000 + ([long]([DateTime]::UtcNow.Ticks / 10000) % 800000000000))   # unique per run (the Recycle Bin keeps names between runs)
function NextId { $script:seq++; return [string]$script:seq }
function Item { param($Root, [string]$Id) return [pscustomobject]@{ Id = $Id; Path = (Join-Path $Root "$Id-3-hoan-chinh.mp4") } }
function Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Posts { param($Root) return (Join-Path $Root '.cache\tiktok-posts') }
function Write-Job {
    # A retained / live job file of a request: <req>.job with Record.VideoId, plus optional <req>.lock.
    param($Root, [string]$Req, [string]$VideoId, [switch]$Lock, [string]$Raw = '')
    $d = Posts $Root; [void][IO.Directory]::CreateDirectory($d)
    $text = $(if ($Raw) { $Raw } else { ConvertTo-Json @{ Record = @{ VideoId = $VideoId; RequestId = $Req } } -Depth 4 })
    [IO.File]::WriteAllText((Join-Path $d "$Req.job"), $text, [Text.UTF8Encoding]::new($false))
    if ($Lock) { [IO.File]::WriteAllText((Join-Path $d "$Req.lock"), '', [Text.UTF8Encoding]::new($false)) }
}
function Assert-Moved {
    # The complete end state of a finished move of $Id from $From to $To (shared with the journal-recovery tests).
    param($From, $To, [string]$Id, [string]$Req)
    foreach ($rel in @("$Id-3-hoan-chinh.mp4", ".cache\$Id-1-video-goc.mp4", ".cache\$Id-2-am-thanh-tho.m4a", ".cache\thumbs\$Id.jpg", ".cache\thumbs\$Id.json", ".cache\tiktok-posts\$Req.json")) {
        Assert-True (-not [IO.File]::Exists((Join-Path $From $rel))) "still in source: $rel"
        Assert-True ([IO.File]::Exists((Join-Path $To $rel))) "missing in target: $rel"
    }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $To "$Id-3-hoan-chinh.mp4"))) "final $Id" 'final bytes'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $To ".cache\$Id-1-video-goc.mp4"))) "source $Id"
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $To ".cache\$Id-2-am-thanh-tho.m4a"))) "audio $Id"
    $rec = Read-TestJson (Join-Path $To ".cache\tiktok-posts\$Req.json")
    Assert-Equal $rec.OutDir $To 'receipt OutDir'; Assert-Equal $rec.SourcePath (Join-Path $To "$Id-3-hoan-chinh.mp4") 'receipt SourcePath'
    $meta = Get-ReupMetadata -OutDir $To
    Assert-True ($null -ne $meta.PSObject.Properties[$Id]) 'target entry'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $From).PSObject.Properties[$Id]) 'source entry removed'
    Assert-Equal @(Get-TestJournalFiles).Count 0 'journal gone'
}


function Complete-Tests {
    Write-Output "SUMMARY pass=$($script:TestPass) fail=$($script:TestFail) skip=$($script:TestSkip)"
    if ($script:TestFail -gt 0) { exit 1 }
    exit 0
}
