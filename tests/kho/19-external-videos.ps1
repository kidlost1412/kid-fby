# D12: every video file in a kho folder is a kho video. Identity (app id vs 'f:' + file name), thumbnail key, TikTok clean-copy plan (remux vs transcode),
# gallery item -> move -> delete of an external file, drag-and-drop copy, sync file list, receipts.
. (Join-Path $PSScriptRoot '_load.ps1')
$shell = New-Object -ComObject Shell.Application
function In-RecycleBin { param([string]$LeafLike) return @($shell.NameSpace(10).Items() | Where-Object { $_.Name -like $LeafLike }).Count }

# ---------------- identity (pure) ----------------
Test-Case 'file names: every listed extension, any case; hidden, .part, .tmp, no extension and other types are not kho videos' {
    foreach ($ok in 'a.mp4', 'a.MOV', 'a.M4v', 'a.mkv', 'a.WEBM', 'a.avi', 'Clip đẹp (1).Mp4', '1000-3-hoan-chinh.mp4') { Assert-True (Test-KhoVideoFileName $ok) "should accept $ok" }
    foreach ($bad in '', '.hidden.mp4', 'a.mp4.part', 'a.part', 'a.tmp', 'a.mp4.tmp', 'a', 'a.txt', 'a.jpg', 'a.m4a', '.mp4') { Assert-True (-not (Test-KhoVideoFileName $bad)) "should reject '$bad'" }
}
Test-Case 'keys: app videos keep the numeric id (any case), everything else is f: + the exact file name' {
    Assert-Equal (Get-KhoVideoKey '123456-3-hoan-chinh.mp4') '123456'
    Assert-Equal (Get-KhoVideoKey '123456-3-HOAN-CHINH.MP4') '123456'
    Assert-Equal (Get-KhoVideoKey 'abc-3-hoan-chinh.mp4') 'f:abc-3-hoan-chinh.mp4'
    Assert-Equal (Get-KhoVideoKey '123456-1-video-goc.mp4') 'f:123456-1-video-goc.mp4'
    Assert-Equal (Get-KhoVideoKey 'Clip đẹp (1).MOV') 'f:Clip đẹp (1).MOV'
    Assert-Equal (Get-KhoVideoKey 'note.txt') ''
    Assert-Equal (Get-KhoVideoKey 'x.mp4.part') ''
}
Test-Case 'key validity and key -> file name round trip' {
    Assert-True (Test-KhoVideoKey '123'); Assert-True (Test-KhoVideoKey 'f:a b.mkv')
    foreach ($bad in '', 'f:', 'f:a.txt', 'abc', '12a', 'f:.x.mp4') { Assert-True (-not (Test-KhoVideoKey $bad)) "invalid '$bad'" }
    Assert-Equal (Get-KhoVideoFileName '123') '123-3-hoan-chinh.mp4'
    Assert-Equal (Get-KhoVideoFileName 'f:Clip đẹp (1).MOV') 'Clip đẹp (1).MOV'
    Assert-Equal (Get-KhoVideoFileName 'zzz') ''
    Assert-Equal (Get-KhoVideoPath 'C:\kho A' 'f:x y.mkv') 'C:\kho A\x y.mkv'
}
Test-Case 'thumbnail key: numeric id as is; external = f_ + lowercase SHA1 of the file name (constants computed with sha1sum)' {
    Assert-Equal (Get-KhoThumbKey '123') '123'
    Assert-Equal (Get-KhoThumbKey 'f:a.mp4') 'f_43a5f5afea642470614d8625c59264de47bea201'
    Assert-Equal (Get-KhoThumbKey 'f:Clip đẹp (1).MOV') 'f_5ee663475768a171a55864ca5b636bfe3333acaf'
    Assert-Equal (Get-KhoThumbKey 'f:x y.mkv') 'f_119f08d75eeee27d1bfa5c100e737cc7dbf1df98'
}
Test-Case 'TikTok wire reel_id: numeric for app videos, nothing for external (history then matches by sha256)' {
    Assert-Equal (Get-TikTokWireReelId '1234') '1234'
    Assert-Equal (Get-TikTokWireReelId 'f:a.mp4') ''
}

