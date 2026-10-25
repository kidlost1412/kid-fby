# Hướng dẫn cho AI làm việc trong dự án

## Đọc và đối chiếu

- Đọc `BAN-GIAO.md` rồi đối chiếu mã trước khi kết luận. Tài liệu là bản đồ theo nguồn tại thời điểm bàn giao (rà 21/10/2026, nhánh `audit-fixes-2.1`, commit `7f5851a` cùng `main`), không thay cho kiểm chứng.
- Phiên bản nguồn ở `core/version.txt` (hiện 3.0.0, đã phát hành tag `v3.0.0` trên `main`). `build-local.ps1` sinh metadata EXE theo file này. `version.json` và `version.json.sig` đã ký (15 file, gồm `core/autotok-bundle.zip`), nằm trên `main`, khớp các file phân phối của 3.0.0; mọi thay đổi file phân phối sau đó cần `publish.ps1` mới.
- Tìm hàm theo tên bằng `rg`; tránh in cả dòng Base64 rất dài gần đầu GUI. Dùng `--max-columns 180` hoặc AST để đọc `$wpfGifPlayerB64`.

## Nơi sửa

| Công việc | Điểm bắt đầu |
| --- | --- |
| Logic UI/hàng đợi/runspace/tua/overlay/Kho/lịch sử đã đăng/cài đặt | `core/kid-fby-gui.ps1` |
| Giao diện: màu, style, bố cục, trang trí | `core/ui/Theme.xaml`, `core/ui/MainWindow.xaml` |
| Phông giao diện (Nunito, OFL 1.1) | `core/ui/fonts/` |
| ADB/UI Meta/thu âm/khớp khung hình/FFmpeg/xuất bản/installer | `core/kid-fby.ps1` |
| Link/ID/chuẩn hóa URL/trùng/lịch sử loại | `core/facebook-links.ps1` |
| Chẩn đoán Whisper tùy chọn | `core/whisper-language.ps1` |
| GIF WPF | `core/wpf-gif-player.cs` |
| Launcher, single-instance, resource nhúng, giao dịch update | `Program.cs`, `core/updater.ps1` |
| Build, ký manifest và chuẩn bị phát hành | `build-local.ps1`, `publish.ps1`, `new-signing-key.ps1` |
| Tích hợp TikTok: hộp đăng, hàng chuyển, hashtag, link bài | `core/kid-fby-gui.ps1`; làm sạch video `core/kid-fby.ps1`; backend `integrations/autotok/` |
| Bộ cài backend TikTok một chấm, gói `core/autotok-bundle.zip` | `integrations/autotok/kid-install.ps1`, `build-autotok-bundle.ps1`; nút cài ở trang Công cụ trong `core/kid-fby-gui.ps1` |

## Chạy, kiểm, build, phát hành

