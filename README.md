# Kid FB.Y — v1.0.12

Tải video Facebook và ghép audio lồng tiếng Meta AI thu từ Facebook trên Android/LDPlayer. Video hoàn tất vẫn cần nghe nghiệm thu trước khi dùng.

## Thử trên máy Windows mới

1. Tải toàn bộ dự án bằng **Code → Download ZIP**, hoặc tải [ZIP bản v1.0.12](https://github.com/kidlost1412/kid-fby/archive/refs/tags/v1.0.12.zip).
2. Giải nén ra một thư mục có quyền ghi. Giữ `Kid-FB.Y.exe` cùng thư mục `core`; chạy EXE sau khi giải nén, không chạy bên trong ZIP.
3. Trong tab **Bộ Thư Viện**, bấm **Tải & Cài Đặt Tất Cả**. Lần đầu cần Internet để tải công cụ và model. Các file nằm trong thư mục `tools` và không đi kèm ZIP GitHub.
4. Mở LDPlayer/Android đã có Facebook, đăng nhập và bật kết nối ADB. Quy trình thu audio cần Android hỗ trợ audio capture; cấu hình đang dùng của dự án là LDPlayer Android 14.
5. Bấm **Kiểm tra máy**, dán một link video công khai để thử. Có thể dán link `share/r`, `share/v`, `fb.watch` hoặc link kèm văn bản/Markdown; app tách URL và thử chuyển link chia sẻ sang link video trực tiếp. Đợi thu xong rồi nghe nghiệm thu. File xuất mặc định ở `output`.

Bộ tiny dùng CPU Windows x64, không cần cài Python/CUDA. Model đa ngôn ngữ khoảng 78 MB tải một lần. Có thể cài riêng bằng nút **Whisper tiny** trong tab công cụ. Bỏ chọn **Nhận diện tiếng Việt bằng tiny** trước khi chạy nếu muốn bỏ bước nhận diện.

## Nhận diện ngôn ngữ thử nghiệm

Tiny lấy tối đa hai đoạn audio ngắn, chỉ ước tính ngôn ngữ. Thiếu tool/model, audio quá ngắn hoặc kết quả chưa rõ không chặn xuất video. Với nguồn Khmer và một số ngôn ngữ Ấn Độ, tiny còn yếu trong bộ mẫu đã thử; điểm model cao cũng có thể sai. Luôn nghe nghiệm thu.

Xem [WHISPER.md](WHISPER.md) để biết cách thử audio có sẵn, số đo tốc độ, bộ mẫu và giới hạn. Các sửa lỗi khởi tạo/hủy tác vụ/giữ bản cũ được ghi trong [AUDIT.md](AUDIT.md). Bản này đã qua kiểm tra khởi tạo WPF trong thư mục trống và model thật trên máy phát triển; lần thử của anh trên máy mới vẫn cần kiểm tra cả Facebook/LDPlayer.

Nếu gặp lỗi, giữ nội dung tab **Terminal Logs** và thông báo lỗi, kèm phiên bản Windows/LDPlayer để đối chiếu. Không cần cung cấp thông tin đăng nhập Facebook.