# ---------------- clean copy plan from ffprobe JSON ----------------
function Plan { param([string]$Json) return (Get-TikTokCleanPlan (ConvertFrom-Json $Json)) }
$h264 = '{"codec_type":"video","codec_name":"h264"}'; $hevc = '{"codec_type":"video","codec_name":"hevc"}'; $vp9 = '{"codec_type":"video","codec_name":"vp9"}'
$aac = '{"codec_type":"audio","codec_name":"aac"}'; $opus = '{"codec_type":"audio","codec_name":"opus"}'; $mp3 = '{"codec_type":"audio","codec_name":"mp3"}'
Test-Case 'plan: H.264 + AAC and HEVC + AAC are remuxed (copy)' {
    Assert-Equal (Plan "{`"streams`":[$h264,$aac]}") 'copy'; Assert-Equal (Plan "{`"streams`":[$hevc,$aac]}") 'copy'
}
Test-Case 'plan: H.264 / HEVC without audio is remuxed' { Assert-Equal (Plan "{`"streams`":[$h264]}") 'copy'; Assert-Equal (Plan "{`"streams`":[$hevc]}") 'copy' }
Test-Case 'plan: H.264 + opus/mp3 keeps the video and re-encodes only the audio to AAC' {
    Assert-Equal (Plan "{`"streams`":[$h264,$opus]}") 'audio'; Assert-Equal (Plan "{`"streams`":[$hevc,$mp3]}") 'audio'
}
Test-Case 'plan: other video codecs (vp9, prores, mpeg4) are transcoded to H.264/AAC' {
    Assert-Equal (Plan "{`"streams`":[$vp9,$opus]}") 'video'
    Assert-Equal (Plan '{"streams":[{"codec_type":"video","codec_name":"prores"},{"codec_type":"audio","codec_name":"pcm_s16le"}]}') 'video'
    Assert-Equal (Plan '{"streams":[{"codec_type":"video","codec_name":"mpeg4"},{"codec_type":"audio","codec_name":"aac"}]}') 'video'
}
Test-Case 'plan: no video stream (audio only, or only a cover picture) cannot be posted' {
    Assert-Equal (Plan "{`"streams`":[$aac]}") 'none'
    Assert-Equal (Plan '{"streams":[{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"codec_type":"audio","codec_name":"aac"}]}') 'none'
    Assert-Equal (Plan '{"streams":[]}') 'none'
}
Test-Case 'plan: codec names are case-insensitive; a cover picture next to the real video is ignored' {
    Assert-Equal (Plan '{"streams":[{"codec_type":"video","codec_name":"H264"},{"codec_type":"audio","codec_name":"AAC"}]}') 'copy'
    Assert-Equal (Plan '{"streams":[{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"codec_type":"video","codec_name":"h264"},{"codec_type":"audio","codec_name":"aac"}]}') 'copy'
}
Test-Case 'clean copy: when ffprobe fails the error is a clear Vietnamese message and nothing is created' {
    $fakeRoot = New-TestDir
    $tools = Join-Path $fakeRoot 'tools\ffmpeg'; [void][IO.Directory]::CreateDirectory($tools)
    foreach ($n in 'ffmpeg.exe', 'ffprobe.exe') { Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $tools $n) }   # exits non-zero with these arguments
    $src = Join-Path $fakeRoot 'broken.mov'; [IO.File]::WriteAllBytes($src, [byte[]](1..200))
    $posts = Join-Path $fakeRoot 'posts'; [void][IO.Directory]::CreateDirectory($posts)
    Assert-Throws { New-TikTokCleanCopy -SourcePath $src -PostsDir $posts -RequestId ('a' * 32) -Root $fakeRoot } 'Không đọc được thông tin video bằng ffprobe*'
    Assert-Equal @(Get-ChildItem -LiteralPath $posts -Force).Count 0 'no clean file left behind'
}

