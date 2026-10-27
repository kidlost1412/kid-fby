'use strict';
// Renders from chrome.storage.local only. Never waits for the service worker: actions are fire-and-forget
// and the UI updates through storage.onChanged.
const $ = (id) => document.getElementById(id);
const nudge = (popup, extra) => { try { chrome.runtime.sendMessage(Object.assign({ popup }, extra)).catch(() => {}); } catch (_) { /* SW asleep: it wakes on its own */ } };
const STEPS = ['start', 'transfer-in', 'step', 'transfer', 'post'];
const STEP_VI = { 'transfer-in': 'nhận video từ ứng dụng', step: 'gọi TikTok (tải lên)', transfer: 'tải video lên', start: 'bắt đầu', post: 'bấm Đăng', hello: 'bắt đầu', opened: 'mở cửa sổ', opening: 'mở cửa sổ', 'content-ready': 'trang đã sẵn sàng', identity: 'kiểm tra tài khoản' };
const NEED_RELOAD = 'Cần tải lại tiện ích (chrome://extensions → ⟳)';
let last = {};
let formFilled = false;

function conn(d) {
  const c = d.conn || { state: 'unpaired' };
  const paired = !!(d.settings && d.settings.token);
  let dot = '', text = '', sub = '';
  if (!paired) { text = 'Chưa ghép nối'; sub = 'Nhập mã 6 số từ ứng dụng (Cài đặt → Kết nối Chrome)'; }
  else if (c.state === 'unauthorized') { dot = 'bad'; text = 'Cần ghép nối lại'; sub = 'Ứng dụng đã gỡ Chrome này'; }
  else if (c.needReload || c.state === 'need_reload') { dot = 'bad'; text = 'Cần tải lại tiện ích'; sub = c.message || NEED_RELOAD; }
  else if (c.state === 'conflict') { dot = 'bad'; text = 'Trùng tài khoản'; sub = c.message || 'Một Chrome khác đang dùng cùng tài khoản TikTok'; }
  else if (c.state === 'no_identity') { dot = 'bad'; text = 'Chưa đăng nhập TikTok'; sub = 'Đăng nhập TikTok trong Chrome này rồi chờ vài giây'; }
  else if (c.error) { dot = 'bad'; text = 'Mất kết nối ứng dụng'; sub = String(c.error).slice(0, 100); }
  else if (c.state === 'ok' && c.helloAt && Date.now() - c.helloAt < 120000) { dot = 'ok'; text = 'Đã kết nối ứng dụng'; }
  else { text = 'Đang kết nối…'; }
  return { dot, text, sub, paired, c };
}

function render(d) {
  last = d;
  const a = d.activeJob, r = d.lastResult;
  const st = $('status');
  const bar = $('bar');
  const k = conn(d);
  if (a) {
    const i = STEPS.indexOf(a.phase), n = STEPS.length;
    st.className = 'card st-run';
    $('sTitle').textContent = a.finished ? 'Đang gửi kết quả…' : `Đang ${a.mode === 'selfcheck' ? 'tự kiểm' : 'làm việc'}: bước ${Math.max(i + 1, 1)}/${n}`;
    $('sSub').textContent = (STEP_VI[a.phase] || a.phase || '') + (a.pct != null ? ` · ${a.pct}%` : '') + (a.authorized ? ' · ĐÃ CẤP QUYỀN ĐĂNG' : '');
    bar.hidden = false;
    const frac = a.pct != null && i >= 0 ? (i + a.pct / 100) / n : (Math.max(i, 0) + 1) / n;
    $('barFill').style.width = Math.round(frac * 100) + '%';
  } else if (r && /^(failed|rejected|uncertain)$/.test(r.outcome)) {
    st.className = 'card st-err'; bar.hidden = true;
    $('sTitle').textContent = 'Lỗi: ' + (r.reason || r.outcome);
    $('sSub').textContent = (r.detail || '').slice(0, 160);
  } else {
    st.className = 'card ' + (k.c.needReload ? 'st-err' : 'st-idle'); bar.hidden = true;
    $('sTitle').textContent = k.c.needReload ? 'Cần tải lại tiện ích' : 'Đang rảnh';
    $('sSub').textContent = k.c.needReload ? NEED_RELOAD : (r ? 'Việc cuối: ' + r.outcome : '');
  }
  $('srvDot').className = 'dot' + (k.dot ? ' ' + k.dot : '');
  $('srvText').textContent = k.text;
  $('srvSub').textContent = k.sub;
  $('acct').textContent = 'Tài khoản TikTok: ' + (k.c.identity ? '@' + k.c.identity.username : d.account ? '@' + d.account : 'chưa biết');
  $('pairBox').hidden = k.paired;
  $('pairErr').textContent = d.pairError || '';
  $('pairBtn').disabled = !!d.pairing;
  $('unpair').hidden = !k.paired;
  if (!formFilled) {
    formFilled = true;
    const s = Object.assign({ server: 'http://127.0.0.1:8765', windowStrategy: 'minimized', keepOpen: false, polling: true }, d.settings);
    $('server').value = s.server; $('strategy').value = s.windowStrategy;
    $('keepOpen').checked = s.keepOpen; $('polling').checked = s.polling;
  }
  if ($('dLog').open) renderLog();
}
function renderLog() { $('log').textContent = (last.log || []).slice(-20).join('\n'); }

const load = () => chrome.storage.local.get(['activeJob', 'lastResult', 'conn', 'settings', 'account', 'log', 'pairError', 'pairing']).then(render);
let timer = null;
chrome.storage.onChanged.addListener(() => { clearTimeout(timer); timer = setTimeout(load, 300); });
load();
$('dLog').addEventListener('toggle', renderLog);

$('pairBtn').onclick = () => { $('pairErr').textContent = ''; nudge('pair', { code: $('code').value }); };
$('unpair').onclick = () => nudge('unpair');
$('selfcheck').onclick = () => nudge('selfcheck');
$('pollnow').onclick = () => nudge('poll');
$('clear').onclick = () => nudge('clear');
$('copy').onclick = () => navigator.clipboard.writeText(JSON.stringify(last.lastResult, null, 1)).catch(() => {});
$('save').onclick = () => {
  const cur = last.settings || {};
  const settings = Object.assign({}, cur, { server: $('server').value.trim(), windowStrategy: $('strategy').value, keepOpen: $('keepOpen').checked, polling: $('polling').checked });
  chrome.storage.local.set({ settings }).then(() => { $('saved').textContent = 'Đã lưu'; nudge('poll'); });
};
