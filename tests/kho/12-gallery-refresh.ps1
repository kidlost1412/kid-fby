# Gallery refresh: rename of a kho rebuilds only that kho's cards (2,500 synthetic items, counted - not timed);
# status tab counts follow the date filter and the search text while the kho dropdown counts stay whole-kho.
. (Join-Path $PSScriptRoot '_load.ps1')
$script:khoRegistry = [pscustomobject]@{ version = 2; downloadTarget = 'kd'; libraries = @(
    [pscustomobject]@{ id = 'kd'; name = 'Output cu'; path = 'C:\k\d'; account = '' }, [pscustomobject]@{ id = 'ka'; name = 'A'; path = 'C:\k'; account = 'a' }, [pscustomobject]@{ id = 'kb'; name = 'B'; path = 'C:\k'; account = 'b' }) }
$script:khoRegistryReady = $true
$script:probeCache = @{}; $script:filterKho = 'all'; $script:filterStatus = 'all'; $script:filterSearch = ''; $script:filterDate = 'all'
$script:galleryNowUtc = [DateTime]::UtcNow
$today = [DateTime]'2026-10-20'

# 2,500 items: kho = ka for i%5==0 (500), kb for i%5==1 (500), '' (a folder nobody registered: in no kho) for i%5==2, else kd (1000).
# i%3==0 posted, i%3==1 pending, i%3==2 held. Date: i%2==0 -> today, else 2026-10-10.
function New-FakeItems {
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 2500; $i++) {
        $kho = switch ($i % 5) { 0 { 'ka' } 1 { 'kb' } 2 { '' } default { 'kd' } }
        $held = $null; $posted = $false
        switch ($i % 3) { 0 { $posted = $true } 2 { $held = [DateTime]::UtcNow.AddDays(3) } }
        $date = if ($i % 2 -eq 0) { $today.AddHours(8) } else { $today.AddDays(-10).AddHours(8) }
        [void]$list.Add([pscustomobject]@{ Id = ('v{0:D4}' -f $i); Path = "p$i"; File = $i; Kho = $kho; Posted = $posted; HeldUntil = $held; Date = $date; Signature = 's' })
    }
    return , $list
}

function Get-ReupMetadata { return [pscustomobject]@{} }
function New-GalleryItem { param($File, $Metadata, $Probe) $script:rebuilt++; return [pscustomobject]@{ Id = ('v{0:D4}' -f [int]$File); Path = "p$File"; File = $File; Kho = $script:galleryAll[[int]$File].Kho; Posted = $false; HeldUntil = $null; Date = $today; Signature = 'new' } }
function Apply-GalleryFilter { $script:applied++ }

Test-Case 'rename: only the renamed kho cards are rebuilt (not all 2,500); cards of an unregistered folder belong to no kho' {
    $script:galleryAll = New-FakeItems
    $script:rebuilt = 0; $script:applied = 0
    Update-KhoKnown
    Update-KhoCardsAfterRename -KhoId 'ka'
    Assert-Equal $script:rebuilt 500 'rebuilt cards for ka'
    Assert-Equal $script:applied 1 'one filter pass'
    Assert-Equal @($script:galleryAll | Where-Object { $_.Signature -eq 'new' }).Count 500 'only ka replaced'
    $script:rebuilt = 0
    Update-KhoCardsAfterRename -KhoId 'kd'
    Assert-Equal $script:rebuilt 1000 'kd = its own 1000 cards only (the 500 unregistered-folder cards are not in it)'
}
Test-Case 'rename of a kho with no cards: no rebuild at all (empty Ids must not mean everything)' {
    $script:galleryAll = New-FakeItems
    $script:khoRegistry.libraries += [pscustomobject]@{ id = 'ke'; name = 'E'; path = 'C:\k\e'; account = '' }
    $script:rebuilt = 0; $script:applied = 0
    Update-KhoKnown
    Update-KhoCardsAfterRename -KhoId 'ke'
    Assert-Equal $script:rebuilt 0 'rebuilt'
    Assert-Equal $script:applied 1 'filter still applied'
}

# Real Select-GalleryItems below (re-load: drop the stubs above is not needed, it is not stubbed).
Test-Case 'status tab counts follow date filter and search; kho counts stay whole-kho; one pass' {
    $script:galleryAll = New-FakeItems
    $script:filterKho = 'all'; $script:filterStatus = 'all'; $script:filterSearch = ''; $script:filterDate = 'all'
    [void](Select-GalleryItems -Today $today -UpdateCounts)
    # 2500: posted = i%3==0 -> 834, pending i%3==1 -> 833, held i%3==2 -> 833
    Assert-Equal ($script:galleryTabCounts -join ',') '833,833,834' 'no filters: pending,held,posted'
    # today = even i. i=2k: i%3 = 0 for k%3==0 (417), 1 for k%3==2 (416), 2 for k%3==1 (417) -> pending 416 held 417 posted 417
    $script:filterDate = 'today'
    $r = Select-GalleryItems -Today $today -UpdateCounts
    Assert-Equal ($script:galleryTabCounts -join ',') '416,417,417' 'today'
    Assert-Equal $r.Count 1250 'list size'
    Assert-Equal ($script:khoCounts['ka'] -join ',') '166,167,167' 'kho counts ignore the date filter'
    $script:filterStatus = 'held'
    $r = Select-GalleryItems -Today $today -UpdateCounts
    Assert-Equal ($script:galleryTabCounts -join ',') '416,417,417' 'status filter does not change the tab counts'
    Assert-Equal $r.Count 417 'held list'
    $script:filterStatus = 'all'; $script:filterDate = 'all'; $script:filterSearch = 'v00'
    [void](Select-GalleryItems -Today $today -UpdateCounts)   # v0000..v0099 = 100 items: 34 posted, 33 pending, 33 held
    Assert-Equal ($script:galleryTabCounts -join ',') '33,33,34' 'search v00'
    $script:filterKho = 'ka'; $script:filterSearch = ''
    [void](Select-GalleryItems -Today $today -UpdateCounts)   # i%5==0: i=5m
    Assert-Equal ($script:galleryTabCounts -join ',') ($script:khoCounts['ka'] -join ',') 'single kho, no date/search -> equals kho counts'
}
Complete-Tests
