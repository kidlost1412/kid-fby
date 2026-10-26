# Folder rules of a kho: same volume, no nesting, no duplicates, not a drive root, last kho cannot be deleted, createdByApp, default folder name.
. (Join-Path $PSScriptRoot '_load.ps1')
$w = New-TestWorld @('B')
$tempDrive = [IO.Path]::GetPathRoot($script:root)                       # e.g. C:\
$otherDrive = $(if ($tempDrive -like 'C:*') { 'D:\' } else { 'C:\' })     # a different volume letter (the path need not exist for the rule)
function Why { param([string]$Path, [string]$ExceptId = '') return (Test-KhoPathAllowed (Get-KhoRegistry) $Path $ExceptId) }

Test-Case 'a fresh sibling folder on the same volume is allowed' {
    Assert-Equal (Why (Join-Path $script:root 'kho-new')) ''
}
Test-Case 'another volume is refused with the same-volume message (instant rename, no copy)' {
    $why = Why ($otherDrive + 'Kho video')
    Assert-True ($why -like '*cùng một ổ đĩa*') "got '$why'"
    Assert-True ($why -like "*$tempDrive*") 'names the volume of the first kho'
}
Test-Case 'a drive root, a relative path and an empty path are refused' {
    Assert-True ((Why $tempDrive) -like '*gốc ổ đĩa*') 'drive root'
    Assert-True ((Why 'kho\relative') -like '*thư mục đầy đủ*') 'relative'
    Assert-True ((Why '') -like '*thư mục đầy đủ*') 'empty'
    Assert-True ((Why '   ') -like '*thư mục đầy đủ*') 'blank'
}
Test-Case 'the same folder is refused whatever the case, slash direction or trailing separator' {
    foreach ($variant in @($w.B.path, $w.B.path.ToUpperInvariant(), ($w.B.path + '\'), ($w.B.path.Replace('\', '/')), ($w.B.path + '\.'), (Join-Path $w.B.path '..\kho-B'))) {
        Assert-True ((Why $variant) -like "*đã là kho 'B'*") "variant '$variant' -> '$(Why $variant)'"
    }
}
Test-Case 'a folder inside another kho is refused; a folder that contains a kho is refused' {
    Assert-True ((Why (Join-Path $w.B.path 'child')) -like "*nằm trong kho 'B'*") 'inside'
    Assert-True ((Why (Join-Path $w.B.path '.cache')) -like "*nằm trong kho 'B'*") 'inside .cache'
    Assert-True ((Why $script:root) -like '*chứa kho*') 'parent contains both khos'
}
Test-Case 'a sibling whose name only starts with the same text is NOT nested (prefix is not a path prefix)' {
    Assert-Equal (Why ($w.B.path + ' 2')) '' 'kho-B 2 next to kho-B'
    Assert-Equal (Why ($w.B.path + 'x')) ''
}
Test-Case 'ExceptId lets a kho keep its own folder' {
    Assert-Equal (Why $w.B.path $w.B.id) ''
}
Test-Case 'Vietnamese + spaces + brackets in a folder name work end to end (folder made with the literal name)' {
    $name = 'Kho [mới] ưu tiên #1'
    $path = Join-Path $script:root $name
    $k = New-Kho -Name 'VN' -Path $path
    Assert-True ([IO.Directory]::Exists($path)) 'folder exists under the literal name'
    Assert-Equal $k.path $path; Assert-Equal (Get-KhoByPath $path).id $k.id
    $script:khoRegistry = $null
    Assert-Equal (Get-KhoById $k.id).path $path 'survives a reload (UTF-8 registry)'
}
Test-Case 'New-Kho refused by a rule changes nothing: registry file identical, no folder, no journal' {
    $hash = (Get-FileHash -LiteralPath (Get-KhoPath)).Hash
    $before = @(Get-KhoList).Count
    foreach ($bad in @(($otherDrive + 'Kho x'), (Join-Path $w.B.path 'in'), $script:root, $w.A.path)) {
        Assert-Throws { [void](New-Kho -Name 'Nope' -Path $bad) } '*'
    }
    Assert-Equal @(Get-KhoList).Count $before; Assert-Equal (Get-FileHash -LiteralPath (Get-KhoPath)).Hash $hash
    Assert-True (-not [IO.Directory]::Exists((Join-Path $w.B.path 'in'))) 'no nested folder created'
}
Test-Case 'createdByApp: true for a folder this call made, false for a folder that already existed' {
    $fresh = New-Kho -Name 'Fresh' -Path (Join-Path $script:root 'kho-fresh')
    Assert-Equal $fresh.createdByApp $true
    $pre = Join-Path $script:root 'kho-existing'; [void][IO.Directory]::CreateDirectory($pre)
    $e = New-Kho -Name 'Existing' -Path $pre
    Assert-Equal $e.createdByApp $false
    $script:khoRegistry = $null
    Assert-Equal (Get-KhoById $fresh.id).createdByApp $true 'persisted'
    Assert-Equal (Get-KhoById $e.id).createdByApp $false
}
Test-Case 'default folder = <parent of the download kho>\Kho <name>; illegal file-name characters become _; empty name -> moi' {
    Assert-Equal (Get-KhoDefaultFolder 'Anna') (Join-Path $script:root 'Kho Anna')
    Assert-Equal (Get-KhoDefaultFolder 'a:b*c?"d<e>f|g') (Join-Path $script:root 'Kho a_b_c__d_e_f_g')
    Assert-Equal (Get-KhoDefaultFolder '...') (Join-Path $script:root 'Kho moi')
    $k = New-Kho -Name 'Auto folder'
    Assert-Equal $k.path (Join-Path $script:root 'Kho Auto folder'); Assert-True ([IO.Directory]::Exists($k.path)) 'folder created'
}
Test-Case 'the default folder follows the download target (its parent decides)' {
    $deep = Join-Path $script:root 'sub\kho-deep'
    $d = New-Kho -Name 'Deep' -Path $deep
    Set-KhoDownloadTarget $d.id
    Assert-Equal (Get-KhoDefaultFolder 'Z') (Join-Path $script:root 'sub\Kho Z')
    Set-KhoDownloadTarget $w.A.id
}
Test-Case 'the last kho cannot be deleted; the registry and its folder are untouched' {
    $one = New-TestWorld @()
    $hash = (Get-FileHash -LiteralPath (Get-KhoPath)).Hash
    Assert-Equal @(Get-KhoList).Count 1
    Assert-Throws { [void](Remove-KhoWithVideos -Id $one.A.id) } '*kho cuối cùng*'
    Assert-Equal @(Get-KhoList).Count 1; Assert-Equal (Get-FileHash -LiteralPath (Get-KhoPath)).Hash $hash
}
Test-Case 'deleting an unknown kho id is refused' {
    $x = New-TestWorld @('B')
    Assert-Throws { [void](Remove-KhoWithVideos -Id 'k-ffffffffffffffffffffffffffffffff') } '*Không tìm thấy kho*'
}

Complete-Tests
