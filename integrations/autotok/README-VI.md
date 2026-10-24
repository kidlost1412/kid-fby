# autotok - backend đăng TikTok cho Kid FB.Y

Dịch vụ cục bộ (bảng điều khiển + bộ hẹn giờ) mà Kid FB.Y dùng để đăng video lên TikTok. Mã nguồn nằm trong `src\`.

## Cài trên máy mới

1. Cài Python 3.11 trở lên (python.org, tick "Add python.exe to PATH") và Google Chrome.
2. Clone repo, mở Windows PowerShell tại thư mục repo, chạy:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\integrations\autotok\cai-dat.ps1`
   (tuỳ chọn `-DataDir "D:\noi\luu\du-lieu"` để đổi nơi lưu dữ liệu). Cần mạng để tải thư viện; chạy lại nhiều lần vẫn an toàn.
3. Mở `Kid-FB.Y.exe`. Bảng điều khiển TikTok tự khởi động ở `http://127.0.0.1:8765` (cổng điều khiển `17900`).
4. Đăng nhập tài khoản TikTok ngay trong bảng điều khiển (Chrome riêng sẽ mở để đăng nhập hoặc quét mã QR).

Dừng dịch vụ: `.\integrations\autotok\dung.ps1` (từ chối nếu đang có lịch đăng hoặc còn video đang chờ gửi lên TikTok; thêm `-Force` để ép dừng).

## Dữ liệu nằm ở đâu

- Mặc định `%LOCALAPPDATA%\KidFBY\autotok-data` (phiên đăng nhập TikTok, cơ sở dữ liệu, video). Đổi bằng `-DataDir`, biến môi trường `AUTOTOK_DATA_DIR`, hoặc `integrations\autotok\config.json` (`DataDir`).
- Thư mục này chứa phiên đăng nhập: không chép, không đưa vào git, không gửi cho ai.
- `integrations\autotok\runtime\` (PID và log dịch vụ), `.venv\` và `config.json` chỉ là của máy này và đã được gitignore.

## Giấy phép

`src\` dựa trên [makiisthenes/TiktokAutoUploader](https://github.com/makiisthenes/TiktokAutoUploader), giấy phép AGPL-3.0 (xem `src\LICENSE`, `src\THIRD_PARTY_NOTICES.md`). Các chỉnh sửa của chúng tôi so với bản gốc được công khai ngay trong repo này.
