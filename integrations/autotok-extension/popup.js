'use strict';
// Renders from chrome.storage.local only. Never waits for the service worker: actions are fire-and-forget
// and the UI updates through storage.onChanged.
const $ = (id) => document.getElementById(id);
const nudge = (popup) => { try { chrome.runtime.sendMessage({ popup }).catch(() => {}); } catch (_) { /* SW asleep: it wakes on its own */ } };
const STEPS = ['start', 'identity', 'transfer', 'attach', 'processing', 'processed', 'caption', 'visibility', 'schedule', 'post'];
const STEP_VI = { start: 'bắt đầu', identity: 'kiểm tra tài khoản', transfer: 'chuyển video', attach: 'gán file', processing: 'TikTok xử lý video', processed: 'xử lý xong', caption: 'điền caption', visibility: 'quyền riêng tư', schedule: 'hẹn giờ', post: 'bấm Đăng', hello: 'bắt đầu', opened: 'mở cửa sổ', opening: 'mở cửa sổ', 'content-ready': 'trang đã sẵn sàng' };
let last = {};
let formFilled = false;

function render(d) {
  last = d;
  const a = d.activeJob, r = d.lastResult;
  const st = $('status');
  const bar = $('bar');
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
    st.className = 'card st-idle'; bar.hidden = true;
    $('sTitle').textContent = 'Đang rảnh';
    $('sSub').textContent = r ? 'Việc cuối: ' + r.outcome : '';
  }
  const p = d.poll;
  const fresh = p && Date.now() - p.at < 90000;
  const ok = p && /^đang chờ/.test(p.state);
  const bad = p && /^lỗi/.test(p.state);
  $('srvDot').className = 'dot' + (ok && fresh ? ' ok' : bad ? ' bad' : '');
  $('srvText').textContent = 'Máy chủ: ' + (bad ? 'mất kết nối' : ok && fresh ? 'đã kết nối' : p ? p.state : 'chưa rõ');
  $('srvSub').textContent = bad ? p.state.slice(0, 100) : '';
  $('acct').textContent = 'Tài khoản TikTok: ' + (d.account ? '@' + d.account : 'chưa biết (bấm Tự kiểm)');
  if (!formFilled) {
    formFilled = true;
    const s = Object.assign({ server: 'http://127.0.0.1:8799', token: '', windowStrategy: 'minimized', keepOpen: false, polling: true }, d.settings);
    $('server').value = s.server; $('token').value = s.token; $('strategy').value = s.windowStrategy;
    $('keepOpen').checked = s.keepOpen; $('polling').checked = s.polling;
  }
  if ($('dLog').open) renderLog();
}
function renderLog() { $('log').textContent = (last.log || []).slice(-20).join('\n'); }

const load = () => chrome.storage.local.get(['activeJob', 'lastResult', 'poll', 'settings', 'account', 'log']).then(render);
let timer = null;
chrome.storage.onChanged.addListener(() => { clearTimeout(timer); timer = setTimeout(load, 300); });
load();
$('dLog').addEventListener('toggle', renderLog);

$('selfcheck').onclick = () => nudge('selfcheck');
$('pollnow').onclick = () => nudge('poll');
$('clear').onclick = () => nudge('clear');
$('copy').onclick = () => navigator.clipboard.writeText(JSON.stringify(last.lastResult, null, 1)).catch(() => {});
$('save').onclick = () => {
  const settings = { server: $('server').value.trim(), token: $('token').value.trim(), windowStrategy: $('strategy').value, keepOpen: $('keepOpen').checked, polling: $('polling').checked };
  chrome.storage.local.set({ settings }).then(() => { $('saved').textContent = 'Đã lưu'; nudge('poll'); });
};
