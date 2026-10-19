# Bàn giao kỹ thuật Kid FB.Y

Ngày rà nguồn: 19/10/2026. Bản vá dọn mã chuẩn bị ở `core/version.txt` là 2.0.1; trạng thái Git và phiên bản máy khác cần kiểm tra lại. Tài liệu mô tả hành vi có trong nguồn, không chứng nhận không có lỗi, hiệu năng hay kết quả của Facebook.

## 1. Cây dự án và công nghệ

| Thành phần | Cơ chế trong nguồn |
| --- | --- |
| `Program.cs` | Launcher C# WinExe, .NET Framework, STA; giải nén resource còn thiếu, phục hồi/cài update, chạy Windows PowerShell ẩn |
| `core/kid-fby-gui.ps1` | WPF/XAML, PresentationFramework/PresentationCore/WindowsBase; runspace PowerShell nền, DispatcherTimer, MediaElement phát video/audio |
| `core/kid-fby.ps1` | Engine CLI: tìm/cài công cụ, ADB, đọc UI, thu âm, xử lý và xuất media |
| `core/facebook-links.ps1` | Phân tích URL/ID, phát hiện ID lặp, lịch sử loại JSON, quyết định theo trạng thái UI |
| `core/whisper-language.ps1` | Chẩn đoán ngôn ngữ CLI và cài whisper.cpp/tiny tùy chọn |
| `core/wpf-gif-player.cs` | Decoder/compositor GIF WPF, cache/checkpoint và worker STA; được Base64 hóa vào GUI lúc build |
| `core/updater.ps1` | Đọc manifest, tải staging, kiểm SHA256 và công bố READY |
| `core/fix-ket-noi.ps1` | Tiện ích PowerShell chẩn đoán và thử sửa kết nối Android/LDPlayer; đọc mã trước khi chạy vì có thao tác ADB |
| `build-local.ps1` / `publish.ps1` | Biên dịch, kiểm khởi tạo; chuẩn bị version/manifest và thao tác Git khi phát hành |

Đây không phải app web/Electron, không có backend hay SQL riêng. Không có `.csproj`, `.sln`, lockfile công cụ chung hoặc bộ regression test được phân phối trong cây Git tại lần rà này. Chạy tác vụ con bằng quyền người dùng Windows; `ExecutionPolicy Bypass` không tạo sandbox.

### Phụ thuộc ngoài

- ADB điều khiển Android; scrcpy ghi audio; yt-dlp đọc thông tin và tải hình; FFmpeg/ffprobe cắt, đo, mã hóa, ghép và kiểm file.
- `Find-Tool` xét `tools`, một số vị trí LDPlayer/LOCALAPPDATA, PATH và WinGet. Công cụ tìm thấy không nhất thiết đến từ cùng một bản cài.
- Installer có URL scrcpy 3.1/fallback 2.7, yt-dlp latest, FFmpeg release và các mirror/WinGet. Đây là cấu hình trong mã, không phải tuyên bố phiên bản mới nhất. Các URL/mirror có thể thay đổi hoặc hỏng.
- Bộ cài scrcpy/yt-dlp/FFmpeg chủ yếu kiểm file/kích thước và công cụ có mặt, không có bộ SHA cố định chung cho các tải này. Downloader hiện dùng kiểm chứng chứng chỉ mặc định của Windows/curl; không đặt callback chấp nhận mọi chứng chỉ hoặc `curl -k`.
- Whisper tùy chọn dùng whisper.cpp v1.8.2 x64 CPU và tiny đa ngôn ngữ; archive/model có SHA được ghi trong helper. Tải tất cả còn gọi phần cài này dù luồng tải video không cần nó.

## 2. Đường đi một video

Đọc `Invoke-OneLink`, `Ensure-VietnameseDubbing` và các helper trong `facebook-links.ps1`.

