# Kid FB.Y — v1.0.17

Tải video Facebook và ghép audio lồng tiếng Meta AI thu từ Facebook trên Android/LDPlayer. Video hoàn tất vẫn cần nghe nghiệm thu trước khi dùng.

## Thử trên máy Windows mới

1. Tải toàn bộ dự án bằng **Code → Download ZIP**, hoặc tải [ZIP bản v1.0.17](https://github.com/kidlost1412/kid-fby/archive/refs/tags/v1.0.17.zip).
2. Giải nén ra một thư mục có quyền ghi. Giữ `Kid-FB.Y.exe` cùng thư mục `core`; chạy EXE sau khi giải nén, không chạy bên trong ZIP.
3. Trong tab **Bộ Thư Viện**, bấm **Tải & Cài Đặt Tất Cả**. Lần đầu cần Internet để tải công cụ và model. Các file nằm trong thư mục `tools` và không đi kèm ZIP GitHub.
4. Mở LDPlayer/Android đã có Facebook, đăng nhập và bật kết nối ADB. Quy trình thu audio cần Android hỗ trợ audio capture; cấu hình đang dùng của dự án là LDPlayer Android 14.
5. Bấm **Kiểm tra máy**, dán một link video công khai để thử. Có thể dán link `share/r`, `share/v`, `fb.watch` hoặc link kèm văn bản/Markdown; app tách URL và thử chuyển link chia sẻ sang link video trực tiếp. Đợi thu xong rồi nghe nghiệm thu. File xuất mặc định ở `output`.

Bộ tiny dùng CPU Windows x64, không cần cài Python/CUDA. Model đa ngôn ngữ khoảng 78 MB tải một lần. Có thể cài riêng bằng nút **Whisper tiny** trong tab công cụ. Bỏ chọn **Nhận diện tiếng Việt bằng tiny** trước khi chạy nếu muốn bỏ bước nhận diện.

## Nhận diện ngôn ngữ thử nghiệm

Tiny lấy tối đa hai đoạn audio ngắn, chỉ ước tính ngôn ngữ. Thiếu tool/model, audio quá ngắn hoặc kết quả chưa rõ không chặn xuất video. Với nguồn Khmer và một số ngôn ngữ Ấn Độ, tiny còn yếu trong bộ mẫu đã thử; điểm model cao cũng có thể sai. Luôn nghe nghiệm thu.

Nhận diện chạy cục bộ trên CPU, không tự tải model giữa lúc xử lý và không thay đổi audio xuất. Kết quả vẫn cần nghe nghiệm thu trên video thực tế.

Nếu gặp lỗi, giữ nội dung tab **Terminal Logs** và thông báo lỗi, kèm phiên bản Windows/LDPlayer để đối chiếu. Không cần cung cấp thông tin đăng nhập Facebook.

## Chèn logo PNG

Giao diện hai cột: bên trái là cài đặt và tiến trình/kho video; bên phải là trình xem video có chiều cao riêng.

Để sửa logo trên video đã xuất, mở video bằng **Xem** trong **Kho Video** (hoặc video đang nghiệm thu), chỉnh ảnh/kích thước/độ mờ/chế độ rồi bấm **Áp dụng logo · Sửa lại video**. App dùng lại `-1-video-goc.mp4` và `-2-am-thanh-tho.m4a`, không tải hay thu âm lại, rồi thay bản `-3-hoan-chinh.mp4` khi xuất thành công. Mỗi lần sửa dùng bản gốc sạch để không chồng logo. Bỏ chọn **Chèn logo** rồi áp dụng để xuất lại không có logo. Nếu thiếu file nguồn/audio, app báo lỗi và giữ bản hiện có. Video lỗi hoặc tác vụ bị hủy không thay bản cũ.

Bật **Chèn logo**, bấm **Chọn PNG...** để chọn logo đã tách nền trên máy; nút **Logo Kid** dùng lại logo chữ gỗ mộc có sẵn. Kéo **Kích thước** từ 5–60% chiều rộng video (mặc định 30%); ảnh giữ tỷ lệ và giới hạn chiều cao tối đa 60% khung hình để không tràn. Độ mờ từ 0–95% (mặc định 60%); mờ 60% nghĩa là độ đậm còn 40%.

Sau khi chọn ảnh, khung logo hiển thị ảnh xem trước, tên file đang dùng và đường dẫn (có thể chọn/copy, rê chuột để xem đầy đủ). Logo mặc định có dấu **✓ Logo Kid** và trạng thái **Đang dùng: Logo Kid**.

Chọn **Tự do · di chuyển** để logo di chuyển theo đường cong mềm trong khung hình; phần vị trí được ẩn hoàn toàn. Chọn **Cố định · đứng yên** mới hiện lựa chọn bốn góc hay giữa. Video gốc và audio tách vẫn được giữ riêng. Chèn logo cần mã hóa lại hình ảnh bằng H.264 nên có thể lâu hơn khi tắt logo; độ phân giải và audio được giữ nguyên.

Có thể tạo bản thử từ một video đã có mà không mở Facebook/Android:

```powershell
.\core\kid-fby.ps1 -WatermarkVideo '.\output\video-hoan-chinh.mp4' -LogoFade 60
.\core\kid-fby.ps1 -WatermarkVideo '.\output\video-khac.mp4' -LogoFile 'C:\Logo\logo.png' -LogoSize 15 -LogoFade 50 -LogoMotion Fixed -LogoPosition TopRight
```

Xuất file `video-hoan-chinh-logo-preview.mp4` cạnh file đầu vào, không ghi đè video gốc hoặc bản thử đã có. Logo được đóng gói trong `core/kid-logo.zip` và nhúng vào EXE để máy mới/cập nhật nhận đủ file.

## Chỉnh logo, GIF và kiểm tra link

Logo và GIF có tám tay kéo: kéo cạnh đổi riêng chiều rộng hoặc chiều cao, kéo góc đổi cả hai mà không khóa tỉ lệ ảnh. Nút **Phủ đầy khung video** giãn GIF kín khung. Thanh kích thước/lăn chuột trở lại chế độ giữ tỉ lệ nguồn. GIF trong suốt giữ alpha trong preview và video xuất.

Thanh tua có một hàng riêng; bấm/kéo hoặc dùng phím trái/phải để tua ba giây khi xem video, kể cả ở Kho video.

ID lặp trong danh sách chỉ được xử lý một lần. Với link chứa ID Reel/video trực tiếp, ứng dụng kiểm tra file video gốc hoặc hoàn tất có cùng ID trong thư mục xuất hiện tại và cảnh báo đã tải; khi bắt đầu có thể tải lại, bỏ qua hoặc hủy. Link chia sẻ/rút gọn chưa có ID không được suy đoán từ token.

## Build và phát hành

Trên Windows x64, chạy `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\build-local.ps1`. Script đồng bộ nguồn GIF nhúng, kiểm tra cú pháp, biên dịch EXE và chạy SelfTest trong thư mục tạm, đối chiếu bảy tài nguyên nhúng. Lệnh này không đổi phiên bản, commit, tag hoặc push.

`publish.ps1` dùng cùng luồng build trước khi tạo manifest và phát hành. Chỉ chạy khi chủ động phát hành phiên bản mới; dùng `-NoPush` nếu chỉ muốn chuẩn bị bản phát hành cục bộ.

`tools/` chứa công cụ/model và `output/` chứa video người dùng; cả hai được Git bỏ qua. Báo cáo và fixture kiểm thử không nằm trong cây dự án phát hành.
