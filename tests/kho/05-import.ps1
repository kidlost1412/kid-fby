# D5/A5: Import-KhoFolder - no overwrite, idempotent retry after a failed metadata step, history union, cancel, background runspace.
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$root = $tmp
$guid = 'c-0123456789abcdef0123456789abcdef'
function Get-Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function New-Bytes { param([string]$Path, [int]$Size, [int]$Seed) $b = New-Object byte[] $Size; (New-Object System.Random $Seed).NextBytes($b); [IO.File]::WriteAllBytes($Path, $b) }
function Get-TreeSnapshot {
    # relative path -> hash for every file under a folder (to prove the source is untouched)
    param([string]$Dir)
    $base = (Get-Item -LiteralPath $Dir).FullName.TrimEnd('\')
    return ((Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($base.Length) + '=' + (Get-Sha $_.FullName) + '@' + $_.LastWriteTimeUtc.Ticks }) -join "`n")
}
function New-SourceFolder {
    $s = New-TestDir
    New-Bytes (Join-Path $s '111-3-hoan-chinh.mp4') (9MB + 17) 1          # > 2 chunks of 4 MB
    [void][IO.Directory]::CreateDirectory((Join-Path $s '.cache'))
    New-Bytes (Join-Path $s '.cache\111-1-video-goc.mp4') 3000 2
    New-Bytes (Join-Path $s '.cache\111-2-am-thanh-tho.m4a') 2000 3
    New-Bytes (Join-Path $s '222-3-hoan-chinh.mp4') 5000 4
    New-Bytes (Join-Path $s '222-1-video-goc.mp4') 1500 5                  # legacy root companion
    New-Bytes (Join-Path $s '333-3-hoan-chinh.mp4') 4000 6
    New-Bytes (Join-Path $s 'abc-3-hoan-chinh.mp4') 100 7                  # not a Reel id
    New-Bytes (Join-Path $s '444-3-hoan-chinh.mp4.part') 100 8             # not a final file
    $h1 = New-TestHistoryEntry -Request 'k1' -User 'Anna' -Created '2026-10-20T09:00:00Z'
    $h2 = New-TestHistoryEntry -Request 'k2' -User 'Bob' -Created '2026-10-21T09:00:00Z' -Accepted '2026-10-21T10:00:00Z'
    Write-TestMetadata $s @{
        '111' = [ordered]@{ Posted = $true; Date = '20/10 10:00'; Source = 'autotok-history'; History = @($h1, $h2); ManualPosted = $false; ManualDate = ''; FileSha256 = 'f111'; Kho = 'acct:old'; KhoManual = $true }
        '222' = [ordered]@{ Posted = $true; Date = '19/10 08:00' }
    }
    return $s
}

