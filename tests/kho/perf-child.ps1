# Child of 08-perf.ps1: builds a synthetic output folder (tiny files, fake backend, fake receipts), runs the real sync worker
# three times (cold / warm restart / steady state) and prints one "PERF {json}" line. -GuiFile selects the code under test.
param([Parameter(Mandatory)][string]$GuiFile, [Parameter(Mandatory)][string]$Work, [int]$Count = 2500, [int]$ReceiptCount = 500, [string]$Label = 'new')
$KhoGuiFile = $GuiFile
. (Join-Path $PSScriptRoot '_load.ps1')
. (Join-Path $PSScriptRoot 'FakeBackend.ps1')
$out = Join-Path $Work 'out'
[void][IO.Directory]::CreateDirectory($out)
$server = Start-FakeBackend
$users = 'Anna', 'Bob', 'Carl'
$receipts = New-Object System.Collections.Generic.List[object]
$succeededIds = New-Object System.Collections.Generic.List[string]
for ($i = 1; $i -le $Count; $i++) {
    $id = [string](5000000 + $i)
    [IO.File]::WriteAllText((Join-Path $out "$id-3-hoan-chinh.mp4"), "synthetic video $id")
    $entries = @()
    if ($i % 5 -eq 0) {
        $rid = '{0:x32}' -f [long]$i
        $entries += (New-TestHistoryEntry -Request $rid -User $users[$i % 3] -Accepted ('2026-10-{0:00}T10:00:00Z' -f (1 + $i % 27)) -Created ('2026-10-{0:00}T09:00:00Z' -f (1 + $i % 27)))
        $succeededIds.Add($id)
        if ($receipts.Count -lt $ReceiptCount) {
            $receipts.Add([pscustomobject]@{ RequestId = $rid; VideoId = $id; Username = $users[$i % 3]; ScheduledFor = ''; Status = 'succeeded'; CreatedAt = '2026-10-01T09:00:00Z'; LaunchedAt = ''; SourceSha256 = ''; UploadSha256 = ''; WorkerAlive = $false })
        }
    } elseif ($i % 7 -eq 0) {
        $rid = '{0:x32}' -f [long](100000 + $i)
        $entries += (New-TestHistoryEntry -Request $rid -User $users[$i % 3] -Status 'pending' -Accepted '' -Created '2026-10-20T09:00:00Z')
        if ($receipts.Count -lt $ReceiptCount) {
            $receipts.Add([pscustomobject]@{ RequestId = $rid; VideoId = $id; Username = $users[$i % 3]; ScheduledFor = ''; Status = 'preparing'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; SourceSha256 = ''; UploadSha256 = ''; WorkerAlive = $true })
        }
    }
    if ($entries.Count) { $server.Rows[$id] = ConvertTo-EntriesJson $entries }
}
function New-Payload {
    param($Last = $null)
    return @{ out_dir = $out; receipts = $receipts.ToArray(); last_input_sig = $(if ($Last) { [string]$Last.InputSig } else { '' }); last_file_stamp = $(if ($Last) { [string]$Last.FileStamp } else { '' })
              probe_cursor = ''; identity_cache = $null; file = $null }
}
$cacheFile = Join-Path $out '.cache\tiktok-identities.json'

$cold = Invoke-Worker 'sync' (New-Payload) $server.Url
if ($cold.Errors.Count) { throw "cold pass errors: $($cold.Errors -join ' | ')" }
$cacheStamp = (Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc.Ticks

# From here on every media file is locked exclusively: any pass that opened a file to hash it would fail to get a hash.
$locks = foreach ($f in [IO.Directory]::GetFiles($out, '*-3-hoan-chinh.mp4')) { [IO.File]::Open($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
try {
    $stampCold = Get-FileStamp (Join-Path $out 'reup-status.json')
    $warmRestart = Invoke-Worker 'sync' (New-Payload) $server.Url
    if ($warmRestart.Errors.Count) { throw "warm restart errors: $($warmRestart.Errors -join ' | ')" }
    $steady = Invoke-Worker 'sync' (New-Payload $warmRestart.Result) $server.Url
    if ($steady.Errors.Count) { throw "steady errors: $($steady.Errors -join ' | ')" }
    $emptyHashes = @($warmRestart.Result.Hashes.Values | Where-Object { -not $_ }).Count
} finally { foreach ($l in $locks) { $l.Dispose() } }

$final = Read-TestJson (Join-Path $out 'reup-status.json')
$normalized = [ordered]@{}
foreach ($p in ($final.PSObject.Properties | Sort-Object Name)) {
    $copy = ConvertFrom-Json (ConvertTo-Json $p.Value -Depth 12 -Compress)
    foreach ($n in 'Kho', 'KhoManual') { if ($copy.PSObject.Properties[$n]) { [void]$copy.PSObject.Properties.Remove($n) } }
    $normalized[$p.Name] = $copy
}
[IO.File]::WriteAllText((Join-Path $Work 'normalized.json'), (ConvertTo-Json $normalized -Depth 12), [Text.UTF8Encoding]::new($false))
$khoCount = @($final.PSObject.Properties | Where-Object { $_.Value.Kho }).Count
$server.Stop()
$summary = [ordered]@{
    label = $Label; videos = $Count; receipts = $receipts.Count; succeeded = $succeededIds.Count
    coldMs = [Math]::Round($cold.Ms); warmRestartMs = [Math]::Round($warmRestart.Ms); steadyMs = [Math]::Round($steady.Ms)
    steadySkipped = [bool]$steady.Result.Skipped; warmRestartChanged = [bool]$warmRestart.Result.Changed
    hashesEmptyWhileLocked = $emptyHashes; identityCacheRewritten = ((Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc.Ticks -ne $cacheStamp)
    statusFileRewrittenByWarmPasses = ((Get-FileStamp (Join-Path $out 'reup-status.json')) -ne $stampCold)
    entriesWithKho = $khoCount; lookupCalls = $server.LookupCalls
}
Write-Output ('PERF ' + (ConvertTo-Json $summary -Compress))
