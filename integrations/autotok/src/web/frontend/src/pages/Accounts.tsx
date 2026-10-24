import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Trash2, RefreshCcw, LogIn, Download, Globe, ShieldCheck } from "lucide-react";
import { Account, Accounts, Proxies, errorMessage } from "../api/client";
import { formatDateTime, localizeMessage } from "../locale";

function ProxyCell({ account }: { account: Account }) {
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState("");
  const [note, setNote] = useState<string | null>(null);

  const save = useMutation({
    mutationFn: (proxy: string) => Accounts.update(account.id, { proxy }),
    onSuccess: () => {
      setEditing(false);
      setNote(null);
      qc.invalidateQueries({ queryKey: ["accounts"] });
    },
    onError: e => setNote(errorMessage(e)),
  });
  const test = useMutation({
    mutationFn: () => Proxies.test({ account_id: account.id }),
    onSuccess: r => setNote(r.ok ? `TikTok sẽ nhận diện địa chỉ IP ${r.ip}` : localizeMessage(r.error ?? "proxy test failed")),
    onError: e => setNote(errorMessage(e)),
  });

  if (editing) {
    return (
      <div className="space-y-1">
        <div className="flex gap-1">
          <input
            className="input py-1 text-xs"
            placeholder="http://user:pass@host:port"
            value={value}
            onChange={e => setValue(e.target.value)}
            autoFocus
          />
          <button className="btn-primary px-2 py-1 text-xs" onClick={() => save.mutate(value)}>
            Lưu
          </button>
          <button className="btn-secondary px-2 py-1 text-xs" onClick={() => setEditing(false)}>
            Hủy
          </button>
        </div>
        <p className="text-xs text-slate-500">Để trống rồi lưu để gỡ proxy.</p>
        {note && <p className="text-xs text-red-600">{note}</p>}
      </div>
    );
  }

  return (
    <div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span className="font-mono text-xs text-slate-600 truncate max-w-[12rem]" title={account.proxy ?? ""}>
          {account.proxy ?? "Kết nối trực tiếp (không dùng proxy)"}
        </span>
        <button
          className="min-h-9 whitespace-nowrap px-1 text-sm font-medium text-brand-600"
          onClick={() => {
            setValue("");
            setNote(null);
            setEditing(true);
          }}
        >
          {account.proxy ? "Đổi proxy" : "Thêm proxy"}
        </button>
        <button className="min-h-9 whitespace-nowrap px-1 text-sm text-slate-600" onClick={() => test.mutate()} disabled={test.isPending}>
          <Globe size={12} className="inline" /> {test.isPending ? "Đang kiểm tra…" : "Kiểm tra proxy"}
        </button>
      </div>
      {note && <p className="text-xs text-slate-500 mt-1">{note}</p>}
    </div>
  );
}

export default function AccountsPage() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({ queryKey: ["accounts"], queryFn: Accounts.list });
  const [checkNote, setCheckNote] = useState<Record<number, string>>({});

  const importMut = useMutation({
    mutationFn: Accounts.importFromDisk,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["accounts"] }),
  });

  const deleteMut = useMutation({
    mutationFn: (id: number) => Accounts.remove(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["accounts"] }),
  });

  const checkMut = useMutation({
    mutationFn: (id: number) => Accounts.check(id),
    onSuccess: (r, id) => {
      setCheckNote(n => ({ ...n, [id]: r.valid ? "Phiên đăng nhập còn hiệu lực" : "Phiên bị từ chối, cần đăng nhập lại" }));
      qc.invalidateQueries({ queryKey: ["accounts"] });
    },
    onError: (e, id) => setCheckNote(n => ({ ...n, [id]: errorMessage(e) })),
  });

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold">Tài khoản</h2>
          <p className="text-sm text-slate-500 mt-1">
            Quản lý các tài khoản TikTok đã kết nối. Proxy của mỗi tài khoản được dùng cho
            cả đăng nhập và đăng video.
          </p>
        </div>
        <div className="flex gap-2">
          <button
            className="btn-secondary"
            onClick={() => importMut.mutate()}
            disabled={importMut.isPending}
          >
            <Download size={16} />
            Nhập phiên đã lưu
          </button>
          <Link to="/login" className="btn-primary">
            <LogIn size={16} />
            Thêm tài khoản
          </Link>
        </div>
      </div>

      <div className="card p-0 overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="text-left p-3">Tên tài khoản</th>
              <th className="text-left p-3">Phiên đăng nhập</th>
              <th className="text-left p-3">Proxy</th>
              <th className="text-left p-3">Dùng gần nhất</th>
              <th className="p-3 text-right">Thao tác</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {isLoading && (
              <tr>
                <td className="p-4 text-slate-500" colSpan={5}>
                  Đang tải…
                </td>
              </tr>
            )}
            {!isLoading && data && data.length === 0 && (
              <tr>
                <td className="p-6 text-center text-slate-500" colSpan={5}>
                  Chưa có tài khoản. Chọn “Thêm tài khoản” hoặc “Nhập phiên đã lưu”.
                </td>
              </tr>
            )}
            {data?.map(a => (
              <tr key={a.id} className="hover:bg-slate-50 align-top">
                <td className="p-3">
                  <div className="font-medium max-w-[14rem] truncate" title={a.username}>{a.username}</div>
                  {a.display_name && <div className="text-xs text-slate-500 max-w-[14rem] truncate" title={a.display_name}>{a.display_name}</div>}
                </td>
                <td className="p-3">
                  <span
                    className={
                      "chip whitespace-nowrap " +
                      (a.has_valid_session
                        ? "bg-emerald-100 text-emerald-700"
                        : "bg-amber-100 text-amber-700")
                    }
                  >
                    {a.has_valid_session ? "Còn hiệu lực" : "Cần đăng nhập lại"}
                  </span>
                  {checkNote[a.id] && <div className="text-xs text-slate-500 mt-1">{checkNote[a.id]}</div>}
                </td>
                <td className="p-3">
                  <ProxyCell account={a} />
                </td>
                <td className="p-3 text-slate-500">
                  {a.last_used_at ? formatDateTime(a.last_used_at) : "—"}
                </td>
                <td className="p-3 text-right space-x-1 whitespace-nowrap">
                  <button
                    className="inline-flex min-h-10 items-center gap-1 px-2 text-slate-600 text-sm font-medium"
                    onClick={() => checkMut.mutate(a.id)}
                    disabled={checkMut.isPending && checkMut.variables === a.id}
                  >
                    <ShieldCheck size={14} /> Kiểm tra
                  </button>
                  <Link
                    to={`/login?username=${encodeURIComponent(a.username)}`}
                    className="inline-flex min-h-10 items-center gap-1 px-2 text-brand-600 text-sm font-medium"
                  >
                    <RefreshCcw size={14} /> Đăng nhập lại
                  </Link>
                  <button
                    className="inline-flex min-h-10 items-center gap-1 px-2 text-red-600 text-sm font-medium"
                    onClick={() => {
                      if (window.confirm(`Xóa tài khoản '${a.username}' và phiên đăng nhập đã lưu?`)) deleteMut.mutate(a.id);
                    }}
                  >
                    <Trash2 size={14} /> Xóa
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
