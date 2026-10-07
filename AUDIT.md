# Đánh giá lại Kid FB.Y — 07/10/2026

Bản sửa trước: 1.0.8. Đợt này chỉ xử lý lỗi có bằng chứng rõ và cách sửa vừa sức với tool hiện tại. Không coi 21 nhận xét trước là 21 lỗi đang xảy ra trên máy anh. Một nhánh code có thể sai trong tình huống cụ thể nhưng các video gần đây vẫn chạy đúng.

## Hai điểm cần điều chỉnh kết luận

**Căn âm thanh:** đã tái hiện nhánh sai bằng log mô phỏng, chưa thử trên một video Facebook thật. Quy trình hiện tại bắt đầu thu trước khi mở Reel khoảng 1,8 giây, nên thường có khoảng lặng đầu và nhánh sai có thể không được dùng. Trải nghiệm các video gần đây của anh là bằng chứng cần tôn trọng. Giữ nguyên Get-AudioOnset và mọi mốc cắt/thu/chuẩn hóa; chỉ cho thời gian xử lý FFmpeg đủ dài. Chỉ nên chỉnh thuật toán sau khi có video thật bị lệch kèm file ghi thô để đối chiếu.

**Tiếng Việt:** không đọc thấy dòng ngôn ngữ từ UI chưa chứng minh video không hỗ trợ hoặc không đang phát tiếng Việt. UI có thể đổi bố cục hoặc dump thiếu. Đợt này chỉ phân biệt “đã gửi lựa chọn trên UI” với “chưa xác nhận được”; cả hai vẫn cần nghe nghiệm thu. Không bổ sung model và không tự chặn video khi UI chưa rõ. Đây là sửa cách thông báo, chưa phải xác minh tiếng nói tự động.

Whisper tiny đa ngôn ngữ hỗ trợ nhận diện ngôn ngữ; tiny.en chỉ dành cho tiếng Anh. Nó cần tải model/runtime và đọc audio, còn chi phí/tốc độ trên máy anh chưa được đo. Nếu sau này có nhu cầu bỏ nghe nghiệm thu, có thể thử nhận diện một đoạn có lời nói khi UI chưa rõ; không đặt thành bước bắt buộc cho tất cả video. Nguồn: https://github.com/openai/whisper

## Đánh giá lại toàn bộ nhận xét trước