# ---------------- gallery item / receipts / sync file list ----------------
function New-ExternalFile {
    param($Root, [string]$Name, [switch]$Receipt, [switch]$Thumb, [switch]$Entry)
    [void][IO.Directory]::CreateDirectory($Root)
    $path = Join-Path $Root $Name
    [IO.File]::WriteAllBytes($path, (Get-TestBytes "external $Name"))
    $key = Get-KhoVideoKey $Name
    if ($Thumb) {
        $td = Join-Path $Root '.cache\thumbs'; [void][IO.Directory]::CreateDirectory($td); $tk = Get-KhoThumbKey $key
        [IO.File]::WriteAllBytes((Join-Path $td "$tk.jpg"), (Get-TestBytes 'thumb')); [IO.File]::WriteAllBytes((Join-Path $td "$tk.json"), (Get-TestBytes '{}'))
    }
    $req = '{0:x32}' -f ([Math]::Abs($Name.GetHashCode()) + 1)
    if ($Receipt) {
        Save-TikTokReceipt ([pscustomobject]@{ RequestId = $req; VideoId = $key; Username = 'anna'; ScheduledFor = ''; Status = 'posted'; CreatedAt = '2026-10-20T09:00:00Z'; LaunchedAt = ''; OutDir = $Root; SourcePath = $path; SourceSha256 = ''; UploadSha256 = '' })
    }
    if ($Entry) {
        $e = New-TestPostedEntry $req
        [void](Update-ReupMetadata -OutDir $Root -Change { param($meta) $meta | Add-Member -MemberType NoteProperty -Name $key -Force -Value ([pscustomobject]$e); return $true })
    }
    return @{ Path = $path; Key = $key; Req = $req }
}
Test-Case 'gallery item: external file -> id f:<name>, title = name without extension, thumbnail key, flagged external; app file unchanged' {
    $w = New-TestWorld @('B'); Update-KhoKnown
    $ext = New-ExternalFile $w.A.path 'Clip đẹp (1).MOV'
    $fi = Get-Item -LiteralPath $ext.Path
    $file = [pscustomobject]@{ FullName = $fi.FullName; Name = $fi.Name; Length = $fi.Length; LastWriteTime = $fi.LastWriteTime; Stamp = 'x'; Root = $w.A.path }
    $item = New-GalleryItem -File $file -Metadata ([pscustomobject]@{}) -Probe $null
    Assert-Equal $item.Id 'f:Clip đẹp (1).MOV'; Assert-Equal $item.Title 'Clip đẹp (1)'; Assert-True $item.External
    Assert-Equal $item.ThumbKey 'f_5ee663475768a171a55864ca5b636bfe3333acaf'; Assert-Equal $item.Kho $w.A.id
    $id = NextId; [void](New-TestVideo -Root $w.A.path -Id $id -NoReceipt)
    $app = [pscustomobject]@{ FullName = (Join-Path $w.A.path "$id-3-hoan-chinh.mp4"); Name = "$id-3-hoan-chinh.mp4"; Length = 5; LastWriteTime = [DateTime]::Now; Stamp = 'y'; Root = $w.A.path }
    $item2 = New-GalleryItem -File $app -Metadata ([pscustomobject]@{}) -Probe $null
    Assert-Equal $item2.Id $id; Assert-Equal $item2.Title "Reel #$id"; Assert-True (-not $item2.External); Assert-Equal $item2.ThumbKey $id
}
Test-Case 'receipt of an external video is accepted by the receipt reader (VideoId must equal the key of its SourcePath)' {
    $w = New-TestWorld @('B')
    $ext = New-ExternalFile $w.A.path 'a b.mkv' -Receipt
    $r = @(Get-TikTokReceipts $w.A.path)
    Assert-Equal $r.Count 1; Assert-Equal $r[0].VideoId 'f:a b.mkv'
    $bad = New-ExternalFile $w.A.path 'c.mp4' -Receipt
    $p = Join-Path $w.A.path ".cache\tiktok-posts\$($bad.Req).json"
    $doc = Read-TestJson $p; $doc.VideoId = 'f:other.mp4'; [IO.File]::WriteAllText($p, (ConvertTo-Json $doc), [Text.UTF8Encoding]::new($false))
    $script:tikTokReceiptCache = @{}
    Assert-Equal @(Get-TikTokReceipts $w.A.path).Count 1 'the mismatching receipt is ignored'
}
Test-Case 'metadata: a manual mark on an external video works while the file exists and is refused after it left the folder' {
    $w = New-TestWorld @('B')
    $ext = New-ExternalFile $w.A.path 'm.webm'
    Set-ReupMetadata -VideoId $ext.Key -Posted $true -OutDir $w.A.path
    Assert-True ((Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$ext.Key].Value.Posted) 'marked'
    Remove-Item -LiteralPath $ext.Path
    Assert-Throws { Set-ReupMetadata -VideoId 'f:gone.webm' -Posted $true -OutDir $w.A.path } '*không còn trong thư mục kho*'
}
Test-Case 'kho video files: all video types are listed, partial/temp/hidden/other files are not' {
    $w = New-TestWorld @('B'); $d = $w.A.path
    foreach ($n in 'a.mp4', 'b.MOV', 'c.m4v', 'd.mkv', 'e.webm', 'f.avi', 'g.mp4.part', 'h.tmp', '.i.mp4', 'j.txt', '777-3-hoan-chinh.mp4') { [IO.File]::WriteAllBytes((Join-Path $d $n), [byte[]](1, 2)) }
    Assert-Equal ((Get-KhoVideoFiles $d | ForEach-Object { $_.Name } | Sort-Object) -join '|') '777-3-hoan-chinh.mp4|a.mp4|b.MOV|c.m4v|d.mkv|e.webm|f.avi'
}

