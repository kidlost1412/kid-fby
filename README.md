# Kid FB.Y

Ứng dụng Windows tải hình video Facebook, điều khiển Facebook trên Android để chọn Tiếng Việt, thu âm thanh kèm hình màn hình bằng scrcpy, khớp với video tải về rồi ghép MP4 bằng FFmpeg. Phiên bản trong `core/version.txt`; tài liệu này mô tả cách sử dụng, không phải chứng nhận chất lượng hoặc tương thích.

## Bắt đầu

1. Giữ `Kid-FB.Y.exe` cùng thư mục `core` của dự án, giải nén ZIP trước khi chạy. Cần thư mục có quyền ghi. Mỗi thư mục cài chỉ chạy được một cửa sổ; mở lần hai sẽ đưa cửa sổ đang chạy lên trước (không tìm được cửa sổ thì mới báo đang chạy).
2. Mở Facebook đã đăng nhập trên Android/LDPlayer và bật ADB. Mã chặn Android dưới 11; việc thu âm còn phụ thuộc thiết bị và chính sách capture của ứng dụng. Khi chạy, app đặt âm lượng media của thiết bị lên mức cao nhất và force-stop rồi mở lại Facebook nhiều lần.
3. Trong **Cài đặt › Công cụ**, cài scrcpy/ADB, yt-dlp và FFmpeg/ffprobe. **Cài tất cả** chỉ gồm ba nhóm này; Whisper tiny là mục riêng, tùy chọn, và tải video thông thường không cần nó. Bộ cài tải trực tiếp chỉ từ nguồn chính thức qua HTTPS (GitHub của scrcpy/yt-dlp, gyan.dev hoặc BtbN cho FFmpeg) và bắt buộc khớp SHA256 do chính nguồn đó công bố; WinGet và việc chép công cụ có sẵn trên máy hoặc từ LDPlayer là đường riêng, không qua bước SHA256 này.
4. Bấm **Kiểm tra máy**, dán link ở trang **Nguồn** rồi bắt đầu từ thanh hành động phía dưới. Link Reel, video và một số dạng share/fb.watch được phân tích hoặc thử chuyển sang URL trực tiếp; link được chuẩn hóa (host `m.`/`mbasic.` thành `www.`, bỏ tham số theo dõi) trước khi tìm trùng.
5. Đợi ứng dụng thu âm; tránh thao tác lên Android đang được dùng. Video được lưu rồi chuyển mục kế tiếp, không có bước duyệt từng video. **Dừng** (nút chính hoặc `Esc`) hỏi xác nhận nếu hàng đợi còn mục chưa chạy. Cuối lượt có tổng kết; mục dừng giữa chừng ghi "Đã dừng", không ghi "Hoàn tất".

Không cần Python, Node.js hay dịch vụ backend riêng để chạy luồng thông thường. Các công cụ tải ngoài nằm trong `tools/`, không nằm trong bản ZIP Git.

## Đồng bộ tiếng với hình

Lần thu chỉ cắt đúng đoạn nếu biết Reel bắt đầu phát lúc nào trong bản thu. App làm như sau:

1. scrcpy ghi cả hình màn hình độ phân giải thấp (480 px, 30 fps) và âm thanh vào một file `rec.mkv` cùng đồng hồ.
2. Sau khi tải video gốc, so chữ ký khung hình của video gốc với hình màn hình để tìm thời điểm bắt đầu `t0`, kèm độ tin cậy và độ trôi giữa các đoạn. Cắt âm thanh tại `t0`.
3. Reel tự phát lặp trong bản thu không làm khớp thất bại: app nhận ra các đỉnh cách nhau bằng bội số thời lượng video, chọn lần phát sớm nhất hợp lệ và ghi `SYNC_LOOP` vào log. Nếu không thấy đầu video trong bản thu (`start-missing`), khớp không đủ tin cậy (`low-confidence`) hoặc bản thu ngắn hơn video, app thu lại đúng một lần. Vẫn không đạt thì mục đó ở trạng thái "chưa xác nhận" và **không xuất bản**.
4. Độ trôi lớn hơn 80 ms giữa các đoạn vẫn xuất bản nhưng có cảnh báo ở hàng đợi và log.
5. Chỉ khi thiết bị không ghi hình được **và** bạn bật **Cài đặt › Tùy chọn › Cho phép đồng bộ theo âm thanh**, app mới dùng điểm bắt đầu tiếng (onset) làm phương án thay thế; cách này kém chính xác, có thể lệch cỡ 0,5–1,2 s theo số đo của dự án. Mặc định tắt.

Đã kiểm bằng khớp khung hình trên các Reel mẫu, chưa nghe/xem kiểm lệch tiếng–hình bằng tai. Đường tự thu lại và nhận Reel tự lặp mới chạy qua giả lập/fixture, chưa thử Reel tự lặp thật trên Android. Giới hạn đã biết: Reel ngắn dưới 2 giây và tiếng ngắt quãng (onset) khó khớp ổn định. Video xuất từ bản cũ (dùng onset) có thể có tiếng sớm hơn hình nửa giây đến khoảng một giây; đó là suy từ số đo, chưa kiểm bằng nghe.

