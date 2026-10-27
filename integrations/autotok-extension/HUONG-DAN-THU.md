# AutoTok P0 – hướng dẫn thử tiện ích Chrome

Đây là bản **thử nghiệm khả thi** (chưa nối vào app). Mục đích: kiểm chứng trên Chrome thật rằng tiện ích đăng được TikTok từ profile đang đăng nhập. Không có gì đăng lên TikTok trừ khi anh chạy chế độ `post` và đồng ý rõ ràng.

ID tiện ích cố định: `pomofdinonmfmpnpjdneihgklgdkidmc` (do `key` trong manifest).

## 1. Nạp tiện ích (một lần cho mỗi profile)

1. Mở Chrome bằng profile cần thử (ví dụ profile "Vườn").
2. Vào `chrome://extensions` → bật **Chế độ dành cho nhà phát triển** → **Tải tiện ích đã giải nén** → chọn thư mục `integrations\autotok-extension`.
3. Ghim biểu tượng AutoTok lên thanh công cụ; bấm vào để mở popup.
4. Sau khi sửa file trong thư mục này: bấm nút tải lại của tiện ích ở `chrome://extensions`.

## 2. Chạy dev server (PowerShell)

```powershell
cd D:\kidfby-wt\kho\integrations\autotok-extension\devserver
python devserver.py --token DOI-TOKEN-NAY --video "D:\duong-dan\clip.mp4" --mode selftest --caption "Xin chào 🌸 #việtnam #tiktok`ndòng hai" --visibility private
```

Tuỳ chọn: `--schedule 2026-10-30T20:30:00+07:00` (hẹn giờ), `--expect-account tenid` (trang phải đang đăng nhập đúng tài khoản này), `--port`, `--log`.
Server chỉ nghe `127.0.0.1:8799`. Mỗi lần chạy tạo 1 job; muốn thêm job: `POST /api/jobs` (cùng token) hoặc chạy lại.

Trong popup → **Cài đặt**: dán cùng token, giữ địa chỉ `http://127.0.0.1:8799`, chọn kiểu cửa sổ (mặc định **Thu nhỏ**), tick **Bật nhận job**, bấm **Lưu**. Tiện ích tự nhận job, mở cửa sổ Studio thu nhỏ, làm hết các bước rồi đóng cửa sổ (tick "Giữ cửa sổ sau khi xong" nếu muốn xem).

## 3. Ba chế độ

| `--mode` | Làm gì | Có đăng lên TikTok không |
|---|---|---|
| `selftest` | Tải video lên Studio, chờ xử lý, điền caption, chọn quyền riêng tư (+ hẹn giờ). **Dừng trước nút Đăng.** Báo selector nào tìm thấy. Server không bao giờ cấp quyền bấm Đăng. | Không |
| `intercept` | Như trên rồi **bấm Đăng**, nhưng hook ở MAIN world chặn request và trả về phản hồi giả; gửi về server đúng body request (caption, schedule_time, visibility…). | Không (request bị chặn) |
| `post` | Đăng thật, báo `status_code` + `item_id` thật. Server chỉ nhận khi chạy với `--allow-post`. **Chỉ dùng khi anh đồng ý tại thời điểm đó, với video riêng tư/thử.** | CÓ |

Nút **Tự kiểm (không đăng)** trong popup: mở Studio (không cần video/server), liệt kê selector tìm thấy và tài khoản đăng nhập. Xem kết quả ở khung "Kết quả cuối" (nút "Chép kết quả cuối").

Lưu ý: selftest/intercept vẫn **tải video lên máy chủ TikTok** (thành bản nháp trong Studio), nhưng không tạo bài đăng.

## 4. Log nằm đâu

- Console của dev server + file `devserver\logs\autotok-dev.jsonl` (mỗi dòng một sự kiện: job-claimed, progress, authorize, result…). Thư mục `logs\` đã bị git bỏ qua.
- Popup: 25 dòng log cuối + kết quả cuối.
- Chi tiết hơn: `chrome://extensions` → AutoTok → **service worker** (Inspect) để xem console của SW; F12 trên tab Studio (nếu dùng kiểu "Giữ cửa sổ") để xem console của content script (`[autotok]`).

