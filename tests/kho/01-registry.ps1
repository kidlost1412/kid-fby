# Registry v2 (data\kho.json): first start / v1 migration / corrupt / locked, round trip, validation, account helpers.
. (Join-Path $PSScriptRoot '_load.ps1')
$vi = { param([int[]]$codes) -join ($codes | ForEach-Object { [char]$_ }) }
$outCu = & $vi 0x4F, 0x75, 0x74, 0x70, 0x75, 0x74, 0x20, 0x63, 0x0169   # "Output c" + u-tilde ("Output cũ")

function Reset-Registry {
    # Fresh temp root with a kho.json of the given text (or none), registry not loaded yet.
    param($JsonText = $null, [string]$LegacyOut = '')
    $script:root = New-TestDir
    [void][IO.Directory]::CreateDirectory((Join-Path $script:root 'data'))
    $script:khoRegistry = $null; $script:khoRegistryReady = $true; $script:khoLegacyOutDir = $LegacyOut
    $script:TestLog.Clear()
    if ($null -ne $JsonText) { [IO.File]::WriteAllText((Get-KhoPath), $JsonText, [Text.UTF8Encoding]::new($false)) }
}
function Asides { param([string]$Kind) return @(Get-ChildItem -LiteralPath (Join-Path $script:root 'data') -Filter "kho.json.$Kind-*") }
$g1 = 'k-11111111111111111111111111111111'; $g2 = 'k-22222222222222222222222222222222'; $g3 = 'k-33333333333333333333333333333333'

# ---------------- first start / migration ----------------
Test-Case 'no kho.json: one kho "Output cu" = the saved outDir, download target = it, file written, nothing moved' {
    $legacy = Join-Path (New-TestDir) 'Xuất cũ [1]'
    Reset-Registry -LegacyOut $legacy
    $reg = Get-KhoRegistry
    Assert-Equal @($reg.libraries).Count 1; Assert-Equal $reg.version 2
    $lib = $reg.libraries[0]
    Assert-Equal $lib.name $outCu; Assert-Equal $lib.path $legacy; Assert-Equal $lib.account ''; Assert-Equal $lib.createdByApp $false
    Assert-True ($lib.id -cmatch '^k-[0-9a-f]{32}$') "id $($lib.id)"
    Assert-Equal $reg.downloadTarget $lib.id; Assert-True $script:khoRegistryReady 'ready'
    Assert-True ([IO.File]::Exists((Get-KhoPath))) 'kho.json written at once'
    Assert-True ([string]$reg.autoMoveSince -ne '') 'autoMoveSince set (only future posts auto-move)'
    Assert-True (-not [IO.Directory]::Exists($legacy)) 'registering does not create the folder'
    Assert-Equal @(Asides 'corrupt').Count 0 'a missing file is not a corrupt file'
}
Test-Case 'no kho.json and no saved outDir: the folder is <root>\output' {
    Reset-Registry -LegacyOut ''
    Assert-Equal (Get-KhoRegistry).libraries[0].path (Join-Path $script:root 'output')
}
Test-Case 'saved outDir that is not an absolute path is not trusted: falls back to <root>\output and logs' {
    Reset-Registry -LegacyOut 'output-relative'
    Assert-Equal (Get-KhoRegistry).libraries[0].path (Join-Path $script:root 'output')
    Assert-True (@($script:TestLog | Where-Object { $_ -like '*không phải đường dẫn đầy đủ*' }).Count -ge 1) 'logged'
}
Test-Case 'v1 (logical kho) file is renamed .v1-<ts> byte-identical and replaced by v2 with "Output cu"' {
    $v1 = '{"version":1,"libraries":[{"id":"c-0123456789abcdef0123456789abcdef","name":"Kho cu","caption":"x","hashtags":["#a"]}],"autoMoveSince":""}'
    Reset-Registry -JsonText $v1 -LegacyOut (Join-Path (New-TestDir) 'out')
    $reg = Get-KhoRegistry
    Assert-Equal @($reg.libraries).Count 1; Assert-Equal $reg.libraries[0].name $outCu
    $aside = @(Asides 'v1'); Assert-Equal $aside.Count 1
    Assert-Equal ([IO.File]::ReadAllText($aside[0].FullName)) $v1 'v1 content preserved'
    $disk = Read-TestJson (Get-KhoPath); Assert-Equal $disk.version 2; Assert-Equal @($disk.libraries).Count 1
}
Test-Case 'corrupt kho.json is renamed .corrupt-<ts>, a fresh registry is written, and a reload reads it back' {
    Reset-Registry -JsonText '{"libraries": [ {broken' -LegacyOut (Join-Path (New-TestDir) 'out')
    $reg = Get-KhoRegistry
    Assert-Equal @($reg.libraries).Count 1; Assert-True $script:khoRegistryReady 'ready'
    Assert-Equal @(Asides 'corrupt').Count 1
    $first = $reg.libraries[0].id
    $script:khoRegistry = $null
    Assert-Equal (Get-KhoRegistry).libraries[0].id $first 'second load reads the fresh file'
}
Test-Case 'non-object JSON (array / empty / text) counts as corrupt, never as a registry' {
    foreach ($bad in '[]', '', 'hello') {
        Reset-Registry -JsonText $bad -LegacyOut (Join-Path (New-TestDir) 'out')
        Assert-Equal @((Get-KhoRegistry).libraries).Count 1 "text '$bad'"
        Assert-Equal @(Asides 'corrupt').Count 1 "aside for '$bad'"
    }
}
Test-Case 'locked kho.json: in-memory default, NOT ready, file never overwritten or renamed, every change refused, target change is session-only' {
    $legacy = Join-Path (New-TestDir) 'out'
    Reset-Registry -LegacyOut $legacy
    [void](Get-KhoRegistry)
    [void](New-Kho -Name 'B' -Path (Join-Path $script:root 'kho-B'))
    $path = Get-KhoPath; $hash = (Get-FileHash -LiteralPath $path).Hash
    $script:khoRegistry = $null
    $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
    try {
        $reg = Get-KhoRegistry
        Assert-True (-not $script:khoRegistryReady) 'not ready'
        Assert-Equal @($reg.libraries).Count 1 'in-memory default only'
        Assert-Throws { [void](New-Kho -Name 'C' -Path (Join-Path $script:root 'kho-C')) } '*Không đọc được data\kho.json*'
        Assert-Throws { Rename-Kho -Id $reg.libraries[0].id -Name 'Z' } '*Không đọc được data\kho.json*'
        Assert-Throws { Set-KhoOptions -Id $reg.libraries[0].id -Caption 'x' } '*Không đọc được data\kho.json*'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $script:root 'kho-C'))) 'no folder created by a refused New-Kho'
        Set-KhoDownloadTarget $reg.libraries[0].id      # allowed for the session, must not throw or write
    } finally { $fs.Dispose() }
    Assert-Equal (Get-FileHash -LiteralPath $path).Hash $hash 'file byte-identical'
    Assert-Equal (@(Get-ChildItem -LiteralPath (Join-Path $script:root "data") -Filter "kho.json.*" | Where-Object Name -ne "kho.json" | ForEach-Object Name) -join ",") "" "nothing renamed aside"
}

