#Requires -Version 5.1
<#
One-click install / update of the TikTok backend (autotok) for Kid FB.Y. Shipped inside core\autotok-bundle.zip;
the GUI extracts this script and runs it hidden:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File kid-install.ps1 -Root <Kid FB.Y folder>
      [-Bundle <zip>] [-ProgressFile <file>] [-TakeOverStarter]
Layout (all under <Root>\integrations):
  autotok-releases\<sha12>-<yyyyMMdd-HHmmss>\  one release: backend files + its own .venv + runtime\
  autotok-python311\                            pinned CPython (the venvs' base); shared, kept across releases
  autotok-current.json                         {release, sha, version, installedAt, previous}
  autotok-config.json                           {DataDir}; shared by every release (data never moves)
  autotok-start.ps1                             stable starter; integrations\tiktok\local.json points here
  autotok-install.log                           durable log (phases and outcomes, no secrets)
  autotok-install.lock / autotok-upgrade.lock   held while installing / while switching releases
Progress on stdout and in -ProgressFile:  @@AUTOTOK_STEP <phase> <pct> <message>
Final line:                               @@AUTOTOK_RESULT ok|failed <reason> <message>
The old release stays current until the new one has passed every check and answered on /health; any failure
after the old services were stopped puts the old release back and starts it again.
Test switches (never set by the GUI): KID_AUTOTOK_INSTALL_FAKE=services|all replaces the service layer (start,
stop, health, jobs, ports) - and with 'all' also Python/pip/validation - by a JSON state file
KID_AUTOTOK_FAKE_STATE ('dead'/'broken': services down / not coming back on start); KID_AUTOTOK_FAIL_AT=<phase>
injects a failure, hang-<phase> waits there to be killed (fake mode only).
Takeover of a git/custom starter keeps a durable journal (autotok-takeover-journal.json) until the new release is
verified; rollback, the next run and autotok-start.ps1 restore the old setup from it.
Chrome extension: bundle entries extension/<file> are verified, staged to integrations\autotok-extension.new and swapped in by
rename (old folder kept as .bak, restored on any failure). The swap waits while /health says ext_active is busy (-1 or > 0), up to
-DrainTimeoutSec, then is postponed to the next run. It never touches the database (data lives outside the releases).
KID_AUTOTOK_PYTHON_NUPKG may point at an already downloaded python nupkg; it must match the pinned SHA256.
#>
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Bundle = '',
    [string]$ProgressFile = '',
    [switch]$TakeOverStarter,
    [int]$DrainTimeoutSec = 300,
    [int]$ReadyTimeoutSec = 90
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Python runs with -X utf8; read its output as UTF-8 so Vietnamese paths survive in the log.
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { <# no console (redirected host): keep default #> }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Pinned runtime: NuGet package "python" 3.11.9 (CPython for Windows x64). Its tools\ folder (with the PSF licence
# LICENSE.txt and the bundled pip/setuptools licences) is extracted unchanged to autotok-python311\.
# SHA512 of this file matches the packageHash published in the nuget.org catalog.
$PythonVersion = '3.11.9'
$PythonNupkgUrl = 'https://api.nuget.org/v3-flatcontainer/python/3.11.9/python.3.11.9.nupkg'
$PythonNupkgSha256 = '9283876D58C017E0E846F95B490DA3BCA0FC0A6EE1134B2870677CFB7EEC3C67'
$PythonNupkgSize = 17478009
$PypiIndex = 'https://pypi.org/simple'
$MaxExpandedBytes = 60MB
$MaxEntries = 3000
$ReleasePattern = '^[0-9a-f]{12}-[0-9]{8}-[0-9]{6}$'

$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
if (-not $Bundle) { $Bundle = Join-Path $Root 'core\autotok-bundle.zip' }
$Integrations = Join-Path $Root 'integrations'
$Releases = Join-Path $Integrations 'autotok-releases'
$CurrentPath = Join-Path $Integrations 'autotok-current.json'
$ConfigPath = Join-Path $Integrations 'autotok-config.json'
$LauncherPath = Join-Path $Integrations 'autotok-start.ps1'
$LocalJsonPath = Join-Path $Integrations 'tiktok\local.json'
$TikTokStartPath = Join-Path $Integrations 'tiktok\start.ps1'
$LogPath = Join-Path $Integrations 'autotok-install.log'
$ExtDir = Join-Path $Integrations 'autotok-extension'
$HealthUrl = 'http://127.0.0.1:8765/health'   # tests point it at a fake /health
# Takeover of a git/custom setup: original bytes of the files below (fixed keys; paths never come from the journal),
# written before anything is stopped and deleted once the new release passed the readiness gate.
$JournalPath = Join-Path $Integrations 'autotok-takeover-journal.json'
$TakeoverFiles = [ordered]@{ local = $LocalJsonPath; config = $ConfigPath; current = $CurrentPath; launcher = $LauncherPath; tiktokStart = $TikTokStartPath }
# Not under tools\: "Gỡ thư viện" in the app deletes the whole tools folder.
$PythonDir = Join-Path $Integrations 'autotok-python311'
$Fake = [string]$env:KID_AUTOTOK_INSTALL_FAKE
if ($Fake -and $Fake -notin @('services', 'all')) { throw "KID_AUTOTOK_INSTALL_FAKE must be 'services' or 'all'." }
$FailAt = if ($Fake) { [string]$env:KID_AUTOTOK_FAIL_AT } else { '' }
$Utf8 = New-Object Text.UTF8Encoding($false)

# ------------------------------------------------------------------ output ----
function Write-Log([string]$Text) {
    try {
        [IO.File]::AppendAllText($LogPath, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' [' + $PID + '] ' + $Text + "`r`n"), $Utf8)
    } catch { [Console]::Error.WriteLine('autotok-install.log: ' + $_.Exception.Message) }
}
function Send-Line([string]$Line) {
    [Console]::Out.WriteLine($Line)
    if ($ProgressFile) {
        try { [IO.File]::AppendAllText($ProgressFile, $Line + "`n", $Utf8) } catch { Write-Log ('WARN progress file: ' + $_.Exception.Message) }
    }
}
function Write-Step([string]$Phase, [int]$Pct, [string]$Message) {
    Send-Line ("@@AUTOTOK_STEP $Phase $Pct " + ($Message -replace '[\r\n]+', ' '))
    Write-Log "STEP $Phase $Pct $Message"
}
function Stop-Install([string]$Reason, [string]$Message) {
    $e = New-Object Exception($Message)
    $e.Data['reason'] = $Reason
    throw $e
}
function Test-FailAt([string]$Phase) {
    # hang-<phase>: stop here so a test can kill the process at this point.
    if ($FailAt -eq "hang-$Phase") { Write-Step 'hang' 0 $Phase; Start-Sleep -Seconds 600 }
    if ($FailAt -eq $Phase) { Stop-Install "$Phase-failed" "Lỗi giả lập ở bước $Phase (chế độ kiểm thử)." }
}

# ------------------------------------------------------------- file helpers ----
function Write-FileAtomic([string]$Path, [byte[]]$Bytes) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $fs = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $fs.Write($Bytes, 0, $Bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Read-FileBytesOrNull([string]$Path) { if ([IO.File]::Exists($Path)) { return ,[IO.File]::ReadAllBytes($Path) } return $null }
function Restore-FileBytes([string]$Path, $Bytes) {
    if ($null -eq $Bytes) { if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) } }
    else { Write-FileAtomic $Path ([byte[]]$Bytes) }
}
function ConvertTo-JsonBytes($Object) { return ,$Utf8.GetBytes((($Object | ConvertTo-Json -Depth 5) -replace "`r?`n", "`r`n")) }
function Read-JsonFile([string]$Path) { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
function Get-Sha256Hex([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Open-ExclusiveLock([string]$Path, [string]$BusyMessage) {
    # DeleteOnClose: the file disappears with the handle, also when this process is killed.
    try { return New-Object IO.FileStream($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose) }
    catch { Stop-Install 'busy' $BusyMessage }
}
function Get-ProtectedDataDirs {
    # Every data folder the backend may use (this run's choice, autotok-config.json, AUTOTOK_DATA_DIR), as full paths.
    $dirs = @()
    if ($script:config -and $script:config.Dir) { $dirs += [string]$script:config.Dir }
    if ($env:AUTOTOK_DATA_DIR) { $dirs += [string]$env:AUTOTOK_DATA_DIR }
    if ([IO.File]::Exists($ConfigPath)) { try { $dirs += [string](Read-JsonFile $ConfigPath).DataDir } catch { <# unreadable config: nothing to add #> } }
    foreach ($d in $dirs) {
        if ($d.Trim() -notmatch '^([A-Za-z]:\\|\\\\[^\\])') { continue }
        try { [IO.Path]::GetFullPath($d.Trim()).TrimEnd('\') } catch { <# invalid path: cannot hold data #> }
    }
}
function Remove-DirectorySafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $full = [IO.Path]::GetFullPath($Path)
    # Only release folders and the installer's own python folders (staging / broken copies) may be deleted.
    $inReleases = $full.StartsWith([IO.Path]::GetFullPath($Releases).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    $isPythonWork = ([IO.Path]::GetDirectoryName($full) -ieq [IO.Path]::GetFullPath($Integrations).TrimEnd('\')) -and ([IO.Path]::GetFileName($full) -like 'autotok-python311.*')
    if (-not ($inReleases -or $isPythonWork)) { throw "Refusing to delete outside the installer folders: $full" }
    foreach ($data in @(Get-ProtectedDataDirs)) {
        if ($data -ieq $full.TrimEnd('\') -or $data.StartsWith($full.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "WARN not deleting $full : it holds the data folder $data"; return $false
        }
    }
    try { Remove-TreeNoFollow $full; return $true }
    catch { Write-Log "WARN cannot delete $full : $($_.Exception.Message)"; return $false }
}
function Remove-TreeNoFollow([string]$Path) {
    # Never follows a junction/symlink: a reparse point is removed as a link (the target stays), everything else is deleted.
    $info = New-Object IO.DirectoryInfo($Path)
    if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-Log "WARN reparse point removed as a link only (target kept): $Path"
        [IO.Directory]::Delete($Path, $false); return
    }
    foreach ($child in $info.GetFileSystemInfos()) {
        $isDir = [bool]($child.Attributes -band [IO.FileAttributes]::Directory)
        if ($isDir) { Remove-TreeNoFollow $child.FullName }
        else { $child.Attributes = [IO.FileAttributes]::Normal; [IO.File]::Delete($child.FullName) }
    }
    $info.Attributes = [IO.FileAttributes]::Directory
    [IO.Directory]::Delete($Path, $false)
}

# --------------------------------------------------------- bundle checking ----
function Test-EntryName([string]$Name) {
    # Zip entry names come from an archive: accept only plain relative file paths with '/' separators.
    if ([string]::IsNullOrEmpty($Name) -or $Name.Length -gt 200) { return 'empty or too long' }
    if ($Name -match '[\x00-\x1f\\:*?"<>|]') { return 'forbidden character (\, :, control, wildcard)' }
    if ($Name.StartsWith('/')) { return 'rooted path' }
    if ($Name.EndsWith('/')) { return 'directory entry' }
    foreach ($part in $Name.Split('/')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..') { return 'empty, . or .. segment' }
        if ($part.TrimEnd(' ', '.') -ne $part -or $part.StartsWith(' ')) { return 'segment ends with space or dot' }
        if ($part -match '^(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9]|conin\$|conout\$)(\..*)?$') { return 'reserved device name' }
    }
    return ''
}
function Get-BundleTarget([string]$Name, [string]$Dest) {
    # bundle.json and tiktok/start.ps1 go to <release>\.kid\; autotok/<x> goes to <release>\<x>.
    if ($Name -ceq 'bundle.json') { $rel = '.kid\bundle.json' }
    elseif ($Name -ceq 'tiktok/start.ps1') { $rel = '.kid\tiktok-start.ps1' }
    elseif ($Name.StartsWith('extension/', [StringComparison]::Ordinal)) { $rel = '.kid\extension\' + $Name.Substring(10).Replace('/', '\') }
    elseif ($Name.StartsWith('autotok/', [StringComparison]::Ordinal) -and -not $Name.StartsWith('autotok/.kid/', [StringComparison]::OrdinalIgnoreCase)) { $rel = $Name.Substring(8).Replace('/', '\') }
    else { return $null }
    $target = [IO.Path]::GetFullPath((Join-Path $Dest $rel))
    if (-not $target.StartsWith($Dest.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $target
}
function Read-Bundle([string]$Path) {
    # Checks the whole archive before anything is written: entry names, links, case collisions, limits, and that
    # the entries are exactly the files listed in bundle.json (size + SHA256 checked again while extracting).
    $info = @{ Sha = (Get-Sha256Hex $Path).ToLowerInvariant() }
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries)
        if ($entries.Count -eq 0 -or $entries.Count -gt $MaxEntries) { Stop-Install 'bundle-invalid' "Gói cài có $($entries.Count) mục (giới hạn $MaxEntries)." }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        $manifestEntry = $null
        foreach ($entry in $entries) {
            $why = Test-EntryName $entry.FullName
            if ($why) { Stop-Install 'bundle-invalid' "Gói cài có mục không an toàn '$($entry.FullName)': $why." }
            if (-not $seen.Add($entry.FullName)) { Stop-Install 'bundle-invalid' "Gói cài có mục trùng tên (không phân biệt hoa thường): '$($entry.FullName)'." }
            if (($entry.PSObject.Properties['ExternalAttributes']) -and ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000)) {
                Stop-Install 'bundle-invalid' "Gói cài có liên kết (symlink): '$($entry.FullName)'."
            }
            $total += $entry.Length
            if ($total -gt $MaxExpandedBytes) { Stop-Install 'bundle-invalid' "Gói cài giải nén vượt $MaxExpandedBytes byte." }
            if ($entry.FullName -ceq 'bundle.json') { $manifestEntry = $entry }
        }
        if (-not $manifestEntry -or $manifestEntry.Length -gt 1MB) { Stop-Install 'bundle-invalid' 'Gói cài thiếu bundle.json.' }
        $reader = New-Object IO.StreamReader($manifestEntry.Open(), [Text.Encoding]::UTF8)
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } catch { Stop-Install 'bundle-invalid' "bundle.json lỗi: $($_.Exception.Message)" } finally { $reader.Dispose() }
        if ([int]$manifest.format -ne 1 -or [string]$manifest.name -ne 'autotok' -or -not [string]$manifest.version) { Stop-Install 'bundle-invalid' 'bundle.json không đúng định dạng.' }
        $files = @{}
        foreach ($f in @($manifest.files)) {
            $p = [string]$f.path
            if ($files.ContainsKey($p) -or [string]$f.sha256 -notmatch '^[0-9a-f]{64}$' -or [long]$f.size -lt 0) { Stop-Install 'bundle-invalid' "bundle.json có mục lỗi: '$p'." }
            $files[$p] = @{ Sha = [string]$f.sha256; Size = [long]$f.size }
        }
        $listed = @($entries | Where-Object { $_.FullName -cne 'bundle.json' })
        if ($listed.Count -ne $files.Count) { Stop-Install 'bundle-invalid' 'Danh sách file trong gói không khớp bundle.json.' }
        foreach ($entry in $listed) {
            if (-not $files.ContainsKey($entry.FullName) -or $files[$entry.FullName].Size -ne $entry.Length) { Stop-Install 'bundle-invalid' "Mục '$($entry.FullName)' không khớp bundle.json." }
            if (-not (Get-BundleTarget $entry.FullName 'C:\x')) { Stop-Install 'bundle-invalid' "Mục '$($entry.FullName)' nằm ngoài thư mục cho phép." }
        }
        foreach ($required in @('autotok/kid-install.ps1', 'autotok/start.ps1', 'autotok/dung.ps1', 'autotok/autotok-start.ps1', 'autotok/run_autotok_web.py', 'autotok/requirements.lock.txt', 'tiktok/start.ps1')) {
            if (-not $files.ContainsKey($required)) { Stop-Install 'bundle-invalid' "Gói cài thiếu $required." }
        }
        $info.Version = [string]$manifest.version
        $info.Files = $files
        $info.Expanded = $total
    } finally { $zip.Dispose() }
    $info.Sha12 = $info.Sha.Substring(0, 12)
    return $info
}
function Expand-Bundle([string]$Path, [hashtable]$Info, [string]$Dest) {
    # Dest is a fresh directory. CreateNew everywhere: nothing existing is ever overwritten.
    New-Item -ItemType Directory -Path $Dest | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($entry in @($zip.Entries)) {
            $target = Get-BundleTarget $entry.FullName $Dest
            if (-not $target) { Stop-Install 'bundle-invalid' "Mục '$($entry.FullName)' nằm ngoài thư mục cho phép." }
            if ($target.Length -gt 240) { Stop-Install 'path-too-long' "Đường dẫn quá dài: $target. Chuyển Kid FB.Y sang thư mục ngắn hơn (ví dụ D:\KidFBY)." }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $in = $entry.Open()
            try {
                $out = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = New-Object byte[] 65536; [long]$written = 0
                    [void]$sha.Initialize()
                    while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $written += $n
                        if ($written -gt $entry.Length) { Stop-Install 'bundle-invalid' "Mục '$($entry.FullName)' lớn hơn khai báo." }
                        $out.Write($buffer, 0, $n)
                        [void]$sha.TransformBlock($buffer, 0, $n, $null, 0)
                    }
                    [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                    $out.Flush($true)
                } finally { $out.Dispose() }
            } finally { $in.Dispose() }
            if ($entry.FullName -cne 'bundle.json') {
                $hex = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
                if ($hex -ne $Info.Files[$entry.FullName].Sha -or $written -ne $Info.Files[$entry.FullName].Size) { Stop-Install 'bundle-invalid' "Sai SHA256: $($entry.FullName)." }
            }
        }
    } finally { $sha.Dispose(); $zip.Dispose() }
}
function Test-ManifestMatch([hashtable]$Info) {
    # When this folder has the release manifest of the running version (git checkout / full download), the bundle
    # must be the one it lists. Installs updated in-app were already checked by the updater against the signed manifest.
    $manPath = Join-Path $Root 'version.json'; $verPath = Join-Path $Root 'core\version.txt'
    if (-not (Test-Path -LiteralPath $manPath -PathType Leaf) -or -not (Test-Path -LiteralPath $verPath -PathType Leaf)) { return }
    try { $man = Read-JsonFile $manPath } catch { Write-Log "WARN version.json unreadable: $($_.Exception.Message)"; return }
    if ([string]$man.version -ne ([IO.File]::ReadAllText($verPath)).Trim()) { return }
    $listed = @($man.files | Where-Object { [string]$_.path -eq 'core/autotok-bundle.zip' })
    if ($listed.Count -and $Bundle -ieq (Join-Path $Root 'core\autotok-bundle.zip') -and ([string]$listed[0].sha256).ToLowerInvariant() -ne $Info.Sha) {
        Stop-Install 'bundle-mismatch' 'Gói cài core\autotok-bundle.zip không khớp version.json của bản này. Bấm Cập nhật trong app rồi thử lại.'
    }
}

# ------------------------------------------------------------ environment ----
function Find-Chrome {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $exe = Join-Path $base 'Google\Chrome\Application\chrome.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    }
    return ''
}
function ConvertTo-NativeText($Item) {
    # 2>&1 wraps stderr lines in ErrorRecords; a blank stderr line prints as the type name RemoteException.
    $text = if ($Item -is [Management.Automation.ErrorRecord]) { [string]$Item.Exception.Message } else { [string]$Item }
    if ($text -eq 'System.Management.Automation.RemoteException') { return '' }
    return $text
}
function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$Reason, [string]$What) {
    # Tools write warnings to stderr; keep them as log lines instead of terminating errors (Windows PowerShell 5.1).
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { ConvertTo-NativeText $_ }) } finally { $ErrorActionPreference = $old }
    $code = $LASTEXITCODE
    foreach ($l in $lines) { if ($l.Trim()) { Write-Log ('  | ' + $(if ($l.Length -gt 400) { $l.Substring(0, 400) } else { $l })) } }
    if ($code -ne 0) {
        $last = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 1)
        Stop-Install $Reason ("$What thất bại (mã $code). " + $(if ($last.Count) { $last[0].Trim() } else { '' }) + ' Xem integrations\autotok-install.log.')
    }
    return ,$lines
}
function Invoke-PowerShellFile([string]$File, [string[]]$Arguments) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $File @Arguments 2>&1 | ForEach-Object { ConvertTo-NativeText $_ }) } finally { $ErrorActionPreference = $old }
    $code = $LASTEXITCODE
    foreach ($l in $lines) { if ($l.Trim()) { Write-Log ('  | ' + $l) } }
    return @{ Code = $code; Lines = $lines }
}
function Invoke-PowerShellDetached([string]$File, [string]$LogDir) {
    # start.ps1 launches long-lived services that inherit our handles: no pipes, logs to files, wait for this process only.
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $out = Join-Path $LogDir 'kid-start.out.log'; $err = Join-Path $LogDir 'kid-start.err.log'
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $File + '"')) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle
    if (-not $p.WaitForExit(180000)) { return @{ Code = -1; Lines = @('start.ps1 did not finish within 180 s') } }
    $lines = @()
    foreach ($f in @($out, $err)) {
        try { $lines += @(([IO.File]::ReadAllText($f)) -split "`r?`n" | Where-Object { $_.Trim() }) } catch { $lines += "log unreadable: $f" }
    }
    foreach ($l in $lines) { Write-Log ('  | ' + $l) }
    return @{ Code = $p.ExitCode; Lines = $lines }
}
function Use-ScopedEnv([hashtable]$Values, [scriptblock]$Body) {
    $saved = @{}
    foreach ($k in $Values.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $Values[$k], 'Process') }
    try { & $Body } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') } }
}

