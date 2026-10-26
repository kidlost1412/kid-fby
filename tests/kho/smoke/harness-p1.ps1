# WPF smoke harness for the physical kho (dot-sourced into a TEMP COPY of kid-fby-gui.ps1 right before ShowDialog). Temp data only.
# Phase main: Kho page lists 2 khos, manager dialog (create / rename / caption), download combo, multi-select move, card-menu move,
# delete a video (Recycle Bin), delete a kho. Phase recovery: the app starts with a fabricated mid-phase journal.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$global:H = @{ Step = 0; Log = New-Object System.Collections.Generic.List[string]; Wait = 0; Data = @{}; Fail = 0 }
$script:HOut = $env:KHO_HARNESS_OUT
$script:HShots = $env:KHO_SHOTS
$script:HPhase = $env:KHO_PHASE
$script:HDir = $env:KHO_SMOKE_DIR     # folder with khoA / khoB
function HLog { param([string]$m) $global:H.Log.Add(('[{0:HH:mm:ss.fff}] {1}' -f (Get-Date), $m)); [IO.File]::WriteAllText($script:HOut, ($global:H.Log -join "`r`n"), $utf8) }
function HShot {
    param([string]$Name, $Visual = $win)
    try {
        $w = [int]$Visual.ActualWidth; $hgt = [int]$Visual.ActualHeight
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $hgt, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($Visual)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        New-Item -ItemType Directory -Force -Path $script:HShots | Out-Null
        $fs = [IO.File]::Create((Join-Path $script:HShots "$Name.png")); try { $enc.Save($fs) } finally { $fs.Dispose() }
        HLog "shot $Name ${w}x$hgt"
    } catch { HLog "SHOT FAIL $Name $($_.Exception.Message)" }
}
function Expect { param($Name, $Actual, $Expected) $ok = ([string]$Actual -ceq [string]$Expected); if (-not $ok) { $global:H.Fail++ }; HLog ('{0} {1}: actual={2} expected={3}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Name, $Actual, $Expected) }
function Pump { $f = New-Object Windows.Threading.DispatcherFrame; [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{ $f.Continue = $false }); [Windows.Threading.Dispatcher]::PushFrame($f) }
function Click-Item { param($Mi) $peer = [Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Mi); $peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Invoke).Invoke(); Pump; Pump }
function Click-Btn { param($B) $B.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); Pump; Pump }
function Find-Visual { param($Root, [scriptblock]$Pred)
    $q = New-Object System.Collections.Generic.Queue[object]; $q.Enqueue($Root)
    while ($q.Count) { $n = $q.Dequeue(); if (& $Pred $n) { return $n }
        if ($n -is [Windows.Media.Visual]) { for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($n); $i++) { $q.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($n, $i)) } } }
    return $null
}
function MenuText { param($Menu) (($Menu.Items | ForEach-Object { if ($_ -is [Windows.Controls.MenuItem]) { '{0}:{1}' -f $_.Header, $_.IsEnabled } else { '---' } }) -join ' ; ') }
function MenuItemLike { param($Menu, [string]$Like) return @($Menu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] -and [string]$_.Header -like $Like })[0] }
function ToastText { (@($ui.NotificationHost.Children | ForEach-Object { [Windows.Automation.AutomationProperties]::GetName($_) }) -join ' || ') }
function KhoByName { param([string]$Name) return @((Get-KhoRegistry).libraries | Where-Object { $_.name -ceq $Name })[0] }
function F { param($Dir, [string]$Rel) return [IO.File]::Exists((Join-Path $Dir $Rel)) }
function InBin { param([string]$Like) $sh = New-Object -ComObject Shell.Application; return @($sh.NameSpace(10).Items() | Where-Object { $_.Name -like $Like }).Count }
function JournalCount { $d = Join-Path $root 'data\kho-moves'; if ([IO.Directory]::Exists($d)) { return @([IO.Directory]::GetFiles($d)).Count } else { return 0 } }
function RunDialog {
    # one-shot driver for the modal manager dialog: $Script runs after it rendered; it must not leave the dialog open
    param([string]$Kho, [scriptblock]$Script)
    $script:HTimer.Stop()
    $sb = $Script
    $dt = New-Object Windows.Threading.DispatcherTimer; $dt.Interval = [TimeSpan]::FromMilliseconds(900)
    $dt.Add_Tick({ $dt.Stop(); try { $d = @($win.OwnedWindows)[0]; & $sb $d; try { $d.Close() } catch { } } catch { $global:H.Fail++; HLog "DIALOG SCRIPT ERROR: $($_.Exception.Message) $($_.ScriptStackTrace)"; try { @($win.OwnedWindows)[0].Close() } catch { } } }.GetNewClosure())
    $dt.Start()
    Show-KhoManagerDialog -Kho $Kho
    $script:HTimer.Start()
}
function Select-DialogKho { param($d, [string]$Id) $rb = Find-Visual $d { param($n) $n -is [Windows.Controls.RadioButton] -and [string]$n.Tag -ceq $Id }; if (-not $rb) { throw "no chip for $Id" }; $rb.IsChecked = $true; Pump; Pump }

