# D13 "Hen lai": Get-TikTokRescheduleSeed (newest entry = rejected native schedule -> same account + receipt caption) and the gallery card flag.
. (Join-Path $PSScriptRoot '_load.ps1')
function Hx { param([string]$Req, [string]$Status, [string]$Mode, [string]$Created, [string]$User = 'anna') $h = New-TestHistoryEntry -Request $Req -User $User -Status $Status -Created $Created; $h.schedule_mode = $Mode; return $h }
Test-Case 'newest entry failed + native -> seed with account and the receipt caption (Vietnamese)' {
    $w = New-TestWorld @(); $id = NextId; [void](New-TestVideo $w.A.path $id)
    $req = '{0:x32}' -f 501
    $rec = [pscustomobject]@{ RequestId = $req; VideoId = $id; Caption = 'Chào cả nhà #bé' }
    [IO.File]::WriteAllText((Join-Path $w.A.path ".cache\tiktok-posts\$req.json"), (ConvertTo-Json $rec), [Text.UTF8Encoding]::new($false))
    $s = Get-TikTokRescheduleSeed -History @((Hx ('{0:x32}' -f 500) 'succeeded' 'now' '2026-10-20T10:00:00Z'), (Hx $req 'failed' 'native' '2026-10-25T10:00:00Z')) -OutDir $w.A.path
    Assert-Equal $s.Account 'anna'; Assert-Equal $s.Caption 'Chào cả nhà #bé'; Assert-Equal $s.RequestId $req
}
Test-Case 'not offered: failed but NOT native, native but succeeded, or an older failure followed by a newer success' {
    $w = New-TestWorld @()
    Assert-True ($null -eq (Get-TikTokRescheduleSeed -History @((Hx ('{0:x32}' -f 1) 'failed' 'now' '2026-10-25T10:00:00Z')) -OutDir $w.A.path)) 'now-mode'
    Assert-True ($null -eq (Get-TikTokRescheduleSeed -History @((Hx ('{0:x32}' -f 2) 'succeeded' 'native' '2026-10-25T10:00:00Z')) -OutDir $w.A.path)) 'succeeded'
    Assert-True ($null -eq (Get-TikTokRescheduleSeed -History @((Hx ('{0:x32}' -f 3) 'failed' 'native' '2026-10-20T10:00:00Z'), (Hx ('{0:x32}' -f 4) 'succeeded' 'native' '2026-10-25T10:00:00Z')) -OutDir $w.A.path)) 'older failure'
    Assert-True ($null -eq (Get-TikTokRescheduleSeed -History @() -OutDir $w.A.path)) 'empty'
}
Test-Case 'no receipt / no caption kept -> seed with empty caption (dialog falls back to the kho template)' {
    $w = New-TestWorld @()
    $s = Get-TikTokRescheduleSeed -History @((Hx ('{0:x32}' -f 9) 'failed' 'native' '2026-10-25T10:00:00Z' 'Bob')) -OutDir $w.A.path
    Assert-Equal $s.Account 'Bob'; Assert-Equal $s.Caption ''
}
Test-Case 'gallery card of such a video carries Reschedule; a normal one does not' {
    $w = New-TestWorld @(); $a = NextId; $b = NextId
    $meta = [pscustomobject]@{}
    $meta | Add-Member -NotePropertyName $a -NotePropertyValue ([pscustomobject]@{ Posted = $false; Date = ''; History = @((Hx ('{0:x32}' -f 11) 'failed' 'native' '2026-10-25T10:00:00Z')) })
    $meta | Add-Member -NotePropertyName $b -NotePropertyValue ([pscustomobject]@{ Posted = $true; Date = ''; History = @((Hx ('{0:x32}' -f 12) 'succeeded' 'native' '2026-10-25T10:00:00Z')) })
    foreach ($id in $a, $b) { [void](New-TestVideo $w.A.path $id) }
    $script:khoByPath = @{}
    function Mk($id) { $fi = Get-Item -LiteralPath (Join-Path $w.A.path "$id-3-hoan-chinh.mp4"); return [pscustomobject]@{ FullName = $fi.FullName; Name = $fi.Name; Length = $fi.Length; LastWriteTime = $fi.LastWriteTime; Stamp = 's'; Root = $w.A.path } }
    Assert-Equal (New-GalleryItem (Mk $a) $meta $null).Reschedule.Account 'anna'
    Assert-True ($null -eq (New-GalleryItem (Mk $b) $meta $null).Reschedule) 'normal card'
}
Complete-Tests
