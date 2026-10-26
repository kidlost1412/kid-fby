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
function Complete-Tests {
    Write-Output "SUMMARY pass=$($script:TestPass) fail=$($script:TestFail) skip=$($script:TestSkip)"
    if ($script:TestFail -gt 0) { exit 1 }
    exit 0
}