# ---------------------------------------------------------------- python ----
function Test-PythonRuntime([string]$Dir) {
    $exe = Join-Path $Dir 'python.exe'
    if ($Fake -eq 'all') { return (Test-Path -LiteralPath (Join-Path $Dir 'fake-python.txt')) }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    # Collect all output: Select-Object -First stops the pipeline early and leaves $LASTEXITCODE at -1.
    try { $v = @(& $exe -I -X utf8 -c "import sys,venv,ensurepip;print('%d.%d.%d'%sys.version_info[:3])" 2>$null) } finally { $ErrorActionPreference = $old }
    return ($LASTEXITCODE -eq 0 -and $v.Count -ge 1 -and "$($v[0])".Trim() -eq $PythonVersion)
}
function Get-PythonPackage([string]$WorkDir) {
    $file = Join-Path $WorkDir 'python.nupkg'
    if ($env:KID_AUTOTOK_PYTHON_NUPKG) {
        Copy-Item -LiteralPath $env:KID_AUTOTOK_PYTHON_NUPKG -Destination $file
    } else {
        if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        $req = [Net.HttpWebRequest]::Create($PythonNupkgUrl)
        $req.UserAgent = 'KidFBY-Installer'; $req.Timeout = 30000; $req.ReadWriteTimeout = 60000; $req.AllowAutoRedirect = $true
        try { $resp = $req.GetResponse() } catch { Stop-Install 'python-failed' "Không tải được Python từ nuget.org: $($_.Exception.Message)" }
        try {
            if ($resp.ResponseUri.Scheme -ne 'https') { Stop-Install 'python-failed' 'Nguồn tải Python không phải HTTPS.' }
            $in = $resp.GetResponseStream(); $out = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 65536; [long]$got = 0; $lastPct = -1
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $got += $n
                    if ($got -gt $PythonNupkgSize) { Stop-Install 'python-failed' 'File Python tải về lớn hơn dự kiến.' }
                    $out.Write($buffer, 0, $n)
                    $pct = [int](20 + 10 * $got / $PythonNupkgSize)
                    if ($pct -ne $lastPct) { $lastPct = $pct; Write-Step 'python' $pct ("Đang tải Python $PythonVersion… " + [int]($got / 1MB) + '/' + [int]($PythonNupkgSize / 1MB) + ' MB') }
                }
            } finally { $out.Dispose(); $in.Dispose() }
        } catch [Net.WebException] { Stop-Install 'python-failed' "Tải Python bị ngắt: $($_.Exception.Message)" } catch [IO.IOException] { Stop-Install 'python-failed' "Tải Python bị ngắt: $($_.Exception.Message)" } finally { $resp.Close() }
    }
    $hash = Get-Sha256Hex $file
    if ($hash -ne $PythonNupkgSha256) { Stop-Install 'python-failed' "Python tải về sai SHA256 ($hash). Đã dừng, không cài." }
    return $file
}
function Install-PythonRuntime {
    Test-FailAt 'python'
    if (Test-PythonRuntime $PythonDir) { Write-Step 'python' 35 "Python $PythonVersion đã có."; return }
    Write-Step 'python' 20 "Đang chuẩn bị Python $PythonVersion…"
    $work = $PythonDir + '.staging-' + [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        if ($Fake -eq 'all') {
            New-Item -ItemType Directory -Path (Join-Path $work 'py') | Out-Null
            [IO.File]::WriteAllText((Join-Path $work 'py\fake-python.txt'), 'fake')
        } else {
            $pkg = Get-PythonPackage $work
            Write-Step 'python' 31 'Đang giải nén Python…'
            $dest = Join-Path $work 'py'
            New-Item -ItemType Directory -Path $dest | Out-Null
            $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
            try {
                foreach ($entry in @($zip.Entries)) {
                    if (-not $entry.FullName.StartsWith('tools/', [StringComparison]::Ordinal) -or $entry.FullName.EndsWith('/')) { continue }
                    $rel = $entry.FullName.Substring(6)
                    if (Test-EntryName $rel) { Stop-Install 'python-failed' "Gói Python có mục lạ: $($entry.FullName)" }
                    $target = [IO.Path]::GetFullPath((Join-Path $dest ($rel.Replace('/', '\'))))
                    if (-not $target.StartsWith($dest + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-Install 'python-failed' "Gói Python có mục lạ: $($entry.FullName)" }
                    $parent = Split-Path -Parent $target
                    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
                }
            } finally { $zip.Dispose() }
            Remove-Item -LiteralPath $pkg -Force
        }
        if (-not (Test-PythonRuntime (Join-Path $work 'py'))) { Stop-Install 'python-failed' "Python $PythonVersion vừa giải nén không chạy được." }
        if (Test-Path -LiteralPath $PythonDir) {
            # Broken leftover (a working one returned above). A python in use cannot be renamed: report, do not force.
            $aside = $PythonDir + '.broken-' + (Get-Date).ToString('yyyyMMddHHmmss')
            try { [IO.Directory]::Move($PythonDir, $aside) } catch { Stop-Install 'python-failed' "Không thay được $PythonDir (đang được dùng?): $($_.Exception.Message)" }
            [void](Remove-DirectorySafe $aside)
        }
        [IO.Directory]::Move((Join-Path $work 'py'), $PythonDir)
    } finally { [void](Remove-DirectorySafe $work) }
    Write-Step 'python' 35 "Đã cài Python $PythonVersion."
}

# --------------------------------------------------------- release runtime ----
function New-ReleaseVenv([string]$ReleaseDir) {
    $venv = Join-Path $ReleaseDir '.venv'
    $venvPy = Join-Path $venv 'Scripts\python.exe'
    Write-Step 'venv' 40 'Đang tạo môi trường Python riêng…'
    if ($Fake -eq 'all') { New-Item -ItemType Directory -Path (Split-Path -Parent $venvPy) -Force | Out-Null; [IO.File]::WriteAllText($venvPy + '.fake', 'fake') }
    else { [void](Invoke-Native (Join-Path $PythonDir 'python.exe') @('-I', '-X', 'utf8', '-m', 'venv', $venv) 'venv-failed' 'Tạo môi trường Python') }
    Write-Step 'deps' 45 'Đang tải và cài thư viện (khoảng 50 MB)…'
    Test-FailAt 'pip'
    if ($Fake -ne 'all') {
        $lock = Join-Path $ReleaseDir 'requirements.lock.txt'
        [void](Invoke-Native $venvPy @('-I', '-X', 'utf8', '-m', 'pip', 'install', '--isolated', '--disable-pip-version-check', '--no-input', '--no-warn-script-location',
            '--index-url', $PypiIndex, '--timeout', '60', '--retries', '5', '--require-hashes', '--only-binary=:all:', '--no-deps', '-r', $lock) 'pip-failed' 'Cài thư viện')
        Write-Step 'deps' 75 'Đang kiểm tra thư viện…'
        [void](Invoke-Native $venvPy @('-I', '-X', 'utf8', '-m', 'pip', 'check', '--isolated', '--disable-pip-version-check') 'pip-failed' 'Kiểm tra thư viện (pip check)')
    }
}
function Test-ReleaseRuntime([string]$ReleaseDir, [string]$DataDir, [switch]$Quiet) {
    # Imports of all three services + the host's own --check; nothing is started and the real data folder is not written.
    Test-FailAt 'validate'
    if ($Fake -eq 'all') { return (Test-Path -LiteralPath (Join-Path $ReleaseDir '.venv\Scripts\python.exe.fake')) }
    $venvPy = Join-Path $ReleaseDir '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPy -PathType Leaf)) { if ($Quiet) { return $false } Stop-Install 'validate-failed' 'Thiếu môi trường Python của bộ đăng.' }
    $scratch = Join-Path $ReleaseDir ('.validate-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        $code = "import sys,os;r=sys.argv[1];sys.path[:0]=[os.path.join(r,'src'),os.path.join(r,'src','web')];import api.main,scheduler.main,scheduler.worker,novnc.control_server,uvicorn,playwright.sync_api;print('IMPORT_OK')"
        $envs = @{ AUTOTOK_HOME = $scratch; AUTOTOK_VIDEOS_DIR = (Join-Path $scratch 'videos'); TIKTOK_API_DB_PATH = (Join-Path $scratch 'validate.db') }
        $here = Get-Location
        Set-Location -LiteralPath $scratch
        try {
            $imports = @(Use-ScopedEnv $envs { $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { @(& $venvPy -I -X utf8 -c $code $ReleaseDir 2>&1 | ForEach-Object { ConvertTo-NativeText $_ }) } finally { $ErrorActionPreference = $old } })
            $importCode = $LASTEXITCODE
        } finally { Set-Location -LiteralPath $here }
        foreach ($l in $imports) { if ($l.Trim()) { Write-Log ('  | ' + $l) } }
        if ($importCode -ne 0 -or ($imports -notcontains 'IMPORT_OK')) {
            if ($Quiet) { return $false }
            Stop-Install 'validate-failed' ('Bộ đăng không nạp được thư viện: ' + (@($imports | Where-Object { $_.Trim() } | Select-Object -Last 1) -join '') + ' Xem integrations\autotok-install.log.')
        }
    } finally { [void](Remove-DirectorySafe $scratch) }
    $check = @(Use-ScopedEnv @{ AUTOTOK_DATA_DIR = $DataDir } { $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { @(& $venvPy -X utf8 (Join-Path $ReleaseDir 'run_autotok_web.py') --check 2>&1 | ForEach-Object { ConvertTo-NativeText $_ }) } finally { $ErrorActionPreference = $old } })
    $checkCode = $LASTEXITCODE
    foreach ($l in $check) { Write-Log ('  | ' + $l) }
    $values = @{}
    foreach ($l in $check) { if ($l -match '^(SRC|DATA|DIST|CHROME)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    $problem = ''
    if ($checkCode -ne 0) { $problem = "run_autotok_web.py --check lỗi (mã $checkCode)." }
    elseif ($values.SRC -ne (Join-Path $ReleaseDir 'src')) { $problem = "Đường dẫn mã nguồn sai: $($values.SRC)" }
    elseif ($values.DATA -ne $DataDir) { $problem = "Thư mục dữ liệu sai: $($values.DATA)" }
    elseif ($values.DIST -notlike '*index.html=True') { $problem = 'Thiếu giao diện bảng điều khiển (frontend dist).' }
    elseif (-not $values.CHROME -or $values.CHROME -like 'NOT FOUND*') { $problem = 'Chưa có Google Chrome. Cài Chrome từ https://www.google.com/chrome/ rồi bấm lại.' }
    if ($problem) { if ($Quiet) { return $false } Stop-Install 'validate-failed' $problem }
    return $true
}

# ---------------------------------------------------------- service layer ----
# Real: HTTP on 127.0.0.1:8765/17900 and the release's own start.ps1 / dung.ps1. Fake: a JSON state file.
function Get-FakeState { return (Read-JsonFile $env:KID_AUTOTOK_FAKE_STATE) }
function Save-FakeState($State) { Write-FileAtomic $env:KID_AUTOTOK_FAKE_STATE (ConvertTo-JsonBytes $State) }
function Add-FakeEvent([string]$Text) { $s = Get-FakeState; $s.events = @($s.events) + $Text; Save-FakeState $s }
function Get-LocalJson([string]$Url) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Proxy = $null; $req.Timeout = 4000; $req.ReadWriteTimeout = 4000; $req.AllowAutoRedirect = $false
    $req.Headers.Add('X-Requested-With', 'autotok')
    $resp = $req.GetResponse()
    try { $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); return ($sr.ReadToEnd() | ConvertFrom-Json) } finally { $resp.Close() }
}
function Test-BackendHealthy {
    # True only for an autotok API new enough for Kid FB.Y (native TikTok scheduling).
    if ($Fake) { $s = Get-FakeState; return [bool]($s.running -and -not (@($s.unhealthy) -contains $s.running)) }
    try { $h = Get-LocalJson 'http://127.0.0.1:8765/health'; return ([string]$h.status -eq 'ok' -and [int]$h.native_schedule -eq 1) } catch { return $false }
}
function Test-PortsFree {
    if ($Fake) { return (-not (Get-FakeState).running) }
    foreach ($port in @(8765, 17900)) {
        $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if (@($listeners | Where-Object { $_.Port -eq $port }).Count) { return $false }
    }
    return $true
}
function Get-BusyJobCount {
    # Same rule as dung.ps1: running uploads and videos still waiting to be sent to TikTok block the switch.
    if ($Fake) { return [int](Get-FakeState).busy }
    $running = Get-LocalJson 'http://127.0.0.1:8765/api/schedules?status=running'
    $pending = Get-LocalJson 'http://127.0.0.1:8765/api/schedules?status=pending'
    $count = (@($running | Where-Object { $_ }).Count + @($pending | Where-Object { $_ }).Count)
    # Chrome publisher: waiting / posting jobs and a busy-or-unknown ext_active (-1) also block the switch.
    $h = Get-LocalJson $HealthUrl
    if ($null -ne $h.PSObject.Properties['chrome_ext']) {
        foreach ($st in @('pending_ext', 'waiting_ext')) { $count += @((Get-LocalJson "http://127.0.0.1:8765/api/schedules?status=$st") | Where-Object { $_ }).Count }
        if ($null -ne $h.PSObject.Properties['ext_active']) { $a = [int]$h.ext_active; if ($a -ne 0) { $count += [Math]::Max(1, $a) } }
    }
    return $count
}
function Test-ProcessRecordAlive($Record) {
    $p = Get-Process -Id ([int]$Record.pid) -ErrorAction SilentlyContinue
    if (-not $p -or $p.ProcessName -ne 'python') { return $false }
    try { return ($p.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$Record.startTimeUtcTicks) } catch { return $false }
}
function Get-TargetLabel($Target) { if ($Target.Kind -eq 'release') { return (Split-Path -Leaf $Target.Dir) } return 'foreign' }
function Get-TargetDir($Target) { if ($Target.Kind -eq 'release') { return $Target.Dir } return (Split-Path -Parent $Target.Starter) }
function Test-TargetProcessesAlive($Target) {
    # Any recorded service (also the port-less scheduler) still alive for this setup.
    if ($Fake) { return ((Get-FakeState).running -eq (Get-TargetLabel $Target)) }
    if ($Target.Kind -eq 'foreign' -and -not $Target.Starter) { return $false }
    $state = Join-Path (Get-TargetDir $Target) 'runtime\processes.json'
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { return $false }
    try { $records = Read-JsonFile $state } catch { return $false }
    return [bool](@(@($records) | Where-Object { $_ -and (Test-ProcessRecordAlive $_) }).Count)
}
function Test-SchedulerAlive([string]$ReleaseDir) {
    if ($Fake) { $s = Get-FakeState; return ($s.running -eq (Split-Path -Leaf $ReleaseDir) -and -not (@($s.unhealthy) -contains $s.running) -and -not (@($s.dead) -contains 'scheduler')) }
    $state = Join-Path $ReleaseDir 'runtime\processes.json'
    try { $records = Read-JsonFile $state } catch { return $false }
    return [bool](@(@($records) | Where-Object { $_ -and [string]$_.service -eq 'scheduler' -and (Test-ProcessRecordAlive $_) }).Count)
}
function Test-ControlHealthy {
    if ($Fake) { return ((Test-BackendHealthy) -and -not (@((Get-FakeState).dead) -contains 'control')) }
    try { $h = Get-LocalJson 'http://127.0.0.1:17900/health'; return [bool]$h } catch { return $false }
}
function Start-Backend($Target) {
    # $Target: @{Kind='release'; Dir=...} or @{Kind='foreign'; Starter=...}. Releases start from their own start.ps1
    # with the shared data folder; the stable starter is not used here because it refuses to run during the switch.
    if ($Fake) {
        $label = Get-TargetLabel $Target
        Add-FakeEvent "start $label"
        if ($FailAt -eq 'start' -and $Target.IsNew) { Stop-Install 'start-failed' 'Lỗi giả lập khi khởi động bản mới.' }
        # Like start.ps1: services listed in 'dead' come back, except those also listed in 'broken'.
        $s = Get-FakeState; $s.running = $label
        $s | Add-Member -NotePropertyName dead -NotePropertyValue @(@($s.dead) | Where-Object { $_ -and (@($s.broken) -contains $_) }) -Force
        Save-FakeState $s
        return
    }
    if ($Target.Kind -eq 'release') {
        $envs = @{ AUTOTOK_DATA_DIR = $(if ($env:AUTOTOK_DATA_DIR) { $env:AUTOTOK_DATA_DIR } else { $Target.DataDir }) }
        $ffprobe = Join-Path $Root 'tools\ffmpeg\ffprobe.exe'
        if (-not $env:KID_FBY_FFPROBE -and (Test-Path -LiteralPath $ffprobe -PathType Leaf)) { $envs.KID_FBY_FFPROBE = $ffprobe }
        $r = Use-ScopedEnv $envs { Invoke-PowerShellDetached (Join-Path $Target.Dir 'start.ps1') (Join-Path $Target.Dir 'runtime') }
    } else {
        $r = Invoke-PowerShellDetached $Target.Starter (Join-Path (Split-Path -Parent $Target.Starter) 'runtime')
    }
    if ($r.Code -ne 0) { Stop-Install 'start-failed' ('Không khởi động được bộ đăng: ' + (@($r.Lines | Where-Object { $_.Trim() } | Select-Object -Last 1) -join '')) }
}
function Stop-Backend($Target, [switch]$Force) {
    # Returns $true when the stop script ran without refusing (it refuses while jobs are running or pending).
    if ($Fake) {
        $label = Get-TargetLabel $Target
        Add-FakeEvent "stop $label"
        $s = Get-FakeState
        if (-not $Force -and [int]$s.busy -gt 0) { return $false }
        if ($s.running -eq $label) { $s.running = $null; Save-FakeState $s }
        return $true
    }
    $script = if ($Target.Kind -eq 'release') { Join-Path $Target.Dir 'dung.ps1' } else { Join-Path (Split-Path -Parent $Target.Starter) 'dung.ps1' }
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { Write-Log "WARN no stop script: $script"; return $false }
    $r = Invoke-PowerShellFile $script $(if ($Force) { @('-Force') } else { @() })
    return ($r.Code -eq 0)
}
function Wait-PortsFree([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (Test-PortsFree) { return $true }; Start-Sleep -Milliseconds 500 }
    return (Test-PortsFree)
}
function Wait-Healthy([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (Test-BackendHealthy) { return $true }; Start-Sleep -Seconds 1 }
    return (Test-BackendHealthy)
}
function Wait-Ready([string]$ReleaseDir) {
    # Readiness gate: /health ok with native_schedule, control server up, scheduler process alive - twice, 3 s apart.
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-BackendHealthy) -and (Test-ControlHealthy) -and (Test-SchedulerAlive $ReleaseDir)) {
            Start-Sleep -Seconds $(if ($Fake) { 0 } else { 3 })
            if ((Test-BackendHealthy) -and (Test-SchedulerAlive $ReleaseDir)) { return }
        }
        Start-Sleep -Milliseconds $(if ($Fake) { 200 } else { 1000 })
    }
    Stop-Install 'not-ready' "Bản mới không sẵn sàng sau $ReadyTimeoutSec giây (/health, cổng 17900 hoặc bộ hẹn giờ). Nhật ký dịch vụ: $ReleaseDir\runtime\"
}

# ------------------------------------------------------------- state files ----
function Get-StarterInfo {
    # local.json Starter: ours (stable starter) / foreign (custom or git setup) / none. Unreadable counts as foreign.
    if (-not (Test-Path -LiteralPath $LocalJsonPath -PathType Leaf)) { return @{ Kind = 'none'; Starter = '' } }
    try { $s = [string](Read-JsonFile $LocalJsonPath).Starter } catch { return @{ Kind = 'foreign'; Starter = '' } }
    if ($s -and [IO.Path]::GetFullPath($s) -ieq $LauncherPath) { return @{ Kind = 'ours'; Starter = $s } }
    return @{ Kind = 'foreign'; Starter = $s }
}
function Get-CurrentRelease {
    if (-not (Test-Path -LiteralPath $CurrentPath -PathType Leaf)) { return $null }
    try { $c = Read-JsonFile $CurrentPath } catch { Write-Log "WARN autotok-current.json unreadable: $($_.Exception.Message)"; return $null }
    if ([string]$c.release -notmatch $ReleasePattern) { return $null }
    $dir = Join-Path $Releases ([string]$c.release)
    if (-not (Test-Path -LiteralPath (Join-Path $dir '.kid-release-ok') -PathType Leaf)) { return $null }
    # Written as verified=false at the switch and true once the readiness gate passed; files without the field predate it.
    $verified = ($null -eq $c.PSObject.Properties['verified']) -or [bool]$c.verified
    return @{ Release = [string]$c.release; Sha = [string]$c.sha; Version = [string]$c.version; Dir = $dir; Previous = [string]$c.previous.release; Verified = $verified }
}
function Write-CurrentJson([string]$Release, [string]$Sha, [string]$Version, [string]$Previous, [string]$PreviousKind, [bool]$Verified) {
    Write-FileAtomic $CurrentPath (ConvertTo-JsonBytes ([ordered]@{
        release = $Release; sha = $Sha; version = $Version; installedAt = (Get-Date).ToString('o'); verified = $Verified
        previous = [ordered]@{ release = $Previous; kind = $PreviousKind }
    }))
}
function Get-ReleaseVersion([string]$Dir) {
    try { return [string](Read-JsonFile (Join-Path $Dir '.kid\bundle.json')).version } catch { return '' }
}
function Assert-DataDirAllowed([string]$Dir, [string]$Source) {
    # The data folder (accounts, cookies, schedules) must never sit where the installer replaces or deletes folders.
    $full = ''
    if ($Dir -match '^([A-Za-z]:\\|\\\\[^\\])') {
        try { $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\') } catch { $full = '' }
    }
    if (-not $full) { Stop-Install 'datadir-invalid' "Thư mục dữ liệu bộ đăng '$Dir' (từ $Source) không phải đường dẫn đầy đủ hợp lệ. Sửa thành dạng D:\TikTokData rồi thử lại." }
    $within = $full.StartsWith($Integrations + '\', [StringComparison]::OrdinalIgnoreCase)
    $first = if ($within) { $full.Substring($Integrations.Length + 1).Split('\')[0] } else { '' }
    if ($full -ieq $Integrations -or ($within -and ($first -ieq 'autotok-releases' -or $first -like 'autotok-python311*'))) {
        Stop-Install 'datadir-invalid' "Thư mục dữ liệu bộ đăng '$Dir' (từ $Source) nằm trong thư mục cài đặt mà trình cài sẽ thay hoặc xoá. Chọn thư mục khác (ví dụ D:\TikTokData), chuyển dữ liệu sang đó rồi thử lại."
    }
    # Junction/symlink aliases: the path may look safe but resolve into a managed folder.
    $probe = $full
    while ($probe -and $probe.Length -gt 3) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Log "WARN data folder path passes through a reparse point: $probe (from $Source)"
                foreach ($t in @($item.Target)) {
                    if (-not $t) { continue }
                    $tFull = ''
                    try { $tFull = [IO.Path]::GetFullPath(([string]$t -replace '^\\\?\?\\', '')).TrimEnd('\') } catch { Write-Log "WARN cannot resolve link target '$t' of $probe" }
                    if ($tFull -and ($tFull -ieq $Releases.TrimEnd('\') -or $tFull.StartsWith($Releases.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $tFull -like (Join-Path $Integrations 'autotok-python311*') -or $tFull -ieq $Integrations)) {
                        Stop-Install 'datadir-invalid' "Thư mục dữ liệu bộ đăng '$Dir' (từ $Source) là lối tắt (junction/symlink) trỏ vào thư mục cài đặt mà trình cài sẽ thay hoặc xoá. Chọn thư mục thật khác (ví dụ D:\TikTokData)."
                    }
                }
            }
        }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
}
function Resolve-DataDir($StarterInfo) {
    # Existing choice wins: autotok-config.json, then AUTOTOK_DATA_DIR, then the git setup's config.json, then default.
    # AUTOTOK_DATA_DIR also wins when the services start (Start-Backend, run_autotok_web.py): check it in every case.
    if ($env:AUTOTOK_DATA_DIR -and $env:AUTOTOK_DATA_DIR.Trim()) { Assert-DataDirAllowed $env:AUTOTOK_DATA_DIR.Trim() 'AUTOTOK_DATA_DIR' }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $v = ''
        try { $v = [string](Read-JsonFile $ConfigPath).DataDir } catch { Stop-Install 'config-invalid' "autotok-config.json lỗi: $($_.Exception.Message). Sửa hoặc xoá file rồi thử lại." }
        if (-not $v.Trim()) { Stop-Install 'config-invalid' 'autotok-config.json thiếu DataDir.' }
        Assert-DataDirAllowed $v.Trim() 'autotok-config.json'
        return @{ Dir = $v.Trim(); Created = $false }
    }
    $dir = ''; $source = 'AUTOTOK_DATA_DIR'
    if ($env:AUTOTOK_DATA_DIR) { $dir = $env:AUTOTOK_DATA_DIR.Trim() }
    if (-not $dir -and $StarterInfo.Kind -eq 'foreign' -and $StarterInfo.Starter) {
        $gitConfig = Join-Path (Split-Path -Parent $StarterInfo.Starter) 'config.json'; $source = $gitConfig
        if (Test-Path -LiteralPath $gitConfig -PathType Leaf) { try { $dir = [string](Read-JsonFile $gitConfig).DataDir } catch { Write-Log "WARN $gitConfig unreadable: $($_.Exception.Message)" } }
    }
    if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA 'KidFBY\autotok-data'; $source = 'LOCALAPPDATA' }
    Assert-DataDirAllowed $dir.Trim() $source
    Write-FileAtomic $ConfigPath (ConvertTo-JsonBytes ([ordered]@{ DataDir = $dir.Trim() }))
    Write-Log "config: wrote $ConfigPath"
    return @{ Dir = $dir.Trim(); Created = $true }
}
function Install-SharedFiles([string]$ReleaseDir) {
    # Stable starter + Kid FB.Y starter come from the release; only rewritten when the content differs.
    foreach ($pair in @(@((Join-Path $ReleaseDir 'autotok-start.ps1'), $LauncherPath), @((Join-Path $ReleaseDir '.kid\tiktok-start.ps1'), $TikTokStartPath))) {
        $bytes = [IO.File]::ReadAllBytes($pair[0])
        if ([IO.File]::Exists($pair[1]) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($pair[1])) -eq [Convert]::ToBase64String($bytes)) { continue }
        Write-FileAtomic $pair[1] $bytes
    }
    $starter = Get-StarterInfo
    if ($starter.Kind -ne 'ours') { Write-FileAtomic $LocalJsonPath (ConvertTo-JsonBytes ([ordered]@{ Starter = $LauncherPath })) }
}
function Write-TakeoverJournal($Journal, [string]$Phase) {
    $Journal.phase = $Phase
    Write-FileAtomic $JournalPath (ConvertTo-JsonBytes $Journal)
    Write-Log "takeover journal: $Phase"
}
function Restore-Takeover($Journal, [string]$Why) {
    # Puts the git/custom setup back exactly as before the takeover and starts it again if it was running.
    # Returns a note for the result message. The journal is deleted only after every file was restored.
    $rel = [string]$Journal.release
    if ($rel -match $ReleasePattern) {
        $newTarget = @{ Kind = 'release'; Dir = (Join-Path $Releases $rel) }
        if (Test-TargetProcessesAlive $newTarget) { [void](Stop-Backend $newTarget -Force); [void](Wait-PortsFree 20) }
    }
    foreach ($k in $TakeoverFiles.Keys) {
        $b64 = [string]$Journal.files.$k
        $bytes = $null
        if ($b64) { $bytes = [Convert]::FromBase64String($b64) }
        Restore-FileBytes $TakeoverFiles[$k] $bytes
    }
    # Files are back: from here the git/custom setup is in charge again, also if its own starter fails below.
    [IO.File]::Delete($JournalPath)
    Write-Log "takeover restored ($Why): starter=$($Journal.starter)"
    $note = ' Đã trả lại bộ đăng cũ.'
    if ([bool]$Journal.wasRunning -and [string]$Journal.starter) {
        if (-not (Test-BackendHealthy)) { Start-Backend @{ Kind = 'foreign'; Starter = [string]$Journal.starter } }
        $note = if (Wait-Healthy $ReadyTimeoutSec) { ' Đã trả lại bộ đăng cũ, bộ đăng cũ đang chạy.' } else { ' Đã trả lại bộ đăng cũ nhưng nó chưa trả lời /health; mở lại Kid FB.Y.' }
    }
    return $note
}
function Remove-OldReleases([string[]]$Keep) {
    foreach ($d in @(Get-ChildItem -LiteralPath $Releases -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($Keep -contains $d.Name) { continue }
        if ($d.Name -notmatch $ReleasePattern -and $d.Name -notlike '.staging-*') { continue }
        if ($d.Name -match $ReleasePattern -and (Test-TargetProcessesAlive @{ Kind = 'release'; Dir = $d.FullName })) { Write-Log "keep $($d.Name): processes alive"; continue }
        if (Remove-DirectorySafe $d.FullName) { Write-Log "removed old release $($d.Name)" }
    }
}

# ------------------------------------------------------- Chrome extension: stage, verify, swap ----
function Get-ExtActive {
    # /health ext_active: number of Chrome jobs in flight, -1 = unknown (busy). Missing field (backend without Chrome) or
    # no backend answering = nothing can be in flight = 0.
    if ($Fake) { $s = Get-FakeState; if ($null -ne $s.PSObject.Properties['ext_active']) { return [int]$s.ext_active } return 0 }
    try { $h = Get-LocalJson $HealthUrl } catch { Write-Log "ext_active: /health not answering ($($_.Exception.Message)): treated as idle"; return 0 }
    if ($null -eq $h.PSObject.Properties['ext_active']) { return 0 }
    return [int]$h.ext_active
}
function Remove-ExtTree([string]$Path) {
    # Only the three extension folders may be deleted here.
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notin @($ExtDir, ($ExtDir + '.new'), ($ExtDir + '.bak'))) { throw "Refusing to delete outside the extension folders: $full" }
    if (Test-Path -LiteralPath $full) { Remove-TreeNoFollow $full }
}
function Test-ExtFolder([string]$Dir, [hashtable]$Wanted) {
    # True when $Dir holds exactly the wanted files with the wanted SHA256 (Wanted: relative path with '/' -> sha256).
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    $have = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)
    if ($have.Count -ne $Wanted.Count) { return $false }
    foreach ($rel in $Wanted.Keys) {
        $f = Join-Path $Dir ($rel -replace '/', '\')
        if (-not [IO.File]::Exists($f) -or (Get-Sha256Hex $f).ToLowerInvariant() -ne $Wanted[$rel]) { return $false }
    }
    return $true
}
function Install-Extension([hashtable]$Info, [string]$SrcDir) {
    # Returns 'none' | 'current' | 'postponed' | 'installed'; throws after restoring the old folder when the swap fails.
    $wanted = @{}
    foreach ($k in $Info.Files.Keys) { if ($k.StartsWith('extension/', [StringComparison]::Ordinal)) { $wanted[$k.Substring(10)] = $Info.Files[$k].Sha } }
    if (-not $wanted.Count) { return 'none' }
    if (Test-ExtFolder $ExtDir $wanted) { Write-Log 'extension: already current'; return 'current' }
    $new = $ExtDir + '.new'; $bak = $ExtDir + '.bak'
    Remove-ExtTree $new
    try {
        foreach ($rel in $wanted.Keys) {
            $src = Join-Path $SrcDir ($rel -replace '/', '\'); $dst = Join-Path $new ($rel -replace '/', '\')
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dst))
            [IO.File]::Copy($src, $dst, $false)
        }
        Test-FailAt 'ext-stage'
        if (-not (Test-ExtFolder $new $wanted)) { throw 'staged extension does not match the bundle manifest (SHA256)' }
    } catch { Remove-ExtTree $new; throw }
    $deadline = (Get-Date).AddSeconds($DrainTimeoutSec)
    while ($true) {
        $active = Get-ExtActive
        if ($active -eq 0) { break }
        if ((Get-Date) -ge $deadline) {
            Remove-ExtTree $new
            Write-Log "extension: swap POSTPONED to the next run (ext_active=$active after $DrainTimeoutSec s)"
            return 'postponed'
        }
        Write-Log "extension: waiting, ext_active=$active"
        Start-Sleep -Seconds $(if ($Fake) { 1 } else { 5 })
    }
    Remove-ExtTree $bak
    $hadOld = Test-Path -LiteralPath $ExtDir -PathType Container
    try {
        if ($hadOld) { [IO.Directory]::Move($ExtDir, $bak) }
        Test-FailAt 'ext-swap'
        [IO.Directory]::Move($new, $ExtDir)
        Test-FailAt 'ext-verify'
        if (-not (Test-ExtFolder $ExtDir $wanted)) { throw 'extension folder does not match the manifest after the swap' }
    } catch {
        Write-Log "extension: swap FAILED ($($_.Exception.Message)), restoring the old folder"
        if (Test-Path -LiteralPath $ExtDir) { Remove-ExtTree $ExtDir }
        if ($hadOld -and (Test-Path -LiteralPath $bak)) { [IO.Directory]::Move($bak, $ExtDir) }
        Remove-ExtTree $new
        throw
    }
    Write-Log "extension: installed $($wanted.Count) files (previous kept in autotok-extension.bak)"
    return 'installed'
}
function Invoke-ExtensionInstall([hashtable]$Info, [string]$ReleaseDir) {
    # Never fails the backend install (already committed): returns a sentence for the result line, '' when nothing to say.
    try {
        switch (Install-Extension $Info (Join-Path $ReleaseDir '.kid\extension')) {
            'installed' { return ' Tiện ích Chrome đã cập nhật: vào chrome://extensions bấm ⟳ nếu tiện ích đang bật.' }
            'postponed' { return ' Tiện ích Chrome chưa cập nhật vì Chrome đang đăng video; sẽ cập nhật ở lần mở sau.' }
        }
    } catch {
        Write-Log "extension: not updated: $($_.Exception.Message)"
        return " Tiện ích Chrome chưa cập nhật được ($($_.Exception.Message)); thư mục cũ được giữ nguyên."
    }
    return ''
}

# ------------------------------------------------------------------ main ----
$installLock = $null; $upgradeLock = $null
$newDir = $null; $staging = $null; $committed = $false
$switched = $false; $prevStopped = $false; $newStarted = $false
$saved = @{}; $prev = $null; $config = $null; $journal = $null; $journalWritten = $false
$resultLine = ''
try { :main do {
    New-Item -ItemType Directory -Path $Releases -Force | Out-Null
    Write-Log "BEGIN root=$Root bundle=$Bundle fake=$Fake takeover=$([bool]$TakeOverStarter)"
    Write-Step 'check' 2 'Đang kiểm tra máy…'
    $installLock = Open-ExclusiveLock (Join-Path $Integrations 'autotok-install.lock') 'Đang có một lần cài bộ đăng TikTok khác chạy.'
    Test-FailAt 'check'
    if (-not $Fake -and -not (Find-Chrome)) { Stop-Install 'chrome-missing' 'Chưa có Google Chrome. Cài Chrome từ https://www.google.com/chrome/ rồi bấm lại.' }
    if (-not (Test-Path -LiteralPath $Bundle -PathType Leaf)) { Stop-Install 'bundle-missing' 'Bản Kid FB.Y này chưa có gói bộ đăng TikTok (core\autotok-bundle.zip). Bấm Cập nhật trong app.' }
    if (($Releases.Length + 1 + 28 + 125) -gt 259) { Stop-Install 'path-too-long' "Thư mục Kid FB.Y quá sâu ($Root). Chuyển sang thư mục ngắn hơn (ví dụ D:\KidFBY) rồi cài lại." }

    if ([IO.File]::Exists($JournalPath)) {
        # An earlier takeover of a git/custom setup was interrupted.
        try { $journal = Read-JsonFile $JournalPath } catch { Stop-Install 'journal-invalid' "File integrations\autotok-takeover-journal.json bị hỏng ($($_.Exception.Message)); không tự trả lại được bộ đăng cũ. Gửi file này và autotok-install.log cho người hỗ trợ." }
        $jCurrent = Get-CurrentRelease
        if ($jCurrent -and $jCurrent.Release -eq [string]$journal.release -and $jCurrent.Verified) {
            [IO.File]::Delete($JournalPath); $journal = $null
            Write-Log 'takeover journal: release already verified, journal removed'
        } elseif (-not ($jCurrent -and $jCurrent.Release -eq [string]$journal.release)) {
            # Stopped before the switch finished: nothing new to verify, put the old setup back.
            $upgradeLock = Open-ExclusiveLock (Join-Path $Integrations 'autotok-upgrade.lock') 'Đang có một lần chuyển bản bộ đăng khác.'
            Write-Step 'recover' 6 'Lần thay bộ đăng trước bị ngắt giữa chừng, đang trả lại bộ đăng cũ…'
            $note = Restore-Takeover $journal 'interrupted'
            Stop-Install 'recovered' ("Lần thay bộ đăng TikTok trước bị ngắt giữa chừng." + $note + ' Bấm cài lại để thử lần nữa.')
        }
        # Otherwise the new release is current but unverified: the recover step below verifies it or restores the old setup.
    }

    $starterInfo = Get-StarterInfo
    if ($starterInfo.Kind -eq 'foreign' -and -not $TakeOverStarter) {
        Stop-Install 'foreign-starter' "integrations\tiktok\local.json đang trỏ tới bộ đăng khác ($($starterInfo.Starter)). Chọn dùng bản cài một chạm để thay thế."
    }
    $current = Get-CurrentRelease
    if ($starterInfo.Kind -eq 'foreign') { $prev = @{ Kind = 'foreign'; Starter = $starterInfo.Starter } }
    elseif ($current) { $prev = @{ Kind = 'release'; Dir = $current.Dir; Release = $current.Release } }
    else { $prev = @{ Kind = 'none' } }
    $currentBroken = (-not $current) -and (Test-Path -LiteralPath $CurrentPath -PathType Leaf)
    if ($currentBroken -and $prev.Kind -eq 'none') {
        # autotok-current.json unreadable/empty: adopt the release whose services are still running as the previous one.
        foreach ($d in @(Get-ChildItem -LiteralPath $Releases -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $ReleasePattern })) {
            if ((Test-Path -LiteralPath (Join-Path $d.FullName '.kid-release-ok')) -and (Test-TargetProcessesAlive @{ Kind = 'release'; Dir = $d.FullName })) {
                $prev = @{ Kind = 'release'; Dir = $d.FullName; Release = $d.Name }
                Write-Log "autotok-current.json unreadable: running release $($d.Name) taken as previous"
                break
            }
        }
    }

    Write-Step 'verify' 5 'Đang kiểm tra gói cài…'
    Test-FailAt 'verify'
    $info = Read-Bundle $Bundle
    Test-ManifestMatch $info
    Write-Log "bundle sha=$($info.Sha) version=$($info.Version) files=$($info.Files.Count) expanded=$($info.Expanded)"
    $configOriginal = Read-FileBytesOrNull $ConfigPath
    $config = Resolve-DataDir $starterInfo
    $dataDir = $config.Dir

    if ($current -and -not $current.Verified -and $prev.Kind -eq 'release') {
        # An earlier run was killed after switching, before the readiness gate passed. Verify that release now;
        # if it does not come up, go back to its previous release and stop here (do not reinstall in the same run).
        Write-Step 'recover' 6 'Lần cập nhật trước bị ngắt giữa chừng, đang kiểm tra bản đang dùng…'
        $upgradeLock = Open-ExclusiveLock (Join-Path $Integrations 'autotok-upgrade.lock') 'Đang có một lần chuyển bản bộ đăng khác.'
        $target = @{ Kind = 'release'; Dir = $current.Dir; DataDir = $dataDir }
        $recovered = $false
        try {
            if (-not (Test-BackendHealthy)) {
                if (Test-TargetProcessesAlive $target) { [void](Stop-Backend $target -Force); [void](Wait-PortsFree 20) }
                if (-not (Test-PortsFree)) { throw 'ports busy' }
                Start-Backend $target
            }
            Wait-Ready $current.Dir
            $recovered = $true
        } catch { Write-Log "recover: $($current.Release) not ready: $($_.Exception.Message)" }
        if ($recovered) {
            Write-CurrentJson $current.Release $current.Sha $current.Version $current.Previous 'release' $true
            $current.Verified = $true
            Write-Log "recover: $($current.Release) verified"
            if ($journal) { [IO.File]::Delete($JournalPath); $journal = $null; Write-Log 'takeover journal: committed by recover' }
        } else {
            [void](Stop-Backend $target -Force); [void](Wait-PortsFree 20)
            if ($journal -and [string]$journal.release -eq $current.Release) {
                $note = Restore-Takeover $journal 'not-ready'
                Stop-Install 'recovered' ("Bộ đăng cài lần trước (thay bộ đăng cũ) không chạy được." + $note + ' Bấm cài lại để thử lần nữa.')
            }
            $oldDir = Join-Path $Releases $current.Previous
            if ($current.Previous -match $ReleasePattern -and (Test-Path -LiteralPath (Join-Path $oldDir '.kid-release-ok') -PathType Leaf)) {
                $oldSha = ([IO.File]::ReadAllText((Join-Path $oldDir '.kid-release-ok'))).Trim()
                Write-CurrentJson $current.Previous $oldSha (Get-ReleaseVersion $oldDir) '' 'none' $true
                Start-Backend @{ Kind = 'release'; Dir = $oldDir; DataDir = $dataDir }
                $note = if (Wait-Healthy $ReadyTimeoutSec) { 'bản cũ đang chạy' } else { 'bản cũ chưa trả lời /health, mở lại Kid FB.Y' }
                Write-Log "recover: rolled back to $($current.Previous)"
                Stop-Install 'recovered' "Bản bộ đăng cài lần trước không chạy được; đã quay lại bản cũ ($note). Bấm cài lại để thử lần nữa."
            }
            [IO.File]::Delete($CurrentPath)
            if ((Get-StarterInfo).Kind -eq 'ours') { [IO.File]::Delete($LocalJsonPath) }
            Write-Log 'recover: no previous release; configuration removed'
            Stop-Install 'recovered' 'Bản bộ đăng cài lần trước không chạy được và không có bản cũ; đã gỡ cấu hình. Bấm cài lại.'
        }
        $upgradeLock.Dispose(); $upgradeLock = $null
    }

    if ($prev.Kind -eq 'release' -and $current -and $current.Verified -and $current.Sha -eq $info.Sha -and (Test-ReleaseRuntime $current.Dir $dataDir -Quiet)) {
        # Same bundle already installed and healthy on disk: repair the shared files, make sure it runs.
        Write-Step 'switch' 90 'Bộ đăng TikTok đã là bản mới nhất, đang kiểm tra…'
        Install-SharedFiles $current.Dir
        $target = @{ Kind = 'release'; Dir = $current.Dir; DataDir = $dataDir }
        if (-not ((Test-BackendHealthy) -and (Test-ControlHealthy) -and (Test-SchedulerAlive $current.Dir))) {
            # API, control server or scheduler missing: start.ps1 starts only the services that are not running.
            if (-not (Test-TargetProcessesAlive $target) -and -not (Test-PortsFree)) { Stop-Install 'port-busy' 'Cổng 8765/17900 đang bị chương trình khác dùng.' }
            Write-Step 'start' 92 'Đang khởi động bộ đăng…'
            Start-Backend $target
        }
        # Same gate as after an upgrade (health + native scheduling, control server, scheduler), also when all looked up.
        try { Wait-Ready $current.Dir }
        catch { Stop-Install 'not-ready' "Bộ đăng TikTok $($info.Version) đã cài nhưng chưa chạy đủ (/health, cổng 17900 hoặc bộ hẹn giờ) sau $ReadyTimeoutSec giây. Nhật ký dịch vụ: $($current.Dir)\runtime\" }
        $committed = $true
        $extNote = Invoke-ExtensionInstall $info $current.Dir
        $resultLine = "@@AUTOTOK_RESULT ok already-current Bộ đăng TikTok $($info.Version) đã sẵn sàng.$extNote"
        break main
    }
    if ($prev.Kind -eq 'none' -and ((Test-BackendHealthy) -or -not (Test-PortsFree))) {
        if ($currentBroken) { Stop-Install 'current-invalid' 'File integrations\autotok-current.json bị hỏng và cổng 8765/17900 đang bị dùng. Khởi động lại máy rồi bấm cài lại.' }
        Stop-Install 'port-busy' 'Cổng 8765/17900 đang có chương trình khác chạy (không phải bộ đăng do Kid FB.Y cài). Tắt chương trình đó rồi thử lại.'
    }

    Write-Step 'extract' 10 'Đang giải nén gói cài…'
    $staging = Join-Path $Releases ('.staging-' + [Guid]::NewGuid().ToString('N'))
    Expand-Bundle $Bundle $info $staging
    Test-FailAt 'extract'
    $releaseName = $info.Sha12 + '-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $newDir = Join-Path $Releases $releaseName
    [IO.Directory]::Move($staging, $newDir); $staging = $null

    Install-PythonRuntime
    New-ReleaseVenv $newDir
    Write-Step 'validate' 80 'Đang kiểm tra bộ đăng mới…'
    [void](Test-ReleaseRuntime $newDir $dataDir)
    [IO.File]::WriteAllText((Join-Path $newDir '.kid-release-ok'), $info.Sha)

    # ---- switch: from here on every failure puts the previous state back ----
    Write-Step 'lock' 82 'Tạm dừng nhận video mới để chuyển bản…'
    $upgradeLock = Open-ExclusiveLock (Join-Path $Integrations 'autotok-upgrade.lock') 'Đang có một lần chuyển bản bộ đăng khác.'
    $prevRunning = Test-BackendHealthy
    $prev.WasRunning = $prevRunning
    if ($prev.Kind -eq 'foreign') {
        # Durable copy of the git/custom setup before it is stopped: rollback, the next run and autotok-start.ps1 use it.
        $files = [ordered]@{}
        foreach ($k in $TakeoverFiles.Keys) {
            if ($k -eq 'config') { $b = $configOriginal } else { $b = Read-FileBytesOrNull $TakeoverFiles[$k] }
            $files[$k] = if ($null -eq $b) { $null } else { [Convert]::ToBase64String([byte[]]$b) }
        }
        $journal = [ordered]@{ format = 1; phase = ''; release = $releaseName; starter = [string]$prev.Starter; wasRunning = [bool]$prevRunning; createdAt = (Get-Date).ToString('o'); files = $files }
        Write-TakeoverJournal $journal 'prepared'
        $journalWritten = $true
        Test-FailAt 'journal'
    }
    if ($prevRunning -or ($prev.Kind -ne 'none' -and (-not (Test-PortsFree) -or (Test-TargetProcessesAlive $prev)))) {
        Write-Step 'drain' 85 'Đợi các video đang gửi lên TikTok xong…'
        $deadline = (Get-Date).AddSeconds($DrainTimeoutSec)
        while ($true) {
            $busy = -1
            try { $busy = Get-BusyJobCount } catch { Write-Log "WARN job check: $($_.Exception.Message)" }
            if ($busy -eq 0) {
                Write-Step 'stop' 88 'Đang dừng bản cũ…'
                if (Stop-Backend $prev) { $prevStopped = $true; break }
            }
            if ((Get-Date) -ge $deadline -and $busy -lt 0) { Stop-Install 'old-not-responding' 'Bản cũ còn chạy dở nhưng không trả lời (không kiểm tra được lịch đăng). Đã giữ nguyên bản cũ. Khởi động lại máy rồi thử lại.' }
            if ((Get-Date) -ge $deadline) { Stop-Install 'drain-timeout' "Còn video đang đăng hoặc chờ gửi lên TikTok sau $DrainTimeoutSec giây. Bản cũ vẫn chạy; thử lại khi lịch đăng xong." }
            Start-Sleep -Seconds $(if ($Fake) { 1 } else { 5 })
        }
        if (-not (Wait-PortsFree 20)) { Stop-Install 'port-busy' 'Bản cũ đã dừng nhưng cổng 8765/17900 vẫn bị chiếm.' }
    }
    if ($journalWritten) { Write-TakeoverJournal $journal 'stopped'; Test-FailAt 'stopped' }

    Write-Step 'switch' 90 'Đang chuyển sang bản mới…'
    foreach ($p in @($CurrentPath, $LocalJsonPath, $LauncherPath, $TikTokStartPath)) { $saved[$p] = Read-FileBytesOrNull $p }
    $switched = $true
    Install-SharedFiles $newDir
    $previousName = if ($prev.Kind -eq 'release') { $prev.Release } else { '' }
    Write-CurrentJson $releaseName $info.Sha $info.Version $previousName $prev.Kind $false
    if ($journalWritten) { Write-TakeoverJournal $journal 'switched' }
    Test-FailAt 'switch'

    Write-Step 'start' 92 'Đang khởi động bản mới…'
    $newStarted = $true
    Start-Backend @{ Kind = 'release'; Dir = $newDir; DataDir = $dataDir; IsNew = $true }
    Write-Step 'ready' 95 'Đang chờ bản mới sẵn sàng…'
    if ($FailAt -eq 'ready') { $s = Get-FakeState; $s.unhealthy = @(@($s.unhealthy) + $releaseName | Where-Object { $_ }); Save-FakeState $s }
    Wait-Ready $newDir
    Write-CurrentJson $releaseName $info.Sha $info.Version $previousName $prev.Kind $true
    $committed = $true
    Write-Log "COMMIT release=$releaseName previous=$previousName"
    if ($journalWritten) { try { [IO.File]::Delete($JournalPath) } catch { Write-Log "WARN takeover journal not removed (next run removes it): $($_.Exception.Message)" } }

    Write-Step 'cleanup' 98 'Đang dọn bản cũ…'
    Remove-OldReleases @($releaseName, $previousName)
    $extNote = Invoke-ExtensionInstall $info $newDir
    $resultLine = "@@AUTOTOK_RESULT ok installed Đã cài bộ đăng TikTok $($info.Version).$extNote"
} while ($false) } catch {
    $reason = [string]$_.Exception.Data['reason']
    if (-not $reason) { $reason = 'internal' }
    $message = $_.Exception.Message
    Write-Log "FAIL reason=$reason message=$message at=$($_.InvocationInfo.ScriptLineNumber)"
    $rollbackNote = ''
    if (-not $committed -and $journalWritten) {
        # Takeover of a git/custom setup: restore it from the durable journal (also used if this process dies here).
        Write-Step 'rollback' 96 'Có lỗi, đang trả lại bộ đăng cũ…'
        try {
            if ($newStarted -and $newDir) { [void](Stop-Backend @{ Kind = 'release'; Dir = $newDir } -Force); [void](Wait-PortsFree 20) }
            $rollbackNote = Restore-Takeover (Read-JsonFile $JournalPath) 'rollback'
            Write-Log "ROLLBACK done:$rollbackNote"
        } catch {
            $rollbackNote = " Trả lại bộ đăng cũ gặp lỗi: $($_.Exception.Message)" + $(if ([IO.File]::Exists($JournalPath)) { ' Lần cài sau sẽ thử lại.' } else { '' })
            Write-Log "ROLLBACK error: $($_.Exception.Message)"
        }
    } elseif (-not $committed -and ($switched -or $prevStopped -or $newStarted)) {
        Write-Step 'rollback' 96 'Có lỗi, đang quay lại bản cũ…'
        try {
            if ($newStarted -and $newDir) { [void](Stop-Backend @{ Kind = 'release'; Dir = $newDir } -Force); [void](Wait-PortsFree 20) }
            if ($switched) { foreach ($p in @($saved.Keys)) { Restore-FileBytes $p $saved[$p] } }
            if ($prev.WasRunning) {
                if ($prev.Kind -eq 'release') { Start-Backend @{ Kind = 'release'; Dir = $prev.Dir; DataDir = $config.Dir } }
                elseif ($prev.Kind -eq 'foreign') { Start-Backend $prev }
                if (Wait-Healthy $ReadyTimeoutSec) { $rollbackNote = ' Đã quay lại bản cũ, bản cũ đang chạy.' }
                else { $rollbackNote = ' Đã quay lại bản cũ nhưng bản cũ chưa trả lời /health; mở lại Kid FB.Y.' }
            } else { $rollbackNote = ' Đã quay lại bản cũ.' }
            Write-Log "ROLLBACK done:$rollbackNote"
        } catch {
            $rollbackNote = " Quay lại bản cũ gặp lỗi: $($_.Exception.Message)"
            Write-Log "ROLLBACK error: $($_.Exception.Message)"
        }
    }
    if (-not $committed -and $config -and $config.Created -and -not $switched) { try { [IO.File]::Delete($ConfigPath) } catch { Write-Log "WARN config cleanup: $($_.Exception.Message)" } }
    if (-not $committed -and $newDir -and (Test-Path -LiteralPath $newDir)) {
        if (-not (Test-TargetProcessesAlive @{ Kind = 'release'; Dir = $newDir })) { [void](Remove-DirectorySafe $newDir) }
    }
    $resultLine = "@@AUTOTOK_RESULT failed $reason " + (($message + $rollbackNote) -replace '[\r\n]+', ' ')
} finally {
    if ($staging) { [void](Remove-DirectorySafe $staging) }
    if ($upgradeLock) { $upgradeLock.Dispose() }
    if ($installLock) { $installLock.Dispose() }
    if (-not $resultLine) { $resultLine = '@@AUTOTOK_RESULT failed internal Trình cài dừng giữa chừng.' }
    Write-Log ('END ' + $resultLine)
    Send-Line $resultLine
}
if ($resultLine -like '@@AUTOTOK_RESULT ok *') { exit 0 } else { exit 1 }
