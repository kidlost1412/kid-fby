#Requires -Version 5.1
chcp 65001 >$null 2>&1

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "   KID FB.Y - CHẨN ĐOÁN & TỰ ĐỘNG SỬA KẾT NỐI LDPLAYER / ANDROID" -ForegroundColor Yellow
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ((Split-Path $dir -Leaf) -in @('core','src','app')) {
    $dir = Split-Path $dir -Parent
}

# 1. Tim adb cua Tool
$toolAdb = $null
$candAdb = @(
    (Join-Path $dir 'tools\scrcpy\scrcpy-win64-v4.1\adb.exe'),
    (Join-Path $dir 'tools\scrcpy\scrcpy-win64-v3.1\adb.exe'),
    (Join-Path $dir 'tools\scrcpy\adb.exe')
)
foreach ($c in $candAdb) {
    if (Test-Path -LiteralPath $c) { $toolAdb = $c; break }
}
if (-not $toolAdb) {
    $hit = Get-ChildItem -LiteralPath (Join-Path $dir 'tools') -Recurse -Filter 'adb.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $toolAdb = $hit.FullName }
}

if (-not $toolAdb) {
    Write-Host "[X] KHÔNG TÌM THẤY ADB TRONG THƯ MỤC TOOLS!" -ForegroundColor Red
    Write-Host "    Vui lòng chạy file cai-dat.cmd trước để tải bộ thư viện." -ForegroundColor Yellow
    pause
    exit
}

Write-Host "[1] Tắt các tiến trình ADB đang kẹt hoặc xung đột..." -ForegroundColor Gray
Stop-Process -Name 'adb' -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600

# 2. Quet thu muc cai dat LDPlayer
Write-Host "[2] Quét tìm thư mục cài đặt LDPlayer trên máy..." -ForegroundColor Gray
$ldDirs = @(
    'C:\LDPlayer\LDPlayer14',
    'D:\LDPlayer\LDPlayer14',
    'E:\LDPlayer\LDPlayer14',
    'C:\leidian\LDPlayer14',
    'D:\leidian\LDPlayer14',
    'E:\leidian\LDPlayer14',
    'C:\Program Files\LDPlayer14',
    'D:\Program Files\LDPlayer14',
    'C:\LDPlayer\LDPlayer9',
    'D:\LDPlayer\LDPlayer9',
    'E:\LDPlayer\LDPlayer9',
    'C:\leidian\LDPlayer9',
    'D:\leidian\LDPlayer9',
    'E:\leidian\LDPlayer9',
    'C:\Program Files\LDPlayer9',
    'D:\Program Files\LDPlayer9'
)

$ldFound = $null
foreach ($ld in $ldDirs) {
    if (Test-Path -LiteralPath $ld) {
        $ldFound = $ld
        Write-Host "    -> Tìm thấy LDPlayer tại: $ldFound" -ForegroundColor Green
        break
    }
}

