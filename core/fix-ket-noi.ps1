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
    if (Test-Path $c) { $toolAdb = $c; break }
}
if (-not $toolAdb) {
    $hit = Get-ChildItem -Path (Join-Path $dir 'tools') -Recurse -Filter 'adb.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
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
    if (Test-Path $ld) {
        $ldFound = $ld
        Write-Host "    -> Tìm thấy LDPlayer tại: $ldFound" -ForegroundColor Green
        break
    }
}

# Dong bo adb voi LDPlayer neu co
if ($ldFound) {
    $ldAdb = Join-Path $ldFound 'adb.exe'
    if (Test-Path $ldAdb) {
        Write-Host "    -> Đang đồng bộ phiên bản ADB với LDPlayer để tránh xung đột version..." -ForegroundColor Gray
        try {
            $toolDir = Split-Path $toolAdb -Parent
            Copy-Item (Join-Path $toolDir 'adb.exe') $ldFound -Force -ErrorAction SilentlyContinue
            if (Test-Path (Join-Path $toolDir 'AdbWinApi.dll')) {
                Copy-Item (Join-Path $toolDir 'AdbWinApi.dll') $ldFound -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path (Join-Path $toolDir 'AdbWinUsbApi.dll')) {
                Copy-Item (Join-Path $toolDir 'AdbWinUsbApi.dll') $ldFound -Force -ErrorAction SilentlyContinue
            }
            Write-Host "    [V] Đã đồng bộ ADB thành công! Không còn nguy cơ xung đột." -ForegroundColor Green
        } catch {
            Write-Host "    (!) Không thể ghi đè ADB vào LDPlayer (có thể LDPlayer đang mở)." -ForegroundColor Yellow
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

$online = @($devList | Where-Object { $_ -match '\sdevice\s*' })
$unauth = @($devList | Where-Object { $_ -match '\sunauthorized' })

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
