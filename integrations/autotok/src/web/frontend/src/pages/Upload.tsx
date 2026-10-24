import { useMemo, useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { useDropzone } from "react-dropzone";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Accounts, Schedules, Uploads, Videos, errorMessage } from "../api/client";
import clsx from "clsx";
import { Link, useSearchParams } from "react-router-dom";
import SchedulePicker, { inScheduleWindow } from "../components/SchedulePicker";
import { formatFileSize, formatTimeFirst, localizeMessage } from "../locale";

const ytRe =
  /^https?:\/\/(?:www\.|m\.)?(?:youtube\.com\/(?:watch\?v=|shorts\/|embed\/)|youtu\.be\/)[\w-]+/i;

const schema = z
  .object({
    username: z
      .string({ required_error: "Vui lòng chọn tài khoản", invalid_type_error: "Vui lòng chọn tài khoản" })
      .min(1, "Vui lòng chọn tài khoản"),
    title: z
      .string({ required_error: "Vui lòng nhập mô tả video", invalid_type_error: "Vui lòng nhập mô tả video" })
      .min(1, "Vui lòng nhập mô tả video")
      .max(2200, "Tối đa 2.200 ký tự"),
    source_type: z.enum(["local", "library", "youtube"]),
    youtube_url: z.string().optional(),
    library_name: z.string().optional(),
    scheduled_for: z.string().optional(), // datetime-local
    // Checkboxes produce booleans; converted to 0/1 for the API.
    allow_comment: z.boolean(),
    allow_duet: z.boolean(),
    allow_stitch: z.boolean(),
    private: z.boolean(),
    ai_label: z.boolean(),
  })
  .superRefine((val, ctx) => {
    if (val.source_type === "youtube") {
      if (!val.youtube_url) {
        ctx.addIssue({ code: "custom", path: ["youtube_url"], message: "Vui lòng nhập thông tin" });
      } else if (!ytRe.test(val.youtube_url)) {
        ctx.addIssue({ code: "custom", path: ["youtube_url"], message: "Liên kết YouTube không hợp lệ" });
      }
    }
    if (val.source_type === "library" && !val.library_name) {
      ctx.addIssue({ code: "custom", path: ["library_name"], message: "Vui lòng chọn video" });
    }
    if (val.scheduled_for) {
      const when = new Date(val.scheduled_for);
      if (isNaN(when.getTime()) || !inScheduleWindow(when)) {
        ctx.addIssue({ code: "custom", path: ["scheduled_for"], message: "Giờ hẹn phải từ 20 phút đến 10 ngày kể từ bây giờ" });
      }
      if (val.private) {
        ctx.addIssue({ code: "custom", path: ["private"], message: "TikTok không cho hẹn giờ video riêng tư" });
      }
    }
  });

type FormValues = z.infer<typeof schema>;

const SOURCES = [
  ["local", "Chọn tệp video"],
  ["library", "Từ thư viện"],
  ["youtube", "Liên kết YouTube"],
] as const;