Test-Case 'basic import: copies new ids byte-identically with companions, skips a different existing file, leaves the source untouched' {
    $src = New-SourceFolder; $out = New-TestDir
    New-Bytes (Join-Path $out '333-3-hoan-chinh.mp4') 777 99   # different content already in the output folder
    Write-TestMetadata $out @{ '333' = [ordered]@{ Posted = $false; Date = ''; Kho = 'acct:keep' } }
    $target333 = Get-Sha (Join-Path $out '333-3-hoan-chinh.mp4'); $meta333 = ConvertTo-Json (Read-TestJson (Join-Path $out 'reup-status.json')).'333' -Compress
    $snap = Get-TreeSnapshot $src
    $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r.Added 2 'added'; Assert-Equal $r.Skipped 1 'skipped'; Assert-Equal $r.Failed 0 'failed'
    Assert-Equal ($r.AddedIds -join ',') '111,222'; Assert-Equal ($r.SkippedIds -join ',') '333'
    Assert-Equal (Get-Sha (Join-Path $out '111-3-hoan-chinh.mp4')) (Get-Sha (Join-Path $src '111-3-hoan-chinh.mp4')) '111 bytes'
    Assert-Equal (Get-Sha (Join-Path $out '222-3-hoan-chinh.mp4')) (Get-Sha (Join-Path $src '222-3-hoan-chinh.mp4')) '222 bytes'
    Assert-Equal (Get-Sha (Join-Path $out '.cache\111-1-video-goc.mp4')) (Get-Sha (Join-Path $src '.cache\111-1-video-goc.mp4')) '111 -1'
    Assert-Equal (Get-Sha (Join-Path $out '.cache\111-2-am-thanh-tho.m4a')) (Get-Sha (Join-Path $src '.cache\111-2-am-thanh-tho.m4a')) '111 -2'
    Assert-Equal (Get-Sha (Join-Path $out '.cache\222-1-video-goc.mp4')) (Get-Sha (Join-Path $src '222-1-video-goc.mp4')) 'legacy root -1 lands in .cache'
    Assert-True (([IO.File]::GetAttributes((Join-Path $out '.cache')) -band [IO.FileAttributes]::Hidden) -ne 0) '.cache is hidden like the engine makes it'
    Assert-True (-not [IO.File]::Exists((Join-Path $out 'abc-3-hoan-chinh.mp4'))) 'non-id name ignored'
    Assert-Equal (Get-Sha (Join-Path $out '333-3-hoan-chinh.mp4')) $target333 'existing different file untouched'
    Assert-Equal (ConvertTo-Json (Read-TestJson (Join-Path $out 'reup-status.json')).'333' -Compress) $meta333 'its entry untouched'
    Assert-Equal @(Get-ChildItem -LiteralPath $out -Recurse -Force -Filter '*.part').Count 0 'no .part leftovers'
    Assert-Equal (Get-TreeSnapshot $src) $snap 'source folder untouched (content and mtime)'
    $m = Read-TestJson (Join-Path $out 'reup-status.json')
    Assert-Equal $m.'111'.Kho $guid 'imported entry gets the chosen kho (source Kho/KhoManual dropped)'
    Assert-True ($null -eq $m.'111'.PSObject.Properties['KhoManual']) 'source KhoManual not carried over'
    Assert-Equal @($m.'111'.History).Count 2 'history copied'; Assert-Equal $m.'111'.Source 'autotok-history'; Assert-Equal $m.'111'.Posted $true
    Assert-Equal $m.'222'.Kho $guid; Assert-Equal $m.'222'.Date '19/10 08:00' 'manual mark copied'
}

Test-Case 'no overwrite: a pre-existing -3 file with different content is never replaced, even on repeated imports' {
    $src = New-SourceFolder; $out = New-TestDir
    New-Bytes (Join-Path $out '111-3-hoan-chinh.mp4') 10 5
    $h = Get-Sha (Join-Path $out '111-3-hoan-chinh.mp4')
    foreach ($i in 1..2) {
        $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
        Assert-True ($r.SkippedIds -contains '111') "run $i skips 111"
        Assert-Equal (Get-Sha (Join-Path $out '111-3-hoan-chinh.mp4')) $h "run $i bytes"
    }
    $m = Read-TestJson (Join-Path $out 'reup-status.json')
    Assert-True ($null -eq $m.PSObject.Properties['111']) 'skipped id gets no metadata'
}

Test-Case 'metadata failure: files stay, nothing is reported added, the retry finishes the job and a third run changes nothing' {
    $src = New-SourceFolder; $out = New-TestDir
    [IO.File]::WriteAllText((Join-Path $out 'reup-status.json'), '{ broken')   # makes the metadata step fail
    $r1 = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r1.Added 0 'run 1 added'; Assert-Equal $r1.Failed 3 'run 1 failed (111, 222, 333)'
    Assert-True (@($r1.Errors | Where-Object { $_ -like '*Chạy lại*' }).Count -eq 1) 'tells the owner to run again'
    Assert-True ([IO.File]::Exists((Join-Path $out '111-3-hoan-chinh.mp4'))) 'file stayed'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $out 'reup-status.json'))) '{ broken' 'corrupt metadata untouched'
    [IO.File]::Delete((Join-Path $out 'reup-status.json'))                           # the owner fixed the cause
    $r2 = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r2.Added 0 'run 2: files were copied by run 1, so none is newly added'; Assert-Equal $r2.Skipped 3 'identical files already present count as already present'; Assert-Equal $r2.Failed 0
    $m = Read-TestJson (Join-Path $out 'reup-status.json')
    Assert-Equal $m.'111'.Kho $guid; Assert-Equal @($m.'111'.History).Count 2
    $hash = Get-Sha (Join-Path $out 'reup-status.json'); $stamp = (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    $r3 = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r3.Failed 0 'run 3'
    Assert-Equal (Get-Sha (Join-Path $out 'reup-status.json')) $hash 'run 3 rewrites nothing'
    Assert-Equal (Get-Item (Join-Path $out 'reup-status.json')).LastWriteTimeUtc $stamp 'run 3 mtime'
}

