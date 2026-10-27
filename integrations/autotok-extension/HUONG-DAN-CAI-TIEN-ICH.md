# Cài tiện ích Chrome để đăng TikTok

Tiện ích cho Kid FB.Y đăng video bằng chính Chrome của anh (đã đăng nhập TikTok), không cần cookie.
Chỉ cài một lần. Làm theo 5 bước.

## 1. Cài tiện ích (một lần)

1. Mở Chrome, gõ `chrome://extensions` rồi Enter.
2. Bật công tắc **Chế độ nhà phát triển** (góc trên bên phải).
3. Bấm **Tải tiện ích đã giải nén** (Load unpacked).
4. Chọn thư mục tiện ích. Cách nhanh: trong Kid FB.Y vào **Cài đặt → Kết nối Chrome → Mở thư mục tiện ích**, rồi chọn đúng thư mục đó (`...\integrations\autotok-extension`).
5. Thấy tiện ích **AutoTok** hiện ra là xong. Bấm biểu tượng mảnh ghép trên Chrome và **ghim** AutoTok cho dễ bấm.

Đừng đổi tên hay di chuyển thư mục đó sau khi cài. Nếu lỡ làm, cài lại bước 1.

## 2. Ghép nối với Kid FB.Y

1. Trong Kid FB.Y: **Cài đặt → Kết nối Chrome → Tạo mã ghép nối**. App hiện 6 số to, có đếm ngược 5 phút.
2. Trong Chrome: bấm biểu tượng AutoTok, gõ 6 số đó rồi bấm ghép nối.
3. Vài giây sau, Chrome này hiện trong danh sách "Chrome đã ghép nối" của app.

Mã chỉ dùng được một lần. Gõ sai nhiều lần thì mã bị hủy, tạo mã mới.

## 3. Thêm tài khoản TikTok

- Trong Chrome này, đăng nhập TikTok trước (trang tiktok.com).
- Trong app, ở dòng Chrome vừa ghép, bấm **Thêm tài khoản từ Chrome**. Tài khoản mới tự đăng qua Chrome.
- Tài khoản đã có sẵn (đăng nhập bằng cookie) có cùng tên với Chrome đang mở: app tự chuyển sang **Đăng qua Chrome** và báo "Tài khoản … sẽ đăng qua Chrome".
- Muốn đổi tay: ở danh sách tài khoản chọn **Chrome** hoặc **Cookie**. Tài khoản anh chọn Cookie thì app không tự chuyển nữa.

## 4. Khi đăng bài

- **Giữ Chrome mở** và hồ sơ (profile) đó đã đăng nhập TikTok. Có thể thu nhỏ cửa sổ, đừng tắt Chrome.
- Máy không được ngủ khi đang đăng.
- Video đang chờ Chrome hiện trạng thái "Chờ Chrome"; lúc đăng hiện "Chrome đang đăng".
- Nếu tới giờ mà Chrome chưa mở, lần đăng đó báo thất bại (Chrome chưa sẵn sàng, chưa gửi gì lên TikTok). Mở Chrome rồi hẹn lại.

## 5. Sau khi cập nhật Kid FB.Y

Nếu app báo **"Có bản tiện ích mới — vào chrome://extensions bấm ⟳"**: mở `chrome://extensions`, tìm AutoTok, bấm nút tròn **⟳** (Tải lại). Chỉ mất vài giây. Chưa bấm thì Chrome đó tạm không nhận việc mới.

## Gặp lỗi thì xem ở đây

Trong danh sách tài khoản, app ghi lý do tài khoản chưa đăng được:

| App báo | Nghĩa là | Cách xử lý |
| --- | --- | --- |
| Chrome chưa mở/chưa bật tiện ích | Không thấy Chrome nào đang kết nối | Mở Chrome, vào `chrome://extensions` kiểm tra AutoTok đang bật. Đợi vài giây. |
| Cần tải lại tiện ích | Tiện ích cũ hơn bộ đăng | Vào `chrome://extensions`, bấm ⟳ ở AutoTok. |
| Có hai hồ sơ Chrome cùng tài khoản này | Hai Chrome cùng đăng nhập một tài khoản TikTok | Trong **Kết nối Chrome**, bấm **Gỡ** ở Chrome không dùng. |
| Chưa gắn với Chrome nào | Tài khoản chưa nối với Chrome | Mở Chrome có tiện ích (đã đăng nhập đúng tài khoản). App sẽ tự nối; hoặc chọn Chrome ở danh sách tài khoản. |
| Chưa đăng nhập TikTok trong Chrome | Chrome ghép rồi nhưng chưa đăng nhập | Mở tiktok.com trong Chrome đó, đăng nhập, đợi vài giây. |
| chưa đăng nhập (tài khoản Cookie) | Phiên cookie hết hạn | Đăng nhập lại ở Tài khoản / Lịch đăng, hoặc chuyển sang Chrome. |

Vẫn không được: bấm **Gỡ** Chrome đó, tạo mã ghép nối mới và ghép lại. Gửi file `logs` trong thư mục Kid FB.Y cho người hỗ trợ nếu còn lỗi.