## 5. Các phép thử cần quan sát (cổng X4)

Dùng video ~70 MB cho các mục 1–3.

1. **Chuyển byte file + RAM.** SW lấy từng khối 4 MB bằng `Range` từ dev server (có token) rồi gửi cho content script dạng base64; content script ghép thành `File` và gán vào `input[type=file]` bằng `DataTransfer`. Xem log `transfer`: `bytes`, `ms`, `memBefore/memAfter` (MB heap) và dòng `attach` rồi "Studio nhận file". Đạt khi Studio hiện video đã tải và xử lý xong.
2. **Cửa sổ thu nhỏ > 5 phút.** Chạy ở kiểu **Thu nhỏ** với video đủ lâu (hoặc để Studio xử lý lâu). Xem `lagMaxMs` và `vis` trong log `processing` (độ trễ timer khi nền bị giảm tốc), `pct`, thời gian tổng. Sau đó thử khôi phục cửa sổ thủ công (giữ cửa sổ) và so sánh kiểu **Cửa sổ thường, không focus** / **Tab nền**.
3. **Caption.** Dòng log `caption`: `exact`/`loose` và nội dung `actual`. Bằng chứng chính là chế độ `intercept`: kết quả có `request.fields.text`, `request.captionEquals` và `request.body` (tiếng Việt, emoji, hashtag, xuống dòng, `text_extra`). Xem `popupAfter` (popup gợi ý hashtag có còn mở không).
4. **Hook MAIN world.** Kết quả `intercept` có `reqVia` (`xhr`/`fetch`) và `request` ⇒ hook bắt được request đã ký của SDK TikTok. Chế độ `post`: `response` thật, `status_code`, `ids.item_id`.
5. **Hẹn giờ.** Chạy `intercept` với `--schedule`: xem `steps.schedule` (ngày/giờ đọc lại từ ô) và `request.fields.schedule_time` (unix) có đúng giờ đã chọn không. (Hẹn giờ + riêng tư TikTok từ chối; đăng hẹn giờ thật chưa kiểm.)
6. **Tài khoản đăng nhập.** Kết quả có `identity.value`, `identity.source` và `identity.all` (mọi nguồn: `rehydration`, `passport.username`, `dom`, `network:…`). Cho biết nguồn nào ổn định; dùng `--expect-account` để thử từ chối khi sai tài khoản.
7. **SW khởi động lại (không mở 2 tab / không bấm 2 lần).** Trong lúc job đang chạy (lần lượt giai đoạn `transfer`, `processing`, và sau `post`): mở `chrome://serviceworker-internals`, tìm AutoTok, bấm **Stop** (hoặc "Inspect" rồi đóng; hoặc đợi SW tự ngủ). Quan sát: không xuất hiện tab/cửa sổ thứ hai; log có "SW khởi động" rồi job tiếp tục; `authorize` chỉ xuất hiện đúng 1 lần ở `autotok-dev.jsonl`. Thử thêm: tải lại tab Studio **sau** khi có dòng "ĐÃ CẤP QUYỀN" ⇒ kết quả phải là `uncertain` / `tab-reloaded-after-authorization`, không bấm lại. Dọn trạng thái sau thử: nút **Xoá job/log**.

## 6. Giới hạn đã biết

- Selector của Studio **chưa kiểm trên trang thật** (danh sách ở `selectors.js`, nhiều ứng viên/mục). Bước nào không tìm thấy sẽ báo `selector-missing` kèm bản tóm tắt DOM để chỉnh.
- Bộ chọn ngày/giờ hẹn giờ là phần đoán nhiều nhất.
- `tabs.discard`/Chrome đóng giữa chừng: SW kết thúc job là `failed` (trước khi cấp quyền đăng) hoặc `uncertain` (sau đó).

