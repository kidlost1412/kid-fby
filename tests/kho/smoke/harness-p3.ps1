# WPF smoke harness for the P3 features (dot-sourced into a TEMP COPY of kid-fby-gui.ps1 right before ShowDialog by run-smoke-p3.ps1). Temp data + fake backend only.
# Steps: rubber-band selection (pointer injected, auto-scroll) -> external .MOV dropped into a kho, appears, thumbnail, moved, deleted -> Quản lý kho slot chips
# -> Rải lịch dialog with editable time/caption per row -> Confirm closes the dialog, the run goes on in the background (status bar, busy guard, failure toast, final toast).
$p1Text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'harness-p1.ps1'), [Text.Encoding]::UTF8)
Invoke-Expression $p1Text.Substring(0, $p1Text.IndexOf('$script:HTimer = New-Object'))   # the helpers (HLog, HShot, Expect, Pump, Find-Visual, ...)
$global:H.Data.Toasts = New-Object System.Collections.Generic.List[string]
function SampleToasts { foreach ($t in @((ToastText) -split ' \|\| ')) { if ($t -and -not $global:H.Data.Toasts.Contains($t)) { $global:H.Data.Toasts.Add($t) } } }
function RunSpread {
    # Opens the spread dialog for $Items and drives it with $Script once the accounts have loaded (polls; the dialog is modal).
    param($Items, [scriptblock]$Script)
    $script:HTimer.Stop()
    $sb = $Script
    $dt = New-Object Windows.Threading.DispatcherTimer; $dt.Interval = [TimeSpan]::FromMilliseconds(700)
    $global:H.Data.Poll = 0
    $dt.Add_Tick({
        try {
            $d = @($win.OwnedWindows)[0]
            if (-not $d) { return }
            $global:H.Data.Poll++
            $ready = ($d.FindName('Accounts').Children.Count -gt 0) -and ($d.FindName('Rows').Children.Count -gt 0)
            if (-not $ready -and $global:H.Data.Poll -lt 40) { return }
            $dt.Stop()
            if (-not $ready) { $global:H.Fail++; HLog 'SPREAD DIALOG never became ready'; $d.Close(); return }
            & $sb $d
        } catch { $dt.Stop(); $global:H.Fail++; HLog "SPREAD SCRIPT ERROR: $($_.Exception.Message) $($_.ScriptStackTrace)"; try { @($win.OwnedWindows)[0].Close() } catch { } }
    })
    $dt.Start()
    Show-TikTokSpreadDialog -Items $Items
    $dt.Stop()
    $script:HTimer.Start()
}
function RowControls { param($d, $i)
    $g = $d.FindName('Rows').Children[$i]
    $time = Find-Visual $g { param($n) $n -is [Windows.Controls.TextBox] -and [Windows.Automation.AutomationProperties]::GetName($n) -like 'Giờ hẹn*' }
    $cap = Find-Visual $g { param($n) $n -is [Windows.Controls.TextBox] -and [Windows.Automation.AutomationProperties]::GetName($n) -like 'Caption*' }
    $note = Find-Visual $g { param($n) $n -is [Windows.Controls.TextBlock] -and [Windows.Controls.Grid]::GetColumn($n) -eq 3 }
    return @{ Time = $time; Cap = $cap; Note = $note }
}

