# Kid FB.Y — v2.0.0

Tải video Facebook và ghép audio lồng tiếng Meta AI thu từ Facebook trên Android/LDPlayer. Ứng dụng tự lưu và chạy hết danh sách; có thể xem lại bản xuất trong kho video.

## Thử trên máy Windows mới

1. Tải toàn bộ dự án bằng **Code → Download ZIP** trên kho GitHub. Phiên bản trong thư mục dự án hiện tại là **2.0.0**.
2. Giải nén ra một thư mục có quyền ghi. Giữ `Kid-FB.Y.exe` cùng thư mục `core`; chạy EXE sau khi giải nén, không chạy bên trong ZIP.
3. Trong tab **Bộ Thư Viện**, bấm **Tải & Cài Đặt Tất Cả**. Lần đầu cần Internet để tải công cụ và model. Các file nằm trong thư mục `tools` và không đi kèm ZIP GitHub.
4. Mở LDPlayer/Android đã có Facebook, đăng nhập và bật kết nối ADB. Quy trình thu audio cần Android hỗ trợ audio capture; cấu hình đang dùng của dự án là LDPlayer Android 14.
5. Bấm **Kiểm tra máy**, dán một link video công khai để thử. Có thể dán link `share/r`, `share/v`, `fb.watch` hoặc link kèm văn bản/Markdown; app tách URL và thử chuyển link chia sẻ sang link video trực tiếp. Ứng dụng tự xử lý hết danh sách, không chờ duyệt từng video. File xuất mặc định ở `output`.

## Tự động tải hết danh sách

Dán danh sách link rồi bấm **Tự động tải hết danh sách**. Mỗi video xuất thành công được lưu và tự chuyển sang video kế tiếp, không chờ duyệt hoặc bấm giữ. App không phát xem trước giữa các video; khi hết danh sách, hiển thị tổng số đã lưu, bỏ qua và lỗi, rồi mở bản thành công gần nhất để xem lại. Các video đã xuất nằm trong **Kho Video Đã Xuất**.

Video được xác nhận không có bản dịch bị loại theo chính sách bên dưới. Lỗi tải/thu âm/xuất được ghi trong log cùng link để thử lại sau; hàng đợi tiếp tục và không tự tải lại vô hạn hoặc loại vĩnh viễn vì lỗi tạm thời. Bấm **Dừng** sẽ hủy tác vụ hiện tại và dừng cả hàng đợi; các video đã lưu được giữ nguyên.

Trong Kho Video, mở video rồi bấm **Ghi âm lại** để xử lý riêng đúng ID đó và lưu vào thư mục chứa bản đã chọn. Lượt tải cũ không được khởi động lại. Các file hiện có được giữ khi xử lý lỗi tạm thời hoặc bị dừng; chỉ thay bản mới khi xuất thành công. Chính sách loại video không có bản dịch vẫn áp dụng.

Thư mục xuất và đường dẫn video/logo/GIF có dấu ngoặc vuông được xử lý theo tên thật. Nếu không khởi động được tác vụ, app giải phóng hàng đợi, bật lại các nút và ghi các link chưa chạy vào Logs; có thể sửa nguyên nhân rồi bắt đầu lại.

## Chọn tiếng Việt trên Meta

Ứng dụng đọc ID/thời lượng rồi mở dấu ba chấm của Reel trên LDPlayer. Nếu menu đầy đủ đã được đọc ổn định và quét hết nhưng không có **Âm thanh và ngôn ngữ**, hoặc menu ngôn ngữ xác nhận chỉ có âm thanh gốc, video được loại trước khi thu âm/tải HD. App lưu lịch sử loại, dọn file cũ đúng ID và bỏ qua ID đó ở các lần sau. Menu đang tải, XML lỗi hoặc mục nằm ngoài vùng cuộn không được coi là không có bản dịch; trường hợp chưa rõ sẽ dừng mà không loại vĩnh viễn.

Khi Tiếng Việt đã được chọn sẵn, app đọc hai ảnh chụp UI mới để xác nhận. Nếu chưa chọn, app chạm dòng Tiếng Việt đang hiển thị đúng một lần. Sau đó chỉ đọc UI: xác nhận dấu chọn nếu menu còn mở, hoặc xác nhận Meta tự đóng menu và trở về màn hình Reel qua hai lần đọc mới. App không mở lại bộ chọn để kiểm tra lần hai. Lệnh chạm thành công nhưng UI không phản hồi đúng sẽ dừng, không tải hình.

Sau khi xác nhận lựa chọn trên Meta, app thu audio tiếng Việt, cắt/chuẩn hóa và ghép với phần hình HD. **Không chạy Whisper để kiểm tra lại ngôn ngữ trong luồng tải**, không chặn video vì điểm nhận diện thấp, không yêu cầu cài model tiny để tải video. Thu âm vẫn cần để lấy bản lồng tiếng; đây là bước riêng với nhận diện ngôn ngữ.