# ---------------- move / delete of an external file (temp dirs) ----------------
Test-Case 'move: an external file with its thumbnails and finished receipt moves to the other kho; metadata entry follows; nothing is invented (no -1/-2)' {
    $w = New-TestWorld @('B')
    $ext = New-ExternalFile $w.A.path 'Clip đẹp (1).MOV' -Receipt -Thumb -Entry
    $tk = Get-KhoThumbKey $ext.Key
    $r = Invoke-KhoMove -Items @([pscustomobject]@{ Id = $ext.Key; Path = $ext.Path }) -TargetId $w.B.id -Reason manual
    Assert-Equal $r.Busy ''; Assert-Equal @($r.Failed).Count 0 ($r.Failed | ForEach-Object { $_.Why })
    Assert-Equal @($r.Moved).Count 1
    $to = $w.B.path
    Assert-True ([IO.File]::Exists((Join-Path $to 'Clip đẹp (1).MOV'))) 'file in target'; Assert-True (-not [IO.File]::Exists($ext.Path)) 'gone from source'
    foreach ($rel in ".cache\thumbs\$tk.jpg", ".cache\thumbs\$tk.json", ".cache\tiktok-posts\$($ext.Req).json") { Assert-True ([IO.File]::Exists((Join-Path $to $rel))) "moved $rel"; Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path $rel))) "left $rel" }
    $rec = Read-TestJson (Join-Path $to ".cache\tiktok-posts\$($ext.Req).json")
    Assert-Equal $rec.OutDir $to; Assert-Equal $rec.SourcePath (Join-Path $to 'Clip đẹp (1).MOV'); Assert-Equal $rec.VideoId $ext.Key
    Assert-True ($null -ne (Get-ReupMetadata -OutDir $to).PSObject.Properties[$ext.Key]) 'entry in target'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$ext.Key]) 'entry removed from source'
    Assert-Equal @(Get-TestJournalFiles).Count 0 'journal gone'
}
Test-Case 'move: a same-named external file in the target is never overwritten' {
    $w = New-TestWorld @('B')
    $ext = New-ExternalFile $w.A.path 'same.mp4'
    [IO.File]::WriteAllBytes((Join-Path $w.B.path 'same.mp4'), (Get-TestBytes 'target original'))
    $r = Invoke-KhoMove -Items @([pscustomobject]@{ Id = $ext.Key; Path = $ext.Path }) -TargetId $w.B.id -Reason manual
    Assert-Equal @($r.Moved).Count 0; Assert-Equal @($r.Failed).Count 1
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $w.B.path 'same.mp4'))) 'target original'
    Assert-True ([IO.File]::Exists($ext.Path)) 'source untouched'
}
Test-Case 'delete: an external file goes to the Recycle Bin with its thumbnails removed and its entry gone' {
    $w = New-TestWorld @('B')
    $name = 'rb-' + [Guid]::NewGuid().ToString('N') + '.mp4'
    $ext = New-ExternalFile $w.A.path $name -Receipt -Thumb -Entry
    $tk = Get-KhoThumbKey $ext.Key
    $r = Remove-ReelToRecycleBin -Root $w.A.path -Id $ext.Key
    Assert-True $r.Success "errors: $($r.Errors -join '; ')"
    Assert-True (-not [IO.File]::Exists($ext.Path)) 'file left the kho'
    Assert-Equal (In-RecycleBin $name) 1 'in the Recycle Bin'
    Assert-True (-not [IO.File]::Exists((Join-Path $w.A.path ".cache\thumbs\$tk.jpg"))) 'thumbnail deleted'
    Assert-True ($null -eq (Get-ReupMetadata -OutDir $w.A.path).PSObject.Properties[$ext.Key]) 'entry removed'
}
Test-Case 'delete confirmation text and media list of an external video mention only the file itself' {
    $w = New-TestWorld @('B'); $ext = New-ExternalFile $w.A.path 'only.mov'
    $files = @(Get-ReelMediaFiles -VideoPath $ext.Path -Existing)
    Assert-Equal $files.Count 1; Assert-Equal $files[0].Kind 'final'
    Assert-True ((Get-DeleteConfirmText $ext.Path) -like '*only.mov*') 'names the file'
    Assert-Equal (Test-ReeditInputs $ext.Path) $false 'no re-edit for external'
    Assert-Equal (Get-ReelCompanionPath -VideoPath $ext.Path -Kind source) '' 'no companion'
}
Test-Case 'delete kho: external videos in the folder are recycled too (and the folder is not recycled since it holds non-app files only after they are gone)' {
    $w = New-TestWorld @('B')
    $n1 = 'k1-' + [Guid]::NewGuid().ToString('N') + '.mkv'
    [void](New-ExternalFile $w.B.path $n1)
    $r = Remove-KhoWithVideos -Id $w.B.id
    Assert-True $r.Success $r.Why; Assert-Equal $r.Deleted 1
    Assert-Equal (In-RecycleBin $n1) 1
}