1. Phân tích URL, xét lịch sử loại theo ID/URL, thử giải link share. Gọi yt-dlp `--skip-download` để đọc ID và thời lượng. Mã nhận thời lượng lớn hơn 0,5 giây và không quá 3.600 giây; giới hạn này không chứng minh mọi video trong khoảng sẽ xử lý được.
2. ADB mở Facebook bằng intent, dùng `uiautomator dump` mới và đọc node thuộc package Facebook. Bounds được cắt theo vùng tổ tiên để tránh chạm node ngoài màn hình.
3. Tìm nút tùy chọn Reel, quét menu tìm **Âm thanh và ngôn ngữ**. Chỉ những mẫu menu đầy đủ/ổn định được dùng để kết luận không có bộ chọn; menu lỗi/đang tải không đồng nghĩa không hỗ trợ.
4. Nếu menu ngôn ngữ hoàn chỉnh chỉ còn audio gốc và được đọc xác nhận, hoặc có thông báo không hỗ trợ, trạng thái có thể là `unavailable`.
5. Nếu Tiếng Việt đã checked: hai snapshot mới phải thấy checked. Nếu chưa chọn: chạm dòng Tiếng Việt khả dụng một lần. Sau đó hai lần trở về màn hình Reel cũng được dùng để chấp nhận thao tác. Đây là heuristic phản hồi UI, không chứng minh nội dung audio hoặc chất lượng bản dịch.
6. `selected` cho phép tiếp tục; `unverified` dừng mục hiện tại nhưng không ghi loại vĩnh viễn; `unavailable` lưu lịch sử rồi thử dọn file đúng ID trước khi trả về.
7. Bắt đầu scrcpy `--no-video --no-window --no-audio-playback --audio-codec=aac --require-audio`. Thời gian dự kiến là `ceil(duration + 10)` giây. Sau khoảng 1,8 giây warmup, mở lại Reel để ghi từ lúc phát. Tương tác khác trên Android có thể ảnh hưởng lần thu.
8. `Get-AudioOnset` dùng silencedetect (-60 dB, 0,10 giây) để ước lượng khoảng im lặng đầu, không nhận diện ý nghĩa hay frame số 0. FFmpeg cắt audio, loudnorm mục tiêu -16 LUFS/-1,5 dBTP/LRA11, resample 48 kHz, mã hóa AAC 192 kbps.
9. yt-dlp chọn `bestvideo/best`, sắp theo `res,fps,br`. Chất lượng thực tế phụ thuộc các format truy cập được của nguồn.
10. Không lớp phủ: thường `c:v copy`; AV1/VP9 chuyển libx264. Có logo/GIF: bộ lọc rgba/scale/overlay và H.264; mã thử NVENC/QSV/AMF rồi có nhánh libx264. Không có cam kết lossless hoặc mọi MP4 đều H.264.
11. `Test-ValidReelOutput` đọc stream/thời lượng bằng ffprobe và thử decode bằng FFmpeg nếu có công cụ. Decode dùng ngân sách theo `Get-ReelProcessTimeoutMs` (mã hiện chặn trong khoảng 5–60 phút), có thể vẫn timeout hoặc không bao phủ mọi kiểu hỏng.
12. `Publish-ReelFiles` stage/backup các file và phục hồi lỗi bắt được. Đây không phải giao dịch ba file nguyên tử khi mất điện; không có journal bền giống updater.

### Tên file và lịch sử

- `ID-1-video-goc.mp4`: phần hình không audio, có thể đã chuyển mã cho quy trình xuất.
- `ID-2-am-thanh-tho.m4a`: audio sau cắt/chuẩn hóa/AAC; tên được giữ cho reedit, không phải PCM hoặc bản ghi thô nguyên vẹn.
- `ID-3-hoan-chinh.mp4`: bản ghép/lớp phủ.
- `data/rejected-videos.json`: lịch sử loại dùng chung khi đổi thư mục xuất. `Get-RejectedReels` đọc/kiểm cấu trúc; `Save-RejectedReel` lưu. Lý do cũ `audio-not-vietnamese` vẫn có thể tồn tại; luồng mới chủ yếu ghi `vietnamese-unavailable`.
- `output/reup-status.json`: trạng thái Posted/Date theo ID, do người dùng đánh dấu. Ghi bằng mutex và file tạm/replace; đây không phải xác nhận từ TikTok.
- ID trùng trong cùng input được gộp. Khi đã có `-1` hoặc `-3` không rỗng, GUI có lựa chọn tải lại/bỏ qua/hủy trước khi chạy. Đây là kiểm tên/ID/file, không so sánh nội dung video bằng fingerprint.

## 3. GUI và vòng đời tác vụ

Điểm bắt đầu: `Start-Link`, `Start-Engine`, `Pump-Output`, `Finish-Engine`, `Complete-QueueItem`, `Next-Link`, `Stop-Engine`.

