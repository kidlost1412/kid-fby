import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useDropzone } from "react-dropzone";
import { Link } from "react-router-dom";
import { Trash2, Play, UploadCloud, Search, X, Send, Film } from "lucide-react";
import clsx from "clsx";
import { Videos, errorMessage, type VideoFile } from "../api/client";
import { formatDateTime, formatFileSize } from "../locale";

function VideoCard({ video, onPreview, onRemove, deleting }: { video: VideoFile; onPreview: () => void; onRemove: () => void; deleting: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const observer = new IntersectionObserver(([entry]) => { if (entry.isIntersecting) { setVisible(true); observer.disconnect(); } }, { rootMargin: "150px" });
    if (ref.current) observer.observe(ref.current);
    return () => observer.disconnect();
  }, []);
  return <article ref={ref} className="group overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm transition-shadow hover:shadow-lg">
    <button onClick={onPreview} className="relative block aspect-[4/3] w-full overflow-hidden bg-slate-200 text-white" aria-label={`Xem video ${video.name}`}>
      <Film size={36} className="absolute inset-0 m-auto text-slate-400" aria-hidden="true" />
      {visible && <video src={`${Videos.streamUrl(video.name)}#t=0.1`} preload="metadata" muted playsInline className="relative h-full w-full bg-slate-950 object-contain" aria-hidden="true" />}
      <span className="absolute inset-0 bg-gradient-to-t from-black/50 to-transparent" />
      <span className="absolute inset-0 flex items-center justify-center"><span className="rounded-full border border-white/40 bg-white/20 p-4 backdrop-blur-sm transition-transform group-hover:scale-110"><Play size={25} fill="currentColor" /></span></span>
      <span className="absolute bottom-3 left-3 rounded-full bg-black/50 px-2 py-1 text-xs">{formatFileSize(video.size_bytes)}</span>
    </button>
    <div className="space-y-3 p-4"><h3 className="truncate text-sm font-semibold" title={video.name}>{video.name}</h3><p className="text-xs text-slate-500">{formatDateTime(video.modified_at)}</p>
      <div className="flex items-center gap-2"><Link className="btn-primary flex-1 justify-center" to={`/upload?video=${encodeURIComponent(video.name)}`}><Send size={14} /> Đăng video</Link><button className="btn-secondary min-h-10" aria-label={`Xóa ${video.name}`} disabled={deleting} onClick={onRemove}><Trash2 size={16} /></button></div>
    </div>
  </article>;
}

