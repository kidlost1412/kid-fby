import { useEffect, useRef, useState } from "react";
import { useForm } from "react-hook-form";
import { Link, useSearchParams } from "react-router-dom";
import { useMutation, useQuery } from "@tanstack/react-query";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { ExternalLink, Globe } from "lucide-react";
import { Login, Proxies, ProxyProvider, errorMessage } from "../api/client";
import { localizeMessage, loginPhase, providerText } from "../locale";

const schema = z.object({
  username: z
    .string()
    .min(1, "Vui lòng nhập tên lưu phiên")
    .max(128, "Tối đa 128 ký tự")
    .regex(/^[A-Za-z0-9_.\-]+$/, "Chỉ dùng chữ không dấu, chữ số và các dấu . _ -"),
  proxy: z.string().optional(),
});
type FormValues = z.infer<typeof schema>;

type Phase = "idle" | "starting" | "pending" | "active" | "completing" | "completed" | "failed" | "expired";

// "own", "none", or "provider:<key>" (prefixed so a provider key can't clash with the others).
type ProxyChoice = string;

function ChoiceRow(props: {
  checked: boolean;
  onSelect: () => void;
  title: string;
  description?: string;
  badge?: string;
}) {
  return (
    <label
      className={`flex items-start gap-3 rounded-md border p-3 cursor-pointer ${
        props.checked ? "border-brand-500 bg-brand-50" : "border-slate-200 hover:bg-slate-50"
      }`}
    >
      <input type="radio" className="mt-1" checked={props.checked} onChange={props.onSelect} />
      <span className="text-sm">
        <span className="font-medium">{props.title}</span>
        {props.badge && <span className="chip bg-amber-100 text-amber-800 ml-2">{props.badge}</span>}
        {props.description && <span className="block text-xs text-slate-500 mt-0.5">{props.description}</span>}
      </span>
    </label>
  );
}

function ProviderSteps({ provider }: { provider: ProxyProvider }) {
  return (
    <div className="rounded-md bg-slate-50 p-3 space-y-2 text-xs text-slate-600">
      <a href={provider.signup_url} target="_blank" rel="noopener noreferrer" className="btn-secondary">
        Mở {provider.name} <ExternalLink size={14} />
      </a>
      {provider.steps.length > 0 && (
        <ol className="list-decimal pl-4 space-y-0.5">
          {provider.steps.map(step => (
            <li key={step}>{providerText(step, "step")}</li>
          ))}
        </ol>
      )}
      <p>
        Sau đó dán địa chỉ proxy vào ô bên dưới (<span className="font-mono">{provider.proxy_format}</span>).
      </p>
    </div>
  );
}

