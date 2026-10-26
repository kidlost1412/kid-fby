# Child process of 06-concurrency.ps1: hammers Update-ReupMetadata on a shared folder.
#   -Mode Posted  : Set-ReupMetadata manual mark (own ids 1000001.. whose -3 exists, plus the shared entry 9)
#   -Mode History : history change in one Change block, like the sync worker (own ids 2000001.. plus entry 9)
param([Parameter(Mandatory)][ValidateSet('Posted', 'History')][string]$Mode, [Parameter(Mandatory)][string]$OutDir, [int]$Iterations = 200)
. (Join-Path $PSScriptRoot '_load.ps1')
$failures = 0
for ($i = 1; $i -le $Iterations; $i++) {
    try {
        if ($Mode -eq 'Posted') {
            $own = [string](1000000 + $i)
            [IO.File]::WriteAllText((Join-Path $OutDir "$own-3-hoan-chinh.mp4"), 'x')
            Set-ReupMetadata -VideoId $own -Posted $true -OutDir $OutDir
            Set-ReupMetadata -VideoId '9' -Posted $true -OutDir $OutDir
        } else {
            $id = [string](2000000 + $i); $n = $i
            [void](Update-ReupMetadata -OutDir $OutDir -Change {
                param($meta)
                $e1 = ConvertTo-TikTokHistoryEntry (New-TestHistoryEntry -Request "own$n" -User 'Anna')
                $a = Set-TikTokItemHistory $meta $id @($e1) ''
                # shared entry: history grows by one key per iteration
                $shared = $meta.PSObject.Properties['9']
                $existing = if ($shared) { @($shared.Value.History | Where-Object { $_ }) } else { @() }
                $e2 = ConvertTo-TikTokHistoryEntry (New-TestHistoryEntry -Request "shared$n" -User 'Bob' -Status 'pending' -Accepted '')
                $b = Set-TikTokItemHistory $meta '9' (@($existing) + @($e2)) ''
                return ($a -or $b)
            })
        }
    } catch {
        $failures++
        [Console]::Error.WriteLine("iteration $i failed: $($_.Exception.Message)")
    }
}
exit $(if ($failures) { 1 } else { 0 })
