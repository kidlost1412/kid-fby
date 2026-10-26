# D2: per-video Kho / KhoManual in reup-status.json (Set-VideoKho), delete-kho reassignment, gallery item data (A6).
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$root = $tmp
$baseValidator = Get-BaseGuiFunction -Name 'Get-ReupMetadata' -AsName 'Get-ReupMetadataV301'
if ($baseValidator) { Invoke-Expression $baseValidator }
function Reset-Kho { $script:khoRegistry = $null; $script:khoRegistryReady = $true; $script:khoDownloadTarget = 'default'; $script:importBusy = $false; $script:TestLog.Clear() }
function New-OutDir { $d = New-TestDir; return $d }
function Get-FileHashText { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$statusOf = { param($Dir) Read-TestJson (Join-Path $Dir 'reup-status.json') }
$guid = 'c-0123456789abcdef0123456789abcdef'

# counts Update-ReupMetadata calls (batch = one call)
$script:updateOriginal = (Get-Item function:Update-ReupMetadata).ScriptBlock
$script:updateCalls = 0
function Update-ReupMetadata {
    param([string]$OutDir, [scriptblock]$Change, [int]$TimeoutMs = 10000)
    $script:updateCalls++
    & $script:updateOriginal -OutDir $OutDir -Change $Change -TimeoutMs $TimeoutMs
}

Test-Case 'Set-VideoKho creates minimal valid entries; the v3.0.1 validator accepts the file' {
    $out = New-OutDir
    Assert-True (Set-VideoKho -VideoIds @('111', '222') -KhoId $guid -OutDir $out) 'changed'
    $meta = & $statusOf $out
    foreach ($id in '111', '222') {
        $e = $meta.$id
        Assert-Equal $e.Posted $false; Assert-Equal $e.Date ''; Assert-Equal $e.Kho $guid
        Assert-True ($null -eq $e.PSObject.Properties['KhoManual']) 'KhoManual only when -Manual'
        Assert-Equal @($e.PSObject.Properties).Count 3 'no other fields'
    }
    if ($baseValidator) { $old = Get-ReupMetadataV301 -OutDir $out; Assert-Equal $old.'111'.Kho $guid 'old validator reads it' }
    else { throw 'baseline validator unavailable (git)' }
}

Test-Case 'a batch is one Update-ReupMetadata call' {
    $out = New-OutDir
    $script:updateCalls = 0
    [void](Set-VideoKho -VideoIds @('1', '2', '3', '4', '5') -KhoId $guid -Manual -OutDir $out)
    Assert-Equal $script:updateCalls 1 'calls'
    $meta = & $statusOf $out
    foreach ($id in 1..5) { Assert-Equal $meta."$id".Kho $guid; Assert-Equal $meta."$id".KhoManual $true }
}

Test-Case 'History, ManualPosted and unknown fields are untouched; no-op does not rewrite the file' {
    $out = New-OutDir
    $hist = @((New-TestHistoryEntry -Request 'r1' -User 'Anna'))
    Write-TestMetadata $out @{ '777' = [ordered]@{ Posted = $true; Date = '20/10 10:00'; Source = 'autotok-history'; History = $hist; ManualPosted = $true; ManualDate = '19/10'; FileSha256 = 'abc'; Extra = @{ a = 1 } } }
    $before = & $statusOf $out
    Assert-True (Set-VideoKho -VideoIds @('777') -KhoId $guid -Manual -OutDir $out) 'first call changes'
    $after = & $statusOf $out
    foreach ($name in 'Posted', 'Date', 'Source', 'History', 'ManualPosted', 'ManualDate', 'FileSha256', 'Extra') {
        Assert-Equal (ConvertTo-Json $after.'777'.$name -Depth 8 -Compress) (ConvertTo-Json $before.'777'.$name -Depth 8 -Compress) "field $name"
    }
    Assert-Equal $after.'777'.Kho $guid; Assert-Equal $after.'777'.KhoManual $true
    $hash = Get-FileHashText (Join-Path $out 'reup-status.json'); $stamp = (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    Assert-True (-not (Set-VideoKho -VideoIds @('777') -KhoId $guid -Manual -OutDir $out)) 'second identical call is a no-op'
    Assert-Equal (Get-FileHashText (Join-Path $out 'reup-status.json')) $hash 'bytes'
    Assert-Equal (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc $stamp 'mtime'
}

Test-Case 'manual move to the default kho is a tombstone (Kho=default + KhoManual) that auto-assign respects' {
    $out = New-OutDir
    $hist = @((New-TestHistoryEntry -Request 'r1' -User 'anna'))
    Write-TestMetadata $out @{ '5' = [ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = $hist; ManualPosted = $false; ManualDate = ''; Kho = 'acct:anna' } }
    [void](Set-VideoKho -VideoIds @('5') -KhoId 'default' -Manual -OutDir $out)
    $meta = & $statusOf $out
    Assert-Equal $meta.'5'.Kho 'default'; Assert-Equal $meta.'5'.KhoManual $true
    Assert-True (-not (Invoke-KhoAutoAssign $meta)) 'auto-assign must leave a manual default alone'
    Assert-Equal $meta.'5'.Kho 'default'
}

Test-Case '-OnlyIfUnassigned never overrides an existing Kho or a manual choice' {
    $out = New-OutDir
    Write-TestMetadata $out @{
        '1' = [ordered]@{ Posted = $false; Date = ''; Kho = 'acct:keep' }
        '2' = [ordered]@{ Posted = $false; Date = ''; KhoManual = $true }
        '3' = [ordered]@{ Posted = $false; Date = ''; KhoManual = $false }
        '4' = [ordered]@{ Posted = $false; Date = '' }
    }
    [void](Set-VideoKho -VideoIds @('1', '2', '3', '4', '5') -KhoId $guid -OnlyIfUnassigned -OutDir $out)
    $m = & $statusOf $out
    Assert-Equal $m.'1'.Kho 'acct:keep'
    Assert-True ($null -eq $m.'2'.PSObject.Properties['Kho']) 'manual choice kept'
    Assert-Equal $m.'3'.Kho $guid 'KhoManual=false counts as unassigned'
    Assert-Equal $m.'4'.Kho $guid
    Assert-Equal $m.'5'.Kho $guid 'missing entry created'
}

Test-Case 'bad kho id / video id throw before anything is written' {
    $out = New-OutDir
    Assert-Throws { Set-VideoKho -VideoIds @('1') -KhoId 'nope' -OutDir $out } '*Mã kho không hợp lệ*'
    Assert-Throws { Set-VideoKho -VideoIds @('abc') -KhoId $guid -OutDir $out } '*ID video không hợp lệ*'
    Assert-Throws { Set-VideoKho -VideoIds @('1', '../x') -KhoId $guid -OutDir $out } '*ID video không hợp lệ*'
    Assert-True (-not [IO.File]::Exists((Join-Path $out 'reup-status.json'))) 'no file'
    Assert-True (-not (Set-VideoKho -VideoIds @() -KhoId $guid -OutDir $out)) 'empty batch is a no-op'
}

Test-Case 'a corrupt reup-status.json is never overwritten by Set-VideoKho' {
    $out = New-OutDir
    [IO.File]::WriteAllText((Join-Path $out 'reup-status.json'), '{ broken')
    Assert-Throws { Set-VideoKho -VideoIds @('1') -KhoId $guid -OutDir $out }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $out 'reup-status.json'))) '{ broken'
}