| Nhận xét | Tính thực tế | Quyết định đợt này |
|---|---|---|
| Tìm sai onset | Nhánh sai được mô phỏng; chưa chứng minh ảnh hưởng video thật, quy trình thường có khoảng lặng đầu. | Giữ thuật toán. Cần ca video thật trước khi sửa căn tiếng. |
| Không xác nhận tiếng Việt vẫn tiếp tục | Thiếu bằng chứng ngôn ngữ; việc tiếp tục để nghe nghiệm thu vẫn hợp lý. | Sửa log/status cho trung thực, không thêm Whisper và không chặn khi chưa rõ. |
| Dừng mọi tiến trình cùng tên | Lệnh kill toàn máy tồn tại và còn được gọi ở nhánh hoàn tất. Có thể ảnh hưởng tác vụ khác nếu đang chạy. | Theo dõi tiến trình do tác vụ tạo; hoàn tất bình thường chỉ thu hồi tài nguyên. |
| Ghi lại xóa bản cũ trước | Hành vi trực tiếp trong BtnRedo. Mất bản cũ nếu lần ghi mới lỗi. | Giữ bản cũ, tạo đủ bộ file mới trước khi thay; khôi phục nếu thay thất bại. |
| Bỏ kiểm chứng TLS/checksum tool | Đúng là hardening còn thiếu; chưa có bằng chứng file tải bị can thiệp. Các nguồn chính là GitHub/Gyan. | Chưa đổi downloader vì từng có fallback phục vụ máy/mạng khác; cần kiểm cài tool thực tế riêng trước. Không mô tả như lỗi đang bị khai thác. |
| Không xét mã thoát / nhận file dang dở | Điều kiện “file tồn tại” không đủ nếu download/FFmpeg bị ngắt. | Kiểm mã thoát, loại .part/.ytdl/.tmp, probe final và chỉ nhận file hoàn tất. |
| Timeout 15 giây cho media | Giới hạn cứng có thể không đủ cho video/mạng chậm. Không biết video anh đã gặp chưa. | Giữ timeout ngắn cho ADB; đặt giới hạn riêng cho tải và media. Trần cao hơn không làm tác vụ bình thường chạy lâu hơn. |
| Chờ scrcpy vô hạn | scrcpy vốn có time-limit nên bình thường tự thoát; watchdog chỉ phòng treo. | Thêm giới hạn thời lượng thu + 30 giây, không đổi thời lượng thu/flags. |
| Log scrcpy đọc file không được ghi | Xác nhận từ code. Bình thường không ảnh hưởng audio; khi lỗi thì mất thông tin. | Đọc stderr thực tế của tiến trình. |
| Runspace chưa EndInvoke/Dispose và thiếu error log | Code chưa thu hồi theo vòng đời hoàn tất/hủy. Không đủ bằng chứng đã rò RAM nghiêm trọng. | Hoàn tất/hủy đúng trình tự và hiển thị lỗi thật. Đóng cửa sổ chờ hủy/dọn xong rồi thoát; không xây framework mới. |
| Đổi output/review trong lúc chạy | Các nút có thể làm thay đổi dữ liệu của tác vụ/hàng đợi. Kiểm tra/cài công cụ khi chờ nghiệm thu có thể ẩn bảng nghiệm thu và làm kẹt hàng đợi. | Khóa output khi bận, chặn xem/xóa kho và kiểm tra/cài công cụ khi hàng đợi chưa xong. Ghi lại lịch sử được thông báo không hỗ trợ, không tự đoán URL. |
| Đường dẫn chứa dấu nháy đơn | Đường dẫn hiện tại không chứa ký tự đó; chỉ lỗi khi đổi tên thư mục phù hợp. | Bỏ ghép đường dẫn vào code, dùng LiteralPath. Sửa nhỏ, có kiểm thử. |
| Một EXE thiếu updater/config/version | Chỉ đúng nếu mang mỗi EXE sang máy trống; gói GitHub đủ core không vướng. | Giữ cách đóng gói hiện tại, tài liệu yêu cầu đi kèm core. Không redesign portable. |
| Stage/status cũ hoặc chạy updater song song | Launcher 1.0.8 đã chặn downgrade. Các tình huống status cũ/song song chưa tái hiện. | Giữ cơ chế hiện tại; chưa thêm lock/job protocol. |
| Rollback có thể thiếu, stage bị đổi, nhiều launcher | Cần lock/IO failure/multiple-launcher để phát sinh; chưa tái hiện sự cố EXE thật. | Không mở rộng updater đợt này; backup trùng và downgrade đã được sửa ở 1.0.8. |
| Publish báo thành công khi Git thất bại | Không kiểm native exit code là thiếu sót rõ. Version ghi trước build chỉ ảnh hưởng quy trình dev khi build lỗi. | Kiểm exit code từng bước Git, không force ghi đè tag. Chưa thêm release transaction. |
| minLauncher/mandatory chưa được thực thi đúng nghĩa | Hiện metadata 1.0.0 và mandatory=false không gây lỗi đang gặp. Chính sách bắt buộc cần quyết định sản phẩm. | Để sau; không tự áp đặt khóa app/cập nhật bắt buộc. |
| GUI thiếu ffprobe / portable gom thiếu dependency | GUI có thể báo đủ FFmpeg khi thiếu ffprobe; riêng bộ portable cần thử trên máy sạch. | Bổ sung kiểm ffprobe trong UI; chưa viết lại installer hay gom dependency toàn bộ. |
| Track A ghi “Bản Gốc” | Audio của track đó thực tế là dub đã tách/chuẩn hóa. Đây là nhãn sai, không phải hỏng video. | Đổi thành Audio Tách, không tải thêm audio gốc. |
| Bộ lọc 7 ngày gồm 8 ngày lịch | Lỗi nhỏ về quy ước đếm ngày. | Tính hôm nay + 6 ngày trước, không lấy ngày tương lai. |
| Thông số “lossless/bit-perfect/Android” tĩnh | Không nên hiểu nhãn tĩnh là phép đo. Không chứng minh video đang kém chất lượng. | Để sau; không đổi codec, bitrate, loudnorm hoặc thiết kế giao diện đợt này. |

## Quy ước giao việc

Hai agent GPT-6 Luna, reasoning high, mỗi agent chỉ được sửa một file mã chính và file kiểm thử của phần đó. Prompt chỉ định chức năng, timeout, trạng thái, file được sửa, các hành vi phải giữ và cách kiểm chứng. Agent phải hỏi khi thiếu/conflict; không tự chọn thuật toán căn âm thanh, model, dependency hay thiết kế updater. Root đọc lại diff, chạy kiểm thử và build/đối chiếu tài nguyên cuối cùng. Việc khóa phạm vi không thay thế kiểm tra chất lượng code.