$script:HTimer = New-Object Windows.Threading.DispatcherTimer
$script:HTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:HTimer.Add_Tick({
    try {
        $h = $script:H
        SampleToasts
        if ($h.Wait -gt 0) { $h.Wait--; return }
        $A = Join-Path $script:HDir 'khoA'; $B = Join-Path $script:HDir 'khoB'
        $alphaId = (KhoByName 'Kho Alpha').id; $betaId = (KhoByName 'Kho Beta').id
        switch ($h.Step) {
            0 {
                if (-not $script:galleryScanReady) { return }
                $win.Width = 1280; $win.Height = 640
                Show-Page 'library'
                $h.Step = 1
            }
            1 {
                if ($script:galleryState -ne 'ready' -or @($script:galleryAll).Count -ne 5) { return }
                $ui.CmbKho.SelectedIndex = 0; Pump; $win.UpdateLayout(); $ui.GalleryList.UpdateLayout(); Pump
                Expect 'tiktok enabled (fake backend configured)' (Test-TikTokEnabled) $true
                Expect '5 videos listed' @($script:galleryAll).Count 5
                HShot 'p3-01-library'
                $h.Wait = 2; $h.Step = 2
            }
            2 {
                # ---- rubber band: pointer injected into the product functions; real KidWrapPanel geometry ----
                $panel = Find-GalleryVisualChild $ui.GalleryList ([KidWrapPanel])
                $cols = $panel.Columns; $iw = $panel.ItemWidth; $ih = $panel.ItemHeight; $vw = $panel.ViewportWidth; $vh = $panel.ViewportHeight
                HLog ("panel cols=$cols cell=${iw}x$ih viewport=${vw}x$vh extentH=$($panel.ExtentHeight)")
                Expect 'panel is scrollable (2 rows of tall cards in a short window)' ($panel.ExtentHeight -gt $vh) $true
                $left = [Math]::Max(0.0, ($vw - $cols * $iw) / 2.0)
                $ui.GalleryList.UnselectAll()
                $global:KhoBandPointerOverride = [Windows.Point]::new($left + 10, 10)
                $ev = New-Object psobject -Property @{ LeftButton = [Windows.Input.MouseButtonState]::Pressed }
                $ev | Add-Member -MemberType ScriptMethod -Name GetPosition -Value { param($el) return (Get-BandPointer $null) }
                Start-GalleryBand $ui.GalleryList $ev
                Expect 'press on empty space arms the band but selects nothing yet' (($null -ne $script:band) -and -not $script:band.Active -and $ui.GalleryList.SelectedItems.Count -eq 0) $true
                $global:KhoBandPointerOverride = [Windows.Point]::new($left + 12, 12)
                Move-GalleryBand $ev
                Expect 'a 2 px move is below the drag threshold (plain click unchanged)' $ui.GalleryList.SelectedItems.Count 0
                $global:KhoBandPointerOverride = [Windows.Point]::new($left + $iw + $iw / 2, $ih / 2)
                Move-GalleryBand $ev
                Expect 'band over cells 0 and 1 selects 2 cards' $ui.GalleryList.SelectedItems.Count 2
                Expect 'band rectangle is drawn' $ui.BandRect.Visibility 'Visible'
                Expect 'band rectangle has the dragged size' ([Math]::Round($ui.BandRect.Width)) ([Math]::Round($iw + $iw / 2 - 10))
                Expect 'selection bar shows for 2 cards' $ui.PanelSelBar.Visibility 'Visible'
                $win.UpdateLayout(); Pump; HShot 'p3-02-rubber-band'
                # pointer at the bottom edge: auto-scroll moves the offset and the band reaches row 2
                $global:KhoBandPointerOverride = [Windows.Point]::new($left + $iw + $iw / 2, $vh - 4)
                for ($k = 0; $k -lt 12; $k++) { Step-GalleryBandScroll; Pump }
                Expect 'auto-scroll moved the grid' ($panel.VerticalOffset -gt 0) $true
                Expect 'band now covers more cards after scrolling' ($ui.GalleryList.SelectedItems.Count -gt 2) $true
                $global:H.Data.BandCount = $ui.GalleryList.SelectedItems.Count
                Stop-GalleryBand
                Expect 'releasing hides the rectangle and keeps the selection' (($ui.BandRect.Visibility -eq 'Collapsed') -and $ui.GalleryList.SelectedItems.Count -eq $global:H.Data.BandCount) $true
                $global:KhoBandPointerOverride = $null
                $ui.GalleryList.UnselectAll(); $panel.SetVerticalOffset(0); Pump
                $h.Step = 3
            }
            3 {
                # ---- external video: drop into Kho Alpha ----
                $script:filterKho = $alphaId; Apply-GalleryFilter; Pump
                $src = Join-Path $script:HDir 'drop\Clip ngoài (1).MOV'
                Invoke-KhoDrop -Files @($src)
                Expect 'drop copied the file into the selected kho' (F $A 'Clip ngoài (1).MOV') $true
                Expect 'no .part file left' (F $A 'Clip ngoài (1).MOV.part') $false
                Expect 'the dropped source is untouched' ([IO.File]::Exists($src)) $true
                $h.Step = 4
            }
            4 {
                if ($script:galleryState -ne 'ready') { return }
                $row = @($script:galleryAll | Where-Object { $_.Id -eq 'f:Clip ngoài (1).MOV' })[0]
                if (-not $row) { $h.Data.Retry = 1 + [int]$h.Data.Retry; if ($h.Data.Retry -lt 20) { return }; Expect 'external card appeared' $false $true; $h.Step = 99; return }
                if (-not $row.ThumbPath) { $h.Data.Retry = 1 + [int]$h.Data.Retry; if ($h.Data.Retry -lt 40) { return } }
                Expect 'external card title = file name without extension' $row.Title 'Clip ngoài (1)'
                Expect 'external card is flagged external' $row.External $true
                Expect 'external card has a generated thumbnail' ([bool]$row.ThumbPath) $true
                $tk = Get-KhoThumbKey 'f:Clip ngoài (1).MOV'
                Expect 'thumbnail stored under f_<sha1> in .cache\thumbs' (F $A ".cache\thumbs\$tk.jpg") $true
                Expect 'app videos still listed' @($script:galleryAll | Where-Object { -not $_.External }).Count 5
                $win.UpdateLayout(); Pump; HShot 'p3-03-external-card'
                $h.Data.Retry = 0
                # re-edit is disabled for the external video
                $script:lastOut = $row.Path; Update-RedoAvailability $row.Path
                Expect 'record-again disabled for external' $ui.BtnRedo.IsEnabled $false
                Expect 'record-again tooltip explains' $ui.BtnRedo.ToolTip 'Chỉ dùng cho video do app tạo'
                # move to Beta
                Move-GalleryItemsToKho -Items @($row) -KhoId $betaId
                $h.Step = 5
            }
            5 {
                if ($script:galleryState -ne 'ready') { return }
                Expect 'external file moved to Kho Beta' (F $B 'Clip ngoài (1).MOV') $true
                Expect 'external file left Kho Alpha' (F $A 'Clip ngoài (1).MOV') $false
                $tk = Get-KhoThumbKey 'f:Clip ngoài (1).MOV'
                Expect 'its thumbnail moved too' (F $B ".cache\thumbs\$tk.jpg") $true
                Expect 'journal folder empty' (JournalCount) 0
                $h.Data.BinExt = InBin 'Clip ngoài (1).MOV'
                $script:confirmDialogAutoAnswer = $true
                $row = @($script:galleryAll | Where-Object { $_.Id -eq 'f:Clip ngoài (1).MOV' })[0]
                Expect 'card now belongs to Kho Beta' $row.KhoName 'Kho Beta'
                [void](Invoke-GalleryDelete -FilePath $row.Path -Controls $ui)
                $h.Step = 6
            }
            6 {
                if ($script:galleryState -ne 'ready') { return }
                Expect 'external file deleted from the kho' (F $B 'Clip ngoài (1).MOV') $false
                Expect 'external file is in the Recycle Bin' ((InBin 'Clip ngoài (1).MOV') - $h.Data.BinExt) 1
                Expect 'card removed' @($script:galleryAll | Where-Object { $_.External }).Count 0
                HShot 'p3-04-after-external-delete'
                $h.Step = 7
            }
            7 {
                # ---- slot chips in Quản lý kho (Beta has account anna) ----
                RunDialog $betaId {
                    param($d)
                    Select-DialogKho $d $betaId
                    $d.FindName('SlotAddBox').Text = '9:30'; Click-Btn $d.FindName('BtnSlotAdd')
                    $d.FindName('SlotAddBox').Text = '20:15'; Click-Btn $d.FindName('BtnSlotAdd')
                    $d.FindName('SlotAddBox').Text = '25:00'; Click-Btn $d.FindName('BtnSlotAdd')
                    Expect 'slots stored in kho.slots (normalised, sorted); the invalid time was refused' (((Get-KhoById $betaId).slots) -join ',') '09:30,20:15'
                    Expect 'two chips shown' @($d.FindName('SlotChips').Children | Where-Object { $_ -is [Windows.Controls.Button] }).Count 2
                    Expect 'invalid time gives a message' ([bool]$d.FindName('Status').Text) $true
                    HShot 'p3-05-slot-chips' $d
                    $chip = @($d.FindName('SlotChips').Children | Where-Object { $_ -is [Windows.Controls.Button] })[1]
                    Click-Btn $chip
                    Expect 'clicking a chip removes the slot' (((Get-KhoById $betaId).slots) -join ',') '09:30'
                    $d.FindName('SlotAddBox').Text = '20:15'; Click-Btn $d.FindName('BtnSlotAdd')
                    Expect 'persisted in kho.json' ((Get-Content -LiteralPath (Join-Path $root 'data\kho.json') -Raw -Encoding UTF8 | ConvertFrom-Json).libraries | Where-Object { $_.id -eq $betaId } | ForEach-Object { $_.slots -join ',' }) '09:30,20:15'
                }
                $h.Wait = 2; $h.Step = 8
            }
            8 {
                # ---- spread dialog: edit rows, Confirm closes it, the run goes on in the background ----
                $ui.CmbKho.SelectedIndex = 0; $script:filterKho = 'all'; Apply-GalleryFilter; Pump
                $items = @($script:galleryAll | Where-Object { $_.Kho -ceq $alphaId } | Sort-Object Id)
                Expect 'three Alpha videos to spread' $items.Count 3
                $global:H.Data.Items = $items
                RunSpread $items {
                    param($d)
                    $rb = Find-Visual $d { param($n) $n -is [Windows.Controls.RadioButton] -and [string]$n.Tag -ceq 'anna' }
                    $rb.IsChecked = $true; Pump; Pump
                    $r = 0..2 | ForEach-Object { RowControls $d $_ }
                    Expect 'rows prefilled with the kho caption template' $r[0].Cap.Text 'Mẫu của Anna #anna'
                    Expect 'rows got times from the kho slots (09:30 / 20:15)' ((0..2 | ForEach-Object { $r[$_].Time.Text.Substring(6) } | Select-Object -Unique | Sort-Object) -join ',') '09:30,20:15'
                    HShot 'p3-06-spread-dialog' $d
                    $r[0].Time.Text = 'abc'; Pump
                    Expect 'invalid time -> row marked (red border)' ([object]::ReferenceEquals($r[0].Time.BorderBrush, $d.FindResource('Danger'))) $true
                    Expect 'invalid time -> Confirm disabled' $d.FindName('Confirm').IsEnabled $false
                    Expect 'invalid time -> row note explains the format' ($r[0].Note.Text -like 'Nhập giờ dạng dd/MM HH:mm*') $true
                    $r[0].Time.Text = [DateTime]::Today.AddDays(1).ToString('dd/MM') + ' 21:00'; Pump
                    $r[1].Time.Text = [DateTime]::Today.AddDays(1).ToString('dd/MM') + ' 21:30'; Pump
                    Expect 'two rows 30 min apart -> a warning, not an error' ($r[1].Note.Text -like 'Cách một bài khác chỉ*') $true
                    Expect 'warning does not disable Confirm' $d.FindName('Confirm').IsEnabled $true
                    $day2 = [DateTime]::Today.AddDays(2)
                    $global:H.Data.T1 = $day2.AddHours(9).AddMinutes(5); $global:H.Data.T2 = $day2.AddHours(13).AddMinutes(30); $global:H.Data.T3 = $day2.AddHours(18).AddMinutes(20)
                    $r[0].Time.Text = $global:H.Data.T1.ToString('dd/MM HH:mm'); $r[1].Time.Text = $global:H.Data.T2.ToString('dd/MM HH:mm'); $r[2].Time.Text = $global:H.Data.T3.ToString('dd/MM HH:mm'); Pump
                    $r[0].Cap.Text = 'Một #a'; $r[2].Cap.Text = 'FAILME hỏng'; Pump
                    Expect 'valid edited times -> Confirm enabled' $d.FindName('Confirm').IsEnabled $true
                    HShot 'p3-07-spread-edited' $d
                    Click-Btn $d.FindName('Confirm')
                    Expect 'Confirm closed the dialog' (@($win.OwnedWindows).Count) 0
                    Expect 'the run exists in the background' (Test-SpreadRunActive) $true
                }
                $h.Step = 9; $h.Data.RunTicks = 0
            }
            9 {
                $h.Data.RunTicks = 1 + [int]$h.Data.RunTicks
                if (Test-SpreadRunActive) {
                    if (-not $h.Data.SeenBar) {
                        $h.Data.SeenBar = $true
                        Expect 'status bar visible while sending' $ui.SpreadBar.Visibility 'Visible'
                        Expect 'status text "Đang gửi lịch k/N…"' ($ui.TxtSpreadStatus.Text -like 'Đang gửi lịch */3…') $true
                        Expect 'Rải lịch button disabled while the run goes on' $ui.BtnSpreadSelected.IsEnabled $false
                        Expect 'app is busy for moves' (Test-KhoQuiet) 'đang rải lịch đăng TikTok'
                        $win.UpdateLayout(); Pump; HShot 'p3-08-spread-running'
                    }
                    if ($h.Data.RunTicks -gt 400) { Expect 'run finished in time' $false $true; $h.Step = 99 }
                    return
                }
                SampleToasts
                Expect 'status bar hidden after the run' $ui.SpreadBar.Visibility 'Collapsed'
                Expect 'Rải lịch button enabled again' $ui.BtnSpreadSelected.IsEnabled $true
                Expect 'app quiet again' (Test-KhoQuiet) ''
                Expect 'a toast reported the failed video' (@($h.Data.Toasts | Where-Object { $_ -like '*gửi lịch lỗi*' }).Count -ge 1) $true
                Expect 'final toast "Đã gửi 2, lỗi 1, chưa gửi 0"' (@($h.Data.Toasts | Where-Object { $_ -like '*Đã gửi 2, lỗi 1, chưa gửi 0*' }).Count -ge 1) $true
                $creates = @(Get-Content -LiteralPath ($env:KHO_BACKEND_STATE + '.creates') -Encoding UTF8 -ErrorAction SilentlyContinue)
                Expect 'the fake backend accepted exactly 2 jobs (the third was rejected)' $creates.Count 2
                $byReel = @{}; foreach ($line in $creates) { $p = $line -split '\|', 4; $byReel[$p[1]] = $p }
                $it = @($global:H.Data.Items)
                Expect 'job 1 carries the edited caption' $byReel[[string]$it[0].Id][3] 'Một #a'
                Expect 'job 1 carries the edited time' $byReel[[string]$it[0].Id][2] ($global:H.Data.T1.ToUniversalTime().ToString('o'))
                Expect 'job 2 keeps the template caption and its edited time' ($byReel[[string]$it[1].Id][3] + '@' + $byReel[[string]$it[1].Id][2]) ('Mẫu của Anna #anna@' + $global:H.Data.T2.ToUniversalTime().ToString('o'))
                Expect 'job 3 (FAILME) was not accepted' $byReel.ContainsKey([string]$it[2].Id) $false
                HLog ('toasts: ' + ($h.Data.Toasts -join ' || '))
                HShot 'p3-09-after-spread'
                HLog "RESULT fail=$($h.Fail)"
                $script:HTimer.Stop(); $win.Close()
            }
            99 { HLog "ABORTED fail=$($h.Fail)"; $script:HTimer.Stop(); $win.Close() }
        }
    } catch { $global:H.Fail++; HLog ("HARNESS ERROR step=$($global:H.Step): $($_.Exception.Message)`n$($_.ScriptStackTrace)"); $script:HTimer.Stop(); $win.Close() }
})
$script:HTimer.Start()
