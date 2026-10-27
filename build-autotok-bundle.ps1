#Requires -Version 5.1
<#
  Build core\autotok-bundle.zip: the TikTok backend (integrations\autotok) packed for the one-click installer
  (integrations\autotok\kid-install.ps1). Only files on the explicit allowlist below go in; the zip is deterministic
  (sorted entries, fixed timestamps) so an unchanged backend gives the same SHA256 and is not re-downloaded by the updater.
    .\build-autotok-bundle.ps1 [-Root <repo>] [-OutFile <zip>] [-ExtensionDir <folder>]
  The Chrome extension (integrations\autotok-extension, or -ExtensionDir) goes in as extension/<file> on an allowlist; the build FAILS when key material is found in that folder.
  Local build only: does not publish, commit or change the version.
#>
param([string]$Root = '', [string]$OutFile = '', [string]$ExtensionDir = '')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
if (-not $OutFile) { $OutFile = Join-Path $Root 'core\autotok-bundle.zip' }
$OutFile = [IO.Path]::GetFullPath($OutFile)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$maxCompressed = 15MB
$maxExpanded = 60MB
$maxEntries = 3000
$autotok = Join-Path $Root 'integrations\autotok'

# Zip path (forward slashes) -> source file. 'autotok/' is the release directory; 'tiktok/start.ps1' is the Kid FB.Y starter.
$single = @('run_autotok_web.py', 'start.ps1', 'dung.ps1', 'cai-dat.ps1', 'README-VI.md', 'requirements.lock.txt',
    'kid-install.ps1', 'autotok-start.ps1', 'src/LICENSE', 'src/THIRD_PARTY_NOTICES.md', 'src/pyproject.toml')
$trees = @('src/autotok', 'src/web/api', 'src/web/scheduler', 'src/web/frontend/dist')
$entries = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)

function Test-Excluded([string]$rel) {
    $parts = $rel.Split('/')
    foreach ($p in $parts) {
        if ($p -in @('__pycache__', 'node_modules', 'tests', '.venv', 'runtime', 'data') -or $p -like '.env*') { return $true }
    }
    # Folder trees carry code and the built frontend only: no data, keys, cookies, databases or JSON state.
    return ($parts[-1] -notmatch '\.(py|js|mjs|css|html|svg|png|ico|woff|woff2|typed)$')
}

