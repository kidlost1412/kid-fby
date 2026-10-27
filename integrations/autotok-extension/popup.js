'use strict';
const $ = (id) => document.getElementById(id);
const ask = (popup, extra) => chrome.runtime.sendMessage(Object.assign({ popup }, extra));
let loaded = false;

async function refresh() {
  const s = await ask('status');
  if (!s) return;
  if (!loaded) {
    loaded = true;
    $('server').value = s.settings.server; $('token').value = s.settings.token;
    $('strategy').value = s.settings.windowStrategy; $('keepOpen').checked = s.settings.keepOpen; $('polling').checked = s.settings.polling;
  }
  const a = s.active;
  $('state').textContent = a ? `Job ${a.id} [${a.mode}] pha: ${a.phase}${a.authorized ? ' · ĐÃ CẤP QUYỀN ĐĂNG' : ''}${a.finished ? ' · đã xong, chờ gửi kết quả' : ''}` : 'Rảnh (không có job)';
  $('poll').textContent = s.poll ? `Poll: ${s.poll.state} (${new Date(s.poll.at).toLocaleTimeString()})` : '';
  const lg = s.log.slice(-25).join('\n'); if ($('log').textContent !== lg) $('log').textContent = lg;
  $('last').textContent = s.lastResult ? JSON.stringify(s.lastResult, null, 1).slice(0, 6000) : '';
  window.__last = s.lastResult;
}

$('selfcheck').onclick = async () => { await ask('selfcheck'); refresh(); };
$('pollnow').onclick = async () => { await ask('poll'); refresh(); };
$('clear').onclick = async () => { await ask('clear'); refresh(); };
$('copy').onclick = () => navigator.clipboard.writeText(JSON.stringify(window.__last, null, 1));
$('save').onclick = async () => {
  await ask('saveSettings', { settings: { server: $('server').value.trim(), token: $('token').value.trim(),
    windowStrategy: $('strategy').value, keepOpen: $('keepOpen').checked, polling: $('polling').checked } });
  refresh();
};
// event-driven: refresh when storage changes (debounced), plus a slow fallback
let timer = null;
chrome.storage.onChanged.addListener(() => { clearTimeout(timer); timer = setTimeout(refresh, 400); });
refresh(); setInterval(refresh, 5000);