Test-Case 'delete custom kho: its videos lose Kho (and KhoManual), others byte-identical, registry updated' {
    Reset-Kho
    $root = New-TestDir
    $out = New-OutDir
    $k = New-Kho -Name 'Xóa tôi'
    $other = New-Kho -Name 'Giữ'
    Write-TestMetadata $out @{
        '1' = [ordered]@{ Posted = $false; Date = ''; Kho = $k.id; KhoManual = $true }
        '2' = [ordered]@{ Posted = $false; Date = ''; Kho = $k.id }
        '3' = [ordered]@{ Posted = $false; Date = ''; Kho = $other.id; KhoManual = $true }
        '4' = [ordered]@{ Posted = $true; Date = 'x' }
    }
    $before = & $statusOf $out
    $moved = Remove-Kho -Id $k.id -OutDir $out
    Assert-Equal $moved 2 'moved count'
    $m = & $statusOf $out
    foreach ($id in '1', '2') { Assert-True ($null -eq $m.$id.PSObject.Properties['Kho'] -and $null -eq $m.$id.PSObject.Properties['KhoManual']) "video $id back to default" }
    foreach ($id in '3', '4') { Assert-Equal (ConvertTo-Json $m.$id -Compress) (ConvertTo-Json $before.$id -Compress) "video $id untouched" }
    Assert-True (@((Get-KhoRegistry).libraries | Where-Object { $_.id -eq $k.id }).Count -eq 0) 'registry'
    Assert-Equal (Get-KhoEffectiveId $m.'1') 'default'
}