# ---------------- drag and drop copy ----------------
Test-Case 'drop copy: new files appear without overwriting; same name skipped; non-video, folders and missing files skipped; no .part left' {
    $w = New-TestWorld @('B')
    $src = New-TestDir
    $a = Join-Path $src 'new clip.mov'; $b = Join-Path $src 'dup.mp4'; $c = Join-Path $src 'readme.txt'; $dir = Join-Path $src 'sub.mp4'
    [IO.File]::WriteAllBytes($a, (Get-TestBytes 'AAA')); [IO.File]::WriteAllBytes($b, (Get-TestBytes 'from outside')); [IO.File]::WriteAllBytes($c, (Get-TestBytes 'x')); [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllBytes((Join-Path $w.B.path 'dup.mp4'), (Get-TestBytes 'already in kho'))
    $r = Copy-KhoExternalFiles -Files @($a, $b, $c, $dir, (Join-Path $src 'missing.mp4')) -ToRoot $w.B.path
    Assert-Equal ($r.Copied -join '|') 'new clip.mov'; Assert-Equal @($r.Skipped).Count 4; Assert-Equal @($r.Failed).Count 0
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $w.B.path 'new clip.mov'))) 'AAA'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $w.B.path 'dup.mp4'))) 'already in kho' 'not overwritten'
    Assert-Equal @(Get-ChildItem -LiteralPath $w.B.path -Filter '*.part').Count 0 'no partial left'
    Assert-True ([IO.File]::Exists($a)) 'the source is only copied'
}
Test-Case 'drop copy: a copy that fails midway leaves no .part and no video' {
    $w = New-TestWorld @('B')
    $src = New-TestDir; $a = Join-Path $src 'locked.mov'; [IO.File]::WriteAllBytes($a, (Get-TestBytes 'AAA'))
    $lock = [IO.File]::Open($a, 'Open', 'Read', 'None')
    try { $r = Copy-KhoExternalFiles -Files @($a) -ToRoot $w.B.path } finally { $lock.Dispose() }
    Assert-Equal @($r.Failed).Count 1; Assert-Equal @($r.Copied).Count 0
    Assert-Equal @(Get-ChildItem -LiteralPath $w.B.path -Force -File).Count 0 'folder is clean'
}
Test-Case 'drop is refused while the app is not quiet, and with "Tất cả kho"; allowed when quiet' {
    $w = New-TestWorld @('B'); $src = New-TestDir; $a = Join-Path $src 'q.mp4'; [IO.File]::WriteAllBytes($a, (Get-TestBytes 'Q'))
    function Update-Gallery { $script:galleryRefreshed++ }
    $script:filterKho = [string]$w.B.id; $script:galleryRefreshed = 0
    $script:importBusy = $true; $script:TestLog.Clear()
    Invoke-KhoDrop -Files @($a)
    Assert-True (-not [IO.File]::Exists((Join-Path $w.B.path 'q.mp4'))) 'refused while busy'; Assert-True (@($script:TestLog | Where-Object { $_ -like '*Đang bận*' }).Count -eq 1) 'says busy'
    $script:importBusy = $false; $script:filterKho = 'all'; $script:TestLog.Clear()
    Invoke-KhoDrop -Files @($a)
    Assert-True (-not [IO.File]::Exists((Join-Path $w.B.path 'q.mp4'))) 'refused for all khos'; Assert-True (@($script:TestLog | Where-Object { $_ -like '*Chọn một kho cụ thể*' }).Count -eq 1)
    $script:filterKho = [string]$w.B.id; $script:TestLog.Clear()
    Invoke-KhoDrop -Files @($a)
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $w.B.path 'q.mp4'))) 'Q'; Assert-Equal $script:galleryRefreshed 1 'gallery refreshed'
    Assert-True (-not $script:khoMoveRunning) 'busy flag released'
}
# ---------------- TikTok sync worker (real worker block, fake backend) ----------------
. (Join-Path $PSScriptRoot 'FakeBackend.ps1')
Test-Case 'sync worker: an external video is listed under key f:<name>, looked up by the short id f_<sha1>, its history stored under the key; app videos still sync' {
    $out = New-TestDir
    $server = Start-FakeBackend
    try {
        [IO.File]::WriteAllText((Join-Path $out '555-3-hoan-chinh.mp4'), 'app video')
        [IO.File]::WriteAllText((Join-Path $out 'a.mp4'), 'external video')
        [IO.File]::WriteAllText((Join-Path $out 'skip.mp4.part'), 'partial')
        $req1 = '{0:x32}' -f 11; $req2 = '{0:x32}' -f 22
        $server.Rows['555'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request $req1 -User 'Anna'))
        $server.Rows['f_43a5f5afea642470614d8625c59264de47bea201'] = ConvertTo-EntriesJson @((New-TestHistoryEntry -Request $req2 -User 'Bob'))
        $payload = @{ out_dir = $out; receipts = @(); last_input_sig = ''; last_file_stamp = ''; probe_cursor = ''; identity_cache = $null; file = $null }
        $run = Invoke-Worker 'sync' $payload $server.Url
        Assert-Equal $run.Errors.Count 0 ($run.Errors -join ' | ')
        $m = Read-TestJson (Join-Path $out 'reup-status.json')
        Assert-Equal @($m.'555'.History).Count 1 'app video'
        Assert-True ($null -ne $m.PSObject.Properties['f:a.mp4']) 'external entry stored under f:a.mp4'
        Assert-Equal $m.'f:a.mp4'.History[0].username 'Bob'
        Assert-Equal @($m.PSObject.Properties | Where-Object { $_.Name -like '*part*' }).Count 0 'partial file ignored'
    } finally { $server.Stop(); Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue }
}
Complete-Tests
