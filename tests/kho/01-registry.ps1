# D1: kho registry (data\kho.json) - missing / corrupt / locked behaviour, create / rename / delete / options, download target.
. (Join-Path $PSScriptRoot '_load.ps1')
$tmp = New-TestDir
$root = $tmp
$khoFile = Join-Path $tmp 'data\kho.json'
$outDir = Join-Path $tmp 'out'
function Reset-Kho {
    $script:khoRegistry = $null; $script:khoRegistryReady = $true; $script:khoDownloadTarget = 'default'; $script:importBusy = $false
    $script:TestLog.Clear()
}
function Get-FileHashText { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

Test-Case 'missing kho.json -> default only, ready, nothing written' {
    Reset-Kho
    $reg = Get-KhoRegistry
    Assert-Equal @($reg.libraries).Count 1 'library count'
    Assert-Equal $reg.libraries[0].id 'default'
    Assert-Equal $reg.libraries[0].name 'Kho chung'
    Assert-True $script:khoRegistryReady 'ready flag'
    Assert-True (-not [IO.File]::Exists($khoFile)) 'kho.json must not be created by a read'
    Assert-Equal @(Get-KhoList).Count 1
}

Test-Case 'create / rename / options persist across a reload (Vietnamese text, single hashtag stays an array)' {
    Reset-Kho
    $lib = New-Kho -Name '  Phim hài Việt  '
    Assert-True ($lib.id -cmatch '^c-[0-9a-f]{32}$') "id format: $($lib.id)"
    Assert-Equal $lib.name 'Phim hài Việt' 'trimmed name'
    Rename-Kho -Id $lib.id -Name 'Phim hài mới'
    Set-KhoOptions -Id $lib.id -Caption 'Xem ngay nhé' -Hashtags @('#hai') -LowStock 5
    Reset-Kho
    $reg = Get-KhoRegistry
    Assert-Equal @($reg.libraries).Count 2
    $back = @($reg.libraries | Where-Object { $_.id -eq $lib.id })[0]
    Assert-Equal $back.name 'Phim hài mới'
    Assert-Equal $back.caption 'Xem ngay nhé'
    Assert-Equal @($back.hashtags).Count 1
    Assert-Equal $back.hashtags[0] '#hai'
    Assert-Equal $back.lowStock 5
    $raw = [IO.File]::ReadAllText($khoFile, [Text.Encoding]::UTF8)
    Assert-True ($raw -match '"hashtags":\s*\[') 'hashtags must be a JSON array on disk'
    Assert-True ($raw -match 'Phim hài mới') 'Vietnamese text must be stored as UTF-8'
    # Only the parameters given change.
    Set-KhoOptions -Id $lib.id -LowStock 2
    Reset-Kho
    $back = @((Get-KhoRegistry).libraries | Where-Object { $_.id -eq $lib.id })[0]
    Assert-Equal $back.caption 'Xem ngay nhé' 'caption kept'
    Assert-Equal $back.lowStock 2
}

Test-Case 'name rules: empty, too long, duplicate (case-insensitive), default is fixed; failures leave the file untouched' {
    Reset-Kho
    [void](New-Kho -Name 'Kho A')
    $before = Get-FileHashText $khoFile
    Assert-Throws { New-Kho -Name '   ' } '*không được để trống*'
    Assert-Throws { New-Kho -Name ('x' * 61) } '*tối đa 60*'
    Assert-Throws { New-Kho -Name 'kho a' } "*Đã có kho tên*"
    Assert-Throws { New-Kho -Name 'KHO CHUNG' } "*Đã có kho tên*"
    Assert-Throws { Rename-Kho -Id 'default' -Name 'Khác' } '*giữ nguyên tên*'
    $b = New-Kho -Name 'Kho B'
    Assert-Throws { Rename-Kho -Id $b.id -Name 'kho a' } "*Đã có kho tên*"
    Assert-Throws { Set-KhoOptions -Id $b.id -LowStock 1000 } '*0 đến 999*'
    Assert-Throws { Set-KhoOptions -Id 'c-00000000000000000000000000000000' -Caption 'x' } '*Không tìm thấy*'
    # in-memory registry equals the saved one after the failed calls
    $mem = (Get-KhoRegistry).libraries.Count
    Reset-Kho
    Assert-Equal (Get-KhoRegistry).libraries.Count $mem 'memory == disk'
    Assert-True ($before -ne (Get-FileHashText $khoFile)) 'sanity: adding Kho B changed the file'
}

Test-Case 'delete: default refused, unknown refused, refused while an import runs' {
    Reset-Kho
    $x = New-Kho -Name 'Để xóa'
    Assert-Throws { Remove-Kho -Id 'default' -OutDir $outDir } '*Không xóa được Kho chung*'
    Assert-Throws { Remove-Kho -Id 'c-ffffffffffffffffffffffffffffffff' -OutDir $outDir } '*Không tìm thấy*'
    $script:importBusy = $true
    Assert-Throws { Remove-Kho -Id $x.id -OutDir $outDir } '*Đang thêm video*'
    Assert-True (@((Get-KhoRegistry).libraries | Where-Object { $_.id -eq $x.id }).Count -eq 1) 'kho still there'
    $script:importBusy = $false
    Assert-Equal (Remove-Kho -Id $x.id -OutDir $outDir) 0 'no videos moved'
    Assert-True (@((Get-KhoRegistry).libraries | Where-Object { $_.id -eq $x.id }).Count -eq 0) 'kho gone'
}

Test-Case 'corrupt kho.json is renamed .corrupt-<ts>, default only, session may save afterwards' {
    foreach ($garbage in @('{not json', '[]', '{"version":1}', '')) {
        Reset-Kho
        [void][IO.Directory]::CreateDirectory((Split-Path $khoFile))
        Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json*' | Remove-Item -Force
        [IO.File]::WriteAllText($khoFile, $garbage)
        $reg = Get-KhoRegistry
        Assert-Equal @($reg.libraries).Count 1 "garbage '$garbage'"
        Assert-True $script:khoRegistryReady "ready after renaming (garbage '$garbage')"
        Assert-True (-not [IO.File]::Exists($khoFile)) 'original moved away'
        $bad = @(Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json.corrupt-*')
        Assert-Equal $bad.Count 1 'one .corrupt file'
        Assert-Equal ([IO.File]::ReadAllText($bad[0].FullName)) $garbage 'bad content preserved'
        [void](New-Kho -Name 'Sau khi hỏng')
        Assert-True ([IO.File]::Exists($khoFile)) 'saving works again'
    }
}

Test-Case 'invalid / duplicate libraries are dropped, default stays first, bad target falls back' {
    Reset-Kho
    Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json*' | Remove-Item -Force
    $json = @'
{"version":1,"downloadTarget":"c-doesnotexist","libraries":[
 {"id":"c-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Một","lowStock":"7","hashtags":["#a"," ",null]},
 {"id":"c-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Trùng"},
 {"id":"bad id","name":"Sai"},
 {"id":"default","name":"Tên khác","caption":"mẫu"},
 {"id":"acct:anna","name":""},
 null]}
'@
    [IO.File]::WriteAllText($khoFile, $json, [Text.UTF8Encoding]::new($false))
    $reg = Get-KhoRegistry
    $ids = @($reg.libraries | ForEach-Object { $_.id })
    Assert-Equal ($ids -join ',') 'default,c-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,acct:anna'
    Assert-Equal $reg.libraries[0].name 'Kho chung' 'default name is fixed'
    Assert-Equal $reg.libraries[0].caption 'mẫu' 'default keeps its caption'
    Assert-Equal $reg.libraries[1].lowStock 7
    Assert-Equal @($reg.libraries[1].hashtags).Count 1
    Assert-Equal $reg.libraries[2].name '@anna'
    Assert-Equal $reg.libraries[2].account 'anna'
    Assert-Equal $reg.downloadTarget 'default'
}

Test-Case 'locked kho.json: default only, not ready, never written, mutations refused, file byte-identical afterwards' {
    Reset-Kho
    Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json*' | Remove-Item -Force
    $keep = New-Kho -Name 'Giữ lại'
    $before = Get-FileHashText $khoFile
    $lock = [IO.File]::Open($khoFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        Reset-Kho
        $reg = Get-KhoRegistry
        Assert-Equal @($reg.libraries).Count 1 'default only while locked'
        Assert-True (-not $script:khoRegistryReady) 'ready must be false'
        Assert-True (-not (Save-KhoRegistry)) 'Save-KhoRegistry must refuse'
        Assert-Throws { New-Kho -Name 'Không được ghi' } '*không lưu thay đổi kho*'
        Assert-Throws { Rename-Kho -Id $keep.id -Name 'X' } '*không lưu thay đổi kho*'
        Assert-Throws { Remove-Kho -Id $keep.id -OutDir $outDir } '*không lưu thay đổi kho*'
        Set-KhoDownloadTarget -Id 'default'   # session only, must not throw or write
        $list = Get-KhoList -Metadata ([pscustomobject]@{ '1' = [pscustomobject]@{ Posted = $false; Date = ''; Kho = 'acct:zed' } })
        Assert-True (@($list | Where-Object { $_.id -eq 'acct:zed' }).Count -eq 1) 'virtual account kho listed'
    } finally { $lock.Dispose() }
    Assert-Equal (Get-FileHashText $khoFile) $before 'file must be untouched'
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*kho.json*' }).Count -ge 1) 'a log line explains it'
    Reset-Kho
    Assert-Equal @((Get-KhoRegistry).libraries).Count 2 'after unlock the real file is read'
}

Test-Case 'account khos referenced by videos are created once; Get-KhoList without metadata stays cheap' {
    Reset-Kho
    Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json*' | Remove-Item -Force
    $meta = [pscustomobject]@{
        '1' = [pscustomobject]@{ Posted = $true; Date = ''; Kho = 'acct:anna' }
        '2' = [pscustomobject]@{ Posted = $false; Date = ''; Kho = 'acct:bob' }
        '3' = [pscustomobject]@{ Posted = $false; Date = '' }
        '4' = [pscustomobject]@{ Posted = $false; Date = ''; Kho = 'acct:anna' }
    }
    $list = @(Get-KhoList -Metadata $meta)
    Assert-Equal ($list.id -join ',') 'default,acct:anna,acct:bob'
    Assert-Equal $list[1].name '@anna'
    $stamp = Get-FileHashText $khoFile
    [void](Get-KhoList -Metadata $meta)
    Assert-Equal (Get-FileHashText $khoFile) $stamp 'second call does not rewrite'
    Reset-Kho
    Assert-Equal @((Get-KhoRegistry).libraries).Count 3 'persisted'
}

Test-Case 'New-KhoForAccount: lower-case deterministic id, @ stripped, idempotent' {
    Reset-Kho
    Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json*' | Remove-Item -Force
    $a = New-KhoForAccount -Username '@TikTok_Anna'
    Assert-Equal $a.id 'acct:tiktok_anna'
    Assert-Equal $a.account 'tiktok_anna'
    $b = New-KhoForAccount -Username 'tiktok_ANNA'
    Assert-Equal $b.id $a.id
    Assert-Equal @((Get-KhoRegistry).libraries).Count 2
    Assert-Throws { New-KhoForAccount -Username '  ' } '*không hợp lệ*'
}

Test-Case 'download target: persisted, falls back to default when its kho is deleted, unknown refused' {
    Reset-Kho
    Get-ChildItem -LiteralPath (Split-Path $khoFile) -Filter 'kho.json*' | Remove-Item -Force
    $k = New-Kho -Name 'Đích tải'
    Assert-Equal (Get-KhoDownloadTarget) 'default'
    Set-KhoDownloadTarget -Id $k.id
    Reset-Kho
    Assert-Equal (Get-KhoDownloadTarget) $k.id 'survives restart'
    Assert-Throws { Set-KhoDownloadTarget -Id 'c-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' } '*Không tìm thấy*'
    [void](Remove-Kho -Id $k.id -OutDir $outDir)
    Assert-Equal (Get-KhoDownloadTarget) 'default'
    Reset-Kho
    Assert-Equal (Get-KhoDownloadTarget) 'default' 'persisted as default after delete'
}

Remove-Item -LiteralPath $tmp -Recurse -Force
Complete-Tests