# In a git checkout only TRACKED files of the trees are bundled; anything else present there (a planted cookie,
# a local database, a key) is reported and left out. Outside git the extension filter above still applies.
$tracked = $null
$gitTop = ''
try { $gitTop = [string](& git -C $Root rev-parse --show-toplevel 2>$null) } catch { $gitTop = '' }
if ($LASTEXITCODE -eq 0 -and $gitTop -and ([IO.Path]::GetFullPath($gitTop.Replace('/', '\')).TrimEnd('\') -ieq $Root)) {
    $tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in @(& git -C $Root -c core.quotepath=false ls-files -- integrations/autotok/src)) { [void]$tracked.Add([string]$line) }
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
} else {
    Write-Warning "Not the top of a git checkout ($Root): bundling by allowlist + extension filter only."
}

foreach ($rel in $single) {
    $file = Join-Path $autotok ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing bundle file: integrations/autotok/$rel" }
    $entries['autotok/' + $rel] = $file
}
foreach ($tree in $trees) {
    $dir = Join-Path $autotok ($tree -replace '/', '\')
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Missing bundle folder: integrations/autotok/$tree" }
    foreach ($fi in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force)) {
        if ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links are not allowed in the bundle: $($fi.FullName)" }
        $rel = $tree + '/' + $fi.FullName.Substring($dir.Length + 1).Replace('\', '/')
        if (Test-Excluded $rel) { continue }
        if ($tracked -and -not $tracked.Contains('integrations/autotok/' + $rel)) { Write-Warning "Not tracked by git, left out of the bundle: integrations/autotok/$rel"; continue }
        $entries['autotok/' + $rel] = $fi.FullName
    }
}
# novnc: only the Python control server the host imports (entrypoint.sh is Docker-only).
foreach ($name in @('__init__.py', 'control_server.py')) {
    $file = Join-Path $autotok ('src\web\novnc\' + $name)
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing bundle file: integrations/autotok/src/web/novnc/$name" }
    $entries['autotok/src/web/novnc/' + $name] = $file
}
# Chrome extension: allowlist only (manifest.json, *.js, *.html, *.css, icons/*, the owner's guide). devserver/ and tests/ stay out.
# Any key material anywhere in the extension folder fails the build (a signing key must never reach the bundle).
if (-not $ExtensionDir) { $ExtensionDir = Join-Path $Root 'integrations\autotok-extension' }
$ExtensionDir = [IO.Path]::GetFullPath($ExtensionDir).TrimEnd('\')
if (-not (Test-Path -LiteralPath $ExtensionDir -PathType Container)) { throw "Missing extension folder: $ExtensionDir" }
$keyPattern = '(?i)(\.(pem|key|p12|pfx|jks|keystore|crx|der|xml\.key)$|^(\.env.*|id_rsa.*|.*private.*key.*|.*secret.*|update-signing.*)$)'
foreach ($fi in @(Get-ChildItem -LiteralPath $ExtensionDir -Recurse -File -Force)) {
    if ($fi.Name -match $keyPattern) { throw "Key material in the extension folder, build refused: $($fi.FullName)" }
}
foreach ($fi in @(Get-ChildItem -LiteralPath $ExtensionDir -Recurse -File -Force)) {
    if ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links are not allowed in the bundle: $($fi.FullName)" }
    $rel = $fi.FullName.Substring($ExtensionDir.Length + 1).Replace('\', '/')
    $parts = $rel.Split('/')
    if ($parts[0] -in @('devserver', 'tests', 'node_modules', '__pycache__')) { continue }
    $ok = ($parts.Count -eq 1 -and ($rel -ceq 'manifest.json' -or $rel -ceq 'HUONG-DAN-CAI-TIEN-ICH.md' -or $rel -cmatch '^[A-Za-z0-9_.-]+\.(js|html|css)$')) -or
          ($parts[0] -ceq 'icons' -and $parts.Count -eq 2 -and $rel -cmatch '^icons/[A-Za-z0-9_.-]+\.(png|svg|ico)$')
    if ($ok) { $entries['extension/' + $rel] = $fi.FullName }
}
if (-not $entries.ContainsKey('extension/manifest.json')) { throw 'Bundle is missing extension/manifest.json' }
$tiktokStarter = Join-Path $Root 'integrations\tiktok\start.ps1'
if (-not (Test-Path -LiteralPath $tiktokStarter -PathType Leaf)) { throw 'Missing bundle file: integrations/tiktok/start.ps1' }
$entries['tiktok/start.ps1'] = $tiktokStarter
foreach ($required in @('autotok/src/web/frontend/dist/index.html', 'autotok/src/autotok/__init__.py', 'autotok/src/web/api/main.py', 'autotok/src/web/scheduler/main.py')) {
    if (-not $entries.ContainsKey($required)) { throw "Bundle is missing $required" }
}

$version = ''
if ([IO.File]::ReadAllText((Join-Path $autotok 'src\autotok\__init__.py')) -match '(?m)^__version__\s*=\s*"([^"]+)"') { $version = $Matches[1] }
if (-not $version) { throw 'Cannot read autotok __version__.' }

$sha = [Security.Cryptography.SHA256]::Create()
$files = New-Object System.Collections.ArrayList
$data = @{}
[long]$total = 0
foreach ($kv in $entries.GetEnumerator()) {
    $bytes = [IO.File]::ReadAllBytes($kv.Value)
    $data[$kv.Key] = $bytes
    $total += $bytes.Length
    [void]$files.Add([ordered]@{ path = $kv.Key; sha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant(); size = $bytes.Length })
}
$sha.Dispose()
if ($files.Count + 1 -gt $maxEntries) { throw "Bundle has too many entries ($($files.Count))." }
if ($total -gt $maxExpanded) { throw "Bundle expands to $total bytes (limit $maxExpanded)." }
$manifest = [ordered]@{ format = 1; name = 'autotok'; version = $version; files = @($files) }
$manifestBytes = (New-Object Text.UTF8Encoding($false)).GetBytes((($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"))

$temp = $OutFile + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$fixedTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
try {
    $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $ordered = @(@{ Name = 'bundle.json'; Bytes = $manifestBytes }) + @($files | ForEach-Object { @{ Name = $_.path; Bytes = $data[$_.path] } })
            foreach ($item in $ordered) {
                $entry = $zip.CreateEntry($item.Name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $fixedTime
                $out = $entry.Open()
                try { $out.Write($item.Bytes, 0, $item.Bytes.Length) } finally { $out.Dispose() }
            }
        } finally { $zip.Dispose() }
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    $size = (Get-Item -LiteralPath $temp).Length
    if ($size -gt $maxCompressed) { throw "Bundle is $size bytes (limit $maxCompressed)." }
    if (Test-Path -LiteralPath $OutFile) { [IO.File]::Replace($temp, $OutFile, [NullString]::Value) } else { [IO.File]::Move($temp, $OutFile) }
} finally {
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
}
$hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
Write-Output ("BUNDLE {0} version={1} files={2} expanded={3} size={4} sha256={5}" -f $OutFile, $version, $files.Count, $total, (Get-Item -LiteralPath $OutFile).Length, $hash)
