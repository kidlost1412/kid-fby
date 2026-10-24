# Bàn giao kỹ thuật Kid FB.Y

Ngày rà: 21/10/2026, nhánh `audit-fixes-2.1` cùng commit với `main` @ `7f5851a`. `core/version.txt` = 2.1.0; bản 2.1.0 đã phát hành: tag `v2.1.0` trên GitHub, `version.json` và `version.json.sig` đã ký và nằm trên `main`. Trạng thái Git và phiên bản máy khác cần kiểm tra lại. Tài liệu mô tả hành vi có trong nguồn, không chứng nhận không có lỗi, hiệu năng hay kết quả của Facebook.

## 1. Cây dự án và công nghệ

| Thành phần | Cơ chế trong nguồn |
| --- | --- |
| `Program.cs` | Launcher C# WinExe, .NET Framework, STA; một launcher cho mỗi thư mục cài (mutex `Local\KidFBY.SingleInstance.<hash thư mục>`; lần mở thứ hai đọc `core\_update\gui.hwnd` để đưa cửa sổ GUI đang chạy lên trước, không được thì MessageBox như cũ), giải nén resource còn thiếu theo stamp, phục hồi/cài update, chạy Windows PowerShell ẩn bằng đường dẫn tuyệt đối; ghi `logs\launcher-*.log` |
| `core/kid-fby-gui.ps1` | WPF, PresentationFramework/PresentationCore/WindowsBase; nạp XAML từ `core/ui`; runspace PowerShell nền, DispatcherTimer, MediaElement phát video/audio; log bền, crash log, `data\settings.json` |
| `core/ui/Theme.xaml`, `core/ui/MainWindow.xaml` | Theme "cute" (token màu đã chỉnh theo tương phản WCAG, style, trang trí vector, vùng bấm tối thiểu 44) và cây cửa sổ năm trang; GUI nạp lúc chạy, launcher cũng nhúng sẵn |
| `core/ui/fonts/` | Nunito Regular/SemiBold/ExtraBold (SIL OFL 1.1, kèm `OFL.txt`); nhúng vào EXE, thiếu thì GUI dùng Segoe UI |
| `core/kid-fby.ps1` | Engine CLI: tìm/cài công cụ, ADB, đọc UI, thu âm kèm hình, khớp khung hình (C# `KidFrameSync` biên dịch bằng `Add-Type`), FFmpeg, xuất bản |
| `core/facebook-links.ps1` | Phân tích/chuẩn hóa URL, ID, phát hiện ID lặp, lịch sử loại JSON (lưu, gỡ, `Evidence`) |
| `core/whisper-language.ps1` | Chẩn đoán ngôn ngữ CLI và cài whisper.cpp/tiny tùy chọn |
| `core/wpf-gif-player.cs` | Decoder/compositor GIF WPF, cache/checkpoint và worker STA; được Base64 hóa vào GUI lúc build |
| `core/updater.ps1` | Đọc manifest đã ký, xác minh chữ ký RSA, tải staging, kiểm SHA256 và công bố READY |
| `core/fix-ket-noi.ps1` | Tiện ích PowerShell chẩn đoán và thử sửa kết nối Android/LDPlayer. Ghi đè `adb.exe` của LDPlayer chỉ sau khi hỏi Y/N (mặc định N, không hỏi được thì không ghi đè) và sao lưu `.bak-<thời gian>`; vẫn đọc mã trước khi chạy |
| `build-local.ps1` / `publish.ps1` / `new-signing-key.ps1` | Biên dịch, kiểm khởi tạo; chuẩn bị version, manifest, chữ ký và thao tác Git khi phát hành; tạo cặp khóa RSA 3072 bit ngoài repo |
| `integrations/tiktok/` | Tích hợp TikTok tùy chọn: `start.ps1` gọi starter autotok; `local.json` gitignore (mục 8–9) |

Đây không phải app web/Electron, không có backend hay SQL riêng. Không có `.csproj`, `.sln`, lockfile công cụ chung hoặc bộ regression test được phân phối trong cây Git tại lần rà này. Chạy tác vụ con bằng quyền người dùng Windows; `ExecutionPolicy Bypass` không tạo sandbox.

### Phụ thuộc ngoài

- ADB điều khiển Android; scrcpy ghi audio và hình màn hình; yt-dlp đọc thông tin và tải hình; FFmpeg/ffprobe cắt, đo, mã hóa, ghép và kiểm file.
- `Find-Tool` xét `tools`, `%LOCALAPPDATA%\Kid-FB.Y`, một số vị trí LDPlayer, PATH và WinGet. Công cụ tìm thấy không nhất thiết đến từ cùng một bản cài.
- Bộ cài tải trực tiếp chỉ từ nguồn chính thức qua HTTPS: scrcpy v3.1 (GitHub Genymobile), yt-dlp bản latest (GitHub yt-dlp), FFmpeg release essentials (gyan.dev) với dự phòng BtbN. Mỗi file phải khớp SHA256 trong file checksum cùng nguồn và đúng magic bytes (zip/exe), nếu không thì bị xóa và không cài. Đây là cấu hình trong mã, không phải tuyên bố phiên bản mới nhất; URL có thể đổi hoặc hỏng. Không đặt callback chấp nhận mọi chứng chỉ hoặc `curl -k`. Giới hạn: đường WinGet, việc chép công cụ có sẵn trên máy và việc chép `adb`/DLL từ LDPlayer không đi qua bước SHA256 này.
- Mỗi lần chạy lô, engine thử `yt-dlp -U` tối đa 45 giây, không quá một lần mỗi 14 ngày (mốc ở `data\ytdlp-update-check.txt`, chỉ ghi khi `-U` thành công).
- Whisper tùy chọn dùng whisper.cpp v1.8.2 x64 CPU và tiny đa ngôn ngữ; archive/model có SHA ghim trong helper. Whisper chỉ phục vụ `-DetectLanguageFile` và nút cài riêng; **Cài tất cả** (`Invoke-SetupDirect` với `all`) không gồm Whisper, và luồng tải không gọi nó.

## 2. Đường đi một video

Đọc `Invoke-OneLink`, `Ensure-VietnameseDubbing`, `Find-VideoSyncOffset` và các helper trong `facebook-links.ps1`.

1. Phân tích URL, xét lịch sử loại theo ID/URL (URL được chuẩn hóa trước khi so), thử giải link share. Gọi yt-dlp `--skip-download` để đọc ID và thời lượng. Mã nhận thời lượng lớn hơn 0,5 giây và không quá 3.600 giây; giới hạn này không chứng minh mọi video trong khoảng sẽ xử lý được. `-ForceRetryRejected` bỏ qua kiểm lịch sử loại cho link này.
2. ADB đặt âm lượng media thiết bị lên mức tối đa, force-stop rồi mở Facebook bằng intent, dùng `uiautomator dump` mới và đọc node thuộc package Facebook. Bounds được cắt theo vùng tổ tiên để tránh chạm node ngoài màn hình.
3. Tìm nút tùy chọn Reel, quét menu tìm **Âm thanh và ngôn ngữ**. Chỉ những mẫu menu đầy đủ/ổn định được dùng để kết luận không có bộ chọn: cần ít nhất ba lần đọc nhất quán trải trên ít nhất 2,0 giây. Menu lỗi/đang tải không đồng nghĩa không hỗ trợ.
4. Nếu menu ngôn ngữ hoàn chỉnh chỉ còn audio gốc và đọc xác nhận ổn định theo cùng quy tắc, hoặc có thông báo không hỗ trợ, trạng thái là `unavailable`.
5. Nếu Tiếng Việt đã checked: hai snapshot mới phải thấy checked. Nếu chưa chọn: chạm dòng Tiếng Việt khả dụng một lần. Sau đó hai lần trở về màn hình Reel cũng được dùng để chấp nhận thao tác. Đây là heuristic phản hồi UI, không chứng minh nội dung audio hoặc chất lượng bản dịch.
6. `selected` cho phép tiếp tục; `unverified` dừng mục hiện tại (reason `dub-unverified`) nhưng không ghi loại vĩnh viễn; `unavailable` lưu lịch sử loại kèm `Evidence` (reason `vietnamese-unavailable`) và dừng. `Stop-ReelForLanguage` **không** xóa file `-1/-2/-3` đã có.
7. **Thu** (vòng tối đa 2 lần, mỗi lần force-stop Facebook): scrcpy `--no-window --no-audio-playback --audio-codec=aac --require-audio --time-limit=ceil(duration + 20) --record=rec.mkv` cộng `--max-size=480 --video-bit-rate=2M --max-fps=30 --video-codec=h264`. Sau khoảng 1,8 giây warmup, mở lại Reel (ghi `tOpen`; `tRec` bắt từ dòng "Recording started" của scrcpy). Nếu scrcpy thoát lỗi sớm (dưới 15 giây) khi có hình, vòng đó chạy lại chỉ âm thanh (`--no-video`, `rec.m4a`). Tương tác khác trên Android có thể ảnh hưởng lần thu.
8. `ConvertTo-FixedRecording` lấp khoảng trống pts bằng `aresample=async=1:first_pts=0` thành `rec-fixed.wav` (trục mẫu = trục pts). Số giây lấp ghi ở `gapFilledSec`.
9. yt-dlp chọn `bestvideo/best`, sắp theo `res,fps,br`, thử tối đa 3 lần (chờ 3 giây rồi 8 giây). Chất lượng thực tế phụ thuộc các format truy cập được của nguồn. `yt-dlp -F` đã cho thấy Facebook chỉ trả một luồng audio gốc, không có luồng lồng tiếng riêng, nên vẫn phải thu qua Android. Thời lượng tải về phải khớp thời lượng đã đo (lệch tối đa 0,5 giây).
10. **Xác định `t0` theo hình** (`Find-VideoSyncOffset`, C# `KidFrameSync`):
    - Mỗi khung của video gốc và của hình trong `rec.mkv` được quy về chữ ký xám 30 fps (ba hình học thử lần lượt: `fit` 24×42 cắt vùng giữa, `mid`, `full` 32×56). Khớp tương quan Pearson trên khoảng thô rồi tinh bước 1 khung, nội suy parabol dưới khung.
    - Giới hạn tìm: `[0, tOpen − tRec + 20 s]`; video gốc dài hơn 300 giây chỉ lấy chữ ký ba đoạn 6 giây (đầu/giữa/cuối). Việc khớp chạy ở tác vụ nền C# có cờ hủy, PowerShell thăm dò mỗi 100 ms để **Dừng** có hiệu lực (theo ghi chú trong mã). Thời gian xử lý của bước khớp chưa có số đo trong tài liệu này.
    - Reel tự phát lặp (`SYNC_LOOP`): nếu đỉnh thứ hai cách đỉnh một xấp xỉ k×thời lượng video (±3 khung, k=1,2,…) và tương quan ≥ 0,9×đỉnh một thì coi là lần phát lặp, chọn lần phát SỚM NHẤT hợp lệ (≥ `tOpen − tRec − 0,3 s`, tức MinOffset) và tính tỷ lệ so với đỉnh thứ hai không phải lặp (không có thì 9,99); engine ghi `SYNC_LOOP: k lan lap`. Ngưỡng đạt bên dưới không đổi.
    - Đạt khi đỉnh tương quan ≥ 0,6, tỷ lệ đỉnh/đỉnh thứ hai ≥ 1,15 và phần đầu video xuất hiện trong bản thu. Độ trôi `syncDriftMs` là chênh giữa các "bậc" d của cửa sổ cục bộ (cảnh báo khi > 80 ms); `t0` lấy theo bậc sớm nhất (giả định audio là đồng hồ chủ; giả định này chưa được xác nhận bằng nghe).
    - `start-missing` (Reel chạy tiếp từ giữa), `low-confidence`, hoặc bản thu còn ngắn hơn video sau khi trừ `t0`: thu lại **một** lần (không tải lại video gốc, không chọn lại ngôn ngữ). Sau lần hai vẫn không đạt thì trạng thái `unverified` với reason tương ứng và không xuất bản. Đầu mỗi vòng `t0`, `t0Onset`, `syncConfidence`, `syncDriftMs` được đặt lại.
    - Chỉ khi không thu được hình (`no-video-sync`) **và** có `-AllowOnsetSync` mới chạy `Get-AudioOnsetInfo` (RMS mỗi 20 ms bằng `astats`, ngưỡng thích nghi theo nền ồn và mức nội dung, tìm từ `tOpen − tRec − 0,3`); `syncMethod` là `onset` và thông điệp ghi có thể lệch 0,5–1,2 s. Không có onset: `no-onset`. Không còn dùng `silencedetect`; nay không có đường nào cắt âm thanh bằng onset khi khớp hình đã thành công.
11. FFmpeg cắt `rec-fixed.wav` tại `t0` theo thời lượng video, đo loudnorm ở lượt một rồi chuẩn hóa ở lượt hai với mục tiêu -16 LUFS/-1,5 dBTP/LRA11 (`linear=true` khi đo được), 48 kHz, AAC 192 kbps. Mức âm trung bình dưới -50 dB hoặc không đọc được: `silent-capture`, không xuất bản.
12. Ghép: không lớp phủ thường `c:v copy`; AV1/VP9 chuyển libx264. Có logo/GIF: bộ lọc rgba/scale/overlay và H.264; mã thử NVENC/QSV/AMF rồi có nhánh libx264. Thời lượng ghép giới hạn bằng `-t` theo thời lượng video thật; **không** dùng `-shortest`. Không có cam kết lossless hoặc mọi MP4 đều H.264.
13. `Test-ValidReelOutput` đọc stream/thời lượng bằng ffprobe, so thời lượng stream video của `-3` với `-1` (lệch tối đa 0,10 giây) và thử decode toàn bộ bằng FFmpeg. Decode dùng ngân sách theo `Get-ReelProcessTimeoutMs` (mã hiện chặn trong khoảng 5–60 phút), có thể vẫn timeout hoặc không bao phủ mọi kiểu hỏng.
14. `Publish-ReelFiles`: trước khi động vào file nào, kiểm từng đích có mở độc quyền được không (trình xem đang mở `-3` thì không); không được thì dừng sớm với reason `output-locked` và KHÔNG tạo thư mục giao dịch. Sau đó stage/backup ba file rồi di chuyển: `-3` vào thư mục xuất, `-1` và `-2` vào `<thư mục xuất>\.cache\` (thư mục được đặt thuộc tính Hidden; lỗi đặt Hidden chỉ cảnh báo). Thư mục giao dịch `.kidfby-publish-*` nằm trong `.cache` (ẩn), chỉ tạo sau khi đích hợp lệ; rollback thành công thì xóa thư mục giao dịch, rollback không trọn thì giữ lại cùng backup. Lỗi publish (phát từ nhánh publish) có reason `publish-failed`, message không đường dẫn (đường dẫn chỉ ghi log). Thư mục giao dịch cũ hơn 24 giờ (quét cả `.cache` và gốc thư mục xuất cho bản cũ) chỉ được dọn khi cấu trúc đúng và không còn file backup. Đây không phải giao dịch ba file nguyên tử khi mất điện; không có journal bền giống updater.

### Tên file và lịch sử

- `ID-3-hoan-chinh.mp4`: bản ghép/lớp phủ; **file duy nhất hiện ở thư mục xuất**.
- `.cache\ID-1-video-goc.mp4`: phần hình không audio, có thể đã chuyển mã. `.cache\ID-2-am-thanh-tho.m4a`: audio sau cắt/chuẩn hóa/AAC; tên được giữ cho reedit, không phải PCM hoặc bản ghi thô nguyên vẹn.
- File `-1/-2` cũ ở thư mục xuất (bản trước đợt 4): không bị tự xóa hay di chuyển. Mọi chỗ đọc (reedit, Kho, xóa) tìm `.cache` trước rồi fallback thư mục xuất (`Get-ReelIntermediatePath` ở engine, `Get-ReelCompanionPath`/`Get-ReelMediaFiles` ở GUI). "Đã có trong kho" khi phát hiện trùng chỉ dựa vào `-3` ở thư mục xuất.
- `.cache\thumbs\<id>.*`: ảnh thu nhỏ và cache ffprobe của Kho (cũ: `.thumbs\` ở thư mục xuất); tự tạo lại được. GUI chỉ quét Kho sau khi nạp `settings.json`.
- `data/rejected-videos.json`: lịch sử loại dùng chung khi đổi thư mục xuất, `Schema=1`, mỗi mục có `VideoId`, `Urls`, `Reason`, `RejectedAt`, `Evidence` (cắt tối đa 2000 ký tự; mục cũ không có trường này vẫn hợp lệ). Ghi file bằng FileStream + Flush rồi replace. File hỏng khi đọc: không ném lỗi làm hỏng mọi link, mà đổi tên thành `rejected-videos.json.corrupt-<yyyyMMdd-HHmmss>-<id>`, ghi cảnh báo và coi như rỗng (bản `.corrupt` giữ để khôi phục tay). `Save-RejectedReel` chỉ nhận `vietnamese-unavailable` hoặc `audio-not-vietnamese` (lý do cũ có thể còn trong file). `Remove-RejectedReel` gỡ theo ID, cùng mutex và ghi file tạm rồi replace; GUI gọi nó từ nút **Bỏ loại**. Khi chạy với `-ForceRetryRejected` và thành công, engine gỡ mục tương ứng. `Remove-RejectedReelMedia` vẫn còn trong `facebook-links.ps1` nhưng không còn caller trong luồng loại (giữ cho công cụ bảo trì gọi tay).
- `output/reup-status.json`: trạng thái Posted/Date theo ID. Nguồn: đánh dấu tay (`ManualPosted`) hoặc đồng bộ lịch sử autotok khi bật tích hợp TikTok (mục 8). Chỉ `Update-ReupMetadata` ghi file. Không phải xác nhận bài đã công khai trên TikTok.
- ID trùng trong cùng input được gộp. Khi đã có `-3` không rỗng ở thư mục xuất, GUI có lựa chọn bỏ qua hoặc tải và ghi âm lại. Đây là kiểm tên/ID/file, không so sánh nội dung video bằng fingerprint.

### Sự kiện máy đọc (engine → GUI)

Engine in qua `Write-Host`, GUI đọc ở Information stream (`Invoke-EngineEvent`), ẩn khỏi log hiển thị nhưng vẫn ghi file log. Dòng log cũ của engine giữ nguyên chữ.

- `@@KIDFBY_STAGE {"step":<1-7>,"name":"<ASCII>"}`: phát trong `Write-Step` (1 công cụ, 2 thiết bị, 3 đọc ID/thời lượng, 4 kiểm tra lồng tiếng, 5 thu, 6 xác định `t0` và cắt, 7 ghép/xuất; ký tự ngoài ASCII được thay bằng `?`).
- `@@KIDFBY_RESULT {...}`: phát đúng một lần cho mỗi link ở khối `finally` của `Invoke-OneLink`. Trường: `v` (=1), `status` (`ok|rejected|unverified|failed|cancelled`), `id`, `url`, `video` (đường dẫn `-3`), `source` (`-1` trong `.cache`), `audio` (`-2` trong `.cache`), `reason`, `message` (không dấu, dành cho log), `t0`, `tOpen`, `tRec` (giây), `gapFilledSec`, `encoder` (`copy`, `libx264`, hoặc encoder phần cứng đã chọn), `durationSec`, `syncMethod` (`video|onset|null`), `syncConfidence` (đỉnh tương quan), `t0Onset`, `syncDriftMs`, `captureAttempts` (1 hoặc 2).
- `reason` do engine phát: `ok`, `already-rejected`, `vietnamese-unavailable`, `dub-unverified`, `invalid-link`, `metadata-failed`, `invalid-duration`, `history-save-failed`, `capture-failed`, `audio-failed`, `download-failed`, `duration-mismatch`, `start-missing`, `low-confidence`, `no-video-sync`, `no-onset`, `short-capture`, `silent-capture`, `mux-failed`, `invalid-output`, `output-locked`, `publish-failed`, `exception`, `stopped`. `output-locked` (status `failed`): file `-3` đích đang được mở ở ứng dụng khác, phát trước khi tạo giao dịch; GUI dịch "File video đang được mở ở ứng dụng khác — đóng trình xem rồi thử lại" (`$script:reasonText`). `publish-failed` nay phát từ nhánh publish (xuất bản thất bại, file cũ được giữ). GUI tự thêm `missing-output` (engine báo ok nhưng không thấy file) và `gui-exception`. Mã lạ hiển thị "mã <reason>".
- GUI ưu tiên RESULT để phân loại kết quả; chỉ khi không có RESULT mới dùng regex log cũ (`REEL_REJECTED:` và dòng `Video : ...mp4`), vì vậy đổi format log không làm hỏng luồng chính nhưng làm hỏng đường dự phòng.

## 3. GUI và vòng đời tác vụ

Điểm bắt đầu: `Start-Link`, `Start-Engine`, `Pump-Output`, `Finish-Engine`, `Complete-QueueItem`, `Next-Link`, `Request-Stop`/`Stop-Engine`, `Get-QueueItemOutcome`.

- Một runspace xử lý một mục. GUI bơm Information/Error stream, chờ completion rồi dispose trước khi chạy mục kế tiếp. Kết quả xuất đọc từ RESULT (xem trên). Tham số tùy chọn `-ForceRetryRejected`/`-AllowOnsetSync` chỉ được truyền khi `Test-EngineParameter` thấy engine hỗ trợ.
- Tác vụ thành công tăng số đã lưu. Video bị loại tăng số bị loại, link đã loại trước đó tăng số bỏ qua. Lỗi hoặc `unverified` được ghi và chuyển tiếp; không retry vô hạn (ngoài một lần thu lại của engine). Lỗi thiết lập runspace giải phóng trạng thái và dừng hàng đợi với các link chưa khởi động trong Logs.
- Dừng (nút chính hoặc `Esc`) hỏi xác nhận khi còn ít nhất một mục chưa chạy, nếu không thì dừng ngay. Dừng đặt cờ, dừng pipeline và kết thúc các process đăng ký trong `ProcessRegistry`. Tổng kết ghi "Đã dừng · ...", không ghi "Hoàn tất". Không phát preview giữa các mục thu âm; preview ẩn thì tạm dừng.
- Hàng đợi hiển thị từng link thành thẻ với bảy bước, badge, thông điệp, cảnh báo trôi đồng bộ và nút Thử lại/Mở/Bỏ loại. **Thử lại** của dòng sinh từ Ghi âm lại chạy lại đúng luồng Ghi âm lại.
- `Start-RecordingAgain`: lấy ID từ tên `ID-3-hoan-chinh.mp4`, đặt hàng đợi một mục với thư mục xuất tạm thời là thư mục chứa video (không ghi vào settings, khôi phục sau đó), truyền `-ForceRetryRejected`. File cũ được thay qua publisher khi thành công; lỗi tạm thời/Dừng giữ file cũ.
- `Start-Reedit`/`Invoke-ReeditVideo`: dùng lại `-1` và `-2` (tìm `.cache` trước, rồi thư mục xuất); không thu/tải lại. Đầu vào thiếu sẽ dừng, không tự tải lại. Chỉ ghi đè `-3` tại chỗ qua publisher; không đổi `-1/-2`. Có đường preview gốc sạch để sửa overlay.
- `Remove-ReelFiles`: nhả nguồn player nếu cần, stage/backup/xóa `-3`, `-1/-2` trong `.cache`, `-1/-2` cũ ở thư mục xuất và ảnh thu nhỏ, thử phục hồi lỗi bắt được; lỗi phục hồi báo đường dẫn giữ lại. Không nên mô tả là không thể mất dữ liệu trong mọi sự cố.
- **Cài đặt › Tùy chọn**: công tắc đồng bộ theo âm thanh (mặc định tắt; lưu ở `settings.json`, `sync.allowOnset`); **Dọn file trung gian cũ** (hộp thoại hai lựa chọn: chuyển vào `.cache` mặc định hoặc xóa vĩnh viễn; Hủy là nút mặc định; không ghi đè file đã có trong `.cache`); **Dọn cache sửa lại** (xóa cả `.cache` sau xác nhận, mất khả năng sửa logo cho video cũ).
- Giao diện đợt 5 (`core/kid-fby-gui.ps1`, `core/ui/*.xaml`): khung xem trước bỏ vỏ điện thoại, video 9:16 viền sticker, chip độ phân giải và nút ⤢ phủ góc, thanh tua phủ đáy tự ẩn sau 2 giây; chiều rộng cột tính từ chiều cao thân (cùng kích thước khi rỗng và khi có video). **Xem lớn** (nút, phím `F`, nhấp đúp thẻ Kho, `Esc` thoát) ẩn trang bên trái; overlay logo/GIF kéo thả dùng được ở cả hai chế độ. Chiều cao logic < 640 px: chế độ gọn (sidebar 64, ẩn trang trí, bọc ScrollViewer, thẻ 7 bước thành 1 dòng chấm; khung xem trước < 60 px chỗ trống thì ẩn, chỉ còn Xem lớn). Kho là lưới ảo hóa 3–4 cột. Toast góc dưới phải, tối đa 2, gộp "+N". Có pill "Chưa xác nhận" riêng (không tính vào lỗi). Mọi vùng bấm ≥ 44×44; màu chữ chỉnh theo tương phản. Trang Giới thiệu ghi công baoyu-skills (Jim Liu, MIT) và Nunito (OFL 1.1). Log engine ở trang Nhật ký giữ không dấu (log kỹ thuật).
- Các trang: Nguồn, Thương hiệu, Hàng đợi, Kho (có tab Lịch sử đã loại), Cài đặt (Công cụ, Tùy chọn, Nhật ký, Cập nhật, Giới thiệu). Panel nội bộ còn tên `PanelRev`, là vùng thao tác video/xem lại; nút duyệt `BtnKeep`/`BtnSkip` của luồng duyệt cũ đã bỏ.
- Cài đặt người dùng ở `data\settings.json` (thư mục xuất, logo, GIF, công tắc đồng bộ, cửa sổ); nếu nạp lỗi giữa chừng, phiên đó không ghi đè file. Lỗi ĐỌC do khóa tạm (IOException/UnauthorizedAccess) khác file hỏng: không đổi tên `.corrupt`, thử lại 3 lần cách 300 ms; vẫn lỗi thì dùng mặc định và KHÔNG ghi `settings.json` trong phiên (`settingsReady=$false`), có toast cảnh báo. Log: `logs\gui-YYYYMMDD.log` (xoay vòng khi vượt 5 MB), `logs\crash-*.log`; log gui/crash cũ hơn 14 ngày bị xóa khi khởi động. `KID_FBY_NO_MSGBOX=1` làm GUI và launcher không bật hộp thoại (dùng cho kiểm thử).
- Track A mở M4A `-2`; Track B mở MP4 `-3`. Đây không phải so sánh audio nguyên bản của Facebook với audio đã dịch.
- GUI ghi `core\_update\gui.hwnd` (`pid|hwnd|ticks khởi động UTC`) khi mở cửa sổ và xóa khi thoát; launcher lần hai đọc file này rồi `ShowWindow(SW_RESTORE)` + `SetForegroundWindow`.
- Khi cập nhật sẵn sàng, GUI khởi động `Kid-FB.Y.exe -AfterUpdate` rồi đóng; launcher mới chờ tối đa 60 giây để lấy mutex từ launcher cũ trước khi áp dụng.

## 4. Logo, GIF và trình xem

- `Get-MovingLogoMuxArgs` tạo filter graph FFmpeg cho bản xuất. Vị trí/kích thước dùng hệ tọa độ của video; custom geometry và chế độ phủ đầy được truyền từ GUI.
- WPF overlay có drag, tám grip resize, preset/custom và chọn lớp đang thao tác. Logo `Free` chạy theo biểu thức, `Fixed` đứng yên tại preset/custom; các chế độ không có ý nghĩa tạo fingerprint độc nhất.
- `WpfGifPlayer` dùng GifBitmapDecoder, WriteableBitmap và BGRA để dựng frame/disposal. `RawGifFrame` vẫn được cache và render sử dụng, không phải khai báo thừa. `core/wpf-gif-player.cs` không thay đổi so với `main` trong nhánh này.
- `Start-GifSelectionWorker` chuẩn bị GIF ngoài dispatcher; `WpfGifPlaybackWorker` có worker STA riêng, request thời gian mới nhất và bitmap đóng băng đã hoàn tất. Có cache/checkpoint và giới hạn canvas/frame/bộ nhớ trong `.cs`; đây là giới hạn do mã đặt, không phải số đo RAM toàn bộ app.
- Khi GIF ẩn/thu nhỏ, mã bỏ yêu cầu decode theo tick. `Close` có thể chờ worker tối đa khoảng 100 ms qua Join. Không có phép đo mới để suy ra FPS, CPU hay độ mượt trên mọi máy.
- `MediaElement` WPF vẫn phát video/audio; GIF hiện qua `ImgVideoGif` từ decoder/worker, không có MediaElement GIF dự phòng.
- `Test-GifFile` xem header/frame/disposal qua .NET và thử FFmpeg nếu tìm thấy; việc chấp nhận trailer bị thiếu tùy decoder không đồng nghĩa mọi GIF hỏng đều bị nhận ra.
- Preview và FFmpeg là hai bộ dựng; cần so trực quan nhiều mốc thời gian sau các thay đổi geometry/alpha/disposal. Đen đặc là pixel có nội dung, không được chromakey xóa chỉ vì màu đen.
- Tua dùng MediaElement.Position, chuột/slider và phím trái/phải. Giá trị Position hoặc nhịp Dispatcher không phải bằng chứng frame đã trình bày hoặc âm thanh đã settle.

## 5. Build, phiên bản và cập nhật

### Nguồn → EXE → manifest

1. Sửa C#/PS/XAML. PS và XAML giữ UTF-8 BOM/CRLF, C# CRLF. Font là nhị phân, không chuẩn hóa dòng.
2. `core/version.txt` là số x.y.z dùng cho GUI và metadata launcher. Build sinh AssemblyInfo tạm ngoài repo, compile Assembly/File=x.y.z.0, Product=x.y.z; không còn hardcode trong Program.cs.
3. `build-local.ps1` thay đúng assignment `$wpfGifPlayerB64` theo byte `.cs`, parse sáu PS (kể cả `updater.ps1`), kiểm hai XAML (BOM, CRLF, XML hợp lệ) và ba font (chữ ký TrueType), dùng `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, compile icon và **mười ba resource**.
4. Build thử EXE `-SelfTest` trong thư mục tạm (đặt `KID_FBY_ALLOW_MULTI=1` để không va mutex với bản đang mở), kiểm exit, `BOOT_OK` và hash từng resource (font phải trùng từng byte); build không đổi `version.json` hoặc push/tag/commit.
5. `publish.ps1 -Version <mới> -NoPush` tăng version, build, ghi manifest và chữ ký. Nó vẫn đổi file/version cục bộ. Không dùng lệnh này như lệnh kiểm tra không side effect. Lệnh không có `-NoPush` còn có thao tác Git (`git add -A`, commit, tag, push); đọc phần cuối script trước khi chạy.
6. Manifest ghi hash raw cho binary/ZIP; text được bỏ BOM và chuẩn hóa CRLF→LF trước SHA256, size vẫn là byte file trên đĩa. Hash raw của PS không nhất thiết bằng hash chuẩn hóa trong manifest. Manifest liệt kê file trực tiếp trong `core/` (`.ps1 .ico .txt .json .zip`), `core/ui/*.xaml`, `core/ui/fonts/OFL.txt` và `Kid-FB.Y.exe`; **các file `.ttf` chưa được liệt kê** (font đến máy khách qua EXE mới, vì updater cũ chuẩn hóa text sẽ làm hỏng font). `core/wpf-gif-player.cs` không nằm trong manifest.

`publish.ps1` hiện không tự rollback version/config/EXE khi bước build lỗi; cần kiểm tra diff và phục hồi trên bản sao hoặc bằng thay đổi đã xác định. `-NoPush` còn có thể khởi tạo Git nếu thư mục chưa có repo, dù không commit/tag/push.

Mười ba resource nhúng: chín file `kid-fby-gui.ps1`, `kid-fby.ps1`, `whisper-language.ps1`, `facebook-links.ps1`, `fix-ket-noi.ps1`, `Kid-FB.Y.ico`, `kid-logo.zip`, `ui/Theme.xaml`, `ui/MainWindow.xaml`, cộng bốn file `ui/fonts/Nunito-Regular.ttf`, `Nunito-SemiBold.ttf`, `Nunito-ExtraBold.ttf`, `OFL.txt`. `updater.ps1`, `version.txt`, `update.json` không nhúng và cần được phân phối trong `core`.

`EnsureResources` so một **stamp** (`core\.resources-stamp` = FileVersion EXE + SHA256 tổng các resource). Stamp khớp: chỉ tạo lại file thiếu/rỗng. Stamp thiếu hoặc khác: đối chiếu hash và ghi lại file khác hash, trừ khi `core\version.txt` đã mới hơn EXE (updater đã nâng cấp script) thì chỉ tạo file thiếu. Chép EXE mới lên core cũ vì vậy làm mới script khi stamp khác; nhưng đừng tin vào cơ chế này thay cho việc build cùng checkout hoặc dùng đường update/đủ bộ file. Không xóa cả core để ép giải nén vì có cấu hình/trạng thái cần xem xét. `.resources-stamp` là file sinh ra, chưa nằm trong `.gitignore`.

### Update và ký manifest

`core/update.json` chứa repo/branch. Updater chỉ coi là bản mới khi manifest.version lớn hơn local version, nên thay mã cùng số phiên bản có thể không tới máy đã cài. `minLauncher` trong manifest được `updater.ps1` kiểm với FileVersion của `Kid-FB.Y.exe`; launcher thấp hơn thì từ chối cập nhật tự động.

Luồng: tải `version.json` và `version.json.sig` (nguồn `raw.githubusercontent.com`, mirror `ghproxy.net`/`gh-proxy.com` chỉ là dự phòng), xác minh chữ ký RSA-SHA256 (khóa công khai nhúng trong `$UpdatePublicKeyXml`) **trên đúng byte manifest đã tải**, rồi mới đọc manifest. Từng file payload phải khớp SHA256 trong manifest đã xác thực trước khi ghi staging và READY bền. Launcher giữ khóa, `RecoverPending` trước `ApplyUpdate`, kiểm đường dẫn/dung lượng, sao lưu và thay version cuối. Journal/checksum/token/BOOT_OK tham gia xác nhận hoặc phục hồi; GUI mới không báo BOOT_OK trong 120 giây thì rollback và đánh dấu phiên bản đó lỗi (`failed-<ver>.flag`).

**Khóa ký đã có.** `new-signing-key.ps1` tạo cặp RSA 3072 bit (mặc định ở `%USERPROFILE%\.kidfby\`, từ chối lưu trong repo, từ chối ghi đè nếu không có `-Force`). Khóa công khai đã gắn trong `$UpdatePublicKeyXml` của `core/updater.ps1`, không còn placeholder. Khóa riêng nằm ngoài repo ở `%USERPROFILE%\.kidfby\update-signing-private.xml` trên máy phát hành; **phải sao lưu**, vì mất khóa thì không phát hành được cập nhật cho máy đã cài. `publish.ps1` dừng khi thiếu khóa riêng, khi khóa riêng nằm trong repo, khi còn chuỗi `<<PUBLIC_KEY_PLACEHOLDER>>` trong `core/updater.ps1` (bước kiểm này chỉ khớp đúng chuỗi đó), hoặc khi modulus khóa công khai không khớp khóa ký. `version.json` và `version.json.sig` của 2.1.0 đã ký và nằm trên `main`. Chữ ký manifest bảo vệ tính toàn vẹn nguồn cập nhật; nó không phải chữ ký Authenticode của EXE.

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

Chạy SelfTest trong thư mục sao chép riêng khi không muốn ghi trạng thái `_update` vào checkout. SelfTest không kiểm dịch, chất lượng audio, đồng bộ tiếng–hình, queue end-to-end, lỗi khóa file hay hiệu năng. Không có regression suite kèm bản Git này; các harness tạo ngoài repo của phiên làm việc không mặc nhiên có mặt trên máy người nhận.

### Checklist tái hiện khi nhận việc

- Khởi động từ thư mục mới và đường dẫn có space/`[]`; đối chiếu version GUI/EXE/core/manifest và mười ba resource (kể cả font).
- Mở lần hai cùng thư mục (phải đưa cửa sổ đang chạy lên trước, kể cả khi đang thu nhỏ; không có `gui.hwnd` hợp lệ thì mới còn MessageBox); mở hai thư mục khác nhau (không chặn nhau).
- Hàng đợi có thành công/loại/lỗi; Dừng khi đang ghi và lúc completion (có hộp xác nhận khi còn mục chờ); không phát audio preview giữa các mục.
- Ghi âm lại từ kho: đúng ID/thư mục, không chạy lại queue cũ, giữ hash bản cũ khi lỗi hoặc hủy. Phân biệt engine giả lập với Android/tải thật.
- Menu có/không bản dịch, UI đang tải/hỏng XML, node ngoài viewport, Tiếng Việt sẵn chọn/chưa chọn. Không suy từ lệnh tap exit0 rằng đã áp dụng. Loại một video không được làm mất file đã có.
- Đồng bộ: Reel tự phát lặp (`SYNC_LOOP`, thử Reel ngắn < 15 s có tiếng Việt), Reel chạy tiếp từ giữa (`start-missing`), video tối/ít chuyển động (`low-confidence`), thiết bị không ghi hình (có/không có công tắc onset), bản thu ngắn, độ trôi > 80 ms; kiểm `rec.mkv` bằng `-Keep`. **Nghe và xem** ở nhiều mốc (đặc biệt đầu clip) để tìm lệch mà số Position hoặc độ tin cậy không thể hiện.
- Thư mục xuất chỉ có `-3` và `.cache` ẩn; reedit đọc từ `.cache` và từ file cũ ở thư mục xuất; Xóa dọn đủ ba nơi; hai nút dọn ở Tùy chọn.
- Bỏ loại và `-ForceRetryRejected`: mục được gỡ khi thành công; hash `data\rejected-videos.json` đúng như kỳ vọng.
- PNG/GIF trong suốt/đen đặc/disposal, kéo cạnh/góc/custom/preset/fullframe; so preview với export.
- File `-3` đang mở ở trình xem (phải ra `output-locked`, không sót `.cache\.kidfby-publish-*`), file bị khóa, lịch sử JSON lỗi (phải ra `.corrupt-*` và coi như rỗng) hoặc khóa, settings bị khóa tạm lúc đọc, thiếu đầu vào reedit, thiếu companion tool, timeout process, startup runspace lỗi.
- Giao diện ở 1366×768, chế độ gọn (cao < 640 px logic) và DPI 125/150% thật; Nunito thật sự được dùng (không rơi về Segoe UI).
- Update trên bản sao với cặp khóa thử: manifest sai chữ ký, payload sai hash, ngắt giữa giao dịch, phục hồi, `-AfterUpdate`, version cuối và giữ nguyên dữ liệu người dùng.

### Đã kiểm bằng gì, chưa kiểm gì

Các báo cáo và harness nằm ngoài repo (thư mục tạm của phiên làm việc, không có trong clone Git). Số liệu dưới đây là ghi nhận của phiên làm việc, không thay cho việc chạy lại.

- Đợt đồng bộ và giao diện v3 (commit `d2b43cd`): unit engine 54/54 và khớp khung hình 8/8 (fixture và cặp mẫu thật), harness WPF 118/118 (engine giả lập), kiểm chữ ký manifest 8/8 và quote đối số 8/8 (launcher), và một lượt GUI thật trên LDPlayer (hàng đợi ba link, Dừng, Kho phát/tua, đóng/mở lại) đạt. Đã đo `yt-dlp -F` (một luồng audio gốc) và đo onset cũ cắt muộn khoảng 0,45–1,25 s so với khung 0.
- Đợt 4 (`345d753`, chỉ một file hoàn chỉnh + `.cache` + giao diện cute) và lượt sửa theo duyệt toàn nhánh (`08eddcb`, thu lại khi thiếu, hủy khi khớp hình, dọn code chết): tài liệu này **không** dẫn được kết quả chạy hợp lệ cho riêng hai commit đó; coi là chưa kiểm cho tới khi chạy lại build, SelfTest và các ca ở checklist.
- Lượt dọn 19/10/2026 (bản 2.0.1 trước nhánh này) từng kiểm 30 assertion engine, harness GUI, metadata build và một lượt Android thật (Reel `4340858519560389`). Mã đã thay đổi lớn từ đó (engine, GUI, launcher, updater), nên kết quả ấy chỉ còn giá trị lịch sử.
- Phát hành 2.1.0 (21/10/2026): đường cập nhật thật, bản sao app 2.0.1 (updater cũ) nhận 2.1.0 từ GitHub, tải 11 file, SHA256 khớp, launcher cũ áp dụng; EXE 2.1.0.0; lần mở thứ hai launcher mới giải nén phông Nunito; `-SelfTest` exit 0; updater mới kiểm chữ ký trên GitHub thật (`signed=true`). Sau khi cập nhật từ 2.0.1 cần mở app thêm một lần để có Nunito, vì phông không nằm trong manifest.
- Chạy thật 21/10/2026, 20 link: 2 lưu; 16 `vietnamese-unavailable` (bằng chứng: menu chỉ có "Âm thanh gốc" và "Tính năng dịch giọng nói hiện chưa hỗ trợ", đọc 3 lần trong khoảng 6,5 s); 2 chưa xác nhận (một mục `dub-unverified`; một mục `low-confidence` với đỉnh tương quan 0,886 và tỷ lệ 1,10 sau 2 lần thu); 0 lỗi. Một video xuất với `syncDriftMs` 949 (có cảnh báo, chưa nghe kiểm). Giới hạn: ngưỡng tỷ lệ 1,15 có thể chặt với video nhiều cảnh giống nhau; trôi lớn (> ~300 ms) hiện vẫn xuất kèm cảnh báo, chờ chủ dự án nghe kiểm để quyết định có chặn hay không.
- Đợt 5: hai bộ kiểm định độc lập, **nằm ngoài repo trên máy làm việc** (thư mục tạm của phiên, không có trong clone Git): `qa-independent` (280 ca; lần chạy 21/10/2026: 254 PASS; các FAIL còn lại là test kỳ vọng hành vi cũ đã đổi có chủ đích, giới hạn đã biết Reel < 2 s và onset ngắt quãng, và khóa ký/manifest khi đó chưa phát hành; nay đã có 2.1.0) và `ui-critic` (đo video: 1440×900 → 381×677, 1366×768 → 280×498, 1920×1080 → 455×809, 1366@150% → 158×282).
- **Chưa kiểm:** Reel tự lặp thật trên Android (`SYNC_LOOP` mới chạy với fixture); nghe/xem lệch tiếng–hình bằng tai (mới đo bằng khớp khung hình); đường tự thu lại (`start-missing`/`low-confidence`/`short-capture`) mới chạy qua giả lập, các lượt Android thật đều đạt ngay lần một; độ trôi 150–320 ms xuất hiện thường xuyên ở player Facebook và giả định "audio là đồng hồ chủ, lấy bậc d thấp nhất" chưa được xác nhận bằng nghe; updater với manifest đã ký thật chỉ kiểm một lần trên đường 2.0.1 → 2.1.0 (máy phát hành, không kiểm trên máy khác); `publish.ps1` đã dùng cho 2.1.0 nhưng chưa kiểm lại; DPI thật (số đo 150% ở trên là mô phỏng) và nhiều màn hình chưa kiểm; chất lượng dịch Meta không thuộc phạm vi kiểm.
- Chưa bao phủ toàn bộ biến thể UI Facebook, thiết bị Android, mirror tải/cài, codec/driver GPU, clip dài (đường chữ ký ba đoạn cho video trên 300 giây) hoặc sự cố ổ đĩa/nguồn điện. Không lấy kết quả này để suy ra FPS, CPU, đồng bộ audio hay tất cả tính năng đều đúng.

Thương mại hóa (khóa giấy phép, chữ ký Authenticode, installer, repo riêng tư, rà giấy phép FFmpeg bản GPL) chưa làm.

## 7. Thay đổi hợp đồng và phạm vi dọn

Bản 2.0.1 đã bỏ switch CLI `-SkipLanguageCheck`; script cũ truyền switch này cần bỏ đối số đó. Điều kiện tải vẫn là phản hồi UI Meta, không bật lại Whisper.

Hợp đồng đợt 5: reason mới `output-locked` (status `failed`); `publish-failed` phát từ nhánh publish; thư mục giao dịch xuất bản chuyển vào `.cache\.kidfby-publish-*`; file mới `core\_update\gui.hwnd` (GUI ghi, launcher đọc); log mới `SYNC_LOOP`.

So với bản 2.0.1, bản 2.1.0 (nhánh `audit-fixes-2.1`, nay cùng commit với `main`) thêm: tham số CLI `-ForceRetryRejected`, `-AllowOnsetSync`; hai dòng sự kiện `@@KIDFBY_STAGE`/`@@KIDFBY_RESULT`; hàm `Remove-RejectedReel` và tham số `Evidence` của `Save-RejectedReel`; thay đổi hành vi loại (không xóa file đã có); đồng bộ theo hình thay cho onset khi cắt âm thanh; thư mục xuất chỉ còn `-3` và `.cache` ẩn; chuẩn hóa URL; bộ cài chỉ nguồn chính thức với SHA256; single-instance và `-AfterUpdate`; manifest ký RSA; giao diện tách `core/ui` kèm phông; `data\settings.json` và `logs\`. Result của `Invoke-OneLink` ở dạng đối tượng PowerShell vẫn không có `AudioLanguage`; chẩn đoán riêng vẫn dùng `-DetectLanguageFile`.

Giữ media đầu vào/bản hoàn chỉnh/lịch sử/công cụ đang dùng. Các fallback tải/cài, lớp GIF/cache/worker, helper Whisper, lịch sử và dữ liệu phục hồi còn có caller hoặc mục đích nên được giữ. Thư mục `output\.thumbs` có thể còn trên máy đã chạy bản thử trước đợt 4 và xóa tay được; ảnh thu nhỏ mới nằm ở `.cache\thumbs`. Tài liệu này cập nhật theo commit `7f5851a` trên `main` và chưa commit theo yêu cầu của tác vụ; không viết lại lịch sử Git.

## 8. Tích hợp TikTok cục bộ — 24/10/2026, local, chưa phát hành

Mục đích: đăng video từ Kho lên TikTok qua autotok (`integrations/autotok/`, trong repo), không sao chép file tay. Facebook vẫn là luồng chính; tích hợp này không đổi engine tải Facebook, ngưỡng đồng bộ, giao thức STAGE/RESULT, phiên bản 2.1.0 hay manifest đã ký.

### Bật hay tắt

- `Get-TikTokIntegration` đọc biến `KID_FBY_AUTOTOK_STARTER` hoặc `integrations/tiktok/local.json` (`{"Starter": "..."}`, file này nằm trong `.gitignore`). Starter phải tồn tại; quy tắc giống `integrations/tiktok/start.ps1`. Đánh giá một lần lúc khởi động.
- **Không cấu hình**: đúng hành vi trước tích hợp. Nút "Sao chép để đăng", badge thẻ bật/tắt dấu đã đăng thủ công, không có timer đồng bộ, không băm SHA256.
- **Có cấu hình**: nút "Đăng video" dưới preview mở hộp đăng; "Sao chép để đăng" nằm trong menu thêm của thẻ; Ctrl+C vẫn sao chép. Được đăng khi hàng đợi tải đang chạy.
- Trên máy này `integrations/tiktok/local.json` trỏ tới `integrations/autotok/start.ps1`.

### Trạng thái đồng bộ (`reup-status.json`)

- File nằm ở thư mục xuất, theo từng ID video: `Posted`, `Date`, `ManualPosted`, `ManualDate`, `Source='autotok-history'`, `History` (bản rút gọn: key, request_id, username, status, publish_uncertain, prior_uncertain, planned_for, accepted_at, created_at, time_source, sha256), `FileSha256`. `Posted` là trường tổng hợp để bản cũ đọc được.
- Mục cũ không có `Source` được chuyển thành `ManualPosted`. Đồng bộ không bao giờ ghi đè dấu đánh tay.
- Chỉ `Update-ReupMetadata` ghi file này: mutex có tên, đọc một lần, thay file nguyên tử (thử lại khi `IOException`). Bên đọc mở với `FileShare ReadWrite|Delete`. File hỏng không bị ghi đè.
- Đây là ACK của uploader, không chứng minh bài đã công khai trên hồ sơ TikTok.

### Đồng bộ nền

- `Start-TikTokStatusSync`/`Invoke-TikTokSyncTick` chạy trong runspace riêng (`InitialSessionState`), không trên luồng UI.
- Kiểm health trước; backend tắt thì không băm hash. Tra cứu theo lô 500 video. SHA256 đọc theo khối, hủy được. Cache định danh `.cache\tiktok-identities.json`, chỉ ghi khi có thay đổi.
- Không tới được backend: hiện nhãn "TikTok chưa cập nhật". Lỗi báo một lần cho mỗi request_id trong phiên, chỉ với biên nhận trong 24 giờ.

## 9. Hàng chuyển nền và biên nhận — 24/10/2026, local, chưa phát hành

Mục này thay phần hộp đăng và đồng bộ của bản 23/10 (đã bỏ).

### Luồng khi bấm đăng

- Ghi nguyên tử `.cache\tiktok-posts\<request_id>.job` (payload có caption, xóa khi server nhận lịch hoặc có trạng thái cuối) và `<request_id>.json` (biên nhận, không có cookie hay caption).
- `Start-TikTokBackgroundJob`/`Start-TikTokJobProcess` mở PowerShell 5.1 ẩn chạy `-TikTokJobFile`. Hộp đóng ngay; tiến trình tiếp tục khi GUI đóng.
- Tiến trình giữ `<id>.lock` (`FileShare.None`, `DeleteOnClose`) suốt đời. Trước khi gửi, tạo `.cache\tiktok-posts\<id>.clean.mp4` (`New-TikTokCleanCopy`), kiểm bằng `Test-TikTokCleanFile`: tag/chapter của ffprobe, dấu lavf/lavc, x264/x265, facebook; decode; độ dài lệch ≤ 50 ms; số keyframe và số khung khớp nguồn. Nếu không đạt thì thử AAC re-encode, rồi H.264 re-encode.
- Gửi bản sạch với field `source_sha256` (hash của `-3` gốc). Xong thì xóa bản sạch. Làm sạch lỗi: không gửi gì, trạng thái `transfer_failed`, giữ `.job`.
- Trạng thái lấy từ phản hồi server. `.job` chỉ bị xóa khi có `schedule_id` hoặc trạng thái cuối.

### Trạng thái biên nhận (`Get-TikTokReceiptState`)

- Worker còn sống: "Đang chuyển video", chặn tài khoản đó.
- Worker chết và backend 404 quá 2 phút, hoặc `transfer_failed`: "Chưa chuyển được", không chặn. Có "Thử chuyển lại" (cùng `.job`, cùng request_id) và "Bỏ biên nhận" (đổi tên `.archived-<ts>`, không xóa).
- Thăm dò luân phiên, tối đa 20 GET mỗi nhịp. Xóa video bị từ chối khi còn khóa worker. Dọn cache giữ `.cache\tiktok-posts`.

### Hẹn giờ trên TikTok (24/10/2026)

- Hẹn giờ đặt lịch trên TikTok, không giữ lịch chờ trên máy. Job gửi ngay kèm `schedule_time` (giây UTC) qua uploader.
- Khoảng cho phép: từ bây giờ + 20 phút (làm tròn lên phút) đến + 10 ngày. Chế độ riêng tư không hẹn được.
- Thành công: `status` = `succeeded`, `link_state` = `scheduled_on_tiktok`, `tiktok_schedule_time` có giá trị. Thẻ hiện "Đã hẹn trên TikTok"; chỉ tắt máy khi thẻ hiện dòng này.
- Đổi giờ hoặc hủy làm trong TikTok Studio (PATCH đổi giờ trả 409). Xóa trong app chỉ xóa bản ghi của app.
- Job chờ cục bộ cũ, trễ hơn 2 giờ: đánh `failed` "Lỡ giờ khi máy tắt — chưa đăng" (chưa đăng). Bấm thử lại job này sẽ đăng ngay.
- GUI tắt chức năng hẹn khi backend cũ (`/health` không có `native_schedule`).
- Chưa kiểm: bài hẹn có lên đúng giờ khi máy tắt.

### Link bài đăng (24/10/2026)

- Uploader lấy mã bài từ các khóa rõ ràng của phản hồi publish (`item_id`, `aweme_id`, `single_post_resp_list[].item_id`, `data.item_id`...). Phản hồi đã lọc (bỏ khóa và giá trị nhạy cảm) lưu ở `publish_response_json` để sau này xem dạng thật.
- Cột DB mới (`SCHEMA_VERSION` 3): `post_id`, `post_url`, `creation_id`, `link_state`, `link_attempts`, `link_next_at`, `tiktok_schedule_time`, `publish_response_json`, `caption`.
- `post_url` = `https://www.tiktok.com/@<tài khoản>/video/<id>` chỉ khi nhãn tài khoản là handle hợp lệ; nếu không, chỉ hiện "Mã bài" để sao chép.
- Tra cứu dự phòng `find_post` (`autotok/posts.py`) là STUB, luôn trả None: `link_state` đi từ pending sang gave_up. "Thử lấy lại link" gọi `POST /api/history/<key>/refresh-link` (chỉ đọc, không đăng lại).
- GUI: "Mở bài đăng" (kiểm URL trước khi mở), "Sao chép link", "Sao chép mã bài", "Thử lấy lại link".
- Chưa kiểm: phản hồi publish thật có chứa mã bài hay không.

### Hashtag hay dùng (24/10/2026)

- Lưu ở `data\tiktok-hashtags.json`, riêng từng máy; không đưa vào git.
- Chip "Hashtag hay dùng" hiện dưới ô caption, tối đa 20 mục theo số lần dùng. Gõ một phần hashtag để lọc.
- Học khi bấm đăng; tối đa 300 mục. Chuột phải hoặc phím Delete → "Xóa khỏi gợi ý".
- File hỏng: đổi tên `.corrupt-<ts>`, coi như rỗng.

### Engine (`core/kid-fby.ps1`) — áp dụng cho mọi `-3`, kể cả khi tắt tích hợp

- `Get-CleanOutputArgs` bỏ metadata: `-map_metadata -1`, `-map_chapters -1`, bitexact, tag handler/encoder rỗng, lọc SEI (`remove_types=6`) với H.264.
- Lồng tiếng AAC thêm `-fflags +bitexact -flags:a +bitexact`: audio giải mã khác nhẹ (~47 dB SNR), timing gói giữ nguyên (đo trên fixture).
- `Invoke-CleanVideoMux` cho đường stream-copy: so keyframe và số khung giải mã với bản copy thường (`Get-VideoFrameCounts`); mất thì re-encode libx264 (open-GOP). Nguồn HEVC chuyển sang H.264. Đường logo/GIF giữ timing cũ.
- Cần ffmpeg ≥ 5.1 (`-fps_mode`); bản đi kèm là 8.1.2. `-3` cũ vẫn có Lavc trong AAC cho tới khi re-encode lúc đăng.

### Backend (`integrations/autotok/`, trong repo)

- Mã nguồn `integrations/autotok/src` là bản upstream makiisthenes/TiktokAutoUploader (AGPL-3.0, giữ `LICENSE`) cộng sửa đổi của dự án. Giữ ghi công upstream.
- Cài: `cai-dat.ps1` tạo `.venv`, cài requirements, ghi `config.json` (`DataDir`) và `integrations/tiktok/local.json` nếu chưa có. Cần Python 3.11+ và Chrome.
- Chạy: `start.ps1` bật api, control, scheduler (cổng 8765 và 17900); kiểm PID, giờ bắt đầu và tên tiến trình; trạng thái chạy ở `integrations/autotok/runtime`. `dung.ps1` chỉ dừng tiến trình đã ghi; không có `-Force` thì từ chối khi còn job đang chạy hoặc đang chờ. Hướng dẫn: `integrations/autotok/README-VI.md`.
- Dữ liệu (tài khoản, phiên đăng nhập, DB, thư viện) nằm NGOÀI repo: mặc định `%LOCALAPPDATA%\KidFBY\autotok-data`; đổi bằng biến `AUTOTOK_DATA_DIR` hoặc `DataDir` trong `config.json`. `.venv`, `runtime`, `config.json`, `data`, `node_modules`, `__pycache__` nằm trong `.gitignore`.
- Máy này: dữ liệu đã chép sang `%LOCALAPPDATA%`. Thư mục cũ `...\Codex\2026-10-23\ti\work` không còn dùng.
- `/health`: `history_version` 2, `native_schedule` 1, `post_links` 1. DB `SCHEMA_VERSION` 3.
- Test backend: 428 passed, 5 skipped, 1 xfailed (pytest chạy trong `integrations/autotok/src`).

### Giới hạn và chưa kiểm

- Hai request_id khác nhau cho cùng video và tài khoản (từ hai máy) vẫn tạo hai tác vụ; server chưa khử trùng.
- Thành công muộn của attempt đã bị thay thế không chặn được, chỉ gắn `prior_uncertain`. Stale worker còn rủi ro đua khi người dùng thử lại sau timeout. Không tuyên bố chống đăng trùng tuyệt đối.
- Không truy vấn được bài đăng thủ công ngoài app.
- Hẹn mới đã chuyển lên TikTok, nhưng job chờ cục bộ cũ vẫn cần scheduler autotok chạy đúng giờ. Chưa cài dịch vụ Windows, chưa tự khởi động cùng máy.
- **Chưa kiểm**: đăng video TikTok thật; xác minh bài trên hồ sơ; Reel Facebook thật; nhiều DPI cho hộp đăng; phản hồi publish có mã bài; bài hẹn lên đúng giờ khi máy tắt. Kiểm bằng fixture và backend giả lập: harness WPF Windows PowerShell 5.1 STA; test làm sạch và đồng bộ trên fixture.
- Phiên bản vẫn 2.1.0; `version.json` và `version.json.sig` không đổi; thay đổi nằm trên nhánh `audit-fixes-2.1` (commit `f5c9809`, EXE build lại 24/10/2026), chưa qua `publish.ps1`.