---
## CẬP NHẬT P0b (bản hiện tại thay cho mục 3 và 5 ở trên)
Tiện ích **không còn thao tác giao diện Studio** và **không có đường đăng bài** (chế độ `post` bị tắt cả ở server, tiện ích, trang).
- `--mode selftest`: chỉ TẢI VIDEO LÊN máy chủ TikTok (tạo project → xin quyền → apply → gửi từng phần 5 MB → finish → commit) rồi dừng; báo `ids.video_id`, `ids.creation_id`. Đây là **upload thật** (có thể để lại bản nháp/video mồ côi trong tài khoản; hãy xem Drafts/Posts sau lần chạy đầu).
- `--mode intercept`: như selftest + dựng đầy đủ body đăng (caption, text_extra, quyền riêng tư, lịch) và báo trong `body`, `sent:false`. Không gửi.
- `--chunk-credentials omit|include`: chế độ cookie khi gửi phần video tới máy chủ lưu trữ (mặc định `omit`).
Log mỗi bước (progress `step`): host+path, HTTP status, `readable`, `credentials`, ms, bộ nhớ JS. Lỗi CORS hiện là `network/CORS error ... Failed to fetch` kèm tên bước.
Kiểm offline: `node --test tests\parity.test.js` (đối chiếu với Python), `python -m unittest test_devserver` trong `devserver`.

## P0c – chế độ `post` (CHỈ khi anh đồng ý lúc đó)
Điều kiện BẮT BUỘC cùng lúc: server chạy với `--allow-post`; job `--mode post --visibility private` (không hẹn giờ) và có `--expect-account <username>` (nên thêm `--expect-user-id <số>`); tiện ích đã nạp bản mới.
Trước khi tải lên và ngay trước khi đăng, trang phải đang đăng nhập đúng tài khoản (chỉ tin endpoint passport: `username` + `user_id_str`).
Server ghi quyền đăng vào `devserver\logs\state.json` TRƯỚC khi trả lời; khởi động lại server thì việc đã cấp quyền thành `uncertain`, không bao giờ cấp lại/giao lại. **Chạy lại đúng lệnh `--mode post` KHÔNG an toàn nếu không có bảo vệ: server sẽ TỪ CHỐI khởi động (mã thoát 2) khi `state.json` đã có việc post cho cùng video ở trạng thái đã cấp quyền / không rõ / đã đăng. Phải kiểm tra tài khoản TikTok trước; chỉ khi chắc chắn muốn đăng lại mới thêm cờ `--i-know-this-reposts`.** "Xoá việc" sau khi đã cấp quyền chỉ ghi nhận, không huỷ quyền.
Chỉ có đúng 1 lần gửi, gắn với hash nội dung; kết quả: `posted` (`item_id`), `rejected` (`status_code`), hoặc `uncertain` (không phản hồi — phải kiểm tra tài khoản bằng tay).
Nếu SDK của TikTok chưa bọc XHR sau 30 giây → `sdk-not-ready`, chưa gửi gì.
Kiểm offline: `node --test tests\parity.test.js tests\gate.test.js`.

---
## P1 (bản chính thức): nói chuyện với backend Kid FB.Y
Tiện ích giờ nói giao thức v1 (`PROTOCOL.md`) với backend `http://127.0.0.1:8765` (đổi ở Cài đặt → Địa chỉ máy chủ). Ghép nối: ứng dụng hiện mã 6 số (Cài đặt → Kết nối Chrome), nhập vào popup tiện ích. Không còn ô token.
Việc `post` chính thức: đăng công khai hoặc riêng tư ngay, hoặc công khai có hẹn giờ (15 phút–30 ngày). Riêng tư + hẹn giờ và chế độ "bạn bè" bị từ chối (định mức, chưa tải gì lên). Mọi tuỳ chọn (bình luận / duet / stitch / nhãn AI) đi theo việc.
`devserver.py` giờ là bản giả lập backend (cùng đường `/api/ext/*`, mã ghép nối in ra khi chạy hoặc `--pair-code`); các mục ở trên chỉ dùng cho giả lập.
Nút "Tự kiểm" chỉ kiểm tại chỗ: mở Studio, xác nhận hook đã cài và cho biết tài khoản đang đăng nhập (không tải video, không đăng).
