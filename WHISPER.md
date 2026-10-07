# Nhận diện ngôn ngữ thử nghiệm bằng Whisper tiny

Trong giao diện, bật **Nhận diện tiếng Việt bằng tiny** để kiểm tra audio sau khi cắt/chuẩn hóa. Tính năng mặc định bật; có thể tắt trước khi chạy để bỏ hoàn toàn bước này. Kết quả là ước tính ngôn ngữ của đoạn mẫu, không phải chứng nhận toàn bộ video nói cùng một ngôn ngữ.

Tại tab **Công cụ**, nút cài **Whisper tiny** tải bộ CPU và model một lần vào `tools/whisper`. Cài tất cả công cụ cũng cài tiny. Thiếu model hoặc nhận diện lỗi không chặn tải/thu/xuất video; app báo chưa xác định để nghe nghiệm thu. Không tự tải model giữa lúc xử lý video.

Mỗi video dùng tối đa hai đoạn không chồng nhau, mỗi đoạn tối đa sáu giây. Đoạn đầu cho điểm model từ 0,85 trở lên thì dừng ngay. Nếu chưa rõ và video còn đủ dài, thử thêm một đoạn. Đoạn quá ngắn/im lặng bị bỏ qua; toàn bộ bước nhận diện có ngân sách chờ tiến trình 20 giây. Điểm 0,85 là ngưỡng thử nghiệm, không có nghĩa chính xác 85%.

Audio mẫu được giải mã thành mono 16 kHz để chạy CPU với bốn luồng. Không phiên âm, không dịch, không đổi file audio/video xuất. Audio được xử lý cục bộ; mạng chỉ dùng khi cài tool/model. Nhạc nền, tiếng ồn, nhiều ngôn ngữ hoặc giọng khó nghe vẫn có thể gây đoán sai, nên giữ bước nghiệm thu bằng tai.

Để thử riêng một file có sẵn, không kết nối Android:

```powershell
.\core\kid-fby.ps1 -DetectLanguageFile 'C:\duong-dan\audio.m4a'
```

Để cài riêng từ dòng lệnh:

```powershell
.\core\kid-fby.ps1 -SetupTool whisper
```