- Một runspace xử lý một mục. GUI bơm Information/Error stream, chờ completion rồi dispose trước khi chạy mục kế tiếp. Hiện kết quả xuất được nhận qua dòng log `Video : ...mp4` và file hiện có; nếu đổi format log phải sửa/parser/test tương ứng.
- Tác vụ thành công tăng số đã lưu. Video bị loại tăng số bỏ qua. Lỗi khác được ghi link và chuyển tiếp; không retry vô hạn. Lỗi thiết lập runspace giải phóng trạng thái và dừng hàng đợi với các link chưa khởi động trong Logs.
- Dừng đặt cờ, dừng pipeline và kết thúc các process đăng ký trong `ProcessRegistry`. Không phát preview giữa các mục thu âm. Khi hết danh sách, GUI có thể mở bản thành công gần nhất.
- `Start-RecordingAgain`: lấy ID từ tên `ID-3-hoan-chinh.mp4`, đặt hàng đợi một mục, chọn đúng thư mục chứa video; không dựa vào idx cũ. File cũ được thay qua publisher khi thành công; lỗi tạm thời/Dừng giữ file cũ. Quyết định loại theo UI vẫn có thể dọn các file đó.
- `Start-Reedit`/`Invoke-ReeditVideo`: dùng lại `-1` và `-2`; không thu/tải lại. Đầu vào thiếu sẽ dừng. Có đường preview gốc sạch để sửa overlay.
- `Remove-ReelFiles`: nhả nguồn player nếu cần, stage/backup/xóa và thử phục hồi lỗi bắt được; lỗi phục hồi báo đường dẫn giữ lại. Không nên mô tả là không thể mất dữ liệu trong mọi sự cố.
- Panel nội bộ còn tên `PanelRev`, hiện là vùng thao tác video/xem lại. Nút duyệt `BtnKeep`, `BtnSkip` và nhánh tự Next sau xóa của luồng duyệt cũ đã bỏ.
- Track A mở M4A `-2`; Track B mở MP4 `-3`. Đây không phải so sánh audio nguyên bản của Facebook với audio đã dịch.

## 4. Logo, GIF và trình xem

- `Get-MovingLogoMuxArgs` tạo filter graph FFmpeg cho bản xuất. Vị trí/kích thước dùng hệ tọa độ của video; custom geometry và chế độ phủ đầy được truyền từ GUI.
- WPF overlay có drag, tám grip resize, preset/custom và chọn lớp đang thao tác. Logo `Free` chạy theo biểu thức, `Fixed` đứng yên tại preset/custom; các chế độ không có ý nghĩa tạo fingerprint độc nhất.
- `WpfGifPlayer` dùng GifBitmapDecoder, WriteableBitmap và BGRA để dựng frame/disposal. `RawGifFrame` vẫn được cache và render sử dụng, không phải khai báo thừa.
- `Start-GifSelectionWorker` chuẩn bị GIF ngoài dispatcher; `WpfGifPlaybackWorker` có worker STA riêng, request thời gian mới nhất và bitmap đóng băng đã hoàn tất. Có cache/checkpoint và giới hạn canvas/frame/bộ nhớ trong `.cs`; đây là giới hạn do mã đặt, không phải số đo RAM toàn bộ app.
- Khi GIF ẩn/thu nhỏ, mã bỏ yêu cầu decode theo tick. `Close` có thể chờ worker tối đa khoảng 100 ms qua Join. Không có phép đo mới để suy ra FPS, CPU hay độ mượt trên mọi máy.
- `MediaElement` WPF vẫn phát video/audio, nhưng `MediaVideoGif` dự phòng không có source đã bỏ. GIF hiện qua `ImgVideoGif` từ decoder/worker.
- `Test-GifFile` xem header/frame/disposal qua .NET và thử FFmpeg nếu tìm thấy; việc chấp nhận trailer bị thiếu tùy decoder không đồng nghĩa mọi GIF hỏng đều bị nhận ra.
- Preview và FFmpeg là hai bộ dựng; cần so trực quan nhiều mốc thời gian sau các thay đổi geometry/alpha/disposal. Đen đặc là pixel có nội dung, không được chromakey xóa chỉ vì màu đen.
- Tua dùng MediaElement.Position, chuột/slider và phím trái/phải. Giá trị Position hoặc nhịp Dispatcher không phải bằng chứng frame đã trình bày hoặc âm thanh đã settle.

## 5. Build, phiên bản và cập nhật

### Nguồn → EXE → manifest