Mở **Kho Video Đã Xuất → Video đã loại · không tải lại** để xem ID, lý do và thời điểm. Lịch sử ở `data/rejected-videos.json`, dùng chung khi đổi thư mục xuất, được giữ khi khởi động lại và không đưa lên Git. Link có ID đã loại bị bỏ qua ngay; link chia sẻ mới được kiểm tra sau khi giải ID. Khi gặp lại ID đã loại, app thử dọn file cũ đúng ID trong thư mục xuất; file khóa sẽ được báo, không thông báo xóa thành công. `-SkipLanguageCheck` được giữ để tương thích lệnh cũ, không bỏ qua bước chọn Tiếng Việt trên Meta.

Whisper tiny vẫn có thể được cài riêng để kiểm tra audio theo yêu cầu; chức năng này chạy cục bộ trên CPU Windows x64, không cần Python/CUDA, không thay đổi audio xuất. Model đa ngôn ngữ khoảng 78 MB; không tự tải giữa lúc xử lý video.

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

Tùy chọn Logo/GIF mặc định thu gọn. Khi mở rộng ở cửa sổ thấp, vùng nhập có thanh cuộn riêng để các tab tiến trình và kho video vẫn hiện. Chữ phụ dùng màu sáng hơn; cửa sổ khởi tạo theo vùng làm việc của màn hình.

GUI bật nhận biết DPI theo màn hình ngay trong tiến trình PowerShell trước khi tạo cửa sổ, chọn vùng làm việc của màn hình chứa cửa sổ và điều chỉnh lại khi di chuyển/đổi DPI. Ở cửa sổ hẹp, các tab và nút nghiệm thu xuống dòng, hàng thông số trang trí được ẩn. Phép thử DPI mô phỏng không thay thế kiểm tra trên hai màn hình vật lý khác DPI.

GIF được giải mã trên một worker STA riêng, có một yêu cầu thời gian mới nhất và một khung hoàn tất; giao diện chỉ nhận bitmap đã đóng băng. Tua mới thay yêu cầu cũ để tránh hàng đợi kéo dài. App bỏ giải mã khi lớp phủ đang ẩn hoặc cửa sổ thu nhỏ, rồi đồng bộ theo vị trí video khi hiện lại. Các số đo độ trễ UI không đồng nghĩa số FPS phát hình thực tế.

Lịch sử đánh dấu đã đăng được ghi nguyên tử và khóa khi nhiều tiến trình cùng lưu. File lịch sử lỗi hoặc bị khóa sẽ báo lỗi, giữ dữ liệu cũ và không báo lưu thành công. Kho video hiển thị lỗi đọc lịch sử thay vì suy đoán trạng thái chưa đăng.

ID lặp trong danh sách chỉ được xử lý một lần. Với link chứa ID Reel/video trực tiếp, ứng dụng kiểm tra file video gốc hoặc hoàn tất có cùng ID trong thư mục xuất hiện tại và cảnh báo đã tải; khi bắt đầu có thể tải lại, bỏ qua hoặc hủy. Link chia sẻ/rút gọn chưa có ID không được suy đoán từ token.

## Build và phát hành

Trên Windows x64, chạy `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\build-local.ps1`. Script đồng bộ nguồn GIF nhúng, kiểm tra cú pháp, biên dịch EXE và chạy SelfTest trong thư mục tạm, đối chiếu bảy tài nguyên nhúng. Lệnh này không đổi phiên bản, commit, tag hoặc push.

`publish.ps1` dùng cùng luồng build trước khi tạo manifest và phát hành. Chỉ chạy khi chủ động phát hành phiên bản mới; dùng `-NoPush` nếu chỉ muốn chuẩn bị bản phát hành cục bộ.

Bộ cập nhật sao lưu toàn bộ file cần thay trước khi cài, ghi nhật ký phục hồi và thay số phiên bản sau cùng. Nếu bị ngắt, lần mở tiếp theo xử lý phục hồi trước khi kiểm tra phiên bản. Chỉ xác nhận cập nhật sau khi giao diện trả đúng mã khởi động của giao dịch; lỗi khôi phục giữ lại dữ liệu phục hồi và dừng khởi chạy để tránh dùng bộ file lẫn phiên bản.

Journal có checksum để chặn phục hồi thiếu khi file bị cắt/hỏng. Payload staging được flush trước khi công bố READY qua đổi tên file tạm nguyên tử; file READY ghi dở không được dùng để cài. Launcher kiểm tra dung lượng trống dự kiến trước khi sao lưu/thay file trên ổ cục bộ. Kiểm tra này không bảo đảm tránh mọi lỗi ổ đĩa hay việc tiến trình khác sử dụng dung lượng sau đó; lỗi ghi thực tế vẫn phải dừng hoặc phục hồi.

`tools/` chứa công cụ/model và `output/` chứa video người dùng; cả hai được Git bỏ qua. Báo cáo và fixture kiểm thử không nằm trong cây dự án phát hành.