# ---------------- round trip / validation ----------------
Test-Case 'create / rename / options / slots / account persist across a reload (Vietnamese, one hashtag stays an array, slots sorted + unique)' {
    $w = New-TestWorld @('B')
    $b = $w.B
    $ten = & $vi 0x4B, 0x68, 0x6F, 0x20, 0x6D, 0x1EDB, 0x69   # "Kho moi" with horn-o + acute
    Rename-Kho -Id $b.id -Name $ten
    Set-KhoAccount -Id $b.id -Account '@Anna'
    Set-KhoOptions -Id $b.id -Caption ($ten + ' cap') -Hashtags @('#one') -LowStock 5 -Slots @('19:00', '08:00', '19:00', '12:30')
    $script:khoRegistry = $null
    $r = Get-KhoById $b.id
    Assert-Equal $r.name $ten; Assert-Equal $r.account 'Anna'; Assert-Equal $r.caption ($ten + ' cap'); Assert-Equal $r.lowStock 5
    Assert-Equal (@($r.hashtags) -join ',') '#one'; Assert-Equal (@($r.slots) -join ',') '08:00,12:30,19:00'
    Assert-True ((Read-TestJson (Get-KhoPath)).libraries[1].hashtags -is [array]) 'single hashtag stored as an array'
}
Test-Case 'invalid libraries are dropped: bad id, relative path, duplicate id, duplicate folder (case + slash), 2nd kho of an account loses the account; bad target falls back to the first' {
    $p = Join-Path (New-TestDir) 'k'
    $json = ConvertTo-Json -Depth 6 @{ version = 2; downloadTarget = 'k-ffffffffffffffffffffffffffffffff'; libraries = @(
        @{ id = $g1; name = 'One'; path = $p + '1'; account = '@Anna' },
        @{ id = 'c-0123456789abcdef0123456789abcdef'; name = 'badid'; path = $p + '2' },
        @{ id = $g2; name = 'rel'; path = 'relative\path' },
        @{ id = $g1; name = 'dupid'; path = $p + '3' },
        @{ id = $g3; name = 'dupfolder'; path = ($p + '1').ToUpperInvariant() + '\' },
        @{ id = 'k-44444444444444444444444444444444'; name = 'Two'; path = $p + '4'; account = 'anna' },
        @{ id = 'k-55555555555555555555555555555555'; name = ''; path = $p + '5' } ) }
    Reset-Registry -JsonText $json
    $reg = Get-KhoRegistry
    Assert-Equal (@($reg.libraries | ForEach-Object { $_.name }) -join ',') 'One,Two,k5'
    Assert-Equal $reg.libraries[0].account 'Anna'; Assert-Equal $reg.libraries[1].account '' 'second claimant loses the account'
    Assert-Equal $reg.downloadTarget $g1 'fallback to the first kho'
    Assert-Equal (Get-KhoDownloadTarget) $g1
}
Test-Case 'a v2 file with zero valid libraries is renamed .invalid-<ts> and replaced (never an empty registry)' {
    Reset-Registry -JsonText '{"version":2,"libraries":[{"id":"nope","path":"x"}]}' -LegacyOut (Join-Path (New-TestDir) 'out')
    Assert-Equal @((Get-KhoRegistry).libraries).Count 1
    Assert-Equal @(Asides 'invalid').Count 1
}
Test-Case 'lowStock outside 0..999 and invalid slots in the file are normalised, not trusted' {
    $json = ConvertTo-Json -Depth 6 @{ version = 2; libraries = @(@{ id = $g1; name = 'One'; path = (Join-Path (New-TestDir) 'k'); lowStock = 5000; slots = @('25:00', '9:5', '08:00', '08:00', $null) }) }
    Reset-Registry -JsonText $json
    $l = (Get-KhoRegistry).libraries[0]
    Assert-Equal $l.lowStock 3 'default threshold'; Assert-Equal (@($l.slots) -join ',') '08:00'
}
Test-Case 'name rules: empty, > 60 chars, duplicate (case-insensitive) are refused and leave kho.json byte-identical' {
    $w = New-TestWorld @('B')
    $hash = (Get-FileHash -LiteralPath (Get-KhoPath)).Hash
    Assert-Throws { Rename-Kho -Id $w.B.id -Name '   ' } '*không được để trống*'
    Assert-Throws { Rename-Kho -Id $w.B.id -Name ('x' * 61) } '*tối đa 60*'
    Assert-Throws { Rename-Kho -Id $w.B.id -Name $outCu.ToUpperInvariant() } '*Đã có kho tên*'
    Assert-Throws { [void](New-Kho -Name 'b' -Path (Join-Path $script:root 'kho-b2')) } '*Đã có kho tên*'
    Assert-Throws { Rename-Kho -Id 'k-ffffffffffffffffffffffffffffffff' -Name 'X' } '*Không tìm thấy kho*'
    Assert-Equal (Get-FileHash -LiteralPath (Get-KhoPath)).Hash $hash 'file untouched by failures'
    Rename-Kho -Id $w.B.id -Name 'B'     # renaming to its own current name is fine
    Assert-True (-not [IO.Directory]::Exists((Join-Path $script:root 'kho-b2'))) 'no folder from the refused create'
}
Test-Case 'download target: persisted across a reload; unknown id refused; Get-KhoDownloadPath follows it' {
    $w = New-TestWorld @('B')
    Assert-Equal (Get-KhoDownloadTarget) $w.A.id 'first kho is the default target'
    Set-KhoDownloadTarget $w.B.id
    $script:khoRegistry = $null
    Assert-Equal (Get-KhoDownloadTarget) $w.B.id; Assert-Equal (Get-KhoDownloadPath) $w.B.path
    Assert-Throws { Set-KhoDownloadTarget 'k-ffffffffffffffffffffffffffffffff' } '*Không tìm thấy kho*'
    Assert-Equal (Get-KhoDownloadTarget) $w.B.id 'unchanged by the refusal'
}
Test-Case 'a failed save keeps the in-memory registry unchanged (the change is applied to a copy first)' {
    $w = New-TestWorld @('B')
    # lock kho.json AFTER it was loaded: Write-KidSettings cannot swap the file, so the save throws
    $fs = [IO.File]::Open((Get-KhoPath), 'Open', 'Read', 'None')
    try { Assert-Throws { Rename-Kho -Id $w.B.id -Name 'Renamed' } '*' } finally { $fs.Dispose() }
    Assert-Equal (Get-KhoById $w.B.id).name 'B' 'in-memory name unchanged'
    Assert-Equal (Read-TestJson (Get-KhoPath)).libraries[1].name 'B' 'disk unchanged'
}

# ---------------- accounts ----------------
Test-Case 'New-KhoForAccount: creates "<parent of the download kho>\Kho @user" named @user (createdByApp), idempotent, case/@-insensitive' {
    $w = New-TestWorld @('B')
    $k = New-KhoForAccount '@Bob'
    Assert-Equal $k.name '@Bob'; Assert-Equal $k.account 'Bob'; Assert-Equal $k.createdByApp $true
    Assert-Equal $k.path (Join-Path $script:root 'Kho @Bob'); Assert-True ([IO.Directory]::Exists($k.path)) 'folder made'
    Assert-Equal (New-KhoForAccount 'bob').id $k.id 'second call returns the same kho'
    Assert-Equal @((Get-KhoList)).Count 3
    Assert-Equal (Get-KhoForAccount ' @BOB ').id $k.id
    Assert-True ($null -eq (Get-KhoForAccount 'two words')) 'invalid username -> none'
    Assert-Throws { [void](New-KhoForAccount '') } '*không hợp lệ*'
}
Test-Case 'New-KhoForAccount: the name @user is taken -> "@user (TikTok)"' {
    $w = New-TestWorld @('B')
    Rename-Kho -Id $w.B.id -Name '@carl'
    $k = New-KhoForAccount 'carl'
    Assert-Equal $k.name '@carl (TikTok)'; Assert-Equal $k.account 'carl'
}
Test-Case 'one kho per account: New-Kho / Set-KhoAccount refuse a second claimant; clearing frees it; invalid names refused' {
    $w = New-TestWorld @('B', 'C')
    Set-KhoAccount -Id $w.B.id -Account 'Anna'
    Assert-Throws { Set-KhoAccount -Id $w.C.id -Account '@ANNA' } '*đã có kho*'
    Assert-Throws { [void](New-Kho -Name 'D' -Path (Join-Path $script:root 'kho-D') -Account 'anna') } '*đã có kho*'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $script:root 'kho-D'))) 'refused create made no folder'
    Assert-Throws { Set-KhoAccount -Id $w.C.id -Account 'two words' } '*không hợp lệ*'
    Set-KhoAccount -Id $w.B.id -Account ''
    Set-KhoAccount -Id $w.C.id -Account 'anna'
    Assert-Equal (Get-KhoForAccount 'anna').id $w.C.id
}
Test-Case 'Set-KhoOptions: bad slot text and out-of-range threshold are refused without changing anything; only given parameters change' {
    $w = New-TestWorld @('B')
    Set-KhoOptions -Id $w.B.id -Caption 'cap' -Slots @('08:00')
    Assert-Throws { Set-KhoOptions -Id $w.B.id -Slots @('25:61') } '*Giờ đăng không hợp lệ*'
    Assert-Throws { Set-KhoOptions -Id $w.B.id -LowStock 1000 } '*từ 0 đến 999*'
    $l = Get-KhoById $w.B.id
    Assert-Equal $l.caption 'cap'; Assert-Equal (@($l.slots) -join ',') '08:00'
    Set-KhoOptions -Id $w.B.id -LowStock 0
    Assert-Equal (Get-KhoById $w.B.id).caption 'cap' 'caption untouched by a LowStock-only change'
}
Test-Case 'Get-KhoByPath / Get-KhoRoots: canonical + case-insensitive; unknown folder -> null' {
    $w = New-TestWorld @('B')
    Assert-Equal (Get-KhoByPath ($w.B.path.ToUpperInvariant() + '\')).id $w.B.id
    Assert-True ($null -eq (Get-KhoByPath (Join-Path $script:root 'nope')))
    Assert-True ($null -eq (Get-KhoByPath ''))
    Assert-Equal (@(Get-KhoRoots) -join '|') ($w.A.path + '|' + $w.B.path)
}

Complete-Tests