Test-Case 'delete account kho: videos get KhoManual and stay in the default kho; another confirmed video re-creates the kho' {
    Reset-Kho
    $root = New-TestDir
    $out = New-OutDir
    $h1 = @((New-TestHistoryEntry -Request 'a1' -User 'Anna'))
    $h2 = @((New-TestHistoryEntry -Request 'a2' -User 'Anna' -Accepted '2026-10-22T10:00:00Z'))
    Write-TestMetadata $out @{
        '1' = [ordered]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = $h1; ManualPosted = $false; ManualDate = ''; Kho = 'acct:anna' }
        '2' = [ordered]@{ Posted = $false; Date = ''; Source = 'autotok-history'; History = @((New-TestHistoryEntry -Request 'a2' -User 'Anna' -Status 'pending' -Accepted '')); ManualPosted = $false; ManualDate = '' }
    }
    [void](Get-KhoList -Metadata (& $statusOf $out))
    Assert-True (@((Get-KhoRegistry).libraries | Where-Object { $_.id -eq 'acct:anna' }).Count -eq 1) 'account kho materialized'
    Assert-Equal (Remove-Kho -Id 'acct:anna' -OutDir $out) 1
    $m = & $statusOf $out
    Assert-True ($null -eq $m.'1'.PSObject.Properties['Kho']) 'Kho removed'
    Assert-Equal $m.'1'.KhoManual $true
    Assert-True (-not (Invoke-KhoAutoAssign $m)) 'video 1 stays in the default kho for good'
    Assert-True (@((Get-KhoList -Metadata $m) | Where-Object { $_.id -eq 'acct:anna' }).Count -eq 0) 'kho not resurrected by video 1'
    # video 2 is confirmed on Anna later -> its Kho appears, the kho is back, video 1 is still default
    $m.'2'.History[0].status = 'succeeded'; $m.'2'.History[0].accepted_at = '2026-10-22T10:00:00Z'
    Assert-True (Invoke-KhoAutoAssign $m) 'video 2 assigned'
    Assert-Equal $m.'2'.Kho 'acct:anna'
    Assert-True ($null -eq $m.'1'.PSObject.Properties['Kho']) 'video 1 unchanged'
    Assert-True (@((Get-KhoList -Metadata $m) | Where-Object { $_.id -eq 'acct:anna' }).Count -eq 1) 'account kho re-created'
}

Test-Case 'delete kho with a corrupt reup-status.json: nothing changes (kho stays registered)' {
    Reset-Kho
    $root = New-TestDir
    $out = New-OutDir
    $k = New-Kho -Name 'Còn nguyên'
    [IO.File]::WriteAllText((Join-Path $out 'reup-status.json'), '{ broken')
    Assert-Throws { Remove-Kho -Id $k.id -OutDir $out }
    Assert-True (@((Get-KhoRegistry).libraries | Where-Object { $_.id -eq $k.id }).Count -eq 1) 'memory'
    Reset-Kho
    Assert-True (@((Get-KhoRegistry).libraries | Where-Object { $_.id -eq $k.id }).Count -eq 1) 'disk'
}

# ---- A6 gallery item data ----
function Get-TestFile {
    param([string]$Id)
    $path = Join-Path $tmp "$Id-3-hoan-chinh.mp4"
    return [pscustomobject]@{ Name = "$Id-3-hoan-chinh.mp4"; FullName = $path; Length = 123456; LastWriteTime = [datetime]'2026-10-20T10:00:00'; Stamp = '123456|1' }
}
$baseItem = Get-BaseGuiFunction -Name 'New-GalleryItem' -AsName 'New-GalleryItemV301'
if ($baseItem) { Invoke-Expression $baseItem }
$script:tikTok = [pscustomobject]@{ Enabled = $true }