- Gốc dự án: `D:\reup video fb meta\`. Nhánh làm việc `audit-fixes-2.1`, nhánh chính `main`.
- GUI: `.\Kid-FB.Y.exe`; tự kiểm khởi tạo: `.\Kid-FB.Y.exe -SelfTest`. Engine: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\core\kid-fby.ps1 -Check` (tham số ở đầu `core/kid-fby.ps1`).
- Biến môi trường khi thử: `KID_FBY_NO_MSGBOX=1` (không bật hộp thoại), `KID_FBY_ALLOW_MULTI=1` (bỏ chặn mở nhiều phiên).
- Repo không có bộ test hồi quy cho GUI/engine; `-SelfTest` là kiểm duy nhất cho phần đó. Backend autotok có pytest trong `integrations/autotok/src` (25/10/2026: 454 passed, 5 skipped, 1 xfailed). Harness GUI đặt ngoài repo, dùng thư mục xuất tạm.
- Build: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\build-local.ps1` (csc .NET Framework 4, `Framework64\v4.0.30319`). Build ghi lại Base64 GIF trong `core/kid-fby-gui.ps1` nếu `.cs` đổi, kiểm 13 resource và SelfTest ở thư mục tạm; đạt khi in `PASS: fresh launcher SelfTest and all thirteen embedded resource hashes`. Build không đổi `version.json`.
- Phát hành: `.\publish.ps1 -Version x.y.z [-Note "..."] [-Mandatory] -NoPush`; phiên bản phải lớn hơn `core/version.txt`; script đổi `version.txt`, EXE, manifest ngay và không hoàn tác. Thiếu `-NoPush` thì script tự commit, tag `v<x.y.z>` và push `main`: chỉ chủ dự án chạy.
- Không đọc, chép hay gửi ra ngoài (kể cả cho công cụ AI khác) nội dung `data/`, `output/`, `logs/`, khóa ký.

## Quy ước khi sửa

- Dùng Windows PowerShell 5.1 `powershell.exe -STA` cho kiểm tra runtime WPF. Shell PowerShell 7 không thay thế kiểm chứng host này.
- Giữ PS và XAML UTF-8 BOM + CRLF; C# CRLF. Font `.ttf` là nhị phân, không chuẩn hóa dòng. Không sửa Base64 GIF bằng tay: sửa `.cs`, rồi build đồng bộ.
- Dùng `-LiteralPath` cho file/thư mục do người dùng chọn. Không suy diễn wildcard từ tên có `[]`.
- Kiểm tra caller động, WPF event, CLI và worker script trước khi xóa hàm/biến. Không xem một tìm kiếm không có kết quả là bằng chứng duy nhất của code chết.
- Luồng tải hiện dùng UI Meta, không dùng Whisper để chấp nhận/từ chối audio; Whisper chỉ là chẩn đoán tùy chọn và không nằm trong "Cài tất cả". Thay đổi điều kiện này cần được nêu rõ.
- Hợp đồng engine–GUI nằm ở các dòng `@@KIDFBY_STAGE` và `@@KIDFBY_RESULT` (trường và mã `reason` liệt kê trong `BAN-GIAO.md`). Đổi trường hoặc mã phải sửa `Get-QueueItemOutcome`, `$script:reasonText` và `Get-SyncInfo` trong GUI. Mỗi link phải phát đúng một RESULT, kể cả nhánh lỗi và Dừng. Reason `output-locked` (đích `-3` đang mở, status `failed`) và `publish-failed` (từ nhánh publish) đều phải có chữ ở `$script:reasonText`. Dòng log cũ (`Video : ...`, `REEL_REJECTED:`, `REEDIT_OK:`) là đường dự phòng của GUI; đừng đổi chữ khi chưa cần.
- Cắt âm thanh theo `t0` từ khớp khung hình với `rec.mkv`. Onset chỉ được dùng khi `-AllowOnsetSync` và thiết bị không ghi được hình. Không đưa lại `silencedetect`, `-shortest` hay xuất bản khi khớp không đạt. Reel tự lặp (`SYNC_LOOP`) chọn lần phát sớm nhất ≥ MinOffset; đừng làm mất nhánh này. Đổi ngưỡng khớp (đỉnh ≥ 0,6, tỷ lệ ≥ 1,15, trôi > 80 ms) hoặc số lần thu lại cần được nêu rõ và đo lại trên Reel thật.
- Thư mục xuất chỉ có `-3`; `-1`/`-2`, ảnh thu nhỏ và thư mục giao dịch `.kidfby-publish-*` nằm trong `.cache` ẩn. Mọi chỗ đọc/xóa/phát hiện trùng phải xét `.cache` rồi fallback thư mục xuất (file cũ). Loại video (`Stop-ReelForLanguage`) không được xóa file đã có; gỡ mục loại dùng `Remove-RejectedReel`.
- Launcher nhúng mười ba resource (chín file trong `core/`, trong đó hai XAML ở `core/ui/`, + bốn file font). Thêm hoặc bớt resource phải sửa đồng bộ `Program.cs` (`EmbeddedResources`), cờ `/res:` và vòng kiểm hash trong `build-local.ps1`, và manifest trong `publish.ps1`; stamp (`core\.resources-stamp`) quyết định việc ghi đè script ở máy cũ. `.ttf` chưa nằm trong manifest cập nhật; phông đến máy qua EXE mới.
- Khi đổi ngôn ngữ/queue/Stop/GIF/đồng bộ/xuất bản, chạy ca có thao tác và trạng thái thực; đánh dấu engine giả lập, fixture, Android thật riêng biệt. Không báo tất cả PASS từ kết quả đọc mã. Khi chạy harness GUI đặt `KID_FBY_NO_MSGBOX=1` để không bật hộp thoại.
- `-SelfTest` kiểm khởi tạo và tài nguyên, không kiểm dịch tiếng Việt, tải Facebook, đồng bộ audio hoặc FPS.
- Không gọi `publish.ps1` không có `-NoPush`, commit, tag hay push nếu tác vụ chưa yêu cầu. `-NoPush` vẫn đổi phiên bản/build/manifest cục bộ. Khóa công khai đã gắn trong `core/updater.ps1` (`$UpdatePublicKeyXml`); khóa riêng nằm ngoài repo ở `%USERPROFILE%\.kidfby\update-signing-private.xml` trên máy phát hành, **phải sao lưu** (mất thì không phát hành được cập nhật cho máy đã cài). Không tự tạo khóa thay chủ dự án, không bao giờ đặt khóa riêng (`update-signing-*.xml`) trong repo.
- Lịch sử loại hỏng phải đổi tên `.corrupt-<ts>-<id>` rồi coi như rỗng (không ném lỗi, không xóa); ghi bằng FileStream + Flush. Lỗi đọc `settings.json` do khóa tạm không được ghi đè settings trong phiên đó (`settingsReady=$false`) và không đổi tên `.corrupt`. Dùng `-LiteralPath` cả trong `updater.ps1` và `fix-ket-noi.ps1`.
- `core\_update\gui.hwnd` (`pid|hwnd|ticks`) do GUI ghi, launcher (`Program.cs`) đọc để đưa cửa sổ đang chạy lên trước khi mở lần hai; đổi định dạng phải sửa cả hai phía. Giao diện: khung xem trước không vỏ điện thoại, thanh tua phủ tự ẩn, Xem lớn (`F`/`Esc`), chế độ gọn khi cao < 640 px logic, Kho lưới ảo hóa, toast tối đa 2, vùng bấm ≥ 44; giữ chúng khi sửa XAML/GUI và đo lại kích thước video ở nhiều độ phân giải/DPI. Trang Giới thiệu phải giữ ghi công baoyu-skills (MIT) và Nunito (OFL).
- Bộ cài chỉ nhận nguồn chính thức qua HTTPS và bắt buộc khớp SHA256; không thêm mirror không có checksum, không tắt kiểm chứng chứng chỉ.

- Tích hợp TikTok (mục 8–9 BAN-GIAO): `reup-status.json` chỉ ghi qua `Update-ReupMetadata`; không ghi tay hoặc đặt `Posted` trực tiếp. Đồng bộ không ghi đè `ManualPosted`.
- `.cache\tiktok-posts` (`.job`, `.lock`, `.clean.mp4`) là trạng thái giao dịch: không xóa khi worker còn giữ `.lock`; "Bỏ biên nhận" chỉ đổi tên.
- Đổi `Get-CleanOutputArgs`, `Invoke-CleanVideoMux` hoặc `Test-TikTokCleanFile` phải chạy lại kiểm số keyframe và số khung trên fixture.
- Hẹn giờ TikTok (`link_state` = `scheduled_on_tiktok`): đổi/hủy làm trong TikTok Studio; app chỉ xóa bản ghi của mình.
- `integrations/autotok/` là mã AGPL-3.0 (upstream + sửa đổi): giữ `LICENSE` và ghi công. `.venv`, `runtime`, `config.json`, `data` không đưa vào git.
- `core/autotok-bundle.zip` do `build-autotok-bundle.ps1` dựng (tất định, từ file git-tracked theo allowlist); không sửa zip tay. Đổi `kid-install.ps1` hoặc allowlist thì dựng lại gói rồi `publish.ps1` mới.
- Trạng thái bộ cài trên máy (`integrations/autotok-releases`, `autotok-python311`, `autotok-current.json`, `autotok-config.json`, `autotok-start.ps1`, `autotok-install.log`) nằm trong `.gitignore`; không đưa vào git. Đổi giao dịch cài (drain, chuyển `current`, rollback) phải kiểm lại cả đường lỗi.
- `integrations/tiktok/local.json`, khóa, cookie và dữ liệu backend (mặc định `%LOCALAPPDATA%\KidFBY\autotok-data`, hoặc `DataDir`) không đưa vào git hay tài liệu. Không đăng TikTok thật khi chủ dự án chưa cho phép.

## Dữ liệu cần giữ

- `tools/` chứa executable/DLL/model đang dùng; `data/` chứa lịch sử loại (`rejected-videos.json`), `settings.json` và mốc cập nhật yt-dlp; `output/` chứa media và lịch sử đánh dấu đã đăng; `logs/` chứa log GUI/crash/launcher/updater.
- Khi kiểm thử không ghi vào `output/` và `data/` thật: dùng thư mục xuất tạm, sao lưu và so hash `data/rejected-videos.json`, khôi phục `data/settings.json` sau khi chạy.
- File `-1` và `-2` (trong `.cache`, hoặc ở thư mục xuất với bản cũ) là đầu vào reedit, không phải cache để xóa theo tuổi file.
- Kiểm tra giao dịch đang chờ trước khi dọn `core/_update` hoặc `core/_backup`; không xóa staging/journal/backup đang cần phục hồi. Thư mục `.kidfby-publish-*` trong thư mục xuất có thể là giao dịch xuất bản chưa phục hồi.
- Bộ kiểm định `qa-independent` (280 ca) và `ui-critic` của đợt 5 nằm ngoài repo (thư mục tạm của máy làm việc); không giả định có sẵn trên máy khác.
- Test lớn, media mẫu và báo cáo tạm nên nằm ngoài repo. Tài liệu bàn giao và mã kiểm chứng có mục đích rõ ràng không được coi là rác chỉ vì có đuôi `.md`/`.ps1`.

## Cách báo cáo

Nêu thay đổi, cách kiểm tra, đầu vào và giới hạn còn lại. Không dùng các nhãn lossless/bit-perfect/không bug/60 FPS/tương thích mọi máy khi chưa có bằng chứng tương ứng. Không suy từ lựa chọn UI rằng audio chắc chắn là tiếng Việt, và không suy từ độ tin cậy khớp khung hình rằng tiếng–hình đã khớp khi chưa nghe/xem kiểm.
