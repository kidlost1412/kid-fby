# Bàn giao kỹ thuật Kid FB.Y

Ngày rà: 21/10/2026 (đoạn 3.0.0 cập nhật 25/10/2026; đoạn 3.1.0 và 3.2.0 cập nhật 28/10/2026); lúc rà 21/10, nhánh `audit-fixes-2.1` cùng commit với `main` @ `7f5851a`. `core/version.txt` = 3.1.0 (commit `e403d90`, tag `v3.1.0`, phát hành qua `publish.ps1`; `version.json` và `version.json.sig` đổi trong cùng bản này). Bản 3.0.0 đã phát hành qua `publish.ps1`: tag `v3.0.0` trên `main`, `version.json` và `version.json.sig` đã ký, 15 file, gồm `core/autotok-bundle.zip`. Bản 2.1.0 có tag `v2.1.0`. Bản 3.2.0 (đăng qua Chrome, mục 11) nằm ở `feature/chrome-ext` (HEAD `c1d606f`), chưa phát hành: `core/version.txt` của nhánh này vẫn 3.1.0. Bản 3.0.0 phát hành từ nhánh `audit-fixes-2.1` gộp vào `main`. Bản `v3.0.1` (`c29c066`) là gốc của nhánh `feature/kho-accounts` (HEAD `513be65`); `core/version.txt` trên nhánh vẫn 3.0.1. Kho theo tài khoản (mục 10, nhánh `feature/kho-physical`) đã nằm trong 3.1.0. Tài liệu mô tả hành vi có trong nguồn, không chứng nhận không có lỗi, hiệu năng hay kết quả của Facebook.

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
| `integrations/autotok-extension/` | Tiện ích Chrome đăng TikTok (MV3, bản 3.2.0): xem mục 11 |
| `integrations/autotok/kid-install.ps1`, `build-autotok-bundle.ps1` | Bộ cài backend TikTok một chấm và dựng gói `core/autotok-bundle.zip` (mục 9, "Bộ cài một chấm") |

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
- `output/reup-status.json`: trạng thái Posted/Date theo ID. Nguồn: đánh dấu tay (`ManualPosted`) hoặc đồng bộ lịch sử autotok khi bật tích hợp TikTok (mục 8). Chỉ `Update-ReupMetadata` ghi file. Nhãn kho `Kho`/`KhoManual` nằm cùng file (mục 10). Không phải xác nhận bài đã công khai trên TikTok.
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
5. `publish.ps1 -Version <mới> -NoPush` tăng version, build, ghi manifest và chữ ký. Nó vẫn đổi file/version cục bộ. Không dùng lệnh này như lệnh kiểm tra không side effect. Lệnh không có `-NoPush` còn có thao tác Git (`git add -A`, commit, tag, push); đọc phần cuối script trước khi chạy. Từ 3.0.0, `publish.ps1` còn dựng `core/autotok-bundle.zip` (qua `build-autotok-bundle.ps1`) và dừng nếu gói không có trong manifest.
6. Manifest ghi hash raw cho binary/ZIP; text được bỏ BOM và chuẩn hóa CRLF→LF trước SHA256, size vẫn là byte file trên đĩa. Hash raw của PS không nhất thiết bằng hash chuẩn hóa trong manifest. Manifest liệt kê file trực tiếp trong `core/` (`.ps1 .ico .txt .json .zip`), `core/ui/*.xaml`, `core/ui/fonts/OFL.txt` và `Kid-FB.Y.exe`; **các file `.ttf` chưa được liệt kê** (font đến máy khách qua EXE mới, vì updater cũ chuẩn hóa text sẽ làm hỏng font). `core/wpf-gif-player.cs` không nằm trong manifest.

`publish.ps1` hiện không tự rollback version/config/EXE khi bước build lỗi; cần kiểm tra diff và phục hồi trên bản sao hoặc bằng thay đổi đã xác định. `-NoPush` còn có thể khởi tạo Git nếu thư mục chưa có repo, dù không commit/tag/push.

Mười ba resource nhúng: chín file `kid-fby-gui.ps1`, `kid-fby.ps1`, `whisper-language.ps1`, `facebook-links.ps1`, `fix-ket-noi.ps1`, `Kid-FB.Y.ico`, `kid-logo.zip`, `ui/Theme.xaml`, `ui/MainWindow.xaml`, cộng bốn file `ui/fonts/Nunito-Regular.ttf`, `Nunito-SemiBold.ttf`, `Nunito-ExtraBold.ttf`, `OFL.txt`. `updater.ps1`, `version.txt`, `update.json` không nhúng và cần được phân phối trong `core`.

`EnsureResources` so một **stamp** (`core\.resources-stamp` = FileVersion EXE + SHA256 tổng các resource). Stamp khớp: chỉ tạo lại file thiếu/rỗng. Stamp thiếu hoặc khác: đối chiếu hash và ghi lại file khác hash, trừ khi `core\version.txt` đã mới hơn EXE (updater đã nâng cấp script) thì chỉ tạo file thiếu. Chép EXE mới lên core cũ vì vậy làm mới script khi stamp khác; nhưng đừng tin vào cơ chế này thay cho việc build cùng checkout hoặc dùng đường update/đủ bộ file. Không xóa cả core để ép giải nén vì có cấu hình/trạng thái cần xem xét. `.resources-stamp` là file sinh ra, chưa nằm trong `.gitignore`.

### Update và ký manifest

`core/update.json` chứa repo/branch. Updater chỉ coi là bản mới khi manifest.version lớn hơn local version, nên thay mã cùng số phiên bản có thể không tới máy đã cài. `minLauncher` trong manifest được `updater.ps1` kiểm với FileVersion của `Kid-FB.Y.exe`; launcher thấp hơn thì từ chối cập nhật tự động.

Luồng: tải `version.json` và `version.json.sig` (nguồn `raw.githubusercontent.com`, mirror `ghproxy.net`/`gh-proxy.com` chỉ là dự phòng), xác minh chữ ký RSA-SHA256 (khóa công khai nhúng trong `$UpdatePublicKeyXml`) **trên đúng byte manifest đã tải**, rồi mới đọc manifest. Từng file payload phải khớp SHA256 trong manifest đã xác thực trước khi ghi staging và READY bền. Launcher giữ khóa, `RecoverPending` trước `ApplyUpdate`, kiểm đường dẫn/dung lượng, sao lưu và thay version cuối. Journal/checksum/token/BOOT_OK tham gia xác nhận hoặc phục hồi; GUI mới không báo BOOT_OK trong 120 giây thì rollback và đánh dấu phiên bản đó lỗi (`failed-<ver>.flag`).