export default function VideosPage() {
  const qc = useQueryClient();
  const { data, isLoading, error } = useQuery({ queryKey: ["videos"], queryFn: Videos.list });
  const [note, setNote] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [sort, setSort] = useState("newest");
  const [preview, setPreview] = useState<VideoFile | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { setPreviewError(null); if (preview) dialog.current?.showModal(); else dialog.current?.close(); }, [preview]);
  const addMut = useMutation({ mutationFn: Videos.add, onSuccess: v => { setNote(`Đã thêm ${v.name}`); qc.invalidateQueries({ queryKey: ["videos"] }); }, onError: e => setNote(`Lỗi: ${errorMessage(e)}`) });
  const removeMut = useMutation({ mutationFn: Videos.remove, onSuccess: () => qc.invalidateQueries({ queryKey: ["videos"] }), onError: e => setNote(`Lỗi: ${errorMessage(e)}`) });
  const dz = useDropzone({ accept: { "video/mp4": [".mp4"], "video/webm": [".webm"], "video/quicktime": [".mov"] }, multiple: true, onDrop: async files => {
    for (const file of files) { try { await addMut.mutateAsync(file); } catch { /* surfaced by onError */ } }
  }, onDropRejected: () => setNote("Chỉ nhận video MP4, WebM hoặc MOV.") });
  const filtered = (data ?? []).filter(v => v.name.toLocaleLowerCase("vi").includes(search.toLocaleLowerCase("vi"))).sort((a, b) => sort === "name" ? a.name.localeCompare(b.name, "vi") : sort === "size" ? b.size_bytes - a.size_bytes : Date.parse(b.modified_at) - Date.parse(a.modified_at));
  return <div className="space-y-6">
    <div className="flex flex-wrap items-end justify-between gap-4"><div><h2 className="text-2xl font-semibold">Thư viện video</h2><p className="mt-1 text-sm text-slate-500">Xem lại, chọn video và đăng lên TikTok ngay từ thư viện.</p></div><span className="chip bg-brand-50 text-brand-700">{data?.length ?? 0} video</span></div>
    <div {...dz.getRootProps()} className={clsx("cursor-pointer rounded-2xl border-2 border-dashed p-7 text-center transition-colors", dz.isDragActive ? "border-brand-500 bg-brand-50" : "border-slate-200 bg-white hover:border-brand-400")}><input {...dz.getInputProps()} aria-label="Chọn video để thêm vào thư viện" /><UploadCloud className="mx-auto mb-2 text-brand-600" size={28} /><p className="text-sm font-medium">{addMut.isPending ? "Đang thêm video…" : "Kéo thả video vào đây hoặc bấm để chọn tệp"}</p><p className="mt-1 text-xs text-slate-400">MP4 · WebM · MOV</p></div>
    {note && <p role="status" className="text-sm text-slate-600">{note}</p>}{error && <p role="alert" className="text-sm text-red-600">{errorMessage(error)}</p>}
    <div className="flex flex-wrap gap-3"><label className="relative min-w-48 flex-1"><Search size={17} className="absolute left-3 top-3 text-slate-400" /><input className="input pl-10" aria-label="Tìm video" placeholder="Tìm theo tên video…" value={search} onChange={e => setSearch(e.target.value)} /></label><select aria-label="Sắp xếp video" className="input w-auto" value={sort} onChange={e => setSort(e.target.value)}><option value="newest">Mới nhất</option><option value="name">Tên video A–Z</option><option value="size">Dung lượng lớn nhất</option></select></div>
    {isLoading ? <p className="text-sm text-slate-500">Đang tải thư viện…</p> : filtered.length === 0 ? <div className="card py-12 text-center text-slate-500"><Film className="mx-auto mb-3" /><p>{search ? "Không tìm thấy video phù hợp." : "Thêm video đầu tiên để bắt đầu."}</p></div> : <div className="grid grid-cols-1 gap-5 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">{filtered.map(v => <VideoCard key={v.name} video={v} onPreview={() => setPreview(v)} deleting={removeMut.isPending} onRemove={() => { if (window.confirm(`Xóa video ${v.name} khỏi thư viện?`)) removeMut.mutate(v.name); }} />)}</div>}
    <dialog ref={dialog} onCancel={() => setPreview(null)} onClose={() => setPreview(null)} onClick={e => { if (e.target === e.currentTarget) setPreview(null); }} className="w-[min(960px,95vw)] rounded-2xl bg-white p-0 shadow-2xl backdrop:bg-slate-950/75">
      {preview && <div><div className="flex items-center justify-between gap-4 px-5 py-4"><h3 className="truncate font-semibold">{preview.name}</h3><button className="btn-secondary" aria-label="Đóng xem video" onClick={() => setPreview(null)}><X size={18} /></button></div><video key={preview.name} src={Videos.streamUrl(preview.name)} controls playsInline preload="metadata" className="max-h-[65vh] w-full bg-black" onError={() => setPreviewError("Trình duyệt không phát được định dạng video này. Hãy thử bản MP4 H.264/AAC.")} />{previewError && <p role="alert" className="px-5 pt-4 text-sm text-red-600">{previewError}</p>}<div className="flex flex-wrap items-center justify-between gap-3 p-5"><p className="text-sm text-slate-500">{formatFileSize(preview.size_bytes)} · {formatDateTime(preview.modified_at)}</p><Link className="btn-primary" to={`/upload?video=${encodeURIComponent(preview.name)}`}><Send size={16} /> Đăng video này</Link></div></div>}
    </dialog>
  </div>;
}