Test-Case 'history union by key (our entry wins), ManualPosted kept, KhoManual / account kho respected, plain target gets the kho' {
    $src = New-SourceFolder; $out = New-TestDir
    New-Bytes (Join-Path $out '111-3-hoan-chinh.mp4') 1 0
    Copy-Item -LiteralPath (Join-Path $src '111-3-hoan-chinh.mp4') -Destination (Join-Path $out '111-3-hoan-chinh.mp4') -Force   # identical copy already there
    Copy-Item -LiteralPath (Join-Path $src '222-3-hoan-chinh.mp4') -Destination (Join-Path $out '222-3-hoan-chinh.mp4') -Force
    Copy-Item -LiteralPath (Join-Path $src '333-3-hoan-chinh.mp4') -Destination (Join-Path $out '333-3-hoan-chinh.mp4') -Force
    $ours1 = New-TestHistoryEntry -Request 'k1' -User 'Anna' -Status 'running' -Accepted '' -Created '2026-10-20T09:00:00Z'   # same key as source k1 but different state
    $ours3 = New-TestHistoryEntry -Request 'k3' -User 'Carl' -Created '2026-10-22T09:00:00Z' -Accepted '2026-10-22T10:00:00Z'
    Write-TestMetadata $out @{
        '111' = [ordered]@{ Posted = $true; Date = '1/1'; Source = 'autotok-history'; History = @($ours3, $ours1); ManualPosted = $true; ManualDate = '1/1'; FileSha256 = 'mine'; KhoManual = $true; Kho = 'default' }
        '222' = [ordered]@{ Posted = $false; Date = ''; Kho = 'acct:keep' }
        '333' = [ordered]@{ Posted = $false; Date = '' }
    }
    $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r.Added 0 'identical copies are not newly added'; Assert-Equal $r.Skipped 3 'they count as already present'; Assert-Equal $r.Failed 0
    $m = Read-TestJson (Join-Path $out 'reup-status.json')
    $keys = @($m.'111'.History | ForEach-Object { $_.key })
    Assert-Equal ($keys -join ',') 'request:k3,request:k2,request:k1' 'union sorted by created_at desc'
    Assert-Equal (@($m.'111'.History | Where-Object { $_.key -eq 'request:k1' })[0].status) 'running' 'ours wins on the same key'
    Assert-Equal $m.'111'.ManualPosted $true; Assert-Equal $m.'111'.FileSha256 'mine'
    Assert-Equal $m.'111'.Posted $true 'aggregate still posted'
    Assert-Equal $m.'111'.KhoManual $true; Assert-Equal $m.'111'.Kho 'default' 'manual choice kept'
    Assert-Equal $m.'222'.Kho 'acct:keep' 'account kho kept'
    Assert-Equal $m.'222'.Date '' 'target manual state not replaced by the source entry'
    Assert-Equal $m.'333'.Kho $guid 'plain entry gets the kho'
}

Test-Case 'importing into the default kho records history but no Kho field' {
    $src = New-SourceFolder; $out = New-TestDir
    $r = Import-KhoFolder -SourceDir $src -KhoId 'default' -OutDir $out
    Assert-Equal $r.Added 3
    $m = Read-TestJson (Join-Path $out 'reup-status.json')
    Assert-True ($null -eq $m.'111'.PSObject.Properties['Kho']) 'no Kho'
    Assert-Equal @($m.'111'.History).Count 2
}

Test-Case 'unreadable source reup-status.json: files and kho still imported, a warning explains the missing history' {
    $src = New-SourceFolder; $out = New-TestDir
    [IO.File]::WriteAllText((Join-Path $src 'reup-status.json'), '{ broken')
    $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r.Added 3; Assert-True (@($r.Warnings | Where-Object { $_ -like '*reup-status.json của thư mục nguồn*' }).Count -eq 1) 'warning'
    $m = Read-TestJson (Join-Path $out 'reup-status.json')
    Assert-Equal $m.'111'.Kho $guid; Assert-True ($null -eq $m.'111'.PSObject.Properties['History']) 'no history copied'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $src 'reup-status.json'))) '{ broken' 'source untouched'
}

Test-Case 'progress callback gets Done/Total/Id; a throwing callback is reported once and does not stop the import' {
    $src = New-SourceFolder; $out = New-TestDir
    $seen = New-Object System.Collections.Generic.List[string]
    $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out -Progress { param($p) $seen.Add("$($p.Done)/$($p.Total):$($p.Id)") }
    Assert-Equal ($seen -join ' ') '1/3:111 2/3:222 3/3:333'
    $out2 = New-TestDir
    $r2 = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out2 -Progress { param($p) throw 'ui gone' }
    Assert-Equal $r2.Added 3
    Assert-Equal @($r2.Warnings | Where-Object { $_ -like '*báo tiến độ lỗi*ui gone*' }).Count 1
}