## Ngôn ngữ và dữ liệu

Điều kiện tải dựa vào UI Meta: app đọc bộ chọn ngôn ngữ, thử chọn Tiếng Việt một lần và quan sát dấu chọn hoặc việc trở về Reel. Đây là suy luận từ UI, không xác minh nội dung lời nói bằng audio. Không có bước AI của dự án tự dịch video. Whisper chỉ là chẩn đoán tùy chọn bằng lệnh riêng, không tham gia chấp nhận hay từ chối video.

Menu đầy đủ, đọc ổn định (ít nhất ba lần, kéo dài từ hai giây), cho thấy không có bản dịch sẽ được lưu vào `data/rejected-videos.json` kèm trường `Evidence` (đoạn văn bản UI đã đọc). Nếu `data/rejected-videos.json` bị hỏng, app không làm hỏng các link khác: file được đổi tên `rejected-videos.json.corrupt-<thời gian>-<id>` (giữ để khôi phục tay), lịch sử coi như rỗng và các lần ghi sau được ghi bền (Flush) rồi mới thay file. **Việc loại không xóa file nào** đã có trong thư mục xuất; nó chỉ khiến ID đó bị bỏ qua ở lần sau. Trạng thái UI chưa rõ dừng mục hiện tại, không tự loại vĩnh viễn. Trong **Kho › Lịch sử đã loại** có nút **Bỏ loại** để gỡ một mục khỏi lịch sử; chạy engine bằng `-ForceRetryRejected` (hoặc **Ghi âm lại**) bỏ qua lịch sử cho link đó và gỡ mục nếu lần này thành công. Lịch sử cũ có thể chứa lý do từ chính sách nhận diện audio trước đây.

Thư mục xuất chỉ hiện **một file mỗi video** (nếu `-3` đích đang được mở ở ứng dụng khác, mục đó dừng sớm với "File video đang được mở ở ứng dụng khác" và không đụng vào file nào; thư mục giao dịch xuất bản tạm nằm trong `.cache\.kidfby-publish-*`):

