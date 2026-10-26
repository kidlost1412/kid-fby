# Delete a video / a kho: files go to the REAL Windows Recycle Bin (temp folders only), metadata removed only after every file is recycled,
# partial failure (locked file) keeps the metadata and reports, retry finishes, blocked by jobs / journals / busy app, folder recycle rules.
# Note: the recycled files are tiny temp files; they stay in the Recycle Bin of the account running the tests.
. (Join-Path $PSScriptRoot '_load.ps1')
$shell = New-Object -ComObject Shell.Application
function In-RecycleBin { param([string]$LeafLike) return @($shell.NameSpace(10).Items() | Where-Object { $_.Name -like $LeafLike }).Count }
function Full { param($w, [string]$Id, $Root = $null) if (-not $Root) { $Root = $w.A.path } return (New-TestVideo $Root $Id -Entry (New-TestPostedEntry ('{0:x32}' -f [long]$Id))) }

Test-Case 'delete video (real Recycle Bin): -3, -1/-2 and receipts leave the folder AND appear in the Recycle Bin, thumbnails are deleted, the entry goes, other videos are untouched' {
    $w = New-TestWorld @('B')
    $id = NextId; $other = NextId
    [void](Full $w $id); [void](Full $w $other)
    $otherTree = @(Get-ChildItem -LiteralPath $w.A.path -Recurse -Force -File | Where-Object { $_.Name -like "$other*" -or $_.FullName -like "*$other*" } | ForEach-Object { $_.FullName + '=' + (Get-FileHash $_.FullName).Hash }) -join '|'
    $r = Remove-ReelToRecycleBin -Root $w.A.path -Id $id
    Assert-True $r.Success "errors: $($r.Errors -join '; ')"; Assert-Equal @($r.Errors).Count 0; Assert-Equal @($r.Remaining).Count 0
    Assert-Equal @($r.Recycled).Count 5 '-3, -1, -2, receipt, archived receipt'
    foreach ($f in @("$id-3-hoan-chinh.mp4", ".cache\$id-1-video-goc.mp4", ".cache\$id-2-am-thanh-tho.m4a", ".cache\thumbs\$id.jpg", ".cache\thumbs\$id.json")) { Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path $f))) "still there: $f" }
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $w.A.path '.cache\tiktok-posts') -Filter ('{0:x32}*' -f [long]$id)).Count 0 'receipts gone'
    Assert-Equal (In-RecycleBin "$id-3-hoan-chinh.mp4") 1 'the -3 is in the Recycle Bin (not deleted outright)'
    Assert-Equal (In-RecycleBin "$id-1-video-goc.mp4") 1; Assert-Equal (In-RecycleBin "$id.jpg") 0 'thumbnails are regenerable: deleted, not recycled'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'entry removed'
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$other]) 'other entry kept'
    $after = @(Get-ChildItem -LiteralPath $w.A.path -Recurse -Force -File | Where-Object { $_.FullName -like "*$other*" } | ForEach-Object { $_.FullName + '=' + (Get-FileHash $_.FullName).Hash }) -join '|'
    Assert-Equal $after $otherTree 'the other video is byte-identical'
}
Test-Case 'delete video: a locked companion -> the -3 is recycled first, the entry is KEPT, the leftover is reported; after unlocking, a retry (-3 already gone) finishes and removes the entry' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](Full $w $id)
    $audio = Join-Path $w.A.path ".cache\$id-2-am-thanh-tho.m4a"
    $lock = [IO.File]::Open($audio, 'Open', 'Read', 'None')
    try { $r = Remove-ReelToRecycleBin -Root $w.A.path -Id $id } finally { $lock.Dispose() }
    Assert-True (-not $r.Success) 'not a success'
    Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path "$id-3-hoan-chinh.mp4"))) '-3 was recycled first'
    Assert-Equal (@($r.Remaining) -join '|') $audio 'the locked file is reported'
    Assert-True (@($r.Errors)[0] -like "$id-2-am-thanh-tho.m4a*") "error text: $(@($r.Errors)[0])"
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'metadata kept so the owner can retry'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path ".cache\thumbs\$id.jpg"))) 'thumbnails not touched on failure'
    $r2 = Remove-ReelToRecycleBin -Root $w.A.path -Id $id
    Assert-True $r2.Success "retry: $($r2.Errors -join '; ')"
    Assert-True (-not [IO.File]::Exists($audio)) 'leftover recycled by the retry'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$id]) 'entry removed at the end'
}
Test-Case 'delete video: a TikTok job (retained .job or live .lock) refuses before touching any file; invalid ids are refused' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](Full $w $id)
    Write-Job $w.A.path ('{0:x32}' -f 31337) $id
    $before = Get-TestTree $w.A.path
    $r = Remove-ReelToRecycleBin -Root $w.A.path -Id $id
    Assert-True (-not $r.Success); Assert-True (@($r.Errors)[0] -like '*lệnh đăng chưa xong*') "errors: $(@($r.Errors)[0])"
    Assert-Equal (Get-TestTree $w.A.path) $before 'nothing touched'
    $bad = Remove-ReelToRecycleBin -Root $w.A.path -Id '..\..\x'
    Assert-True (-not $bad.Success); Assert-True (@($bad.Errors)[0] -like '*ID video không hợp lệ*')
}
Test-Case 'delete video: the Recycle seam is called once per existing file, never for a missing one (-3 missing with leftovers is still deletable)' {
    $w = New-TestWorld @('B')
    $id = NextId; [void](Full $w $id -Root $w.A.path)
    Remove-Item -LiteralPath (Join-Path $w.A.path "$id-3-hoan-chinh.mp4")
    $script:seen = New-Object System.Collections.Generic.List[string]
    $script:khoRecycleOverride = { param($Path, $IsFolder) $script:seen.Add([IO.Path]::GetFileName($Path)); [IO.File]::Delete($Path) }
    $r = Remove-ReelToRecycleBin -Root $w.A.path -Id $id
    $script:khoRecycleOverride = $null
    Assert-True $r.Success; Assert-True (-not ($script:seen -contains "$id-3-hoan-chinh.mp4")) 'no call for the missing -3'
    Assert-True ($script:seen -contains "$id-1-video-goc.mp4") 'leftover companion recycled'
}