# Dong bo adb voi LDPlayer neu co
if ($ldFound) {
    $ldAdb = Join-Path $ldFound 'adb.exe'
    if (Test-Path -LiteralPath $ldAdb) {
        Write-Host "    -> adb của LDPlayer khác phiên bản adb của tool có thể gây xung đột (server version doesn't match)." -ForegroundColor Gray
        Write-Host "       Ghi đè sẽ thay file trong thư mục LDPlayer; file cũ được sao lưu thành adb.exe.bak-<thời gian>." -ForegroundColor Gray
        $canPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if ($canPrompt) {
            $answer = Read-Host "    Ghi đè adb.exe của LDPlayer bằng adb của tool? (Y/N, mặc định N)"
        } else {
            $answer = 'N'
            Write-Host "    - Không có console tương tác (chạy ẩn hoặc nhập bị chuyển hướng): mặc định N, không ghi đè." -ForegroundColor DarkGray
        }
        if ($answer -match '^(?i:y|yes)$') {
            $toolDir = Split-Path $toolAdb -Parent
            $stamp = Get-Date -Format 'yyyyMMddHHmmss'
            $syncOk = $true
            try {
                Copy-Item -LiteralPath $ldAdb -Destination ($ldAdb + '.bak-' + $stamp) -Force -ErrorAction Stop
                Write-Host "    -> Đã sao lưu: adb.exe.bak-$stamp" -ForegroundColor DarkGray
                Copy-Item -LiteralPath $toolAdb -Destination $ldAdb -Force -ErrorAction Stop
                foreach ($dll in @('AdbWinApi.dll','AdbWinUsbApi.dll')) {
                    $dllSrc = Join-Path $toolDir $dll
                    if (Test-Path -LiteralPath $dllSrc) {
                        $dllDst = Join-Path $ldFound $dll
                        if (Test-Path -LiteralPath $dllDst) { Copy-Item -LiteralPath $dllDst -Destination ($dllDst + '.bak-' + $stamp) -Force -ErrorAction Stop }
                        Copy-Item -LiteralPath $dllSrc -Destination $dllDst -Force -ErrorAction Stop
                    }
                }
            } catch {
                $syncOk = $false
                Write-Host "    (!) Không thể ghi đè ADB vào LDPlayer (có thể LDPlayer đang mở hoặc thiếu quyền): $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if ($syncOk) {
                Write-Host "    [V] Đã đồng bộ ADB. Có thể khôi phục từ adb.exe.bak-$stamp nếu LDPlayer lỗi." -ForegroundColor Green
            }
        } else {
            Write-Host "    - Bỏ qua: không ghi đè adb của LDPlayer." -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "    - Không tìm thấy thư mục mặc định của LDPlayer (có thể cài ở ổ đĩa khác)." -ForegroundColor DarkGray
}

# 3. Khoi dong ADB va quet ket noi cac cong
Write-Host "[3] Khởi động ADB Server và quét kết nối giả lập..." -ForegroundColor Gray
& $toolAdb start-server | Out-Null
Start-Sleep -Milliseconds 500

$ports = @(5555, 5557, 5559, 62001, 21503, 16384)
foreach ($p in $ports) {
    $res = & $toolAdb connect "127.0.0.1:$p" 2>&1
    Write-Host "    -> Thử kết nối cổng 127.0.0.1:$p : $res" -ForegroundColor DarkGray
}

Start-Sleep -Milliseconds 800

# 4. Kiem tra danh sach thiet bi
Write-Host ""
Write-Host "[4] Kiểm tra danh sách thiết bị nhận diện được:" -ForegroundColor Cyan
$devList = & $toolAdb devices -l
$devList | ForEach-Object { Write-Host "    $_" -ForegroundColor White }

$online = @($devList | Where-Object { $_ -match '^\S+\s+device(\s|$)' })
$unauth = @($devList | Where-Object { $_ -match '^\S+\s+unauthorized(\s|$)' })

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
if ($online.Count -gt 0) {
    Write-Host "  >>> KẾT NỐI THÀNH CÔNG! ĐÃ NHẬN DIỆN THIẾT BỊ ANDROID / LDPLAYER <<<" -ForegroundColor Green
    Write-Host "  Bây giờ anh có thể mở Kid-FB.Y-gui.cmd và bấm [ BẮT ĐẦU TỰ ĐỘNG HÓA ]." -ForegroundColor Green
} elseif ($unauth.Count -gt 0) {
    Write-Host "  >>> THIẾT BỊ ĐÃ KẾT NỐI NHƯNG CHƯA ĐƯỢC CẤP QUYỀN (UNAUTHORIZED) <<<" -ForegroundColor Yellow
    Write-Host "  Anh hãy nhìn lên màn hình LDPlayer:" -ForegroundColor Yellow
    Write-Host "  Tích vào ô: 'Luôn cho phép từ máy tính này' -> Bấm nút 'Cho phép' (OK)." -ForegroundColor Yellow
} else {
    Write-Host "  >>> CHƯA TÌM THẤY THIẾT BỊ NÀO <<<" -ForegroundColor Red
    Write-Host "  Lý do chính:" -ForegroundColor Yellow
    Write-Host "  1. LDPlayer chưa được bật lên (phải mở LDPlayer vào hẳn màn hình chính Android)." -ForegroundColor Yellow
    Write-Host "  2. Trong Cài đặt LDPlayer -> Mục khác -> Debug ADB:" -ForegroundColor Yellow
    Write-Host "     Nếu chọn 'Bật kết nối local' không được, anh hãy đổi sang 'Mở kết nối mạng' (Bật kết nối mạng từ xa)," -ForegroundColor Yellow
    Write-Host "     sau đó bấm LƯU và KHỞI ĐỘNG LẠI LDPLAYER." -ForegroundColor Yellow
}
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""