export default function LoginPage() {
  const [params] = useSearchParams();
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { username: params.get("username") ?? "", proxy: "" },
  });
  const [phase, setPhase] = useState<Phase>("idle");
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [vncUrl, setVncUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [proxyChoice, setProxyChoice] = useState<ProxyChoice>("own");
  const [proxyNote, setProxyNote] = useState<string | null>(null);
  const { data: providers = [] } = useQuery({ queryKey: ["proxy-providers"], queryFn: Proxies.providers });
  const provider = providers.find(p => proxyChoice === `provider:${p.key}`);
  // Ignore a result if the proxy was edited while it was being tested.
  const stillTested = (proxy: string) => form.getValues("proxy")?.trim() === proxy;
  const testProxy = useMutation({
    mutationFn: (proxy: string) => Proxies.test({ proxy }),
    onSuccess: (r, proxy) => {
      if (stillTested(proxy)) setProxyNote(r.ok ? `Kết nối thành công. TikTok sẽ nhận diện địa chỉ IP ${r.ip}.` : localizeMessage(r.error ?? "Proxy test failed."));
    },
    onError: (e, proxy) => {
      if (stillTested(proxy)) setProxyNote(errorMessage(e));
    },
  });
  const esRef = useRef<EventSource | null>(null);
  const activeRef = useRef<string | null>(null); // session to cancel if the page is left

  useEffect(() => {
    const cancelActive = () => {
      const id = activeRef.current;
      if (id) {
        fetch(`/api/login/browser/${id}`, {
          method: "DELETE",
          keepalive: true,
          headers: { "X-Requested-With": "autotok" },
        }).catch(() => undefined);
      }
    };
    window.addEventListener("beforeunload", cancelActive);
    return () => {
      window.removeEventListener("beforeunload", cancelActive);
      esRef.current?.close();
      cancelActive();
    };
  }, []);

  const onSubmit = async ({ username, proxy }: FormValues) => {
    if (proxyChoice === "none") proxy = undefined;
    if (provider && !proxy?.trim()) {
      form.setError("proxy", { message: `Dán proxy từ ${provider.name} hoặc chọn “Không thêm proxy mới”.` });
      return;
    }
    setError(null);
    setPhase("starting");
    try {
      const r = await Login.start(username, proxy?.trim());
      setSessionId(r.session_id);
      activeRef.current = r.session_id;
      setVncUrl(r.vnc_url);
      const es = new EventSource(Login.eventStreamUrl(r.session_id));
      esRef.current = es;
      es.addEventListener("status", (e: MessageEvent) => {
        setPhase(e.data as Phase);
        if (["completed", "failed", "expired"].includes(e.data)) {
          activeRef.current = null;
          es.close();
        }
      });
      es.addEventListener("failure", (e: MessageEvent) => setError(localizeMessage(e.data)));
      es.onerror = () => {
        if (esRef.current?.readyState === EventSource.CLOSED) return;
        setError("Mất kết nối với máy chủ. Hãy tải lại trang để kiểm tra trạng thái.");
        es.close();
      };
    } catch (e: any) {
      setPhase("failed");
      setError(errorMessage(e));
    }
  };

  const reset = async () => {
    if (sessionId && !["completed", "failed", "expired"].includes(phase)) {
      await Login.cancel(sessionId).catch(() => undefined);
    }
    esRef.current?.close();
    activeRef.current = null;
    setPhase("idle");
    setSessionId(null);
    setVncUrl(null);
    setError(null);
  };

  const finished = ["completed", "failed", "expired"].includes(phase);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Đăng nhập TikTok</h2>
        <p className="text-sm text-slate-500 mt-1">
          Đăng nhập TikTok trong trình duyệt riêng. Phiên đăng nhập được tự động lưu để dùng cho những lần đăng video sau.
        </p>
      </div>

      {phase === "idle" && (
        <form onSubmit={form.handleSubmit(onSubmit)} className="card space-y-4 max-w-md">
          <div>
            <label className="label">Tên lưu phiên</label>
            <input className="input" placeholder="kenh-cua-ban" {...form.register("username")} />
            {form.formState.errors.username && (
              <p className="text-xs text-red-600 mt-1">{form.formState.errors.username.message}</p>
            )}
          </div>
          <div className="space-y-2">
            <label className="label">Proxy</label>
            <p className="text-xs text-slate-500">
              Proxy cung cấp địa chỉ IP riêng cho tài khoản. Nếu dùng nhiều tài khoản, bạn có thể cấu hình một proxy riêng cho từng tài khoản.
            </p>
            <ChoiceRow
              checked={proxyChoice === "own"}
              onSelect={() => setProxyChoice("own")}
              title="Tôi có proxy"
            />
            {providers.map(p => (
              <ChoiceRow
                key={p.key}
                checked={proxyChoice === `provider:${p.key}`}
                onSelect={() => setProxyChoice(`provider:${p.key}`)}
                title={`Lấy proxy từ ${p.name}`}
                description={providerText(p.tagline, "description")}
                badge={p.sponsor ? "Nhà tài trợ" : undefined}
              />
            ))}
            <ChoiceRow
              checked={proxyChoice === "none"}
              onSelect={() => setProxyChoice("none")}
              title="Không thêm proxy mới"
              description="Dùng proxy đã lưu cho tài khoản, nếu có; nếu chưa có thì kết nối trực tiếp."
            />
            {provider && <ProviderSteps provider={provider} />}
            {proxyChoice !== "none" && (
              <div>
                <div className="flex gap-2">
                  <input
                    className="input font-mono"
                    placeholder={provider ? provider.proxy_format : "http://user:pass@host:port"}
                    {...form.register("proxy", { onChange: () => setProxyNote(null) })}
                  />
                  <button
                    type="button"
                    className="btn-secondary"
                    disabled={testProxy.isPending}
                    onClick={() => {
                      const value = form.getValues("proxy")?.trim();
                      if (value) testProxy.mutate(value);
                      else setProxyNote("Dán địa chỉ proxy để kiểm tra kết nối.");
                    }}
                  >
                    <Globe size={14} /> {testProxy.isPending ? "Đang kiểm tra…" : "Kiểm tra"}
                  </button>
                </div>
                {form.formState.errors.proxy && (
                  <p className="text-xs text-red-600 mt-1">{form.formState.errors.proxy.message}</p>
                )}
                {proxyNote && <p className="text-xs text-slate-600 mt-1">{proxyNote}</p>}
                <p className="text-xs text-slate-500 mt-1">
                  Proxy được dùng cho lần đăng nhập này và các lần đăng video sau.
                  {proxyChoice === "own" && " Để trống để giữ proxy hiện tại của tài khoản."}
                </p>
              </div>
            )}
          </div>
          <button className="btn-primary">Mở trình duyệt đăng nhập</button>
        </form>
      )}

      {phase !== "idle" && (
        <div className="card space-y-4">
          <div className="flex items-center justify-between">
            <div>
              {sessionId && <span className="chip bg-brand-50 text-brand-700">Phiên {sessionId.slice(0, 8)}</span>}
              <span className="ml-2 text-sm text-slate-600">
                Trạng thái: <b>{loginPhase(phase)}</b>
              </span>
              {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
            </div>
            <button className="btn-secondary" onClick={reset}>
              {finished ? "Bắt đầu lại" : "Hủy"}
            </button>
          </div>
          {vncUrl && !finished && (
            <iframe
              title="Trình duyệt đăng nhập TikTok"
              src={vncUrl}
              className="w-full border rounded-md"
              style={{ height: "600px" }}
            />
          )}
          {phase === "completed" && (
            <p className="text-sm text-emerald-700">
              Đã lưu phiên đăng nhập. <Link to="/accounts" className="underline">Xem danh sách tài khoản</Link>.
            </p>
          )}
        </div>
      )}
    </div>
  );
}