**Khóa ký đã có.** `new-signing-key.ps1` tạo cặp RSA 3072 bit (mặc định ở `%USERPROFILE%\.kidfby\`, từ chối lưu trong repo, từ chối ghi đè nếu không có `-Force`). Khóa công khai đã gắn trong `$UpdatePublicKeyXml` của `core/updater.ps1`, không còn placeholder. Khóa riêng nằm ngoài repo ở `%USERPROFILE%\.kidfby\update-signing-private.xml` trên máy phát hành; **phải sao lưu**, vì mất khóa thì không phát hành được cập nhật cho máy đã cài. `publish.ps1` dừng khi thiếu khóa riêng, khi khóa riêng nằm trong repo, khi còn chuỗi `<<PUBLIC_KEY_PLACEHOLDER>>` trong `core/updater.ps1` (bước kiểm này chỉ khớp đúng chuỗi đó), hoặc khi modulus khóa công khai không khớp khóa ký. `version.json` và `version.json.sig` của 3.0.0 đã ký (15 file) và nằm trên `main`. Lịch sử: 2.1.0 đã ký và phát hành trước đó. Chữ ký manifest bảo vệ tính toàn vẹn nguồn cập nhật; nó không phải chữ ký Authenticode của EXE.

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

### Bộ test Kho (`tests\kho`, 01 đến 26)

```powershell
# Chạy mọi file tests\kho\NN-*.ps1 (hiện 01 đến 26), mỗi file trong powershell.exe -STA riêng; in "FAILED: ..." và exit 1 nếu có file lỗi
powershell.exe -NoProfile -STA -File tests\kho\run-all.ps1
```

`08-perf.ps1` có ngưỡng thời gian; máy đang tải CPU nặng có thể làm file này lỗi dù logic đúng. Harness dùng `FakeBackend.ps1`, không gọi TikTok thật. Lần chạy 28/10/2026 tại `c1d606f`: toàn bộ `run-all.ps1` đạt (các file 23–26 kiểm đăng qua Chrome, mục 11).

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

- Nhánh Kho (`feature/kho-accounts`, HEAD `513be65`, 26/10/2026): `tests\kho\run-all.ps1` chạy bằng `powershell.exe -STA`, kết quả `ALL TEST FILES PASSED`, exit 0; 12 file, tổng 167 PASS, 0 FAIL (chi tiết và giới hạn ở mục 10).
- Đợt đồng bộ và giao diện v3 (commit `d2b43cd`): unit engine 54/54 và khớp khung hình 8/8 (fixture và cặp mẫu thật), harness WPF 118/118 (engine giả lập), kiểm chữ ký manifest 8/8 và quote đối số 8/8 (launcher), và một lượt GUI thật trên LDPlayer (hàng đợi ba link, Dừng, Kho phát/tua, đóng/mở lại) đạt. Đã đo `yt-dlp -F` (một luồng audio gốc) và đo onset cũ cắt muộn khoảng 0,45–1,25 s so với khung 0.
- Đợt 4 (`345d753`, chỉ một file hoàn chỉnh + `.cache` + giao diện cute) và lượt sửa theo duyệt toàn nhánh (`08eddcb`, thu lại khi thiếu, hủy khi khớp hình, dọn code chết): tài liệu này **không** dẫn được kết quả chạy hợp lệ cho riêng hai commit đó; coi là chưa kiểm cho tới khi chạy lại build, SelfTest và các ca ở checklist.
- Lượt dọn 19/10/2026 (bản 2.0.1 trước nhánh này) từng kiểm 30 assertion engine, harness GUI, metadata build và một lượt Android thật (Reel `4340858519560389`). Mã đã thay đổi lớn từ đó (engine, GUI, launcher, updater), nên kết quả ấy chỉ còn giá trị lịch sử.
- Phát hành 2.1.0 (21/10/2026): đường cập nhật thật, bản sao app 2.0.1 (updater cũ) nhận 2.1.0 từ GitHub, tải 11 file, SHA256 khớp, launcher cũ áp dụng; EXE 2.1.0.0; lần mở thứ hai launcher mới giải nén phông Nunito; `-SelfTest` exit 0; updater mới kiểm chữ ký trên GitHub thật (`signed=true`). Sau khi cập nhật từ 2.0.1 cần mở app thêm một lần để có Nunito, vì phông không nằm trong manifest.
- Chạy thật 21/10/2026, 20 link: 2 lưu; 16 `vietnamese-unavailable` (bằng chứng: menu chỉ có "Âm thanh gốc" và "Tính năng dịch giọng nói hiện chưa hỗ trợ", đọc 3 lần trong khoảng 6,5 s); 2 chưa xác nhận (một mục `dub-unverified`; một mục `low-confidence` với đỉnh tương quan 0,886 và tỷ lệ 1,10 sau 2 lần thu); 0 lỗi. Một video xuất với `syncDriftMs` 949 (có cảnh báo, chưa nghe kiểm). Giới hạn: ngưỡng tỷ lệ 1,15 có thể chặt với video nhiều cảnh giống nhau; trôi lớn (> ~300 ms) hiện vẫn xuất kèm cảnh báo, chờ chủ dự án nghe kiểm để quyết định có chặn hay không.
- Đợt 5: hai bộ kiểm định độc lập, **nằm ngoài repo trên máy làm việc** (thư mục tạm của phiên, không có trong clone Git): `qa-independent` (280 ca; lần chạy 21/10/2026: 254 PASS; các FAIL còn lại là test kỳ vọng hành vi cũ đã đổi có chủ đích, giới hạn đã biết Reel < 2 s và onset ngắt quãng, và khóa ký/manifest khi đó chưa phát hành; nay đã có 2.1.0 và 3.0.0 đã ký) và `ui-critic` (đo video: 1440×900 → 381×677, 1366×768 → 280×498, 1920×1080 → 455×809, 1366@150% → 158×282).
- **Chưa kiểm:** Reel tự lặp thật trên Android (`SYNC_LOOP` mới chạy với fixture); nghe/xem lệch tiếng–hình bằng tai (mới đo bằng khớp khung hình); đường tự thu lại (`start-missing`/`low-confidence`/`short-capture`) mới chạy qua giả lập, các lượt Android thật đều đạt ngay lần một; độ trôi 150–320 ms xuất hiện thường xuyên ở player Facebook và giả định "audio là đồng hồ chủ, lấy bậc d thấp nhất" chưa được xác nhận bằng nghe; updater với manifest đã ký thật chỉ kiểm một lần trên đường 2.0.1 → 2.1.0 (máy phát hành, không kiểm trên máy khác); `publish.ps1` đã dùng cho 2.1.0 nhưng chưa kiểm lại; DPI thật (số đo 150% ở trên là mô phỏng) và nhiều màn hình chưa kiểm; chất lượng dịch Meta không thuộc phạm vi kiểm.
- Chưa bao phủ toàn bộ biến thể UI Facebook, thiết bị Android, mirror tải/cài, codec/driver GPU, clip dài (đường chữ ký ba đoạn cho video trên 300 giây) hoặc sự cố ổ đĩa/nguồn điện. Không lấy kết quả này để suy ra FPS, CPU, đồng bộ audio hay tất cả tính năng đều đúng.

Thương mại hóa (khóa giấy phép, chữ ký Authenticode, installer, repo riêng tư, rà giấy phép FFmpeg bản GPL) chưa làm.

## 7. Thay đổi hợp đồng và phạm vi dọn

Bản 2.0.1 đã bỏ switch CLI `-SkipLanguageCheck`; script cũ truyền switch này cần bỏ đối số đó. Điều kiện tải vẫn là phản hồi UI Meta, không bật lại Whisper.

Hợp đồng đợt 5: reason mới `output-locked` (status `failed`); `publish-failed` phát từ nhánh publish; thư mục giao dịch xuất bản chuyển vào `.cache\.kidfby-publish-*`; file mới `core\_update\gui.hwnd` (GUI ghi, launcher đọc); log mới `SYNC_LOOP`.

So với bản 2.0.1, bản 2.1.0 (nhánh `audit-fixes-2.1`, nay cùng commit với `main`) thêm: tham số CLI `-ForceRetryRejected`, `-AllowOnsetSync`; hai dòng sự kiện `@@KIDFBY_STAGE`/`@@KIDFBY_RESULT`; hàm `Remove-RejectedReel` và tham số `Evidence` của `Save-RejectedReel`; thay đổi hành vi loại (không xóa file đã có); đồng bộ theo hình thay cho onset khi cắt âm thanh; thư mục xuất chỉ còn `-3` và `.cache` ẩn; chuẩn hóa URL; bộ cài chỉ nguồn chính thức với SHA256; single-instance và `-AfterUpdate`; manifest ký RSA; giao diện tách `core/ui` kèm phông; `data\settings.json` và `logs\`. Result của `Invoke-OneLink` ở dạng đối tượng PowerShell vẫn không có `AudioLanguage`; chẩn đoán riêng vẫn dùng `-DetectLanguageFile`.

Giữ media đầu vào/bản hoàn chỉnh/lịch sử/công cụ đang dùng. Các fallback tải/cài, lớp GIF/cache/worker, helper Whisper, lịch sử và dữ liệu phục hồi còn có caller hoặc mục đích nên được giữ. Thư mục `output\.thumbs` có thể còn trên máy đã chạy bản thử trước đợt 4 và xóa tay được; ảnh thu nhỏ mới nằm ở `.cache\thumbs`. Tài liệu này cập nhật theo commit `7f5851a` trên `main` và chưa commit theo yêu cầu của tác vụ; không viết lại lịch sử Git.

Nhánh Kho (mục 10) thêm `Kho`/`KhoManual` vào `reup-status.json`, thêm `data\kho.json`, `data\tiktok-prefs.json` và trường `accounts` tùy chọn trong `tiktok-hashtags.json`. Ranh giới tương thích: `Set-ReupMetadata` của bản `v2.1.0` ghi đè cả mục bằng `{Posted, Date}`, làm mất `Kho`, `History` và các trường khác. Vì vậy mỗi thư mục xuất chỉ dùng một phiên bản app (đã chấp nhận khi lập kế hoạch Kho).

## 8. Tích hợp TikTok cục bộ — 24/10/2026, có trong 3.0.0 (25/10/2026)

Mục đích: đăng video từ Kho lên TikTok qua autotok (`integrations/autotok/`, trong repo), không sao chép file tay. Facebook vẫn là luồng chính; tích hợp này không đổi engine tải Facebook, ngưỡng đồng bộ hay giao thức STAGE/RESULT. Bản 3.0.0 phát hành tích hợp này cùng bộ cài một chấm (xem "Bộ cài một chấm" dưới mục 9).

### Bật hay tắt

- `Get-TikTokIntegration` đọc biến `KID_FBY_AUTOTOK_STARTER` hoặc `integrations/tiktok/local.json` (`{"Starter": "..."}`, file này nằm trong `.gitignore`). Starter phải tồn tại; quy tắc giống `integrations/tiktok/start.ps1`. Đánh giá một lần lúc khởi động.
- **Không cấu hình**: đúng hành vi trước tích hợp. Nút "Sao chép để đăng", badge thẻ bật/tắt dấu đã đăng thủ công, không có timer đồng bộ, không băm SHA256.
- **Có cấu hình**: nút "Đăng video" dưới preview mở hộp đăng; "Sao chép để đăng" nằm trong menu thêm của thẻ; Ctrl+C vẫn sao chép. Được đăng khi hàng đợi tải đang chạy.
- Trên máy này `integrations/tiktok/local.json` trỏ tới `integrations/autotok/start.ps1`.

### Trạng thái đồng bộ (`reup-status.json`)

- File nằm ở thư mục xuất, theo từng ID video: `Posted`, `Date`, `ManualPosted`, `ManualDate`, `Source='autotok-history'`, `History` (bản rút gọn: key, request_id, username, status, publish_uncertain, prior_uncertain, planned_for, accepted_at, created_at, time_source, sha256), `FileSha256`, và từ nhánh Kho thêm `Kho`/`KhoManual` (mục 10). `Posted` là trường tổng hợp để bản cũ đọc được.
- Mục cũ không có `Source` được chuyển thành `ManualPosted`. Đồng bộ không bao giờ ghi đè dấu đánh tay.
- Chỉ `Update-ReupMetadata` ghi file này: mutex có tên, đọc một lần, thay file nguyên tử (thử lại khi `IOException`). Bên đọc mở với `FileShare ReadWrite|Delete`. File hỏng không bị ghi đè.
- Đây là ACK của uploader, không chứng minh bài đã công khai trên hồ sơ TikTok.

### Đồng bộ nền

- `Start-TikTokStatusSync`/`Invoke-TikTokSyncTick` chạy trong runspace riêng (`InitialSessionState`), không trên luồng UI.
- Kiểm health trước; backend tắt thì không băm hash. Tra cứu theo lô 500 video. SHA256 đọc theo khối, hủy được. Cache định danh `.cache\tiktok-identities.json`, chỉ ghi khi có thay đổi.
- Không tới được backend: hiện nhãn "TikTok chưa cập nhật". Lỗi báo một lần cho mỗi request_id trong phiên, chỉ với biên nhận trong 24 giờ.

## 9. Hàng chuyển nền và biên nhận — 24/10/2026, có trong 3.0.0 (25/10/2026)

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
- `post_url` = `https://www.tiktok.com/@<tài khoản>/video/<id>` khi nhãn tài khoản là handle hợp lệ; nếu không, dùng `https://www.tiktok.com/@_/video/<id>` (TikTok tự chuyển tới bài đúng, đã thử 25/10/2026). Link được dựng khi đọc nên bản ghi cũ có `post_id` cũng có link. App còn "Sao chép mã bài".
- Trạng thái hiển thị theo `schedule_mode` (now/native): "Đang chờ đăng", "Chờ gửi lên TikTok · hẹn …", "Đang đăng…", "Đang gửi lên TikTok · hẹn …", "Đã hẹn trên TikTok · …", "Đã đăng · …". Bài đang xử lý được hỏi nhanh khoảng 5 giây/lần (`GET /api/desktop/jobs/{id}`, tối đa 10 bài/lượt); đồng bộ toàn Kho chờ 4–30 giây giữa các lượt.
- Tra cứu dự phòng `find_post` (`autotok/posts.py`) là STUB, luôn trả None: `link_state` đi từ pending sang gave_up. "Thử lấy lại link" gọi `POST /api/history/<key>/refresh-link` (chỉ đọc, không đăng lại).
- GUI: "Mở bài đăng" (kiểm URL trước khi mở), "Sao chép link", "Sao chép mã bài", "Thử lấy lại link".
- Chưa kiểm: phản hồi publish thật có chứa mã bài hay không.

### Hashtag hay dùng (24/10/2026)

- Lưu ở `data\tiktok-hashtags.json`, riêng từng máy; không đưa vào git.
- Chip "Hashtag hay dùng" hiện dưới ô caption, tối đa 20 mục theo số lần dùng. Gõ một phần hashtag để lọc.
- Học khi bấm đăng; tối đa 300 mục. Chuột phải hoặc phím Delete → "Xóa khỏi gợi ý".
- File hỏng: đổi tên `.corrupt-<ts>`, coi như rỗng.

### Engine (`core/kid-fby.ps1`) — áp dụng cho mọi `-3`, kể cả khi tắt tích hợp

- `Get-CleanOutputArgs` bỏ metadata: `-map_metadata -1`, `-map_chapters -1`, bitexact, lọc SEI (`remove_types=6`) với H.264.
- Kết quả metadata: giữ `handler_name` mặc định của ffmpeg (`VideoHandler`/`SoundHandler`), không để handler/encoder rỗng. Không còn x264/x265/Lavf/Lavc/facebook/title/comment/chapters trong file đầu ra.
- Lồng tiếng AAC thêm `-fflags +bitexact -flags:a +bitexact`: audio giải mã khác nhẹ (~47 dB SNR), timing gói giữ nguyên (đo trên fixture).
- `Invoke-CleanVideoMux` cho đường stream-copy: so keyframe và số khung giải mã với bản copy thường (`Get-VideoFrameCounts`); mất thì re-encode libx264 (open-GOP). Nguồn HEVC chuyển sang H.264. Đường logo/GIF giữ timing cũ.
- Cần ffmpeg ≥ 5.1 (`-fps_mode`); bản đi kèm là 8.1.2. `-3` cũ vẫn có Lavc trong AAC cho tới khi re-encode lúc đăng.

### Backend (`integrations/autotok/`, trong repo)

- Mã nguồn `integrations/autotok/src` là bản upstream makiisthenes/TiktokAutoUploader (AGPL-3.0, giữ `LICENSE`) cộng sửa đổi của dự án. Giữ ghi công upstream.
- Cài: `cai-dat.ps1` tạo `.venv`, cài requirements, ghi `config.json` (`DataDir`) và `integrations/tiktok/local.json` nếu chưa có. Cần Python 3.11+ và Chrome.
- Chạy: `start.ps1` bật api, control, scheduler (cổng 8765 và 17900); kiểm PID, giờ bắt đầu và tên tiến trình; trạng thái chạy ở `integrations/autotok/runtime`. `dung.ps1` chỉ dừng tiến trình đã ghi; không có `-Force` thì từ chối khi còn job đang chạy hoặc đang chờ. Hướng dẫn: `integrations/autotok/README-VI.md`.
- Dữ liệu (tài khoản, phiên đăng nhập, DB, thư viện) nằm NGOÀI repo: mặc định `%LOCALAPPDATA%\KidFBY\autotok-data`; đổi bằng biến `AUTOTOK_DATA_DIR` hoặc `DataDir` trong `config.json`. `.venv`, `runtime`, `config.json`, `data`, `node_modules`, `__pycache__` nằm trong `.gitignore`.
- Máy này: dữ liệu đã chép sang `%LOCALAPPDATA%`. Thư mục cũ `...\Codex\2026-10-23\ti\work` không còn dùng.
- `/health`: `history_version` 2, `native_schedule` 1, `post_links` 1 (bản 3.0.0). DB `SCHEMA_VERSION` 3 ở bản 3.0.0; hiện là 5 (mục 11).
- Test backend: 454 passed, 5 skipped, 1 xfailed (pytest chạy trong `integrations/autotok/src`; 25/10/2026, trước đó là 428).

### Bộ cài một chấm (3.0.0, 25/10/2026)

- Mục đích: cài hoặc cập nhật backend autotok từ trong app, không chép file tay.
- Gói: `build-autotok-bundle.ps1` dựng `core/autotok-bundle.zip` theo cách tất định, từ file theo git trong allowlist, lọc theo đuôi, kèm `bundle.json` (SHA256 từng file). `publish.ps1` dựng gói và dừng nếu gói thiếu trong manifest.
- Cập nhật từ máy cũ: updater bản 2.1.0 tải gói qua đường `core/`, khớp SHA256 trong manifest đã ký. Chỉ máy đã cập nhật từ 2.1.0 trở lên nhận gói qua updater. Clone git có sẵn gói trong `integrations/autotok` làm nguồn.
- Trong app: trang Công cụ có thẻ "Bộ đăng TikTok" với nút "Cài / Cập nhật bộ đăng TikTok". Cần Chrome; thiếu Chrome thì hiện link. Khi đang cài, nút đăng bị tắt. Job hàng chuyển chờ tối đa 10 phút nếu lock nâng cấp đang giữ.
- `integrations/autotok/kid-install.ps1` là giao dịch:
  1. Kiểm gói, giải nén an toàn vào `integrations\autotok-releases\<sha12>-<timestamp>`.
  2. Tải NuGet Python 3.11.9 với SHA256 ghim, vào `integrations\autotok-python311`. Không đặt trong `tools\` vì "Gỡ thư viện" xóa `tools`.
  3. Tạo venv, cài `requirements.lock.txt` (`--require-hashes`, chỉ wheel), chạy `pip check`.
  4. Kiểm bản mới, nâng lock.
  5. Chờ job đang chạy và đang chờ xong (drain), dừng bản cũ.
  6. Chuyển `integrations\autotok-current.json` (cờ verified).
  7. Chạy `start.ps1` của bản mới; sẵn sàng khi `/health` và scheduler đạt.
  8. Lỗi ở bước nào thì quay về bản trước.
  Giữ bản hiện tại và bản trước. Log: `integrations\autotok-install.log`.
- Cấu hình: `integrations\autotok-config.json`, `DataDir` mặc định `%LOCALAPPDATA%\KidFBY\autotok-data`. Launcher ổn định `integrations\autotok-start.ps1` quay về bản trước nếu bản hiện tại chưa verified. `integrations/tiktok/local.json` trỏ tới file này. File `local.json` git hoặc tự cấu hình có sẵn không bị ghi đè khi chưa có đồng ý.
- Các file `integrations\autotok-*` và `autotok-releases`, `autotok-python311` là trạng thái máy, đã nằm trong `.gitignore`.
- Chưa kiểm: bật/dừng dịch vụ thật bằng bộ cài mới mới chạy với lớp dịch vụ giả (cổng đang bận). Lần chạy thật đầu tiên sẽ làm trên máy thứ hai.

### Giới hạn và chưa kiểm

- Hai request_id khác nhau cho cùng video và tài khoản (từ hai máy) vẫn tạo hai tác vụ; server chưa khử trùng.
- Thành công muộn của attempt đã bị thay thế không chặn được, chỉ gắn `prior_uncertain`. Stale worker còn rủi ro đua khi người dùng thử lại sau timeout. Không tuyên bố chống đăng trùng tuyệt đối.
- Không truy vấn được bài đăng thủ công ngoài app.
- Hẹn mới đã chuyển lên TikTok, nhưng job chờ cục bộ cũ vẫn cần scheduler autotok chạy đúng giờ. Chưa cài dịch vụ Windows, chưa tự khởi động cùng máy.
- **Chưa kiểm**: đăng video TikTok thật; xác minh bài trên hồ sơ; Reel Facebook thật; nhiều DPI cho hộp đăng; phản hồi publish có mã bài; bài hẹn lên đúng giờ khi máy tắt; bộ cài một chấm trên dịch vụ thật (chỉ kiểm với lớp dịch vụ giả). Kiểm bằng fixture và backend giả lập: harness WPF Windows PowerShell 5.1 STA; test làm sạch và đồng bộ trên fixture.
- Phiên bản 3.0.0 đã phát hành qua `publish.ps1`: `core/version.txt` = 3.0.0, `version.json` và `version.json.sig` đã ký (15 file, gồm `core/autotok-bundle.zip`). Các thay đổi tích hợp TikTok và bộ cài nằm trong bản này (mục 8, 9).

## 10. Kho = thư mục thật theo tài khoản — nhánh `feature/kho-physical` (26/10/2026, đã nằm trong 3.1.0)

Vì sao: chủ dự án đăng TikTok bằng 3–5 tài khoản. Kho là một thư mục thật chứa video của nó; chuyển video sang kho là chuyển file; xóa video/kho là đưa file vào Thùng rác Windows. Không còn "Kho chung" và không còn nhãn `Kho`/`KhoManual`.

### Nguyên tắc

- Mỗi kho là một thư mục xuất đầy đủ như thư mục `output` cũ: `<id>-3-hoan-chinh.mp4` ở gốc, `.cache` (`-1`/`-2`, `thumbs`, `tiktok-posts`, `tiktok-identities.json`) và `reup-status.json` riêng.
- Chỉ `Update-ReupMetadata` ghi `reup-status.json`. Chỉ luồng UI ghi `data\kho.json`; mã nền làm việc với đường dẫn thư mục, không đọc/ghi registry.
- Thư mục kho: đường dẫn đầy đủ, không phải gốc ổ đĩa, cùng ổ đĩa với kho đầu tiên (mọi lần chuyển là đổi tên tức thì), không trùng/không lồng trong kho khác (`Test-KhoPathAllowed`). Luôn có ít nhất một kho; mỗi tài khoản tối đa một kho.

### Registry `data\kho.json` (version 2)

- Dạng: `{version:2, libraries:[{id,name,path,account,caption,hashtags,lowStock,slots,createdByApp}], downloadTarget, autoMoveSince}`; id `k-<32 hex>`.
- Lần chạy đầu (thiếu file, file v1 kho nhãn, hoặc không có kho hợp lệ): tạo kho "Output cũ" = `outDir` đã lưu (mặc định `<root>\output`), không di chuyển file. File v1/hỏng/không hợp lệ được đổi tên `kho.json.v1-<ts>` / `.corrupt-<ts>` / `.invalid-<ts>`, không xóa.
- File không đọc được (khóa tạm): dùng mặc định trong bộ nhớ, `khoRegistryReady=$false`, phiên đó không ghi đè và mọi thay đổi kho bị từ chối.
- `autoMoveSince` = lúc tạo registry: chỉ bài xác nhận từ mốc này mới tự chuyển kho.

### Chuyển kho (`Invoke-KhoMove`, `Move-KhoVideos`)

- Chỉ chạy khi ứng dụng yên (`Test-KhoQuiet`: không tải/ghi âm/sửa, import, hộp thoại/dọn dẹp, cài bộ đăng); đồng bộ TikTok được tạm dừng và chờ pass đang chạy xong (tối đa 8 s, không hủy giữa chừng). Không yên: báo "Đang bận…", tự chuyển để lần sau.
- Video có `.job`/`.lock` trong `.cache	iktok-posts` (đang chạy hoặc giữ để thử lại) bị chặn; chỉ biên nhận đã xong/lưu trữ được chuyển, với `OutDir`/`SourcePath` viết lại.
- Nhật ký `data\kho-moves\<txid>.json` (ngoài mọi kho; ghi tạm + Flush + đổi tên) ghi trước lần đổi tên đầu; pha `renaming` → `meta-target-done` → `meta-source-done`; `-3` đổi tên cuối cùng. Khôi phục (`Resume-KhoMoves`) chạy lúc khởi động trước khi quét kho/đồng bộ và trước mỗi lần chuyển; mọi bước idempotent. Cả hai tồn tại → xung đột: giữ nhật ký, khóa hai kho (chuyển/xóa/dọn), không ghi đè.
- Gộp metadata đích: có mục thì gộp lịch sử theo `key` (đích thắng), giữ đánh dấu tay nếu một bên có (`Merge-KhoMoveEntry`).
- Chuyển tay video đã có bài xác nhận đặt `KhoPinned=true` (đi theo mục); tự chuyển bỏ qua mục ghim.
- Tự chuyển (`Invoke-KhoAutoMove`): sau đồng bộ, video ở kho không gắn tài khoản có bài xác nhận sớm nhất của một tài khoản → sang kho tài khoản đó; chưa có kho thì tự tạo `<thư mục cha của kho tải về>\Kho @user` (`createdByApp`); lỗi tạo kho thì thử lại sau 10 phút.
- Không tạo mục `reup-status.json` mới cho video không còn `-3` ở thư mục đó (đồng bộ đầy đủ, biên nhận cục bộ, đánh dấu tay).

### Xóa (`Remove-ReelToRecycleBin`, `Remove-KhoWithVideos`)

- Xóa video: `-3` trước, rồi `-1`/`-2` và biên nhận đã xong vào Thùng rác; ảnh thu nhỏ xóa luôn. Một file lỗi → giữ mục metadata, báo phần còn lại; thử lại xóa nốt.
- Xóa kho: từ chối khi ứng dụng bận, có nhật ký chuyển kho nhắc tới thư mục, hoặc có lệnh đăng; xóa hết video, chỉ bỏ đăng ký khi tất cả thành công; nếu là kho tải về thì chuyển đích sang kho khác. Thư mục chỉ vào Thùng rác khi `createdByApp` và chỉ còn file của ứng dụng.

### Nhiều thư mục

- Quét kho là một việc nền trên mọi thư mục; thẻ lấy kho từ thư mục chứa file. Đồng bộ TikTok chạy theo từng thư mục. Kiểm tra trùng khi tải xét mọi kho. Hàng đợi tải chốt thư mục đích lúc bắt đầu (`$script:queueOutDir`); ghi âm lại dùng thư mục của video.
- Giờ bận/giới hạn ngày/giờ trống kế tiếp của một tài khoản đọc mọi kho, bỏ trùng theo `key` (`Get-TikTokAccountBusyTimes`).
- Dọn cache/Dọn ổ theo kho đang chọn hoặc tất cả; không bao giờ đụng file mà nhật ký chuyển kho nhắc tới (`Get-KhoJournalPaths`); nhật ký không đọc được thì từ chối dọn.

### Tương thích (giống ghi chú A1)

- Bản cũ hơn (trước nhánh này) không biết `kho.json` v2: chỉ thấy thư mục "Output cũ" (`outDir` trong `settings.json`) và coi video đã chuyển sang kho khác là không có. Dùng đồng thời hai bản trên cùng dữ liệu không được hỗ trợ; không chạy bản cũ khi còn nhật ký `data\kho-moves` chưa xong.

### Kiểm thử

- `tests\khoun-all.ps1` (PowerShell 5.1 -STA, mỗi file một tiến trình): registry, luật thư mục, chuyển kho, nhật ký/khôi phục, xóa (Thùng rác thật), nhiều thư mục, hiệu năng 5 kho × 500 video, rải lịch nền/dòng sửa được, khung kéo chọn (hàm thuần), video ngoài (`19`), sửa lỗi QA (`20`: không tạo registry trước khi nạp cài đặt, nhật ký kẹt chỉ khóa hai kho, xóa bị chặn bởi nhật ký, tự chuyển khi bận, ổ không Thùng rác dùng ổ `subst` thật, header script), Hẹn lại (`21`). `tests\kho\smokeun-smoke.ps1 -Phase main|recovery` và `run-smoke-p3.ps1`: WPF thật trên bản sao tạm của ứng dụng, backend TikTok GIẢ (`smoke-fake-backend.ps1`, 127.0.0.1), ffmpeg thật; P3 kiểm khung kéo chọn (con trỏ được tiêm), thả `.MOV` ngoài vào kho rồi chuyển và xóa, chip khung giờ, rải lịch nền (hộp thoại đóng, thanh trạng thái, toast cuối).

### Giao diện (`core/kid-fby-gui.ps1`, `core/ui/*.xaml`)

- Chọn kho và đếm (`Update-GalleryKhoSelector`, `Format-KhoCounts`): "Tất cả" và từng kho, đếm Chờ đăng / Đã hẹn / Đã đăng. Tab trạng thái lọc trong bộ nhớ (`Apply-GalleryFilter`, từ `$script:galleryAll`), không quét ổ và không băm lại.
- Chọn nhiều (Ctrl/Shift, `Select-GalleryItems`): thanh dưới lưới có "Chuyển N video sang kho…" và "Rải lịch…". Menu chuyển kho (`Show-KhoMoveMenu`) là menu phẳng, không có menu con (Theme không có popup con).
- Quản lý kho (`Show-KhoManagerDialog`): thêm kho (thư mục, mặc định `Kho <tên>` cạnh kho tải về); thêm kho tài khoản (danh sách từ `/api/accounts` khi TikTok bật); đổi tên (`Rename-Kho`); xóa (`Confirm-KhoDelete`: xóa video và kho vào Thùng rác; ổ không có Thùng rác thì hỏi riêng "xóa vĩnh viễn?"); caption và hashtag mặc định; khung giờ đăng của kho (chip, `Set-KhoOptions`); ngưỡng "sắp hết" (mặc định 3); nhập thư mục. Banner "Có lần chuyển kho dở dang" (khi còn nhật ký trong `data\kho-moves`) có "Thử hoàn tất" (`Resume-KhoMoves`) và "Bỏ qua (giữ file tại chỗ)" (sau xác nhận, nhật ký chuyển sang `data\kho-movesbandoned\`, file không bị đụng; `Move-KhoJournalAside`).
- Cảnh báo sắp hết (`Test-KhoLowStock`): mỗi kho tài khoản một lần mỗi phiên, khi Chờ đăng dưới ngưỡng.
- Đã hẹn sang Đã đăng: `Update-GalleryHeldExpired` chạy mỗi 60 giây (`$tGalleryHeld`), chỉ đọc bộ nhớ, không gọi mạng.
- Nút "Tự hẹn lịch" trong kho tài khoản (`Get-TikTokAutoScheduleItems`): lấy video Chờ đăng chưa có lịch sử, cũ nhất trước, rồi mở hộp Rải lịch để xem trước. Không gửi khi chưa bấm xác nhận.

### Hộp đăng TikTok (`Show-TikTokPublishDialog`)

- Tài khoản mặc định: kho tài khoản của video; không có thì tài khoản dùng lần trước (`data\tiktok-prefs.json`: `lastAccount`, `times`). File hỏng: đổi tên `.corrupt-<ts>`, coi như rỗng.
- Caption trống: điền caption và hashtag mặc định của kho (kho tài khoản, hoặc kho tự tạo của video).
- Gợi ý hashtag xếp theo số lần dùng của tài khoản. `tiktok-hashtags.json` có trường `accounts` tùy chọn; file cũ vẫn đọc được.
- Chip giờ: 4 giờ dùng nhiều nhất của tài khoản, đệm bằng 08:00/12:00/19:00/21:00. Mỗi lần hẹn thành công tăng đếm `times[user]["HH:mm"]` (`Register-TikTokPrefsSubmit`).
- "Giờ trống kế tiếp" (`Get-NextFreeTikTokSlot`): giờ ưa thích sớm nhất trong khoảng hẹn cho phép (+20 phút đến +10 ngày), cách mọi giờ bận của tài khoản ít nhất 60 phút, tìm trong 11 ngày.
- Đăng lại (`Get-TikTokRepostWarning`): nếu video đã xác nhận trên tài khoản khác, hiện "đã đăng ở @A" và phải tick xác nhận mới gửi.

### Rải lịch và Tự hẹn lịch (`Show-TikTokSpreadDialog`)

- Chọn nhiều video, chọn một tài khoản, xem trước giờ, rồi "Hẹn N video". Hộp thoại KHÔNG còn ô "số ngày", "bài mỗi ngày", "cách nhau mấy giờ". `Get-TikTokSpreadPlan` xếp mỗi video vào một khung giờ, theo thứ tự thời gian: khung giờ của kho tài khoản (`kho.slots`), không có thì giờ tài khoản hay dùng, không có nữa thì 08:00/12:00/19:00/21:00. Bắt đầu từ khung đầu tiên ≥ bây giờ + 20 phút, bỏ khung cách một bài đã hẹn/đang chờ của tài khoản (mọi kho) dưới 60 phút, tối đa 10 ngày (giới hạn TikTok). Video còn lại hiện "Còn N video chưa có giờ (quá 10 ngày)". Giờ từng dòng vẫn sửa được (định dạng dd/MM HH:mm; chỉ cảnh báo khi cách bài khác dưới 60 phút).
- Caption: một ô "Caption chung" tự điền cho mọi dòng chưa sửa caption riêng; mỗi dòng có ô caption riêng ngay dưới giờ hẹn. Caption thực sự của dòng = caption riêng nếu có chữ, không thì caption chung (`Get-SpreadEffectiveCaption`). "Hẹn video" chỉ chặn khi một dòng được hẹn trống cả hai, và thông báo nêu đúng video đó (`Get-SpreadCaptionProblem`). Trước đây kiểm tra chỉ nhìn ô chung nên gõ vào ô caption của dòng vẫn bị báo "Vui lòng nhập caption".
- Gửi tuần tự: mỗi lần một tiến trình con (`Start-TikTokBackgroundJob -PassThru`); chỉ gửi bài kế khi tiến trình trước thoát (`Step-TikTokSpreadRun`). Trước mỗi lần gửi kiểm lại: video đang có lượt chạy thì bỏ qua.
- Kết quả đọc từ biên nhận (`Get-TikTokSpreadSendResult`): trạng thái chấp nhận được là đã gửi. `transfer_failed`, `preparation_failed`, `submitted`, `unknown` hoặc thiếu file là lỗi, ghi kèm lý do.
- Dừng (`Stop-TikTokSpreadRun`): không chạy thêm; tiến trình đang chạy để yên và dòng ghi "vẫn đang gửi". Quá 15 phút chỉ báo `LongWait`, không chạy lại.

### Dọn ổ (Cài đặt › Lưu trữ, `Invoke-KhoCleanup`)

- Ứng viên: video do app tạo, đã đăng (xác nhận hoặc đánh dấu tay), ngày đăng cũ hơn N ngày (ô nhập 7–365) và còn `-1`/`-2`. Ngày đăng là giờ hẹn TikTok nếu có, không thì ngày chấp nhận; không xác định được ngày thì bỏ qua. Phạm vi: kho đang chọn hoặc tất cả. Video ngoài (khóa `f:`) không có `-1`/`-2` nên không bao giờ là ứng viên.
- Chỉ xóa `-1-video-goc.mp4` và `-2-am-thanh-tho.m4a` (trong `.cache` và file cũ ở gốc thư mục xuất), sau xác nhận. Không xóa `-3`, ảnh thu nhỏ, `.kidfby-publish-*`, và bỏ qua video đang có lượt chuyển TikTok.
- Đây là ngoại lệ có chủ đích cho quy tắc "-1/-2 không xóa theo tuổi" trong `AGENTS.md`: xét theo ngày đăng, không theo tuổi file.

### Video ngoài (D12) và Hẹn lại (D13)

- Video trong kho là MỌI file `.mp4 .mov .m4v .mkv .webm .avi` (không phân biệt hoa/thường, không đệ quy; bỏ file ẩn bắt đầu bằng `.`, `*.part`, `*.tmp`). Video do app tạo giữ khóa là ID số; video ngoài có khóa `f:` + tên file nguyên văn (`Get-KhoVideoKey`, `Test-KhoVideoKey`, `Get-KhoVideoPath`). Khóa này là tên mục `reup-status.json`, `VideoId` của biên nhận, id nhật ký chuyển kho. Ảnh thu nhỏ: `.cache	humbs_<SHA1 tên file>` (`Get-KhoThumbKey`).
- Backend: video ngoài gửi `reel_id` rỗng (lịch sử khớp theo sha256, `Get-TikTokWireReelId`); worker đồng bộ đổi khóa thành mã ngắn `f_<sha1>` khi hỏi `/api/history/lookup` và đổi ngược khi nhận. Bản sạch cho TikTok (`Get-TikTokCleanPlan`): `copy` (đóng gói lại) khi hình H.264/HEVC và âm AAC hoặc không âm; `audio` khi âm khác AAC; `video` (H.264 + AAC) khi codec hình khác; không có luồng hình hoặc ffprobe lỗi thì từ chối kèm lý do.
- Ghi âm lại, Lồng tiếng/sửa logo-GIF tắt với video ngoài (tooltip "Chỉ dùng cho video do app tạo"); chuyển kho chỉ mang ảnh thu nhỏ và biên nhận đã xong; thẻ hiển thị tên file bỏ đuôi; video ngoài không bao giờ là "trùng khi tải".
- Thả file từ Explorer lên trang Kho (`Invoke-KhoDrop`, `Copy-KhoExternalFiles`): chép vào kho đang chọn (không phải "Tất cả kho") qua `<tên>.part` rồi đổi tên, không ghi đè file cùng tên; bị từ chối khi `Test-KhoQuiet` khác rỗng.
- Hẹn lại (`Get-TikTokRescheduleSeed`): thẻ có mục "Hẹn lại" khi mục TikTok MỚI NHẤT của video là lịch gốc bị TikTok từ chối (`status=failed`, `schedule_mode=native`). Mở hộp đăng với cùng tài khoản, caption đọc từ trường `Caption` của biên nhận (biên nhận cũ không có thì dùng mẫu của kho) và giờ là "giờ trống kế tiếp". Phần hộp thoại WPF chưa có kiểm tự động (unverified); hàm chọn và cờ trên thẻ có test (`21`).

### Sửa lỗi sau QA độc lập (26/10/2026)

- Registry chỉ được tạo/lưu sau khi `settings.json` đã nạp (`$script:khoSettingsLoaded`); trước đó `Get-KhoRegistry` trả kho tạm không lưu. Cài đặt bị khóa thì kho tạm chỉ ở bộ nhớ (`khoRegistryReady=$false`).
- `Invoke-KhoMove` không còn từ chối toàn cục khi có nhật ký kẹt; chỉ hai thư mục của nhật ký bị khóa (`Move-KhoVideos`). `Remove-ReelFiles` từ chối khi nhật ký khóa thư mục. Tự chuyển kiểm "yên" và nhật ký trước khi đọc metadata; khi bận thì chờ lần chuyển bận → yên (`khoAutoMoveDeferred`) thay vì thử mỗi giây.
- Ổ không có Thùng rác (UNC, không phải ổ cố định, `subst`; `Test-KhoRecycleBin`): xóa bị từ chối trừ khi chủ chọn "xóa vĩnh viễn" (`-AllowPermanent`). Thùng rác lỗi ở `-3` thì dừng, `-1/-2`/biên nhận giữ nguyên.
- Biến `$Root`/`foreach ($root …)` che biến `$root` của app (không phân biệt hoa/thường): các tham số kho đổi thành `$KhoRoot` (giữ bí danh `-Root`), vòng lặp thành `$khoRoot`, hàm cấp app dùng `$script:root`.
- Đã khôi phục phần đầu script (`#Requires`, `param([switch]$SelfTest, [string]$TikTokJobFile)`) bị mất trong một commit WIP; có test so với v3.0.1. Closure lồng trong closure làm mất `$c`/`$state` (chip khung giờ) đã sửa.

### Giới hạn đã biết

- Đo ngày 26/10/2026 (`tests\kho\08-perf.ps1`, 2.500 video, HEAD `513be65`): đồng bộ ấm sau khởi động 4.144 ms (bản 3.0.1: 4.803 ms). Mục tiêu dưới 2 giây chưa đạt. Báo cáo phiên ghi khoảng 2–4,5 giây.
- `Get-KhoList`: 158 ms với 2.500 mục (lần đo này). Báo cáo phiên ghi khoảng 240 ms.
- Mục 6 của kế hoạch (trang Facebook sang kho) chưa làm. Trường uploader của yt-dlp chưa kiểm (unverified).
- Chưa có bằng chứng trong tài liệu này cho: đăng/hẹn TikTok thật, Android thật, thao tác giao diện thủ công trên bản thử (unverified).

## 11. Đăng TikTok qua Chrome (tiện ích AutoTok) — nhánh `feature/chrome-ext`, bản 3.2.0 (28/10/2026, chưa phát hành)

Vì sao: tiện ích cho Kid FB.Y đăng video bằng chính Chrome đã đăng nhập TikTok của chủ, không cần cookie (`integrations\autotok-extension\HUONG-DAN-CAI-TIEN-ICH.md`). Đăng qua Chrome là lựa chọn mặc định của tài khoản. Để không đăng trùng, tiện ích chỉ gửi bài sau khi backend ghi nhận cấp phép một lần.

### Kiến trúc

- Tiện ích MV3 ở `integrations\autotok-extension` (`manifest.json`, version 1.0.0). ID cố định `pomofdinonmfmpnpjdneihgklgdkidmc`, do trường `key` (khóa công khai) trong manifest quyết định. Backend chỉ nhận CORS từ đúng ID này (`EXT_ORIGIN` trong `services/ext.py`). Đổi khóa là đổi ID và mất ghép nối.
- Backend: `integrations\autotok\src\web\api\services\ext.py` (máy trạng thái, dựng job, đối soát), `routers\ext.py` (`/api/ext/*`), `db.py` (schema 5, trigger), `web\scheduler\worker.py` (gọi `reconcile_ext` mỗi nhịp). Giao thức: `integrations\autotok-extension\PROTOCOL.md` (protocol v1).
- Đăng: tiện ích tải video từ backend, upload trong trang TikTok Studio (`lib.js` ký yêu cầu, `api-main.js` chạy trong trang), rồi gửi bài bằng XHR mà SDK của trang đã bọc (`hook-main.js`, MAIN world, `document_start`).
- Ghép nối: GUI tạo mã 6 số (5 phút, tối đa 5 lần nhập sai). Tiện ích giữ token trong `chrome.storage.local`; backend chỉ lưu `sha256(token)`.
- GUI (Cài đặt › Kết nối Chrome): thẻ `CardChrome` trong `core\ui\MainWindow.xaml`, logic các hàm `Get-Chrome*` trong `core\kid-fby-gui.ps1`. Có tạo mã, danh sách Chrome, chọn profile, "Thêm tài khoản từ Chrome", "Gỡ", và bộ chọn Chrome/Cookie ở danh sách tài khoản.
- Tự chuyển: tài khoản cookie chuyển sang Chrome đúng một lần khi đúng một Chrome đang online báo cùng tên TikTok (`Get-ChromeAutoSwitchPlan`). Không tự chuyển khi lệch tên (cần xác nhận tay), khi hai Chrome xung đột, hoặc khi chủ đã chọn Cookie.

### Trạng thái và chống đăng trùng

- Job cha (`scheduled_uploads`): tài khoản Chrome không bao giờ ở `pending` hay `running`. Job mới thành `pending_ext`; đến giờ và tài khoản rảnh thì thành `waiting_ext` (tăng `attempt`, tạo job con trong cùng giao dịch); kết thúc `succeeded` hoặc `failed`.
- Job con (`extension_jobs`): `queued` → `claimed` → `uploading` → `ready` → `authorized` → `posted` | `rejected` | `uncertain`; nhánh hủy `revoked`, `failed`. Mỗi tài khoản chỉ có một job con đang mở (chỉ mục duy nhất).
- `authorize` chỉ là một UPDATE có điều kiện, ghi bền trước khi trả lời. Đã cấp phép thì job không bao giờ chạy lại.
- `revoked`: chỉ trước khi cấp phép, khi quá hạn chưa nhận việc (120 s), không có tín hiệu (120 s), hoặc quá 15 phút từ lúc nhận. Job cha `failed`, "chưa đăng".
- `uncertain`: đã cấp phép nhưng không có kết quả sau 180 s. Job cha `failed` kèm `publish_uncertain`; phải kiểm trên TikTok trước khi thử lại. Không bao giờ coi là "chưa đăng".
- Kết quả muộn: `POST /result` nhận mọi lúc, kể cả sau hạn và sau khi backend khởi động lại. Kết quả đầu tiên thắng. Thành công muộn của lần thử đã bị thay: nếu lần mới chưa được cấp phép thì rút lần mới (không đăng trùng); nếu đã cấp phép thì giữ nguyên và ghi lịch sử kèm cảnh báo.
- Trigger `tr_chrome_job_never_running`, `tr_chrome_job_pending_insert`, `tr_chrome_job_pending_update` được tạo lại mỗi lần khởi động: đổi job Chrome `pending` thành `pending_ext` và chặn đổi sang `running`. Lý do (ghi chú trong `db.py`): bản 3.1.0 chỉ nhận `pending`, và nếu gặp job không chạy được nó sẽ thử lại mãi, chặn các tài khoản phía sau.

### Tự mở Chrome

- Job `queued` mà không có Chrome nào của TikTok đó online: backend chạy `chrome.exe --profile-directory="<profile>" --no-first-run`, cửa sổ thu nhỏ không lấy focus (SW_SHOWMINNOACTIVE). Tối đa một lần mỗi job và một lần mỗi 3 phút cho mỗi profile. Sau khi mở, hạn nhận việc là 180 s.
- Đường dẫn `chrome.exe`: `AUTOTOK_BROWSER_PATH` hoặc vị trí chuẩn. `AUTOTOK_CHROME_LAUNCH=off` tắt tự mở (bộ test cũng đặt vậy).
- Profile: GUI lưu profile cho từng Chrome (`PATCH /api/ext/clients/{id}`); chỉ tự lưu gợi ý khi không thể sai (xem commit `a5b3aa0`). Không biết profile và Chrome đóng thì job hết hạn với lời nhắn "mở Chrome hoặc chọn profile".
- Cột mới (schema 5): `extension_clients.chrome_profile_dir`, `extension_clients.last_launch_at`, `extension_jobs.launched_at`.

### Sẵn sàng (`ready`, `ready_reason`)

- Cookie: `ready` = có phiên cookie; lý do `ok` hoặc `no_session`.
- Chrome: `ready` khi Chrome đã gắn với tài khoản, đang online (báo trong 90 s), protocol trong khoảng hỗ trợ, không xung đột. Lý do: `ok`, `chrome_unbound`, `chrome_offline`, `chrome_conflict`, `chrome_need_reload`. GUI đổi thành chữ ở `Get-TikTokReadyReasonText`.
- `has_valid_session` vẫn chỉ nói về phiên cookie.

### Bộ cài và cập nhật tiện ích

- Gói: `build-autotok-bundle.ps1` chỉ đưa vào `extension/` các file allowlist: `manifest.json`, `HUONG-DAN-CAI-TIEN-ICH.md`, `.js`/`.html`/`.css` ở gốc, `icons/*.png|svg|ico`. `devserver/`, `tests/`, `PROTOCOL.md` không vào gói. Build dừng nếu trong thư mục tiện ích có file khóa (`.pem`, `.key`, `.p12`, `.pfx`, `.jks`, `.keystore`, `.crx`, `.der`, `.env*`, `*private*key*`, `update-signing*`).
- Cài (`kid-install.ps1`, `Install-Extension`): đưa file vào `autotok-extension.new`, kiểm SHA256 theo bundle, chờ "drain" (`/health` `ext_active` = 0; `-1` = không rõ, coi là bận), tối đa `-DrainTimeoutSec` (mặc định 300 s), hết thì hoãn sang lần sau. Rồi đổi tên: thư mục cũ thành `.bak`, `.new` thành thư mục chính; lỗi thì trả lại `.bak`. Mất điện giữa hai lần đổi tên thì lần chạy sau khôi phục `.bak` trước mọi việc khác. Không chạm database.
- `dung.ps1` (không `-Force`) từ chối dừng khi còn job `pending_ext`/`waiting_ext` hoặc `ext_active` khác 0.
- Sau khi file tiện ích được thay, Chrome chạy bản cũ tới khi chủ bấm ⟳ ở `chrome://extensions`. Giao thức lệch thì backend báo `need_reload` (PROTOCOL mục 7).

### Giới hạn đã biết

- Cần Chrome đang mở, hoặc mở được bằng profile đã biết. Không thì job hết hạn, chưa gửi gì lên TikTok.
- Riêng tư kèm hẹn giờ bị từ chối (backend và tiện ích). Chế độ bạn bè và nguồn YouTube không hỗ trợ trên đường Chrome.
- Chỉ thử trên Chrome Windows.
- Sau mỗi lần cập nhật tiện ích phải bấm ⟳.
- Hai Chrome cùng tài khoản TikTok: xung đột, không nhận việc, phải gỡ bớt một ở Kết nối Chrome.
- E2E dùng TikTok giả (`integrations\autotok-extension\tests\e2e\harness.js`). Chưa có bằng chứng trong tài liệu này về lần đăng TikTok thật qua Chrome (unverified).
- 3.2.0 chưa có số phát hành: `core/version.txt` vẫn 3.1.0, chưa có tag `v3.2.0`.

### Vị trí test

- Backend (pytest, chạy trong `integrations\autotok\src`): `tests\test_chrome_ext.py`, `test_ext_migration.py`, `test_kiemdinh_ext_p1.py`, `test_kiemdinh_ext_p2.py`. Các file này cần `responses`, không có trong `requirements.lock.txt`; thiếu thì lỗi `ModuleNotFoundError`.
- Tiện ích (Node, chạy trong `integrations\autotok-extension`): `node --test tests\*.test.js` (gate, mainworld, parity, protocol, result-parity, sw).
- E2E: `integrations\autotok-extension\tests\e2e\e2e.test.js` (`node --test tests\e2e\e2e.test.js`); `E2E_PYTHON` trỏ tới Python đã cài thư viện backend.
- GUI và bộ cài: `tests\kho\23-chrome-gui.ps1`, `24-bundle-installer.ps1`, `25-kiemdinh-ext-install.ps1`, `26-kiemdinh-chrome-profile.ps1` (chạy qua `run-all.ps1`).

Kết quả kiểm lúc cập nhật tài liệu (28/10/2026, `c1d606f`, máy làm việc):
- Pytest backend: 623 passed; 2 thất bại do môi trường, đã biết (người điều phối báo cáo; tên hai ca chưa ghi lại ở đây).
- Tiện ích (Node unit): 66/66 pass.
- E2E: 8/8 pass.
- `tests\kho\run-all.ps1`: toàn bộ đạt.
- Chưa kiểm: Chrome thật, đăng TikTok thật, bộ cài trên dịch vụ thật, hạ cấp về 3.1.0.

### Quay lại bản 3.1.0 (thủ tục)

Dùng khi bản 3.2.0 cần lùi. Bản 3.1.0 không biết đường Chrome: nó chỉ nhận job `pending`, còn trigger giữ job Chrome ở `pending_ext`. Vì vậy job Chrome không bị đăng bằng cookie; nó nằm yên ở `pending_ext`.

1. Đợi job Chrome kết thúc, hoặc xóa job chưa gửi. Job `pending_ext` xóa được (`DELETE /api/schedules/{id}`). Job `waiting_ext` không xóa được (409): đợi đến khi nó kết thúc theo hạn ở PROTOCOL mục 5.
2. Muốn bản 3.1.0 đăng các tài khoản đó bằng cookie thì, trong bản 3.2.0, chuyển từng tài khoản sang Cookie trước khi lùi (`PATCH` `publisher: cookies`, hoặc chọn Cookie trong danh sách). Hai điều kiện không vượt được: (a) tài khoản không còn job `pending`, `running`, `pending_ext`, `waiting_ext` hay job con chưa kết thúc (409 nếu còn); (b) tài khoản có phiên cookie. Tài khoản tạo từ Chrome không có cookie, nên phải đăng nhập bằng cookie trước (409 nếu chưa).
3. Tài khoản không chuyển về Cookie thì job `pending_ext` còn lại nằm yên với bản 3.1.0; không có đường nào đăng chúng bằng cookie.
4. Dừng dịch vụ bằng `integrations\autotok\dung.ps1` (không `-Force`); script từ chối nếu còn job Chrome hoặc `ext_active` khác 0.
5. Khuyến nghị: sao lưu thư mục dữ liệu (`DataDir`, mặc định `%LOCALAPPDATA%\KidFBY\autotok-data`) trước khi đổi bản. Repo không có script sao lưu (unverified).
6. Đưa app về 3.1.0 (EXE của tag `v3.1.0`, commit `e403d90`) rồi cài lại bộ đăng từ gói của bản đó (mục 9). Chưa có lệnh hạ cấp riêng cho bộ đăng; cơ chế "quay về bản trước" trong `kid-install.ps1` chỉ dùng khi cài lỗi (unverified: chưa thử hạ cấp trên máy thật).
7. Database: bản 3.1.0 chạy trên schema 5. Migration của 3.1.0 chỉ bỏ qua khi `user_version` ≥ 3 (đọc mã; unverified khi chạy thật). Bảng `extension_*` và cột mới không được 3.1.0 dùng.
8. Kiểm sau khi lùi: `/health` của 3.1.0 không có `chrome_ext`. Muốn lên lại 3.2.0 thì cài lại 3.2.0; trigger và bảng đã có, migration chạy lại được.