Không dùng test mô phỏng để tuyên bố đã thử video thật. Các phép kiểm thử sau đợt sửa phải phân biệt startup/render WPF, tiến trình riêng, lỗi IO/rollback, media tổng hợp và luồng Facebook/LDPlayer chưa chạy.

## Kết quả bản 1.0.9 trên máy

Đã build lại Kid-FB.Y.exe từ mã hiện tại bằng compiler .NET Framework; chưa commit/tag/push GitHub. Bốn suite chạy qua bằng Windows PowerShell 5.1:

- `tests/startup.ps1`: sáu nhóm, gồm cài mới/89 control/tài nguyên EXE, chặn READY cũ, backup/rollback, tái hiện lỗi khởi tạo cũ và mã thoát, gallery trống/có file, WPF ContentRendered thật trong cửa sổ ẩn.
- `tests/engine-runtime.ps1`: bảy nhóm, gồm stdout/stderr, timeout chỉ dừng process sở hữu, thay đủ ba file, khôi phục khi lỗi IO được chèn, hủy runspace thật giữa lần thay file, download/FFmpeg trả lỗi giữ nguyên bộ output cũ đúng tên.
- `tests/gui-runtime.ps1`: gọi các hàm thật với fixture cục bộ; kiểm error/exception, hủy không chặn UI, tiến trình cùng tên không thuộc tác vụ vẫn sống, status tiếng Việt và bảo vệ hàng đợi. Luồng đóng cửa sổ được kiểm tra cấu trúc code; chưa thao tác đóng GUI khi đang thu trên LDPlayer thật.
- `tests/media-output.ps1`: FFmpeg/ffprobe thật tạo clip tổng hợp một giây có hình + tone; chấp nhận clip đủ hai stream và từ chối clip chỉ có video. Đây không phải kiểm tra ngôn ngữ hoặc căn tiếng Facebook.

Manifest 1.0.9 khớp kích thước và SHA256 của cả tám file theo quy tắc chuẩn hóa text của updater. Các script sửa đổi parse thành công, giữ UTF-8 BOM/CRLF; `git diff --check` qua. Chưa chạy lại một Reel Facebook thật với LDPlayer trong đợt này, nên không kết luận chất lượng/căn tiếng/ngôn ngữ ngoài các bằng chứng trên.

## Bổ sung tiny theo yêu cầu sau đó — bản 1.0.10

Anh đã đồng ý triển khai thử nhận diện ngôn ngữ từ audio ngắn. Vì vậy quyết định “chưa thêm Whisper” phía trên mô tả đợt 1.0.9, đã được thay bằng bản thử tùy chọn trong 1.0.10. Không thay thuật toán căn tiếng. Chi tiết chức năng, ngưỡng thử, số đo bằng model thật và giới hạn kiểm chứng nằm trong [WHISPER.md](WHISPER.md).

## Bản 1.0.11 — link Facebook chia sẻ

Anh báo link `https://www.facebook.com/share/r/19bVLUNWK5/` bị báo không đọc được/phải công khai. Trên máy phát triển, cả redirect HTTP và yt-dlp 2026.08.19 đọc được ID `949206081560084`, nên chưa tái hiện được đúng lỗi môi trường của máy anh. Gợi ý “phải công khai” cũ chỉ là thông báo chung khi đọc ID thất bại, không phải kết luận từ Facebook rằng video riêng tư.

Đã bổ sung tách URL Facebook từ văn bản, Markdown, dấu nháy, NBSP và danh sách; loại trùng. Link chia sẻ được thử chuyển hướng có giới hạn thời gian trước khi đọc ID, rồi dùng URL video trực tiếp cho tải và mở Facebook trên Android. Nếu không chuyển hướng được, giữ link gốc để yt-dlp thử; không đoán ID từ token chia sẻ hay URL đăng nhập. Bỏ ảnh hưởng cấu hình yt-dlp ngoài app, không lấy playlist; thông báo thất bại hiện lỗi thực của yt-dlp thay cho kết luận chung “link sai/phải công khai”.

Kiểm tra link thật, với đúng nội dung Markdown/NBSP anh gửi, đọc được một URL và ID đúng, chuẩn hóa thành `https://www.facebook.com/reel/949206081560084/`. Chỉ truy vấn metadata/chuyển hướng; chưa tải/thu toàn bộ Reel này trên LDPlayer. Bộ test link kiểm tra parser, host, ID và các redirect lỗi/đăng nhập/checkpoint bằng mock; suite startup kiểm tra helper mới được nhúng vào EXE.
