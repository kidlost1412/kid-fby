import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Accounts, Schedules, type Schedule } from "../api/client";
import { formatDateTime, localizeMessage, scheduleStatus } from "../locale";
import { Ban, ExternalLink, RotateCw, Trash2 } from "lucide-react";

/** TikTok accepted the post and holds it until tiktok_schedule_time (the PC can be off). */
const onTikTok = (s: Schedule) => s.status === "succeeded" && !!s.tiktok_schedule_time && s.link_state !== "found";
const safeLink = (url?: string | null) =>
  url && /^https:\/\/www\.tiktok\.com\/@[A-Za-z0-9._]+\/video\/\d+$/.test(url) ? url : null;
const linkText = (s: Schedule) => {
  if (s.status !== "succeeded") return "—";
  switch (s.link_state) {
    case "pending": return "Đang lấy link…";
    case "gave_up": return "Chưa lấy được link";
    case "scheduled_on_tiktok": return "Có link sau giờ đăng";
    default: return "—";
  }
};

const isUncertain = (s: Schedule) => s.status === "failed" && s.publish_uncertain;

const statusClass = (s: Schedule) => {
  if (isUncertain(s)) return "bg-amber-100 text-amber-800";
  if (onTikTok(s)) return "bg-sky-100 text-sky-800";
  switch (s.status) {
    case "succeeded": return "bg-emerald-100 text-emerald-700";
    case "failed":    return "bg-red-100 text-red-700";
    case "running":   return "bg-blue-100 text-blue-700";
    case "cancelled": return "bg-slate-200 text-slate-600";
    default:          return "bg-amber-100 text-amber-700"; // pending
  }
};

function TikTokErrorDetails({ data }: { data: unknown }) {
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  const copy = () => {
    navigator.clipboard.writeText(text).then(
      () => { setCopied(true); setTimeout(() => setCopied(false), 1500); },
      () => window.alert("Không sao chép được. Hãy bôi đen nội dung và sao chép thủ công."),
    );
  };
  return (
    <div className="mt-1">
      <button className="text-xs underline text-slate-600" onClick={() => setOpen(!open)}>
        {open ? "Ẩn chi tiết lỗi TikTok" : "Chi tiết lỗi TikTok"}
      </button>
      {open && (
        <div className="mt-1">
          <pre className="max-w-xs max-h-60 overflow-auto whitespace-pre-wrap break-all rounded bg-slate-50 p-2 text-xs">{text}</pre>
          <button className="mt-1 text-xs underline text-brand-600" onClick={copy}>{copied ? "Đã sao chép" : "Sao chép"}</button>
        </div>
      )}
    </div>
  );
}

const actionBtn = "inline-flex min-h-10 items-center gap-1 rounded-md border px-3 text-sm font-medium whitespace-nowrap";

