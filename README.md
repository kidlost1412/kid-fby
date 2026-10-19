# Kid FB.Y

Ứng dụng Windows tải hình video Facebook, điều khiển Facebook trên Android để chọn Tiếng Việt, thu audio bằng scrcpy và ghép file MP4 bằng FFmpeg. Phiên bản trong `core/version.txt`; tài liệu này mô tả cách sử dụng, không phải chứng nhận chất lượng hoặc tương thích.

## Bắt đầu

1. Giữ `Kid-FB.Y.exe` cùng thư mục `core` của dự án, giải nén ZIP trước khi chạy. Cần thư mục có quyền ghi.
2. Mở Facebook đã đăng nhập trên Android/LDPlayer và bật ADB. Mã kiểm tra Android từ 11; việc thu âm còn phụ thuộc thiết bị và chính sách capture của ứng dụng.
3. Trong **Bộ Thư Viện**, cài scrcpy/ADB, yt-dlp và FFmpeg/ffprobe. **Cài tất cả** còn cài Whisper tiny tùy chọn; tải video thông thường không cần model này.
4. Bấm **Kiểm tra máy**, dán link rồi bấm **Tự động tải hết danh sách**. Link Reel, video và một số dạng share/fb.watch được phân tích hoặc thử chuyển sang URL trực tiếp.
5. Đợi ứng dụng thu âm; tránh thao tác lên Android đang được dùng. Video được lưu rồi chuyển mục kế tiếp, không có bước duyệt từng video. **Dừng** dừng cả hàng đợi; cuối lượt có tổng kết và link lỗi trong Logs.

Không cần Python, Node.js hay dịch vụ backend riêng để chạy luồng thông thường. Các công cụ tải ngoài nằm trong `tools/`, không nằm trong bản ZIP Git.

## Ngôn ngữ và dữ liệu

Điều kiện tải dựa vào UI Meta: app đọc bộ chọn ngôn ngữ, thử chọn Tiếng Việt một lần và quan sát dấu chọn hoặc việc trở về Reel. Đây là suy luận từ UI, không xác minh nội dung lời nói bằng audio. Không có bước AI của dự án tự dịch video.

Menu đầy đủ được xác định không có bản dịch sẽ được lưu vào `data/rejected-videos.json`; app thử dọn file đúng ID rồi bỏ qua ID đó ở lần sau. Trạng thái UI chưa rõ dừng mục hiện tại, không tự loại vĩnh viễn. Lịch sử cũ có thể chứa lý do từ chính sách nhận diện audio trước đây.

Mỗi video thường có ba file:

| Tên | Nội dung theo luồng xuất |
| --- | --- |
| `ID-1-video-goc.mp4` | Phần hình không audio; có thể đã được chuyển mã |
| `ID-2-am-thanh-tho.m4a` | Audio đã cắt, loudnorm và mã hóa AAC; tên cũ không có nghĩa là bản ghi thô nguyên vẹn |
| `ID-3-hoan-chinh.mp4` | Hình ghép với audio và lớp phủ đã chọn |

Giữ cả ba file nếu muốn sửa logo/GIF sau này. `output/reup-status.json` là đánh dấu đã đăng do người dùng nhập; app không tự đăng lên TikTok. `data/`, `output/`, `tools/` và trạng thái cập nhật được Git bỏ qua.

## Xem lại và chỉnh lớp phủ

Trong **Kho Video**, có các thao tác Xem, Copy file, mở vị trí, Xóa và đánh dấu đã đăng. **Ghi âm lại** tạo một lượt riêng theo ID trong tên file, tại thư mục video đang chọn. Lỗi tạm thời hoặc Dừng giữ các bản cũ; chính sách loại vì không có bản dịch vẫn áp dụng.

Logo PNG và GIF có kéo vị trí, tám tay chỉnh rộng/cao và nút GIF **Phủ đầy khung video**. `Free` là chuyển động theo biểu thức; `Fixed` dùng preset hoặc tọa độ tùy chỉnh. Preview và bản xuất dùng hai bộ dựng khác nhau: WPF/C# và FFmpeg.

**Áp dụng logo · Sửa lại video** dùng lại file `-1` và `-2`, không tải/thu âm lại. Thiếu đầu vào sẽ báo lỗi. Thanh tua và phím trái/phải thay đổi vị trí xem. Track Audio mở file `-2`; Track Video mở bản `-3`.

## Lệnh cục bộ

```powershell
# Kiểm tra thiết bị/công cụ
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 -Check
# Tải một video; thay URL bằng đầu vào được phép sử dụng
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 'https://www.facebook.com/reel/VIDEO_ID/'
# Chẩn đoán ngôn ngữ độc lập, không dùng làm điều kiện tải
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 -DetectLanguageFile 'C:\media\audio.m4a'
# Biên dịch cục bộ và kiểm khởi tạo/tài nguyên
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\build-local.ps1
```

Build không làm mới manifest. `publish.ps1 -Version x.y.z -NoPush` chuẩn bị phiên bản mới và manifest, vẫn thay file cục bộ. Không chạy `publish.ps1` không có `-NoPush` nếu chưa muốn commit/tag/push. Chép riêng EXE mới lên thư mục `core` cũ không cập nhật các script đã tồn tại; xem cơ chế cập nhật trong bàn giao.

## Đọc tiếp

- [BAN-GIAO.md](BAN-GIAO.md): kiến trúc, thuật toán, dữ liệu, build/cập nhật, giới hạn và kiểm chứng.
- [AGENTS.md](AGENTS.md): điểm bắt đầu cho AI tiếp tục làm việc.