Test-Case 'cancel: before the start nothing is copied; during the run the files already copied are recorded' {
    $src = New-SourceFolder
    $out = New-TestDir
    $cts = [Threading.CancellationTokenSource]::new(); $cts.Cancel()
    $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out -CancelToken $cts.Token
    Assert-True $r.Cancelled 'cancelled'; Assert-Equal $r.Added 0
    Assert-Equal @(Get-ChildItem -LiteralPath $out -Force -Recurse -File).Count 0 'nothing copied'
    $out2 = New-TestDir
    $cts2 = [Threading.CancellationTokenSource]::new()
    $r2 = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out2 -CancelToken $cts2.Token -Progress { param($p) if ($p.Done -eq 2) { $cts2.Cancel() } }
    Assert-True $r2.Cancelled 'cancelled mid-way'
    Assert-Equal $r2.Added 1 'only 111 was complete'; Assert-Equal ($r2.AddedIds -join ',') '111'
    Assert-True (-not [IO.File]::Exists((Join-Path $out2 '222-3-hoan-chinh.mp4'))) '222 not copied'
    Assert-Equal @(Get-ChildItem -LiteralPath $out2 -Force -Recurse -Filter '*.part').Count 0 'no .part leftovers'
    Assert-Equal (Read-TestJson (Join-Path $out2 'reup-status.json')).'111'.Kho $guid
}

Test-Case 'argument errors: same folder, bad kho id, missing source' {
    $src = New-SourceFolder
    Assert-Throws { Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir ($src + '\') } '*trùng thư mục xuất*'
    Assert-Throws { Import-KhoFolder -SourceDir $src -KhoId 'nope' -OutDir (New-TestDir) } '*Mã kho không hợp lệ*'
    Assert-Throws { Import-KhoFolder -SourceDir (Join-Path $src 'missing') -KhoId $guid -OutDir (New-TestDir) } '*Không thấy thư mục nguồn*'
}

Test-Case 'names with spaces, brackets and Vietnamese in the folder paths' {
    $base = New-TestDir
    $src = Join-Path $base 'nguồn [1] kho'; $out = Join-Path $base 'xuất [2] đích'
    [void][IO.Directory]::CreateDirectory($src)
    New-Bytes (Join-Path $src '123-3-hoan-chinh.mp4') 2048 11
    $r = Import-KhoFolder -SourceDir $src -KhoId $guid -OutDir $out
    Assert-Equal $r.Added 1
    Assert-Equal (Get-Sha -Path ([IO.Path]::Combine($out, '123-3-hoan-chinh.mp4'))) (Get-Sha -Path ([IO.Path]::Combine($src, '123-3-hoan-chinh.mp4')))
}

Test-Case 'runs in a background runspace built only from $script:khoImportFunctions (no UI, no globals)' {
    $src = New-SourceFolder; $out = New-TestDir
    $state = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in $script:khoImportFunctions) {
        $state.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Item -LiteralPath "function:$name").ScriptBlock.ToString()))
    }
    $ps = [PowerShell]::Create($state)
    try {
        $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        [void]$ps.AddScript({
            param($S, $K, $O, $Q)
            $callback = { param($p) $Q.Enqueue("$($p.Done)/$($p.Total):$($p.Id)") }.GetNewClosure()
            Import-KhoFolder -SourceDir $S -KhoId $K -OutDir $O -Progress $callback
        }).AddArgument($src).AddArgument($guid).AddArgument($out).AddArgument($queue)
        $handle = $ps.BeginInvoke()
        Assert-True ($handle.AsyncWaitHandle.WaitOne(60000)) 'finished in time'
        $result = $ps.EndInvoke($handle)
        Assert-True ($ps.Streams.Error.Count -eq 0) "runspace errors: $($ps.Streams.Error -join '; ')"
        Assert-Equal $result[0].Added 3
        Assert-Equal @($result[0].Warnings).Count 0 'no warnings'
        Assert-Equal (($queue.ToArray()) -join ' ') '1/3:111 2/3:222 3/3:333' 'progress arrived from the other runspace'
    } finally { $ps.Dispose() }
    Assert-Equal (Read-TestJson (Join-Path $out 'reup-status.json')).'111'.Kho $guid
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