export default function UploadPage() {
  const [params] = useSearchParams();
  const initialVideo = params.get("video") ?? "";
  const qc = useQueryClient();
  const { data: accounts } = useQuery({ queryKey: ["accounts"], queryFn: Accounts.list });
  const { data: videos } = useQuery({ queryKey: ["videos"], queryFn: Videos.list });
  const [file, setFile] = useState<File | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [message, setMessage] = useState<{ ok: boolean; text: string; link?: boolean } | null>(null);
  const [needsReview, setNeedsReview] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);

  const defaults: Partial<FormValues> = {
    source_type: initialVideo ? "library" : "local",
    library_name: initialVideo,
    allow_comment: true,
    allow_duet: false,
    allow_stitch: false,
    private: false,
    ai_label: false,
  };
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: defaults,
  });
  const sourceType = form.watch("source_type");
  const selectedUser = form.watch("username");

  const dz = useDropzone({
    accept: { "video/mp4": [".mp4"], "video/webm": [".webm"], "video/quicktime": [".mov"] },
    maxFiles: 1,
    onDrop: files => {
      setFileError(null);
      setFile(files[0] ?? null);
    },
  });

  const submit = useMutation({
    mutationFn: async (values: FormValues): Promise<{ ok: boolean; uncertain?: boolean; text: string; link?: boolean }> => {
      const options = {
        allow_comment: values.allow_comment ? 1 : 0,
        allow_duet: values.allow_duet ? 1 : 0,
        allow_stitch: values.allow_stitch ? 1 : 0,
        visibility_type: values.private ? 1 : 0,
        ai_label: values.ai_label ? 1 : 0,
      };

      if (values.scheduled_for) {
        let source_type: "local" | "youtube" = "youtube";
        let source_ref = values.youtube_url ?? "";
        if (values.source_type === "local") {
          // Save the dropped file to the library so the scheduler can find it later.
          const saved = await Videos.add(file!);
          qc.invalidateQueries({ queryKey: ["videos"] });
          source_type = "local";
          source_ref = saved.name;
        } else if (values.source_type === "library") {
          source_type = "local";
          source_ref = values.library_name!;
        }
        const r = await Schedules.create({
          username: values.username,
          title: values.title,
          source_type,
          source_ref,
          scheduled_for: new Date(values.scheduled_for).toISOString(),
          options,
        });
        const at = formatTimeFirst(r.tiktok_schedule_time ?? values.scheduled_for);
        return { ok: true, text: `Đang gửi lên TikTok để hẹn đăng lúc ${at}. Khi Lịch đăng hiện “Đã hẹn trên TikTok”, bạn có thể tắt máy.`, link: true };
      }

      if (values.source_type === "youtube") {
        const r = await Uploads.youtube({
          username: values.username,
          title: values.title,
          youtube_url: values.youtube_url,
          options,
        });
        return { ok: r.ok, uncertain: r.uncertain, text: r.ok ? `TikTok đã nhận video (mã ${r.video_id ?? "—"})` : localizeMessage(r.message) };
      }

      if (values.source_type === "library") {
        const r = await Uploads.library({
          username: values.username,
          title: values.title,
          name: values.library_name,
          options,
        });
        return { ok: r.ok, uncertain: r.uncertain, text: r.ok ? `TikTok đã nhận video (mã ${r.video_id ?? "—"})` : localizeMessage(r.message) };
      }

      const fd = new FormData();
      fd.append("video", file!);
      fd.append("username", values.username);
      fd.append("title", values.title);
      fd.append("options_json", JSON.stringify(options));
      const r = await Uploads.file(fd);
      return { ok: r.ok, uncertain: r.uncertain, text: r.ok ? `TikTok đã nhận video (mã ${r.video_id ?? "—"})` : localizeMessage(r.message) };
    },
    onSuccess: (m, values) => {
      setMessage(m);
      if (m.uncertain) setNeedsReview(true);
      if (m.ok) {
        // Clear the form so the same job cannot be submitted twice; keep the chosen account.
        form.reset({ ...defaults, source_type: "local", library_name: "", username: values.username });
        setFile(null);
        setFileError(null);
      }
    },
    onError: (e: any) => {
      setMessage({ ok: false, text: `Lỗi: ${errorMessage(e)}` });
      if (!e?.response || e.response.status >= 500) setNeedsReview(true);
    },
  });

  // Move focus to the first invalid control once React has rendered the error state.
  const focusFirstError = () => {
    setTimeout(() => {
      const el = formRef.current?.querySelector<HTMLElement>('[aria-invalid="true"]');
      if (!el) return;
      const details = el.closest("details");
      if (details) details.open = true;
      el.scrollIntoView({ block: "center", behavior: "smooth" });
      el.focus({ preventScroll: true });
    }, 50);
  };
  const handleFormSubmit = (e: React.BaseSyntheticEvent) => {
    const fileMissing = sourceType === "local" && !file;
    setFileError(fileMissing ? "Vui lòng chọn tệp video hoặc đổi nguồn video" : null);
    return form.handleSubmit(
      values => {
        if (fileMissing) {
          focusFirstError();
          return;
        }
        setMessage(null);
        submit.mutate(values);
      },
      focusFirstError,
    )(e);
  };
  const errors = form.formState.errors;

  const accountOptions = useMemo(
    () => (accounts ?? []).filter(a => a.has_valid_session),
    [accounts],
  );
  const selectedAccount = accountOptions.find(a => a.username === selectedUser);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Đăng video</h2>
        <p className="text-sm text-slate-500 mt-1">
          Đăng video ngay hoặc chọn thời gian để hệ thống tự động đăng theo lịch.
        </p>
      </div>

      <form ref={formRef} onSubmit={handleFormSubmit} noValidate className="card space-y-5">
        <div>
          <p className="label" id="account-label">Tài khoản <span className="text-red-600" aria-hidden="true">*</span></p>
          <div role="group" aria-labelledby="account-label" aria-required="true" aria-invalid={!!errors.username} tabIndex={-1} className="flex flex-wrap gap-3 focus:outline-none">
            {accountOptions.map(a => <button key={a.id} type="button" aria-pressed={selectedUser === a.username}
              onClick={() => form.setValue("username", a.username, { shouldValidate: true })}
              className={clsx("min-h-12 max-w-full min-w-0 rounded-xl border px-4 py-3 text-left transition-colors", selectedUser === a.username ? "border-brand-500 bg-brand-50 text-brand-700 ring-1 ring-brand-500" : "border-slate-200 bg-white hover:border-brand-300")}>
              <span className="block max-w-[16rem] truncate text-sm font-semibold" title={`@${a.username}`}>@{a.username}</span>
              {a.display_name && <span className="block max-w-[16rem] truncate text-xs opacity-70" title={a.display_name}>{a.display_name}</span>}
            </button>)}
            {!accountOptions.length && <p className="text-sm text-slate-500">Chưa có tài khoản sẵn sàng. Mở Đăng nhập TikTok để thêm tài khoản.</p>}
          </div>
          {form.formState.errors.username && (
            <p className="text-xs text-red-600 mt-1">{form.formState.errors.username.message}</p>
          )}
          {selectedAccount && (
            <p className="text-xs text-slate-500 mt-1">
              Proxy: <span className="font-mono break-all">{selectedAccount.proxy ?? "Kết nối trực tiếp (không dùng proxy)"}</span>
            </p>
          )}
        </div>

        <div role="tablist" aria-label="Nguồn video" className="flex flex-wrap gap-2 rounded-md bg-slate-100 p-1 w-fit max-w-full">
          {SOURCES.map(([t, label]) => (
            <button
              key={t}
              type="button"
              role="tab"
              aria-selected={sourceType === t}
              className={clsx(
                "px-3 py-2 text-sm font-medium rounded",
                sourceType === t ? "bg-white shadow-sm" : "text-slate-500",
              )}
              onClick={() => form.setValue("source_type", t)}
            >
              {label}
            </button>
          ))}
        </div>

        {sourceType === "local" && (
          <div>
            <p className="label" id="file-label">Video <span className="text-red-600" aria-hidden="true">*</span></p>
            <div
              {...dz.getRootProps({ "aria-labelledby": "file-label", "aria-invalid": !!fileError })}
              className={clsx(
                "rounded-md border-2 border-dashed p-8 text-center cursor-pointer",
                dz.isDragActive ? "border-brand-500 bg-brand-50" : "border-slate-200",
              )}
            >
              <input {...dz.getInputProps()} aria-label="Chọn tệp video" />
              {file ? (
                <p className="text-sm">
                  <span className="font-medium">{file.name}</span>{" "}
                  <span className="text-slate-500">({formatFileSize(file.size)})</span>
                </p>
              ) : (
                <p className="text-sm text-slate-500">Kéo tệp .mp4, .webm hoặc .mov vào đây, hoặc bấm để chọn.</p>
              )}
            </div>
            {fileError && <p className="text-xs text-red-600 mt-1">{fileError}</p>}
          </div>
        )}

        {sourceType === "library" && (
          <div>
            <label className="label" htmlFor="library-name">Video trong thư viện <span className="text-red-600" aria-hidden="true">*</span></label>
            <select id="library-name" className="input" aria-invalid={!!errors.library_name} {...form.register("library_name")}>
              <option value="">Chọn video…</option>
              {(videos ?? []).map(v => (
                <option key={v.name} value={v.name}>
                  {v.name} ({formatFileSize(v.size_bytes)})
                </option>
              ))}
            </select>
            {form.formState.errors.library_name && (
              <p className="text-xs text-red-600 mt-1">{form.formState.errors.library_name.message}</p>
            )}
          </div>
        )}

        {sourceType === "youtube" && (
          <div>
            <label className="label" htmlFor="youtube-url">Liên kết YouTube <span className="text-red-600" aria-hidden="true">*</span></label>
            <input id="youtube-url" className="input" aria-invalid={!!errors.youtube_url} placeholder="https://www.youtube.com/watch?v=…" {...form.register("youtube_url")} />
            {form.formState.errors.youtube_url && (
              <p className="text-xs text-red-600 mt-1">{form.formState.errors.youtube_url.message}</p>
            )}
          </div>
        )}

        <div>
          <label className="label" htmlFor="caption">Mô tả video <span className="text-red-600" aria-hidden="true">*</span></label>
          <textarea id="caption" className="input h-20" aria-required="true" aria-invalid={!!errors.title} {...form.register("title")} />
          {form.formState.errors.title && (
            <p className="text-xs text-red-600 mt-1">{form.formState.errors.title.message}</p>
          )}
        </div>

        <details className="border-t pt-4">
          <summary className="text-sm font-medium text-slate-600 cursor-pointer">Tùy chọn nâng cao</summary>
          <div className="grid grid-cols-2 gap-4 mt-4">
            {(
              [
                ["allow_comment", "Cho phép bình luận"],
                ["allow_duet", "Cho phép song ca"],
                ["allow_stitch", "Cho phép ghép nối"],
                ["private", "Riêng tư"],
                ["ai_label", "Gắn nhãn nội dung do AI tạo"],
              ] as const
            ).map(([key, label]) => (
              <label key={key} className="flex items-center gap-2 text-sm">
                <input type="checkbox" aria-invalid={key === "private" && !!errors.private} {...form.register(key)} />
                {label}
              </label>
            ))}
          </div>
          {form.formState.errors.private && (
            <p className="text-xs text-red-600 mt-2">{form.formState.errors.private.message}</p>
          )}
        </details>

        <div>
          <p className="label" id="schedule-label">Thời gian đăng (không bắt buộc)</p>
          <SchedulePicker value={form.watch("scheduled_for") ?? ""} onChange={value => form.setValue("scheduled_for", value, { shouldValidate: true, shouldDirty: true })} />
          {form.formState.errors.scheduled_for && (
            <p className="text-xs text-red-600 mt-1">{form.formState.errors.scheduled_for.message}</p>
          )}
        </div>

        <div className="flex items-center justify-between pt-2">
          <div className={clsx("text-sm", message?.ok === false ? "text-red-600" : "text-slate-600")}>
            {message?.text}
            {message?.ok && message.link && <> <Link to="/schedules" className="font-medium text-brand-600 underline">Xem Lịch đăng</Link></>}
          </div>
          <button type="submit" className="btn-primary min-h-10" disabled={submit.isPending || needsReview}>
            {submit.isPending ? "Đang xử lý…" : form.watch("scheduled_for") ? "Hẹn giờ trên TikTok" : "Đăng ngay"}
          </button>
        </div>
        {needsReview && <div role="alert" className="rounded-xl bg-amber-50 p-4 text-sm text-amber-900">Chưa rõ kết quả. Video có thể đã được đăng hoặc đã vào Lịch đăng. Hãy kiểm tra tài khoản và Lịch đăng trước khi thử lại.<button type="button" className="btn-secondary mt-3 block" onClick={() => { if (window.confirm("Bạn đã kiểm tra tài khoản TikTok và Lịch đăng, chắc chắn video chưa được đăng và không còn tác vụ đang chờ?")) setNeedsReview(false); }}>Tôi đã kiểm tra, cho phép thử lại</button></div>}
      </form>
    </div>
  );
}
