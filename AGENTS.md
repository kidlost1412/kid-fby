# Hướng dẫn cho AI làm việc trong dự án

## Đọc và đối chiếu

- Đọc `BAN-GIAO.md` rồi đối chiếu mã trước khi kết luận. Tài liệu là bản đồ theo nguồn tại thời điểm bàn giao, không thay cho kiểm chứng.
- Phiên bản nguồn ở `core/version.txt`. `build-local.ps1` sinh metadata EXE theo file này. `version.json` phải khớp các file phân phối sau build.
- Tìm hàm theo tên bằng `rg`; tránh in cả dòng Base64 rất dài gần đầu GUI. Dùng `--max-columns 180` hoặc AST để đọc `$wpfGifPlayerB64`.

## Nơi sửa

| Công việc | Điểm bắt đầu |
| --- | --- |
| UI/hàng đợi/runspace/tua/overlay/lịch sử đã đăng | `core/kid-fby-gui.ps1` |
| ADB/UI Meta/thu âm/FFmpeg/installer | `core/kid-fby.ps1` |
| Link/ID/trùng/lịch sử loại | `core/facebook-links.ps1` |
| Chẩn đoán Whisper tùy chọn | `core/whisper-language.ps1` |
| GIF WPF | `core/wpf-gif-player.cs` |
| Launcher và giao dịch update | `Program.cs`, `core/updater.ps1` |
| Build và chuẩn bị phát hành | `build-local.ps1`, `publish.ps1` |

## Quy ước khi sửa

- Dùng Windows PowerShell 5.1 `powershell.exe -STA` cho kiểm tra runtime WPF. Shell PowerShell 7 không thay thế kiểm chứng host này.
- Giữ PS UTF-8 BOM và CRLF; C# CRLF. Không sửa Base64 GIF bằng tay: sửa `.cs`, rồi build đồng bộ.
- Dùng `-LiteralPath` cho file/thư mục do người dùng chọn. Không suy diễn wildcard từ tên có `[]`.
- Kiểm tra caller động, WPF event, CLI và worker script trước khi xóa hàm/biến. Không xem một tìm kiếm không có kết quả là bằng chứng duy nhất của code chết.
- Luồng tải hiện dùng UI Meta, không dùng Whisper để chấp nhận/từ chối audio. Thay đổi điều kiện này cần được nêu rõ.
- Khi đổi ngôn ngữ/queue/Stop/GIF, chạy ca có thao tác và trạng thái thực; đánh dấu engine giả lập, fixture, Android thật riêng biệt. Không báo tất cả PASS từ kết quả đọc mã.
- `-SelfTest` kiểm khởi tạo và tài nguyên, không kiểm dịch tiếng Việt, tải Facebook, đồng bộ audio hoặc FPS.
- Không gọi `publish.ps1` không có `-NoPush`, commit, tag hay push nếu tác vụ chưa yêu cầu. `-NoPush` vẫn đổi phiên bản/build/manifest cục bộ.

## Dữ liệu cần giữ

- `tools/` chứa executable/DLL/model đang dùng; `data/` chứa lịch sử loại; `output/` chứa media và lịch sử đánh dấu đã đăng.
- File `-1` và `-2` là đầu vào reedit, không phải cache để xóa theo tuổi file.
- Kiểm tra giao dịch đang chờ trước khi dọn `core/_update` hoặc `core/_backup`; không xóa staging/journal/backup đang cần phục hồi.
- Test lớn, media mẫu và báo cáo tạm nên nằm ngoài repo. Tài liệu bàn giao và mã kiểm chứng có mục đích rõ ràng không được coi là rác chỉ vì có đuôi `.md`/`.ps1`.

## Cách báo cáo

Nêu thay đổi, cách kiểm tra, đầu vào và giới hạn còn lại. Không dùng các nhãn lossless/bit-perfect/không bug/60 FPS/tương thích mọi máy khi chưa có bằng chứng tương ứng. Không suy từ lựa chọn UI rằng audio chắc chắn là tiếng Việt.