Bản tích hợp dùng [whisper.cpp v1.8.2 CPU x64](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.2) và [tiny đa ngôn ngữ](https://huggingface.co/ggerganov/whisper.cpp). URL/revision và SHA256 được cố định; file tải phải khớp trước khi cài. Không cần Python/CUDA. Thư mục `tools` được Git bỏ qua, nên máy khác cần cài một lần hoặc mang theo thư mục này.

Kiểm tra bằng model thật: `tests/whisper-media.ps1`. Bộ kiểm tra này không tải model, không gọi Android và bỏ qua nếu tool tùy chọn chưa được cài.

## Kết quả thử bản 1.0.10 — 07/10/2026

Máy hiện tại: Intel Core i5-13400F, tiny CPU bốn luồng. Đã cài thật bộ ZIP và model có kiểm SHA256, chạy trên thư mục trống, rồi cài lại để xác nhận tái sử dụng model. Build EXE có nhúng helper và manifest khớp cả chín file. Chưa push GitHub.

| Mẫu thử | Kết quả | Thời gian toàn bước lấy mẫu + nhận diện |
|---|---|---|
| Ba mẫu giọng Việt FLEURS, chuẩn hóa như audio của app | Cả ba trả `vi`, một mẫu lấy audio mỗi file | 1,10–1,24 giây |
| Giọng Anh tạo bằng voice có sẵn trên Windows | Trả `en`, một mẫu | Khoảng 1,25 giây |
| Một mẫu tiếng Việt thô rất nhỏ tiếng | Chưa xác định; không đủ audio sau lọc khoảng lặng | Khoảng 0,26 giây |
| Tone 440 Hz sáu giây | Chưa xác định, điểm model thấp | Khoảng 1,12 giây |
| Im lặng mười giây | Chưa xác định | Khoảng 0,33 giây |
| Audio dưới hai giây | Chưa xác định, không chạy tiny | Chỉ probe thời lượng |

Ba bản ghi tiếng Việt lấy từ [Google FLEURS](https://huggingface.co/datasets/google/fleurs), giấy phép CC-BY-4.0. Thông tin nguồn và tên bản ghi gốc được lưu trong `diagnostics/whisper-trial/fleurs-attribution.json`; số đo chi tiết nằm trong `benchmark.json` cùng thư mục. Đây là mẫu đọc có sẵn, chưa phải Reel Facebook/Meta dub thực tế. Số đo trên không dự đoán độ chính xác hoặc thời gian trên mọi máy/video.

Kiểm tra Windows PowerShell 5.1 đã qua: startup/render WPF và helper nhúng; các test cũ về process/rollback/file; parser log thật; một/hai mẫu và điểm thấp; lỗi model/cancellation cleanup; installer hủy giữa chừng khôi phục bản cũ; GUI tokens; model thật với tiếng Anh/im lặng/mẫu ngắn. Test tích hợp engine cũng xác nhận tắt checkbox bỏ classifier, còn ngôn ngữ khác hoặc lỗi model vẫn xuất đủ file và trả kết quả nghiệm thu. Giao diện XAML đã được render và xem lại. Chưa chạy lại toàn bộ thu/xử lý một Reel trên LDPlayer.

## Thử lại theo nguồn video thường dùng của anh

Anh xác định nguồn tiếng gốc chủ yếu là Ấn Độ, Campuchia, Thái Lan và Trung Quốc. Mẫu tiếng Anh bên trên chỉ kiểm tra runtime, không đại diện cho các nguồn này. Tiny đang tự dò mọi ngôn ngữ nó hỗ trợ; code không ép ngôn ngữ tiếng Anh.

Đã lấy thêm 21 bản ghi FLEURS: ba mẫu mỗi ngôn ngữ, chuẩn hóa bằng cùng bộ lọc loudnorm của app và gọi hàm nhận diện thật ở bản 1.0.10. Bốn ngôn ngữ Ấn Độ dưới đây chỉ là một phần, không đại diện cho mọi video từ Ấn Độ. Mẫu Trung Quốc là Quan thoại, chưa thử Quảng Đông/phương ngữ khác.

| Ngôn ngữ nguồn | Đúng tên ngôn ngữ và đủ điểm | Chưa xác định | Đủ điểm nhưng sai tên | Thời gian mỗi file |
|---|---|---|---|---|
| Khmer | 0/3 | 2/3 | 1/3, bị đoán `en` với điểm 0,9884 | 2,26–2,53 giây |
| Thái | 3/3 | 0/3 | 0/3 | 1,14–1,22 giây |
| Quan thoại | 3/3 | 0/3 | 0/3 | 1,19–1,29 giây |
| Hindi | 3/3 | 0/3 | 0/3 | 1,21–2,49 giây |
| Tamil | 1/3 | 2/3 | 0/3 | 1,18–2,22 giây |
| Telugu | 0/3 | 3/3 | 0/3 | 1,21–2,49 giây |
| Bengali | 2/3 | 1/3 | 0/3 | 1,24–2,53 giây |

Trong 21 mẫu này, chưa mẫu nào được trả về **detected/vi**. Điều đó chưa chứng minh tool sẽ luôn phân biệt đúng tiếng Việt với các nguồn trên. Tiny yếu ở Khmer và một số ngôn ngữ Ấn Độ trong bộ thử nhỏ này; điểm cao cũng có thể sai tên ngôn ngữ. Không nên coi “ngôn ngữ khác” là đã xác nhận chính xác ngôn ngữ gốc, hoặc coi một mẫu `vi` là bảo đảm cả video đã lồng tiếng Việt.

Mục đích thực tế của tính năng vẫn là hỗ trợ quyết định **có vẻ là tiếng Việt / có vẻ là ngôn ngữ khác / chưa rõ**. Khi tiếng gốc còn phát, UI không tự xóa, tự bỏ qua hoặc tự ghi lại video. Mẫu khó cần nghe nghiệm thu. Chưa đo trên Reel thực tế với nhạc, tiếng ồn, nhiều giọng hoặc Meta dub.

Nguồn CC-BY-4.0 và tên bản ghi gốc: `diagnostics/whisper-trial/target-languages/attribution.json`; kết quả từng file: `benchmark.json` cùng thư mục. Script lấy mẫu/đo nằm trong `diagnostics/whisper-trial`; không tải nguyên kho dữ liệu, không thêm model hay đổi thuật toán của app trong lần thử này.
