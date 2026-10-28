# autotok - backend đăng TikTok cho Kid FB.Y

Dịch vụ cục bộ (bảng điều khiển + bộ hẹn giờ) mà Kid FB.Y dùng để đăng video lên TikTok. Mã nguồn nằm trong `src\`.

## Cài trên máy mới

1. Cài Python 3.11 trở lên (python.org, tick "Add python.exe to PATH") và Google Chrome.
2. Clone repo, mở Windows PowerShell tại thư mục repo, chạy:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\integrations\autotok\cai-dat.ps1`
   (tuỳ chọn `-DataDir "D:\noi\luu\du-lieu"` để đổi nơi lưu dữ liệu). Cần mạng để tải thư viện; chạy lại nhiều lần vẫn an toàn.
3. Mở `Kid-FB.Y.exe`. Bảng điều khiển TikTok tự khởi động ở `http://127.0.0.1:8765` (cổng điều khiển `17900`).
4. Đăng nhập tài khoản TikTok ngay trong bảng điều khiển (Chrome riêng sẽ mở để đăng nhập hoặc quét mã QR).

## Cài một chạm trong app (không cần git, không cần Python)

1. Cài Google Chrome (https://www.google.com/chrome/) nếu máy chưa có.
2. Trong Kid FB.Y, bấm Cập nhật để nhận bản mới (bản này kèm gói `core\autotok-bundle.zip`).
3. Vào Cài đặt > Công cụ > thẻ "Bộ đăng TikTok", bấm "Cài bộ đăng TikTok". Cần mạng; app tải Python 3.11.9 (nuget.org) và thư viện đã khoá phiên bản (pypi.org), mọi file đều được kiểm SHA256. Lần đầu mất khoảng vài phút, app vẫn dùng được trong lúc cài.
4. Xong là nút "Đăng video" bật ngay, không cần mở lại app.

Khi bản cập nhật app có bộ đăng mới hơn, thẻ hiện "Có bản mới" và nút "Cập nhật bộ đăng". App đợi các video đang gửi lên TikTok xong mới chuyển bản (trong lúc chuyển, nút Đăng tạm khoá); bản mới lỗi thì app tự quay lại bản cũ. Dữ liệu và phiên đăng nhập TikTok giữ nguyên ở thư mục dữ liệu cũ.

Máy đã cài theo cách clone repo ở trên: thẻ hiện "Bản tự cài"; bấm "Chuyển sang bản một chạm" nếu muốn đổi (app hỏi trước, dùng lại cùng thư mục dữ liệu).

Bản cài một chạm nằm trong `integrations\`: `autotok-releases\` (mỗi bản một thư mục), `autotok-python311\`, `autotok-current.json`, `autotok-config.json` (`DataDir`), `autotok-start.ps1`, nhật ký `autotok-install.log`. Đã gitignore. Dừng dịch vụ của bản đang dùng: `dung.ps1` trong thư mục bản ghi ở `autotok-current.json`.

Dừng dịch vụ: `.\integrations\autotok\dung.ps1` (từ chối nếu đang có lịch đăng, còn video đang chờ gửi lên TikTok, hoặc đang chờ/đăng qua Chrome; thêm `-Force` để ép dừng).

## Đăng bằng Chrome (từ bản 3.2.0)

Ngoài cookie, tài khoản có thể đăng qua Chrome đã đăng nhập TikTok, nhờ tiện ích AutoTok (không cần cookie). Cài tiện ích một lần theo `integrations\autotok-extension\HUONG-DAN-CAI-TIEN-ICH.md`.

- Giữ Chrome mở, với profile đã đăng nhập đúng tài khoản. Nếu app biết profile, nó có thể tự mở Chrome khi tới giờ.
- Thêm tài khoản: trong Cài đặt → Kết nối Chrome, bấm "Thêm tài khoản từ Chrome". Tài khoản cookie cùng tên sẽ tự chuyển sang Chrome một lần.
- Sau khi cập nhật tiện ích, vào `chrome://extensions` và bấm ⟳ ở AutoTok.
- Chưa hỗ trợ trên đường Chrome: đăng riêng tư kèm hẹn giờ, chế độ bạn bè, nguồn YouTube.

## Dữ liệu nằm ở đâu

- Mặc định `%LOCALAPPDATA%\KidFBY\autotok-data` (phiên đăng nhập TikTok, cơ sở dữ liệu, video). Đổi bằng `-DataDir`, biến môi trường `AUTOTOK_DATA_DIR`, hoặc `integrations\autotok\config.json` (`DataDir`).
- Thư mục này chứa phiên đăng nhập: không chép, không đưa vào git, không gửi cho ai.
- `integrations\autotok\runtime\` (PID và log dịch vụ), `.venv\` và `config.json` chỉ là của máy này và đã được gitignore.

## Giấy phép

`src\` dựa trên [makiisthenes/TiktokAutoUploader](https://github.com/makiisthenes/TiktokAutoUploader), giấy phép AGPL-3.0 (xem `src\LICENSE`, `src\THIRD_PARTY_NOTICES.md`). Các chỉnh sửa của chúng tôi so với bản gốc được công khai ngay trong repo này.