| Vị trí | Nội dung |
| --- | --- |
| `ID-3-hoan-chinh.mp4` | Hình ghép với audio và lớp phủ đã chọn |
| `.cache\ID-1-video-goc.mp4` (ẩn) | Phần hình không audio; có thể đã được chuyển mã |
| `.cache\ID-2-am-thanh-tho.m4a` (ẩn) | Audio đã cắt, loudnorm và mã hóa AAC; tên cũ không có nghĩa là bản ghi thô nguyên vẹn |
| `.cache\thumbs\` | Ảnh thu nhỏ của Kho, tự tạo lại được |

File `-1`/`-2` trong `.cache` là đầu vào của **Áp dụng logo · Sửa lại video**; xóa chúng thì không sửa lại logo/GIF mà không tải và thu lại. Bản cũ để `-1`/`-2` ngay trong thư mục xuất vẫn dùng được (chương trình tìm `.cache` trước, rồi tới thư mục xuất); app không tự di chuyển hay xóa chúng. **Cài đặt › Tùy chọn › Lưu trữ** có **Dọn file trung gian cũ** (chuyển vào `.cache` hoặc xóa vĩnh viễn, nút mặc định là Hủy) và **Dọn cache sửa lại** (xóa cả `.cache`). `output/reup-status.json` là đánh dấu đã đăng do người dùng nhập; app không tự đăng lên TikTok. `data/`, `output/`, `logs/`, `tools/` và trạng thái cập nhật được Git bỏ qua.

Dữ liệu khác: `data/settings.json` (cài đặt giao diện, logo/GIF, công tắc đồng bộ; nếu file bị khóa tạm khi đọc, app thử lại 3 lần, vẫn lỗi thì dùng mặc định và **không ghi** settings trong phiên đó, có thông báo), `logs/` cạnh thư mục `core` gồm `gui-*.log`, `crash-*.log`, `launcher-*.log`, `updater-*.log`. Log và crash của GUI cũ hơn 14 ngày bị xóa khi khởi động.

## Xem lại và chỉnh lớp phủ

Trong **Kho**, có các thao tác Xem, Copy file, mở vị trí, Xóa và đánh dấu đã đăng. **Xóa** gỡ file `-3`, `-1`/`-2` trong `.cache` (và file cũ ở thư mục xuất nếu có) cùng ảnh thu nhỏ của video đó, sau khi xác nhận. **Ghi âm lại** tạo một lượt riêng theo ID trong tên file, tại thư mục video đang chọn. Lỗi tạm thời hoặc Dừng giữ các bản cũ.

Logo PNG và GIF có kéo vị trí, tám tay chỉnh rộng/cao và nút GIF **Phủ đầy khung video**. `Free` là chuyển động theo biểu thức; `Fixed` dùng preset hoặc tọa độ tùy chỉnh. Preview và bản xuất dùng hai bộ dựng khác nhau: WPF/C# và FFmpeg.

**Áp dụng logo · Sửa lại video** dùng lại `-1` và `-2`, không tải/thu âm lại. Thiếu đầu vào sẽ báo lỗi. Thanh tua và phím trái/phải thay đổi vị trí xem; phím `F` hoặc nút ⤢ mở **Xem lớn**, `Esc` thoát. Track Audio mở file `-2`; Track Video mở bản `-3`.

## Giao diện

Giao diện phong cách "cute" (nền kem, màu pastel, viền nâu bo tròn, bóng cứng kiểu sticker), lấy hướng thẩm mỹ từ phong cách `cute` của baoyu-skills (MIT) và tự dựng lại bằng XAML. Theme và cây cửa sổ nằm ở `core/ui/Theme.xaml`, `core/ui/MainWindow.xaml`; phông Nunito (SIL OFL 1.1) ở `core/ui/fonts/`, thiếu phông thì dùng Segoe UI. Năm trang: Nguồn, Thương hiệu, Hàng đợi, Kho, Cài đặt. Đặc điểm của khung xem trước và bố cục:

- Video 9:16 không còn vỏ điện thoại, chỉ viền sticker; nhãn độ phân giải và nút ⤢ phủ ở góc, thanh tua + Phát/Tạm dừng phủ ở đáy và tự ẩn sau 2 giây không rê chuột. **Xem lớn** (nút ⤢, phím `F`, nhấp đúp thẻ Kho; `Esc` thoát) cho video chiếm cả thân cửa sổ. Kích thước khung tính theo chiều cao cửa sổ; video ngang giữ đúng tỉ lệ.
- Khi chiều cao logic dưới 640 px (ví dụ DPI 125/150%) giao diện vào chế độ gọn: sidebar thu nhỏ, ẩn trang trí, các trang cuộn được; khung xem trước quá nhỏ thì ẩn và chỉ dùng Xem lớn.
- Kho là lưới ảo hóa 3–4 cột. Thông báo (toast) ở góc dưới phải, tối đa 2 cái, cũ hơn gộp "+N". Mục "chưa xác nhận" có pill riêng, không tính vào lỗi. Mọi vùng bấm tối thiểu 44×44.
- Trang **Giới thiệu** ghi công baoyu-skills (Jim Liu, MIT) và phông Nunito (SIL OFL 1.1).

## Lệnh cục bộ

```powershell
# Kiểm tra thiết bị/công cụ
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 -Check
# Tải một video; thay URL bằng đầu vào được phép sử dụng
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 'https://www.facebook.com/reel/VIDEO_ID/'
# Bỏ qua lịch sử loại cho link này / cho phép đồng bộ theo onset khi không thu được hình
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 'https://www.facebook.com/reel/VIDEO_ID/' -ForceRetryRejected -AllowOnsetSync
# Chẩn đoán ngôn ngữ độc lập, không dùng làm điều kiện tải
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 -DetectLanguageFile 'C:\media\audio.m4a'
# Biên dịch cục bộ và kiểm khởi tạo/tài nguyên
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\build-local.ps1
```

Engine in thêm các dòng máy đọc `@@KIDFBY_STAGE` và `@@KIDFBY_RESULT` (định dạng trong bàn giao); GUI ẩn chúng khỏi log hiển thị.

Build không làm mới manifest. `publish.ps1 -Version x.y.z -NoPush` chuẩn bị phiên bản mới, ký manifest và ghi `version.json`/`version.json.sig`, vẫn thay file cục bộ. Không chạy `publish.ps1` không có `-NoPush` nếu chưa muốn commit/tag/push. Chép riêng EXE mới lên thư mục `core` cũ không cập nhật các script đã tồn tại; xem cơ chế cập nhật trong bàn giao.

**Trạng thái cập nhật tự động:** bản 2.1.0 đã phát hành (tag `v2.1.0` trên GitHub); `version.json` và `version.json.sig` đã ký RSA-SHA256 và nằm trên nhánh `main`. Khóa công khai đã gắn trong `core/updater.ps1`. Khóa riêng nằm ngoài repo ở `%USERPROFILE%\.kidfby\update-signing-private.xml` trên máy phát hành; **phải sao lưu**, vì mất khóa thì không phát hành được cập nhật cho máy đã cài. Không đưa khóa riêng vào repo. Đã kiểm đường cập nhật thật từ 2.0.1 lên 2.1.0. Lưu ý: sau khi cập nhật từ 2.0.1, mở app thêm một lần để có phông Nunito, vì phông không nằm trong manifest mà đến qua EXE mới.

## Đọc tiếp

- [BAN-GIAO.md](BAN-GIAO.md): kiến trúc, thuật toán, dữ liệu, build/cập nhật, giới hạn và kiểm chứng.
- [AGENTS.md](AGENTS.md): điểm bắt đầu cho AI tiếp tục làm việc.
