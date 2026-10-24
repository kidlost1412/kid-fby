/** Vietnamese presentation only. API fields, state values and user content stay unchanged. */
const scheduleLabels: Record<string, string> = {
  pending: "Chờ đăng", running: "Đang đăng", succeeded: "Đã đăng",
  failed: "Thất bại", cancelled: "Đã hủy",
};
const loginLabels: Record<string, string> = {
  idle: "Chưa bắt đầu", starting: "Đang mở trình duyệt", pending: "Đang chờ",
  active: "Đang chờ đăng nhập", completing: "Đang lưu phiên",
  completed: "Đã đăng nhập", failed: "Thất bại", expired: "Đã hết hạn",
};
export const scheduleStatus = (status: string, uncertain = false) =>
  status === "failed" && uncertain ? "Chưa rõ kết quả" : scheduleLabels[status] ?? "Không xác định";
export const loginPhase = (phase: string) => loginLabels[phase] ?? "Không xác định";
const pad = (n: number) => String(n).padStart(2, "0");
/** One shared format: "24/10/2026 00:45" (date first, no seconds). */
export const formatDateTime = (value: string | Date) => {
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
/** Sentence form: "08:00, 25/10/2026". */
export const formatTimeFirst = (value: string | Date) => {
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  return `${pad(d.getHours())}:${pad(d.getMinutes())}, ${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`;
};
/** "Giờ địa phương (GMT+7)" from the browser's UTC offset instead of a raw IANA name. */
export const timezoneLabel = () => {
  const offset = -new Date().getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  const minutes = abs % 60;
  return `Giờ địa phương (GMT${sign}${Math.floor(abs / 60)}${minutes ? ":" + pad(minutes) : ""})`;
};
/** "512 KB" below 1 MB, otherwise "12,3 MB". */
export const formatFileSize = (bytes: number) =>
  bytes < 1024 * 1024
    ? `${Math.max(1, Math.round(bytes / 1024)).toLocaleString("vi-VN")} KB`
    : `${(bytes / 1024 / 1024).toLocaleString("vi-VN", { minimumFractionDigits: 1, maximumFractionDigits: 1 })} MB`;

const fields: Record<string, string> = {
  username: "Tên tài khoản", title: "Mô tả video", proxy: "Proxy",
  scheduled_for: "Thời gian đăng", youtube_url: "Liên kết YouTube", source_ref: "Nguồn video",
  name: "Tên video", video: "Video", options: "Tùy chọn", options_json: "Tùy chọn",
  display_name: "Tên hiển thị", status: "Trạng thái", source_type: "Loại nguồn video",
};
const exact: Record<string, string> = {
  "published": "Đã đăng video",
  "account not found": "Không tìm thấy tài khoản.",
  "account row missing": "Tài khoản không còn trong danh sách.",
  "account with that username already exists": "Tên tài khoản này đã tồn tại.",
  "schedule not found": "Không tìm thấy lịch đăng.",
  "login session not found": "Không tìm thấy phiên đăng nhập.",
  "unknown login session": "Không tìm thấy phiên đăng nhập.",
  "no login in progress": "Chưa có phiên đăng nhập nào đang hoạt động.",
  "no sessionid cookie in payload": "Chưa nhận được phiên TikTok. Vui lòng đăng nhập lại.",
  "invalid callback token": "Không thể xác thực phiên đăng nhập. Vui lòng mở lại trình duyệt.",
  "websocket origin not allowed": "Không thể kết nối tới trình duyệt từ trang này.",
  "replaced by a newer login": "Phiên này đã được thay bằng một lần đăng nhập mới.",
  "the virtual browser session was lost": "Phiên trình duyệt đã bị ngắt. Vui lòng đăng nhập lại.",
  "login cancelled": "Đã hủy đăng nhập.",
  "page closed": "Cửa sổ trình duyệt đã đóng.",
  "invalid options_json": "Tùy chọn đăng video không hợp lệ.",
  "video must be a file in the video library": "Vui lòng chọn một video trong thư viện.",
  "this account has pending or running scheduled uploads; cancel them first":
    "Tài khoản còn tác vụ đang chờ hoặc đang đăng. Hãy hủy các lịch đang chờ trước.",
  "the job changed while you were editing it; refresh and try again":
    "Tác vụ đã thay đổi. Hãy tải lại trang rồi thử lại.",
  "cannot delete a running job; wait for it to finish":
    "Không thể xóa tác vụ đang đăng. Vui lòng chờ tác vụ hoàn tất.",
  "scheduled_for must include timezone info": "Thời gian đăng phải có thông tin múi giờ.",
  "scheduled_for must be in the future": "Vui lòng chọn thời gian đăng trong tương lai.",
  "youtube_url must be a valid YouTube URL": "Liên kết YouTube không hợp lệ.",
  "source_ref must be a valid YouTube URL when source_type='youtube'": "Liên kết YouTube không hợp lệ.",
  "proxy test failed": "Không thể kết nối qua proxy. Vui lòng kiểm tra lại địa chỉ.",
  "proxy test failed.": "Không thể kết nối qua proxy. Vui lòng kiểm tra lại địa chỉ.",
  "network error": "Mất kết nối với máy chủ. Nếu đang đăng video, hãy kiểm tra TikTok trước khi thử lại.",
  "failed to fetch": "Không thể kết nối với máy chủ. Vui lòng kiểm tra ứng dụng đang chạy.",
  "failed to load resource": "Không thể tải dữ liệu từ máy chủ.",
  "field required": "Vui lòng nhập thông tin.",
  "required": "Vui lòng nhập thông tin.",
};

/** Translate known backend diagnostics without interpreting captions, filenames or state keys. */
export function localizeMessage(value: unknown): string {
  const message = String(value ?? "").trim();
  if (!message) return "Không thể hoàn tất thao tác. Vui lòng thử lại.";
  const lower = message.toLowerCase();
  if (exact[lower]) return exact[lower];
  let match: RegExpMatchArray | null;
  if ((match = message.match(/^published \(video id (.+)\)$/i))) return `Đã đăng video (mã ${match[1]}).`;
  if ((match = message.match(/^attempt (\d+) failed, will retry: (.*)$/i))) {
    return `Lần thử ${match[1]} chưa thành công, hệ thống sẽ thử lại: ${localizeMessage(match[2])}`;
  }
  if ((match = message.match(/^account ['"](.+)['"] not found$/i))) return `Không tìm thấy tài khoản “${match[1]}”.`;
  if ((match = message.match(/^account ['"](.+)['"] has no valid session/i))) return `Tài khoản “${match[1]}” cần đăng nhập lại.`;
  if ((match = message.match(/^video ['"](.+)['"] is not in the video library$/i))) return `Video “${match[1]}” không có trong thư viện.`;
  if ((match = message.match(/^cannot modify row in status ['"](.+)['"]$/i))) return `Không thể sửa tác vụ ở trạng thái “${scheduleStatus(match[1])}”.`;
  if ((match = message.match(/^invalid transition (.+)→(.+)$/i))) return `Không thể chuyển từ “${scheduleStatus(match[1])}” sang “${scheduleStatus(match[2])}”.`;
  if (lower.includes("may or may not") || lower.includes("may already") || lower.includes("check the account before retrying")) {
    return "Chưa xác nhận được kết quả; video có thể đã được đăng lên TikTok. Hãy kiểm tra tài khoản trước khi thử lại để tránh đăng trùng.";
  }
  if (lower.startsWith("no saved session") || lower.startsWith("no saved session for") || lower.includes("no tiktok session")) {
    return "Chưa có phiên TikTok đã lưu. Vui lòng đăng nhập tài khoản trước.";
  }
  if (lower.includes("session may have expired") || lower.includes("rejected the session") || lower.includes("session expired")) {
    return "Phiên TikTok đã hết hạn hoặc bị từ chối. Vui lòng đăng nhập lại.";
  }
  if (lower.startsWith("invalid account name")) return "Tên lưu phiên chỉ được chứa chữ không dấu, chữ số và các dấu . _ -; không dùng riêng dấu chấm.";
  if (lower.startsWith("unsupported file type")) return "Định dạng tệp không được hỗ trợ. Hãy chọn video .mp4, .webm hoặc .mov.";
  if (lower.startsWith("invalid options_json")) return "Tùy chọn đăng video không hợp lệ. Vui lòng kiểm tra lại.";
  if (lower.includes("only accepts schedules")) return "TikTok chỉ nhận lịch từ 15 phút đến 30 ngày tới; một số tài khoản giới hạn 10 ngày.";
  if (lower.includes("does not allow scheduling private")) return "Không thể lên lịch cho video riêng tư.";
  if (lower.includes("caption is required")) return "Vui lòng nhập mô tả video.";
  if (lower.includes("caption must be at most")) return "Mô tả video không được vượt quá 2.200 ký tự.";
  if (lower.includes("video file is empty") || lower.includes("video is empty")) return "Tệp video rỗng. Vui lòng chọn video khác.";
  if (lower.startsWith("video not found")) return "Không tìm thấy tệp video. Vui lòng chọn lại.";
  if (lower.includes("playwright") && (lower.includes("not installed") || lower.includes("executable doesn't exist"))) {
    return "Chưa tìm thấy trình duyệt để đăng nhập. Vui lòng kiểm tra cài đặt Chrome.";
  }
  if (lower.includes("browser was closed") || lower.includes("target page, context or browser has been closed")) {
    return "Trình duyệt đã đóng trước khi đăng nhập xong. Vui lòng mở lại.";
  }
  if (lower.includes("timed out") || lower.includes("timeout") || lower.includes("econnaborted")) {
    return "Đã hết thời gian chờ. Nếu đang đăng video, hãy kiểm tra tài khoản TikTok trước khi thử lại.";
  }
  if (lower.includes("tiktok rejected the post")) {
    const code = message.match(/status_code[=: ]+(\d+)/i)?.[1];
    return `TikTok đã từ chối bài đăng${code ? ` (mã ${code})` : ""}. Hãy kiểm tra video và tài khoản.`;
  }
  if (lower.includes("proxy") && !/[ăâđêôơư]/i.test(message)) return "Không thể sử dụng proxy. Vui lòng kiểm tra địa chỉ, cổng và thông tin đăng nhập proxy.";
  if (lower.startsWith("youtube download failed") || lower.includes('needs yt-dlp') || lower.includes('no module named') && lower.includes('yt_dlp')) {
    return "Không thể tải video từ YouTube. Vui lòng kiểm tra liên kết và công cụ tải video.";
  }
  if (lower.startsWith("unexpected error") || lower.startsWith("scheduler error")) {
    return "Đã xảy ra lỗi khi xử lý video. Video có thể đã được đăng; hãy kiểm tra TikTok trước khi thử lại.";
  }
  if (lower.includes("could not start the signing browser") || lower.includes("signature generation")) return "Không thể tạo chữ ký để đăng video. Vui lòng kiểm tra trình duyệt và thử lại.";
  if (lower.includes("could not open tiktok") || lower.includes("browser error") || lower.includes("novnc start failed")) return "Không thể mở trình duyệt đăng nhập. Vui lòng kiểm tra Chrome và thử lại.";
  if ((match = message.match(/HTTP[ :]+(\d{3})/i))) return `Máy chủ trả về mã lỗi HTTP ${match[1]}. Vui lòng kiểm tra lại thao tác.`;
  if (lower.includes("connection") || lower.includes("connect") || lower.includes("network") || lower.includes("socket")) {
    return "Không thể kết nối với máy chủ. Vui lòng kiểm tra kết nối và ứng dụng đang chạy.";
  }
  // Messages authored by this interface are already Vietnamese.
  if (/[ăâđêôơưàáạảãèéẹẻẽìíịỉĩòóọỏõùúụủũỳýỵỷỹ]/i.test(message)) return message;
  return "Không thể hoàn tất thao tác. Vui lòng kiểm tra dữ liệu và trạng thái tác vụ.";
}

export function validationMessage(detail: { loc?: Array<string | number>; type?: string; msg?: string; ctx?: Record<string, unknown> }): string {
  const field = [...(detail.loc ?? [])].reverse().find(part => typeof part === "string" && fields[part]);
  const label = typeof field === "string" ? `${fields[field]}: ` : "";
  let message: string;
  switch (detail.type) {
    case "missing": message = "Vui lòng nhập thông tin."; break;
    case "string_too_short": message = `Cần ít nhất ${detail.ctx?.min_length ?? 1} ký tự.`; break;
    case "string_too_long": message = `Tối đa ${detail.ctx?.max_length ?? "số"} ký tự.`; break;
    case "string_pattern_mismatch": message = "Định dạng không hợp lệ."; break;
    case "literal_error": case "enum": message = "Vui lòng chọn một giá trị hợp lệ."; break;
    case "datetime_parsing": case "datetime_from_date_parsing": message = "Ngày hoặc giờ không hợp lệ."; break;
    default: message = localizeMessage((detail.msg ?? "").replace(/^Value error, /i, ""));
  }
  return label + message;
}

export function providerText(text: string, kind: "description" | "step"): string {
  if (/[ăâđêôơưàáạảãèéẹẻẽìíịỉĩòóọỏõùúụủũ]/i.test(text)) return text;
  return kind === "description" ? "Dịch vụ cung cấp proxy." : "Làm theo hướng dẫn trên trang nhà cung cấp để lấy địa chỉ proxy.";
}