export default function SchedulesPage() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ["schedules"],
    queryFn: Schedules.list,
    refetchInterval: 5000, // poll while the scheduler works
  });
  const { data: accounts } = useQuery({ queryKey: ["accounts"], queryFn: Accounts.list });
  const usernameOf = (id: number) => accounts?.find(a => a.id === id)?.username;

  const cancelMut = useMutation({
    mutationFn: (id: number) => Schedules.cancel(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["schedules"] }),
  });
  const retryMut = useMutation({
    mutationFn: ({ id, confirmUncertain }: { id: number; confirmUncertain: boolean }) =>
      Schedules.retry(id, confirmUncertain),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["schedules"] }),
  });

  // A job cut off while publishing may already be live: retrying could post it twice.
  const retry = (s: Schedule) => {
    const message = s.publish_uncertain
      ? "Video này có thể đã được đăng lên TikTok: lần đăng trước bị gián đoạn.\n\n" +
        "Hãy kiểm tra tài khoản trước. Bạn vẫn muốn đăng lại video này?"
      : "Thử đăng lại video này?";
    if (!window.confirm(message)) return;
    retryMut.mutate({ id: s.id, confirmUncertain: s.publish_uncertain });
  };
  const cancel = (s: Schedule) => {
    if (window.confirm("Hủy lịch đăng này? Video sẽ không được đăng vào giờ đã hẹn.")) cancelMut.mutate(s.id);
  };
  const deleteMut = useMutation({
    mutationFn: (id: number) => Schedules.remove(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["schedules"] }),
  });
  const remove = (s: Schedule) => {
    const text = s.tiktok_schedule_time && s.status === "succeeded"
      ? "Chỉ xóa khỏi danh sách trong app. Bài đã hẹn trên TikTok KHÔNG bị hủy — muốn hủy hoặc đổi giờ, hãy vào TikTok Studio.\n\nVẫn xóa khỏi danh sách?"
      : "Xóa lịch đăng này khỏi danh sách? Không thể hoàn tác.";
    if (window.confirm(text)) deleteMut.mutate(s.id);
  };

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Lịch đăng</h2>
        <p className="text-sm text-slate-500 mt-1">
          Theo dõi các video được hệ thống tự động đăng vào thời gian đã chọn.
        </p>
      </div>

      <div className="card p-0 overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="text-left p-3">Thời gian</th>
              <th className="text-left p-3">Tài khoản</th>
              <th className="text-left p-3">Video</th>
              <th className="text-left p-3">Nội dung</th>
              <th className="text-left p-3">Trạng thái</th>
              <th className="text-left p-3">Bài đăng</th>
              <th className="text-left p-3">Số lần thử</th>
              <th className="p-3 text-right">Thao tác</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {isLoading && <tr><td className="p-4 text-slate-500" colSpan={8}>Đang tải…</td></tr>}
            {!isLoading && data && data.length === 0 && (
              <tr><td className="p-6 text-center text-slate-500" colSpan={8}>Chưa có video nào được lên lịch.</td></tr>
            )}
            {data?.map(s => (
              <tr key={s.id} className="align-top">
                <td className="p-3 text-slate-600 whitespace-nowrap">
                  {formatDateTime(s.tiktok_schedule_time ?? s.scheduled_for)}
                </td>
                <td className="p-3">
                  <span className="block max-w-[10rem] truncate font-medium" title={usernameOf(s.account_id) ?? ""}>
                    {usernameOf(s.account_id) ? `@${usernameOf(s.account_id)}` : "—"}
                  </span>
                </td>
                <td className="p-3">
                  <span className="block max-w-[14rem] truncate" title={s.source_ref}>{s.source_ref}</span>
                  <span className="text-xs text-slate-500">{s.source_type === "youtube" ? "YouTube" : "Tệp video"}</span>
                </td>
                <td className="p-3 font-medium max-w-xs truncate" title={s.title}>{s.title}</td>
                <td className="p-3">
                  <span className={"chip whitespace-nowrap " + statusClass(s)}>{onTikTok(s) ? "Đã hẹn trên TikTok" : scheduleStatus(s.status, s.publish_uncertain)}</span>
                  {onTikTok(s) && (
                    <div className="text-xs mt-1 text-sky-800">TikTok sẽ tự đăng lúc {formatDateTime(s.tiktok_schedule_time!)}. Có thể tắt máy.</div>
                  )}
                  {s.prior_uncertain && (
                    <div className="text-xs mt-1 text-amber-800">Từng có lần chưa rõ kết quả</div>
                  )}
                  {s.result_text && (
                    <div
                      className={
                        "text-xs mt-1 max-w-xs whitespace-normal break-words " +
                        (s.publish_uncertain ? "text-amber-800" : "text-slate-500")
                      }
                    >
                      {localizeMessage(s.result_text)}
                    </div>
                  )}
                  {s.tiktok_response != null && s.tiktok_response !== "" && <TikTokErrorDetails data={s.tiktok_response} />}
                </td>
                <td className="p-3 whitespace-nowrap">
                  {safeLink(s.post_url)
                    ? <a className="inline-flex items-center gap-1 font-medium text-brand-600 underline" href={safeLink(s.post_url)!} target="_blank" rel="noopener noreferrer"><ExternalLink size={14} /> Mở bài đăng</a>
                    : <span className="text-xs text-slate-500">{linkText(s)}</span>}
                </td>
                <td className="p-3 text-slate-500">{s.attempts}</td>
                <td className="p-3">
                  <div className="flex flex-wrap items-center justify-end gap-2">
                    {s.status === "pending" && (
                      <button className={actionBtn + " border-slate-200 text-slate-700"} onClick={() => cancel(s)}>
                        <Ban size={14} /> Hủy lịch
                      </button>
                    )}
                    {s.status === "failed" && (
                      <button className={actionBtn + " border-brand-200 text-brand-600"} onClick={() => retry(s)}>
                        <RotateCw size={14} /> {s.publish_uncertain ? "Kiểm tra rồi thử lại" : "Thử lại"}
                      </button>
                    )}
                    {s.status !== "running" && (
                      <button className={actionBtn + " ml-3 border-red-200 text-red-600"} onClick={() => remove(s)}>
                        <Trash2 size={14} /> Xóa
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