$script:HTimer = New-Object Windows.Threading.DispatcherTimer
$script:HTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:HTimer.Add_Tick({
    try {
        $h = $script:H
        if ($h.Wait -gt 0) { $h.Wait--; return }
        $A = Join-Path $script:HDir 'khoA'; $B = Join-Path $script:HDir 'khoB'
        if ($script:HPhase -eq 'recovery') {
            if ($h.Step -eq 0) { if (-not $script:galleryScanReady) { return }; Show-Page 'library'; $h.Wait = 4; $h.Step = 1; return }
            if ($h.Step -eq 1) {
                if ($script:galleryState -ne 'ready') { return }
                $id = '1000000000301'
                Expect 'recovery: -3 now in kho B' (F $B "$id-3-hoan-chinh.mp4") $true
                Expect 'recovery: -3 no longer in kho A' (F $A "$id-3-hoan-chinh.mp4") $false
                Expect 'recovery: companion -1 in B' (F $B ".cache\$id-1-video-goc.mp4") $true
                Expect 'recovery: companion -2 in B' (F $B ".cache\$id-2-am-thanh-tho.m4a") $true
                Expect 'recovery: receipt in B' (F $B ('.cache\tiktok-posts\{0:x32}.json' -f [long]$id)) $true
                $rec = Get-Content -LiteralPath (Join-Path $B ('.cache\tiktok-posts\{0:x32}.json' -f [long]$id)) -Raw -Encoding UTF8 | ConvertFrom-Json
                Expect 'recovery: receipt OutDir rewritten' $rec.OutDir $B
                Expect 'recovery: journal file gone' (JournalCount) 0
                $mb = Get-Content -LiteralPath (Join-Path $B 'reup-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $ma = Get-Content -LiteralPath (Join-Path $A 'reup-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                Expect 'recovery: entry in B metadata' ($null -ne $mb.PSObject.Properties[$id]) $true
                Expect 'recovery: entry removed from A metadata' ($null -eq $ma.PSObject.Properties[$id]) $true
                Expect 'recovery: gallery shows the video under kho B' ((@($script:galleryAll | Where-Object { $_.Id -eq $id })[0]).KhoName) 'Kho Beta'
                Expect 'recovery: 4 videos listed' @($script:galleryAll).Count 4
                HLog ('log tail: ' + ((Get-Content -LiteralPath (Join-Path $root 'logs\kho-moves.log') -ErrorAction SilentlyContinue) -join ' | '))
                HShot 'p1-recovery-library'
                HLog "RESULT fail=$($h.Fail)"
                $script:HTimer.Stop(); $win.Close()
            }
            return
        }
        switch ($h.Step) {
            0 {
                if (-not $script:galleryScanReady) { return }
                $win.Width = 1280; $win.Height = 780
                Show-Page 'library'
                $h.Step = 1
            }
            1 {
                if ($script:galleryState -ne 'ready' -or @($script:galleryAll).Count -ne 6) { return }
                $h.Wait = 6; $h.Step = 2
            }
            2 {
                $texts = @($ui.CmbKho.Items | ForEach-Object { [string]$_.Content })
                HLog ('kho combo: ' + ($texts -join ' | '))
                Expect 'kho filter combo entries (All + 2)' $texts.Count 3
                Expect 'kho 1 listed' (@($texts | Where-Object { $_ -like 'Kho Alpha*' }).Count) 1
                Expect 'kho 2 listed' (@($texts | Where-Object { $_ -like 'Kho Beta*' }).Count) 1
                Expect 'download combo has both khos' (@($ui.CmbDownloadKho.Items | ForEach-Object { [string]$_.Content }) -join ',') 'Kho Alpha,Kho Beta'
                Expect 'cards: 3 in Alpha' (@($script:galleryAll | Where-Object { $_.KhoName -eq 'Kho Alpha' }).Count) 3
                Expect 'cards: 3 in Beta' (@($script:galleryAll | Where-Object { $_.KhoName -eq 'Kho Beta' }).Count) 3
                HShot 'p1-01-library-two-khos'
                $h.Step = 3
            }
            3 {
                $alpha = KhoByName 'Kho Alpha'
                RunDialog $alpha.id {
                    param($d)
                    HShot 'p1-02-manager-dialog' $d
                    $d.FindName('AddBox').Text = 'Kho Gamma'
                    Click-Btn $d.FindName('BtnAdd')
                    $g = KhoByName 'Kho Gamma'
                    Expect 'dialog: kho created in registry' ($null -ne $g) $true
                    Expect 'dialog: kho folder created on disk' ([IO.Directory]::Exists([string]$g.path)) $true
                    Expect 'dialog: folder is next to the download kho' ([IO.Path]::GetDirectoryName([string]$g.path)) ([IO.Path]::GetDirectoryName((KhoByName 'Kho Alpha').path))
                    $global:H.Data.GammaId = [string]$g.id; $global:H.Data.GammaPath = [string]$g.path
                    Select-DialogKho $d $g.id
                    $d.FindName('NameBox').Text = 'Kho Delta'
                    Click-Btn $d.FindName('BtnRename')
                    Expect 'dialog: rename saved' ((Get-KhoById $g.id).name) 'Kho Delta'
                    $d.FindName('CaptionBox').Text = 'Xem ngay #vui'
                    Click-Btn $d.FindName('BtnSaveOpts')
                    Expect 'dialog: caption saved' ((Get-KhoById $g.id).caption) 'Xem ngay #vui'
                    Expect 'dialog: caption persisted in kho.json' ((Get-Content -LiteralPath (Join-Path $root 'data\kho.json') -Raw -Encoding UTF8 | ConvertFrom-Json).libraries | Where-Object { $_.id -eq $g.id } | ForEach-Object { $_.caption }) 'Xem ngay #vui'
                    HShot 'p1-03-manager-after-create' $d
                }
                $h.Wait = 3; $h.Step = 4
            }
            4 {
                if ($script:galleryState -ne 'ready') { return }
                Expect 'download combo lists the new kho' (@($ui.CmbDownloadKho.Items | ForEach-Object { [string]$_.Content }) -join ',') 'Kho Alpha,Kho Beta,Kho Delta'
                Expect 'filter combo lists the new kho' @($ui.CmbKho.Items).Count 4
                $ui.CmbKho.SelectedIndex = 0; Pump
                $alphaId = (KhoByName 'Kho Alpha').id
                $pick = @($script:galleryRows | Where-Object { $_.Kho -ceq $alphaId -and $_.Id -in @('1000000000101', '1000000000102') })
                Expect 'two Alpha videos found for the multi-select' $pick.Count 2
                foreach ($r in $pick) { [void]$ui.GalleryList.SelectedItems.Add($r) }
                $win.UpdateLayout(); Pump
                Expect 'selection bar visible' $ui.PanelSelBar.Visibility 'Visible'
                HShot 'p1-04-selection-bar'
                Click-Btn $ui.BtnMoveSelected
                $menu = $ui.BtnMoveSelected.ContextMenu
                Expect 'move menu open' $menu.IsOpen $true
                HLog ('move menu: ' + (MenuText $menu))
                Pump; HShot 'p1-05-move-menu' $menu
                Click-Item (MenuItemLike $menu 'Kho Beta*')
                $h.Step = 5
            }
            5 {
                if ($script:galleryState -ne 'ready') { return }
                foreach ($id in '1000000000101', '1000000000102') {
                    Expect "multi-move $id -3 in Beta" (F $B "$id-3-hoan-chinh.mp4") $true
                    Expect "multi-move $id -3 left Alpha" (F $A "$id-3-hoan-chinh.mp4") $false
                }
                Expect 'multi-move companion -1 moved' (F $B '.cache\1000000000101-1-video-goc.mp4') $true
                Expect 'multi-move companion left source' (F $A '.cache\1000000000101-1-video-goc.mp4') $false
                $mb = Get-Content -LiteralPath (Join-Path $B 'reup-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $ma = Get-Content -LiteralPath (Join-Path $A 'reup-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                Expect 'multi-move: reup-status entries now in Beta' (($null -ne $mb.PSObject.Properties['1000000000101']) -and ($null -ne $mb.PSObject.Properties['1000000000102'])) $true
                Expect 'multi-move: history kept' @($mb.'1000000000101'.History).Count 1
                Expect 'multi-move: entries removed from Alpha' (($null -eq $ma.PSObject.Properties['1000000000101']) -and ($null -eq $ma.PSObject.Properties['1000000000102'])) $true
                Expect 'multi-move: journal folder empty' (JournalCount) 0
                Expect 'gallery: 5 in Beta, 1 in Alpha' ((@($script:galleryAll | Where-Object { $_.KhoName -eq 'Kho Beta' }).Count).ToString() + ',' + (@($script:galleryAll | Where-Object { $_.KhoName -eq 'Kho Alpha' }).Count)) '5,1'
                HLog ('toast: ' + (ToastText)); HShot 'p1-06-after-multi-move'
                $h.Step = 6
            }
            6 {
                # single move from the card "..." menu: Beta video 201 -> Kho Delta
                $ui.GalleryList.UnselectAll(); $ui.CmbKho.SelectedIndex = 0; Pump; $win.UpdateLayout()
                $row = @($script:galleryRows | Where-Object { $_.Id -eq '1000000000201' })[0]
                $ui.GalleryList.UpdateLayout(); Pump
                $cont = $ui.GalleryList.ItemContainerGenerator.ContainerFromItem($row)
                if (-not $cont) { $h.Data.Retry = 1 + [int]$h.Data.Retry; if ($h.Data.Retry -lt 12) { return } else { HLog ('DIAG rows=' + $script:galleryRows.Count + ' row=' + ($null -ne $row) + ' vis=' + $ui.GalleryList.IsVisible + ' h=' + $ui.GalleryList.ActualHeight + ' page=' + $script:currentPage + ' realized=' + $ui.GalleryList.ItemContainerGenerator.Status); throw 'card container never realized' } }
                $h.Data.Retry = 0
                $more = Find-Visual $cont { param($n) $n -is [Windows.Controls.Button] -and [string]$n.Tag -eq 'more' }
                Click-Btn $more
                $menu = $more.ContextMenu
                HLog ('card menu: ' + (MenuText $menu))
                Click-Item (MenuItemLike $menu 'Chuyển sang kho*')
                $menu2 = $more.ContextMenu
                Expect 'kho menu opened' $menu2.IsOpen $true
                HLog ('kho menu: ' + (MenuText $menu2))
                Pump; HShot 'p1-07-card-kho-menu' $menu2
                Click-Item (MenuItemLike $menu2 'Kho Delta*')
                $h.Step = 7
            }
            7 {
                if ($script:galleryState -ne 'ready') { return }
                $G = $global:H.Data.GammaPath
                Expect 'card-move: -3 in Delta folder' (F $G '1000000000201-3-hoan-chinh.mp4') $true
                Expect 'card-move: -3 left Beta' (F $B '1000000000201-3-hoan-chinh.mp4') $false
                Expect 'card-move: thumb/companion in Delta' (F $G '.cache\1000000000201-1-video-goc.mp4') $true
                $mg = Get-Content -LiteralPath (Join-Path $G 'reup-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $mb = Get-Content -LiteralPath (Join-Path $B 'reup-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                Expect 'card-move: entry in Delta, not in Beta' (($null -ne $mg.PSObject.Properties['1000000000201']) -and ($null -eq $mb.PSObject.Properties['1000000000201'])) $true
                Expect 'card-move: manual move of a confirmed post pins it' $mg.'1000000000201'.KhoPinned $true
                Expect 'card-move: journal folder empty' (JournalCount) 0
                HShot 'p1-08-after-card-move'
                $h.Step = 8
            }
            8 {
                # delete a video (Recycle Bin) through the card menu
                $script:confirmDialogAutoAnswer = $true
                $h.Data.Bin103 = InBin '1000000000103-3-hoan-chinh*'
                $row = @($script:galleryRows | Where-Object { $_.Id -eq '1000000000103' })[0]
                $ui.GalleryList.UpdateLayout(); Pump
                $cont = $ui.GalleryList.ItemContainerGenerator.ContainerFromItem($row)
                if (-not $cont) { $h.Data.Retry = 1 + [int]$h.Data.Retry; if ($h.Data.Retry -lt 12) { return } else { HLog ('DIAG rows=' + $script:galleryRows.Count + ' row=' + ($null -ne $row) + ' vis=' + $ui.GalleryList.IsVisible + ' h=' + $ui.GalleryList.ActualHeight + ' page=' + $script:currentPage + ' realized=' + $ui.GalleryList.ItemContainerGenerator.Status); throw 'card container never realized' } }
                $h.Data.Retry = 0
                $more = Find-Visual $cont { param($n) $n -is [Windows.Controls.Button] -and [string]$n.Tag -eq 'more' }
                Click-Btn $more
                Click-Item (MenuItemLike $more.ContextMenu 'Xóa video*')
                $h.Step = 9
            }
            9 {
                if ($script:galleryState -ne 'ready') { return }
                Expect 'delete video: file left the kho folder' (F $A '1000000000103-3-hoan-chinh.mp4') $false
                Expect 'delete video: one more copy in the Recycle Bin' ((InBin '1000000000103-3-hoan-chinh*') - $h.Data.Bin103) 1
                Expect 'delete video: card removed' @($script:galleryAll | Where-Object { $_.Id -eq '1000000000103' }).Count 0
                Expect 'delete video: other videos untouched' (F $B '1000000000202-3-hoan-chinh.mp4') $true
                HLog ('toast: ' + (ToastText)); HShot 'p1-09-after-delete-video'
                $h.Step = 10
            }
            10 {
                # delete the kho Delta (holds video 201) from the manager dialog
                $script:confirmDialogAutoAnswer = $true
                $global:H.Data.Bin201 = InBin '1000000000201-3-hoan-chinh*'
                $id = $global:H.Data.GammaId
                RunDialog $id {
                    param($d)
                    Select-DialogKho $d $id
                    HShot 'p1-10-manager-delete' $d
                    Click-Btn $d.FindName('BtnDelete')
                    Expect 'kho delete: removed from the registry' ($null -eq (Get-KhoById $id)) $true
                    Expect 'kho delete: its video left the folder' (F $global:H.Data.GammaPath '1000000000201-3-hoan-chinh.mp4') $false
                    Expect 'kho delete: one more copy in the Recycle Bin' ((InBin '1000000000201-3-hoan-chinh*') - $global:H.Data.Bin201) 1
                    Expect 'kho delete: app-made folder recycled' ([IO.Directory]::Exists($global:H.Data.GammaPath)) $false
                    Expect 'kho delete: saved registry no longer lists it' (@((Get-Content -LiteralPath (Join-Path $root 'data\kho.json') -Raw -Encoding UTF8 | ConvertFrom-Json).libraries | Where-Object { $_.id -eq $id }).Count) 0
                }
                $h.Wait = 3; $h.Step = 11
            }
            11 {
                if ($script:galleryState -ne 'ready') { return }
                Expect 'download combo back to 2 khos' (@($ui.CmbDownloadKho.Items | ForEach-Object { [string]$_.Content }) -join ',') 'Kho Alpha,Kho Beta'
                Expect 'filter combo back to All + 2' @($ui.CmbKho.Items).Count 3
                Expect 'gallery: 4 videos left' @($script:galleryAll).Count 4
                HShot 'p1-11-final'
                HLog "RESULT fail=$($h.Fail)"
                $script:HTimer.Stop(); $win.Close()
            }
        }
    } catch { $global:H.Fail++; HLog ("HARNESS ERROR step=$($global:H.Step): $($_.Exception.Message)`n$($_.ScriptStackTrace)"); $script:HTimer.Stop(); $win.Close() }
})
$script:HTimer.Start()