Test-Case 'gallery items: same data as v3.0.1 plus Kho/KhoManual (default when missing); signature gains Kho|KhoManual' {
    if (-not $baseItem) { throw 'baseline New-GalleryItem unavailable (git)' }
    $held = New-TestHistoryEntry -Request 'h1' -User 'Anna'; $held.tiktok_schedule_time = ([datetime]::UtcNow.AddDays(2)).ToString('o'); $held.schedule_mode = 'native'
    $meta = [pscustomobject]@{
        '10' = [pscustomobject]@{ Posted = $true; Date = '19/10 08:00' }
        '11' = [pscustomobject]@{ Posted = $true; Date = '20/10 10:00'; Source = 'autotok-history'; History = @((New-TestHistoryEntry -Request 'r1' -User 'Anna')); ManualPosted = $false; ManualDate = '' }
        '12' = [pscustomobject]@{ Posted = $true; Date = ''; Source = 'autotok-history'; History = @([pscustomobject]$held); ManualPosted = $false; ManualDate = '' }
        '13' = [pscustomobject]@{ Posted = $false; Date = ''; Source = 'autotok-history'; History = @((New-TestHistoryEntry -Request 'r3' -User 'Anna' -Status 'pending')); ManualPosted = $false; ManualDate = '' }
    }
    foreach ($tikTokOn in $true, $false) {
        $script:tikTok.Enabled = $tikTokOn
        foreach ($id in '10', '11', '12', '13', '99') {
            $old = New-GalleryItemV301 -File (Get-TestFile $id) -Metadata $meta -Probe $null
            $new = New-GalleryItem -File (Get-TestFile $id) -Metadata $meta -Probe $null
            foreach ($p in $old.PSObject.Properties) {
                if ($p.Name -in @('Signature', 'Date', 'File')) { continue }
                Assert-Equal "$($new.$($p.Name))" "$($p.Value)" "[$id tiktok=$tikTokOn] property $($p.Name)"
            }
            Assert-Equal $new.Kho 'default' "[$id] Kho"; Assert-Equal $new.KhoManual $false
            Assert-Equal $new.Signature ($old.Signature + '|default|False') "[$id] signature"
        }
    }
    $script:tikTok.Enabled = $true
}

Test-Case 'gallery item: Kho and KhoManual are read from the entry and change the signature' {
    $meta = [pscustomobject]@{ '20' = [pscustomobject]@{ Posted = $false; Date = ''; Kho = 'acct:anna'; KhoManual = $true } }
    $a = New-GalleryItem -File (Get-TestFile '20') -Metadata $meta -Probe $null
    Assert-Equal $a.Kho 'acct:anna'; Assert-Equal $a.KhoManual $true
    $meta.'20'.KhoManual = $false
    $b = New-GalleryItem -File (Get-TestFile '20') -Metadata $meta -Probe $null
    Assert-True ($a.Signature -ne $b.Signature) 'KhoManual changes the signature'
    $meta.'20'.Kho = 'acct:bob'
    $c = New-GalleryItem -File (Get-TestFile '20') -Metadata $meta -Probe $null
    Assert-True ($b.Signature -ne $c.Signature) 'Kho changes the signature'
    Assert-Equal $c.Kho 'acct:bob'
    $d = New-GalleryItem -File (Get-TestFile '20') -Metadata $null -Probe $null
    Assert-Equal $d.Kho 'default' 'no metadata at all'
}

Test-Case 'no kho.json and no TikTok: registry is default-only and Get-KhoList of any metadata adds nothing' {
    Reset-Kho
    $root = New-TestDir
    $meta = [pscustomobject]@{ '1' = [pscustomobject]@{ Posted = $true; Date = 'x' } }
    Assert-Equal @(Get-KhoList -Metadata $meta).Count 1
    Assert-True (-not [IO.File]::Exists((Join-Path $root 'data\kho.json'))) 'no kho.json is created just by browsing'
}

Complete-Tests