# ---------------- delete a kho ----------------
Test-Case 'delete kho (real Recycle Bin): all videos recycled, kho leaves the registry (and the saved file), download target moves to another kho, an app-made folder with only app files is recycled too' {
    $w = New-TestWorld @('B')
    $i1 = NextId; $i2 = NextId
    [void](Full $w $i1 $w.B.path); [void](Full $w $i2 $w.B.path)
    Set-KhoDownloadTarget $w.B.id
    $kept = NextId; [void](Full $w $kept $w.A.path)
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True $r.Success "why: $($r.Why) failed: $(($r.Failed | ForEach-Object { $_.Id + ': ' + ($_.Errors -join ',') }) -join ' | ')"
    Assert-Equal $r.Deleted 2; Assert-Equal @($r.Failed).Count 0; Assert-True $r.FolderRecycled 'folder recycled'
    Assert-True (-not [IO.Directory]::Exists($w.B.path)) 'folder gone from its place'
    Assert-Equal (In-RecycleBin "$i1-3-hoan-chinh.mp4") 1 'video in the Recycle Bin'
    Assert-True ($null -eq (Get-KhoById $w.B.id)) 'unregistered'
    $script:khoRegistry = $null
    Assert-True ($null -eq (Get-KhoById $w.B.id)) 'and the registry file says so'
    Assert-Equal (Get-KhoDownloadTarget) $w.A.id 'target moved to the remaining kho'
    Assert-True ([IO.File]::Exists((Join-Path $w.A.path "$kept-3-hoan-chinh.mp4"))) 'the other kho is untouched'
}
Test-Case 'delete kho: a foreign file in the folder keeps the folder (and that file) but the kho is unregistered; a kho on a pre-existing folder (createdByApp false) never recycles the folder' {
    $w = New-TestWorld @('B', 'C')
    $i1 = NextId; [void](Full $w $i1 $w.B.path)
    [IO.File]::WriteAllText((Join-Path $w.B.path 'notes.txt'), 'owner file')
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True $r.Success; Assert-True (-not $r.FolderRecycled) 'folder kept'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $w.B.path 'notes.txt'))) 'owner file'
    Assert-True ($null -eq (Get-KhoById $w.B.id))
    $pre = Join-Path $script:root 'pre-existing'; [void][IO.Directory]::CreateDirectory($pre)
    $p = New-Kho -Name 'Pre' -Path $pre; Assert-Equal $p.createdByApp $false
    $i2 = NextId; [void](Full $w $i2 $pre)
    $r2 = Remove-KhoWithVideos -Id $p.id
    Assert-True $r2.Success; Assert-True (-not $r2.FolderRecycled); Assert-True ([IO.Directory]::Exists($pre)) 'folder the app did not make is left alone'
    Assert-True (-not [IO.File]::Exists((Join-Path $pre "$i2-3-hoan-chinh.mp4"))) 'its video was recycled'
}
Test-Case 'delete an empty kho: unregistered and (app-made, only app files) its folder recycled' {
    $w = New-TestWorld @('B')
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True $r.Success; Assert-Equal $r.Deleted 0; Assert-True $r.FolderRecycled; Assert-True (-not [IO.Directory]::Exists($w.B.path))
}
Test-Case 'delete kho refusals: busy app, an unfinished move journal, a TikTok job (any video) or an unknown-owner job -> NOTHING is deleted and the kho stays registered' {
    $w = New-TestWorld @('B')
    $i1 = NextId; $i2 = NextId
    [void](Full $w $i1 $w.B.path); [void](Full $w $i2 $w.B.path)
    $before = Get-TestTree $w.B.path
    $script:queue = @(1)
    $r = Remove-KhoWithVideos -Id $w.B.id
    $script:queue = @()
    Assert-True (-not $r.Success); Assert-True ($r.Why -like 'Đang bận (đang tải, ghi âm hoặc sửa video)*') "busy why: $($r.Why)"
    Write-Job $w.B.path ('{0:x32}' -f 5150) $i2
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True ($r.Why -like "Video #${i2}:*lệnh đăng chưa xong*") "job why: $($r.Why)"
    Remove-Item -LiteralPath (Join-Path (Posts $w.B.path) ('{0:x32}.job' -f 5150))
    Write-Job $w.B.path ('{0:x32}' -f 5151) '' -Raw 'garbage{'
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True ($r.Why -like '*không rõ thuộc video nào*') "unknown owner why: $($r.Why)"
    Remove-Item -LiteralPath (Join-Path (Posts $w.B.path) ('{0:x32}.job' -f 5151))
    # unfinished move journal that names this kho (conflict that recovery cannot resolve)
    $dir = Get-KhoMovesDir; [void][IO.Directory]::CreateDirectory($dir)
    $j = [ordered]@{ version = 1; txid = 'a' * 32; id = '1'; from = $w.A.path; to = $w.B.path; phase = 'renaming'; renames = @([ordered]@{ src = (Join-Path $w.A.path 'x'); dst = (Join-Path $w.B.path 'x'); optional = $false; kind = 'companion'; status = 'pending' }) }
    [IO.File]::WriteAllText((Join-Path $dir ('a' * 32 + '.json')), (ConvertTo-Json $j -Depth 8), [Text.UTF8Encoding]::new($false))
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True (-not $r.Success); Assert-True ($null -ne (Get-KhoById $w.B.id)) 'still registered'
    Remove-Item -LiteralPath (Join-Path $dir ('a' * 32 + '.json'))
    Assert-Equal (Get-TestTree $w.B.path) $before 'nothing was deleted by any refusal'
    Assert-Equal @(Get-KhoList).Count 2
}
Test-Case 'delete kho with one locked video: the others are recycled, the kho is KEPT, the failure is listed; after unlocking, a retry deletes the rest and unregisters' {
    $w = New-TestWorld @('B')
    $i1 = NextId; $i2 = NextId; $i3 = NextId
    foreach ($i in $i1, $i2, $i3) { [void](Full $w $i $w.B.path) }
    $lock = [IO.File]::Open((Join-Path $w.B.path "$i2-3-hoan-chinh.mp4"), 'Open', 'Read', 'None')
    try { $r = Remove-KhoWithVideos -Id $w.B.id } finally { $lock.Dispose() }
    Assert-True (-not $r.Success); Assert-Equal $r.Deleted 2; Assert-Equal @($r.Failed).Count 1; Assert-Equal $r.Failed[0].Id $i2
    Assert-True ($r.Why -like 'Chưa xóa hết*') "why: $($r.Why)"
    Assert-True ($null -ne (Get-KhoById $w.B.id)) 'kho kept'
    Assert-True ([IO.File]::Exists((Join-Path $w.B.path "$i2-3-hoan-chinh.mp4"))) 'locked video still there'
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $w.B.path).PSObject.Properties[$i2]) 'its entry kept'
    $r2 = Remove-KhoWithVideos -Id $w.B.id
    Assert-True $r2.Success "retry: $($r2.Why)"; Assert-Equal $r2.Deleted 1; Assert-True ($null -eq (Get-KhoById $w.B.id))
}
Test-Case 'a failed registry save after the files were recycled is reported by an exception, never as success' {
    $w = New-TestWorld @('B')
    $i1 = NextId; [void](Full $w $i1 $w.B.path)
    $fs = [IO.File]::Open((Get-KhoPath), 'Open', 'Read', 'None')
    try { Assert-Throws { [void](Remove-KhoWithVideos -Id $w.B.id) } '*' } finally { $fs.Dispose() }
    Assert-True (-not $script:khoMoveRunning) 'flag cleared even after a failure'
    Assert-True ($null -ne (Get-KhoById $w.B.id)) 'kho still registered in memory'
}
Test-Case 'Test-KhoFolderOnlyAppFiles: status file + hidden cache with thumbs/empty receipt folder/identity cache = app files only; anything else is not' {
    $d = New-TestDir
    [IO.File]::WriteAllText((Join-Path $d 'reup-status.json'), '{}')
    foreach ($sub in '.cache\thumbs', '.cache\tiktok-posts') { [void][IO.Directory]::CreateDirectory((Join-Path $d $sub)) }
    [IO.File]::WriteAllText((Join-Path $d '.cache\tiktok-identities.json'), '{}')
    Assert-True (Test-KhoFolderOnlyAppFiles $d) 'app files only'
    [IO.File]::WriteAllText((Join-Path $d ('.cache\tiktok-posts\{0:x32}.json' -f 1)), '{}')
    Assert-True (-not (Test-KhoFolderOnlyAppFiles $d)) 'a receipt inside tiktok-posts = not only app files'
    Remove-Item -LiteralPath (Join-Path $d '.cache\tiktok-posts') -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $d '.cache\1-1-video-goc.mp4'), 'x')
    Assert-True (-not (Test-KhoFolderOnlyAppFiles $d)) 'a companion = not only app files'
    Remove-Item -LiteralPath (Join-Path $d '.cache\1-1-video-goc.mp4'); [IO.File]::WriteAllText((Join-Path $d '1-3-hoan-chinh.mp4'), 'x')
    Assert-True (-not (Test-KhoFolderOnlyAppFiles $d)) 'a video = not only app files'
    Remove-Item -LiteralPath (Join-Path $d '1-3-hoan-chinh.mp4'); [void][IO.Directory]::CreateDirectory((Join-Path $d 'other-dir'))
    Assert-True (-not (Test-KhoFolderOnlyAppFiles $d)) 'a foreign folder = not only app files'
}

Complete-Tests