1. Sửa C#/PS. PS giữ UTF-8 BOM/CRLF, C# CRLF.
2. `core/version.txt` là số x.y.z dùng cho GUI và metadata launcher. Build sinh AssemblyInfo tạm ngoài repo, compile Assembly/File=x.y.z.0, Product=x.y.z; không còn hardcode trong Program.cs.
3. `build-local.ps1` thay đúng assignment `$wpfGifPlayerB64` theo byte `.cs`, parse các PS, dùng `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, compile icon và bảy resource.
4. Build thử EXE `-SelfTest` trong thư mục tạm, kiểm exit/BOOT_OK và bytehash resource; build không đổi `version.json` hoặc push/tag/commit.
5. `publish.ps1 -Version <mới> -NoPush` tăng version, build và ghi manifest. Nó vẫn đổi file/version cục bộ. Không dùng lệnh này như lệnh kiểm tra không side effect. Lệnh không có `-NoPush` còn có thao tác Git; đọc phần cuối script trước khi chạy.
6. Manifest ghi hash raw cho binary/ZIP; text được bỏ BOM và chuẩn hóa CRLF→LF trước SHA256, size vẫn là byte file trên đĩa. Hash raw của PS không nhất thiết bằng hash chuẩn hóa trong manifest.

`publish.ps1` hiện không tự rollback version/config/EXE khi bước build lỗi; cần kiểm tra diff và phục hồi trên bản sao hoặc bằng thay đổi đã xác định. `-NoPush` còn có thể khởi tạo Git nếu thư mục chưa có repo, dù không commit/tag/push.

Bảy resource: `kid-fby-gui.ps1`, `kid-fby.ps1`, `whisper-language.ps1`, `facebook-links.ps1`, `fix-ket-noi.ps1`, `Kid-FB.Y.ico`, `kid-logo.zip`. Cấu hình `version.txt`, `updater.ps1`, `update.json` cần được phân phối trong `core`.

`ExtractResourceIfMissing` chỉ ghi file core còn thiếu. Chép EXE mới lên core cũ không làm mới script đã tồn tại; build cùng checkout hoặc dùng đường update/đủ bộ file. Không xóa cả core để ép giải nén vì có cấu hình/trạng thái cần xem xét.

### Update

`core/update.json` chứa repo/branch. Updater chỉ coi là bản mới khi manifest.version lớn hơn local version, nên thay mã cùng số phiên bản có thể không tới máy đã cài. `minLauncher` trong manifest hiện là metadata, chưa có kiểm tra tương ứng; không dùng nó làm bằng chứng chặn launcher cũ. Metadata tool tĩnh không có consumer đã được bỏ.

`Get-Bytes` thử URL/mirror; updater đối chiếu SHA256 rồi ghi staging và READY bền trước khi thông báo. Launcher giữ khóa, `RecoverPending` trước `ApplyUpdate`, kiểm đường dẫn/dung lượng, sao lưu và thay version cuối. Journal/checksum/token/BOOT_OK tham gia xác nhận hoặc phục hồi. Chưa có chữ ký số manifest/payload của dự án; hash khớp manifest không tương đương chữ ký nhà phát hành.

Không xóa `core/_update`, `core/_backup`, READY, journal hay backup theo tên/tuổi file khi chưa biết giao dịch đã kết thúc. Backup còn lại có thể là đường phục hồi.

## 6. Kiểm chứng và giới hạn bàn giao

### Lệnh có sẵn trong repo

```powershell
# Build/startup/resources; có thay EXE và đồng bộ Base64, không cập nhật manifest
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\build-local.ps1
# Khởi tạo GUI; không thử tải Facebook
.\Kid-FB.Y.exe -SelfTest
# Kiểm tra công cụ/thiết bị; có truy cập ADB
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 -Check
```

Chạy SelfTest trong thư mục sao chép riêng khi không muốn ghi trạng thái `_update` vào checkout. SelfTest không kiểm dịch, chất lượng audio, queue end-to-end, lỗi khóa file hay hiệu năng. Không có regression suite kèm bản Git này; các harness tạo ngoài repo của phiên làm việc không mặc nhiên có mặt trên máy người nhận.

### Checklist tái hiện khi nhận việc

- Khởi động từ thư mục mới và đường dẫn có space/`[]`; đối chiếu version GUI/EXE/core/manifest và bảy resource.
- Hàng đợi có thành công/loại/lỗi; Dừng khi đang ghi và lúc completion; không phát audio preview giữa các mục.
- Ghi âm lại từ kho: đúng ID/thư mục, không chạy lại queue cũ, giữ hash bản cũ khi lỗi hoặc hủy. Phân biệt engine giả lập với Android/tải thật.
- Menu có/không bản dịch, UI đang tải/hỏng XML, node ngoài viewport, Tiếng Việt sẵn chọn/chưa chọn. Không suy từ lệnh tap exit0 rằng đã áp dụng.
- So audio/video thực tế nhiều mốc, đặc biệt đầu im lặng; nghe và xem để tìm lệch mà số Position không thể hiện.
- PNG/GIF trong suốt/đen đặc/disposal, kéo cạnh/góc/custom/preset/fullframe; so preview với export.
- File bị khóa, lịch sử JSON lỗi/khóa, thiếu đầu vào reedit, thiếu companion tool, timeout process, startup runspace lỗi.
- Update trên bản sao: staging lỗi/hash sai, ngắt giữa giao dịch, phục hồi, version cuối và giữ nguyên dữ liệu người dùng.

### Kết quả của lượt dọn 19/10/2026

Các báo cáo và harness nằm ngoài repo tại `C:\Users\hp\.codex\verification\handoff-cleanup-20261019`. Đây là đường dẫn của máy làm việc, không phải tài nguyên có sẵn khi clone Git.

- `engine-cleanup-results.txt`: 30 assertion trên Windows PowerShell 5.1, gồm timeout/thu hồi process thực, curl đọc file cục bộ, fixture installer thiếu companion và validator theo thời lượng. Các trường hợp installer/fallback được giả lập; chưa tải lại toàn bộ bộ cài ngoài mạng.
- `gui-post-cleanup-verification.txt`, `gui-runtime/`: WPF thực với engine giả lập cho queue/Dừng/retry; fixture GIF kiểm disposal 2/3, alpha, worker seek và geometry. Những ca này không thay cho lượt tải Android đầy đủ hoặc đo độ mượt trên máy khác.
- `build-metadata-results.txt`: build trên bản sao đường dẫn có space/`[]`, metadata theo version, từ chối version sai và dọn thư mục build tạm khi compiler lỗi.
- `gui-final-package-evidence.json`: đối chiếu EXE với bảy resource; chạy launcher mới, BOOT_OK, version và khởi tạo đủ 157 control WPF. Dùng hash trong báo cáo để biết chính xác binary được kiểm.
- `final-runtime/console.txt`, `final-runtime/result.json`: chạy engine thật với LDPlayer `emulator-5554` và Reel `4340858519560389`; nhận trạng thái Tiếng Việt trên UI, thu bằng scrcpy, tải AV1 rồi chuyển H.264. Xuất ba file ngoài repo; ffprobe đọc được bản hoàn chỉnh H.264/AAC, 1440×2560, 22,016 giây. Sau lượt chạy chỉ đổi câu log và parser tương ứng sang mô tả chấp nhận UI, rồi build lại. Chưa nghiệm thu bằng nghe/xem chất lượng dịch hoặc lệch tiếng–hình.
- Parse toàn bộ PS, BOM và CRLF ở các PS có sửa (tiện ích `fix-ket-noi.ps1` không sửa vẫn dùng LF), `git diff --check` và hash/size manifest được kiểm ở lượt chốt; đây là kiểm cấu trúc/đóng gói, không phải bằng chứng không còn bug.

Chưa bao phủ toàn bộ biến thể UI Facebook, thiết bị Android, mirror tải/cài, codec/driver GPU, nhiều màn hình DPI, clip dài hoặc sự cố ổ đĩa/nguồn điện. Không lấy kết quả này để suy ra FPS, CPU, đồng bộ audio hay tất cả tính năng đều đúng.

## 7. Thay đổi hợp đồng và phạm vi dọn

Bản dọn bỏ switch CLI `-SkipLanguageCheck` vì không còn tác dụng; script cũ truyền switch cần bỏ đối số đó. Điều kiện tải vẫn là phản hồi UI Meta, không bật lại Whisper. Result `Invoke-OneLink` không còn trường AudioLanguage luôn null; chẩn đoán riêng vẫn dùng `-DetectLanguageFile`.

Đã bỏ nhánh UI duyệt từng video, MediaElement GIF không dùng, helper mở lại menu không caller và các mô tả quá mức. Các fallback tải/cài, lớp GIF/cache/worker, helper Whisper, lịch sử và dữ liệu phục hồi còn có caller hoặc mục đích nên được giữ.

Giữ media đầu vào/bản hoàn chỉnh/lịch sử/công cụ đang dùng. Artifact thử khoảng 115 MB đã tách ngoài dự án vào `preserved-artifacts` trong thư mục kiểm chứng và có danh sách/hash; không đóng gói vào Git. Người dùng đã yêu cầu xóa vĩnh viễn gói này, nhưng cả lệnh xóa hàng loạt lẫn lệnh chỉ xóa đúng đường dẫn đã bị chính sách thực thi chặn; gói vẫn còn tại thời điểm bàn giao. Bản 2.0.1 và tài liệu được commit/push theo yêu cầu tiếp theo; không viết lại lịch sử Git.
