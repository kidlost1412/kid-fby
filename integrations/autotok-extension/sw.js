// Service worker: coordinator only. All long work (upload, editor, waiting) runs in the Studio tab's
// content script, so a stopped/restarted SW loses nothing: durable state lives in chrome.storage.local
// ('activeJob'), every handler re-reads it, and the worker is re-woken by alarms / content messages.
//
// Idempotency rules (X1 in miniature):
//  - activeJob is written BEFORE the window is opened; a job id that already has an activeJob (or was the
//    last finished one) is never started again -> no second window after a restart.
//  - 'authorized' is persisted BEFORE the content script is allowed to click Post, and only one 'authorize'
//    per job is ever granted (here and on the dev server). A reloaded tab or restarted SW after that point
//    finishes the job as 'uncertain', never re-clicks.
'use strict';

const STUDIO_URL = 'https://www.tiktok.com/tiktokstudio/upload';
const DEFAULTS = { server: 'http://127.0.0.1:8799', token: '', windowStrategy: 'minimized', keepOpen: false, polling: true };
const JOB_DEADLINE_MS = 40 * 60 * 1000;   // whole job
const STALL_MS = 5 * 60 * 1000;           // no progress message from the tab (minimized tabs are throttled)
const CHUNK = 1024 * 1024;
const MAX_LOG = 40;
const CLOSE_GRACE_MS = 10000;

// ---------- storage helpers (serialized so concurrent handlers cannot interleave read-modify-write) ----------
let chain = Promise.resolve();
const locked = (fn) => { const r = chain.then(fn); chain = r.catch(() => {}); return r; };

const getSettings = async () => Object.assign({}, DEFAULTS, (await chrome.storage.local.get('settings')).settings || {});
const getActive = async () => (await chrome.storage.local.get('activeJob')).activeJob || null;

function patchActive(patch, onlyId) {
  return locked(async () => {
    const a = await getActive();
    if (!a || (onlyId && a.id !== onlyId)) return null;
    const n = Object.assign({}, a, patch);
    await chrome.storage.local.set({ activeJob: n });
    return n;
  });
}

function log(msg, level) {
  const line = new Date().toISOString().slice(11, 23) + ' ' + (level ? level + ' ' : '') + msg;
  console.log('[autotok]', line);
  return locked(async () => {
    const { log: l = [] } = await chrome.storage.local.get('log');
    l.push(line);
    await chrome.storage.local.set({ log: l.slice(-MAX_LOG) });
  });
}

// ---------- dev server API ----------
async function api(path, { method = 'GET', body, timeoutMs = 15000, raw = false, headers = {} } = {}) {
  const s = await getSettings();
  if (!s.token) throw new Error('chưa nhập token');
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(s.server + path, {
      method, signal: ctl.signal,
      headers: Object.assign({ Authorization: 'Bearer ' + s.token }, body ? { 'Content-Type': 'application/json' } : {}, headers),
      body: body ? JSON.stringify(body) : undefined,
    });
    if (raw) return r;
    if (r.status === 204) return null;
    if (!r.ok) { const err = new Error(`${method} ${path} -> HTTP ${r.status}`); err.status = r.status; throw err; }
    return await r.json();
  } finally { clearTimeout(timer); }
}

function b64(buf) {
  const u = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
  return btoa(s);
}

// ---------- window / tab ----------
async function openJobWindow(job) {
  const existing = await findJobTab({ id: job.id, windowId: null, strategy: 'tab' });
  if (existing) { await log(`đã có tab ${existing.id} cho job ${job.id}, không mở thêm`, 'WARN'); await patchActive({ tabId: existing.id, windowId: existing.windowId }, job.id); return; }
  const s = await getSettings();
  const url = STUDIO_URL + '#autotok=' + encodeURIComponent(job.id);
  let tab, windowId;
  if (s.windowStrategy === 'tab') {
    tab = await chrome.tabs.create({ url, active: false });
    windowId = tab.windowId;
  } else if (s.windowStrategy === 'unfocused') {
    const w = await chrome.windows.create({ url, focused: false, state: 'normal', width: 1100, height: 800, left: 40, top: 40 });
    tab = w.tabs[0]; windowId = w.id;
  } else {
    const w = await chrome.windows.create({ url, state: 'minimized', focused: false });
    tab = w.tabs[0]; windowId = w.id;
  }
  try { await chrome.tabs.update(tab.id, { autoDiscardable: false }); } catch (e) { await log('autoDiscardable: ' + e.message, 'WARN'); }
  await patchActive({ tabId: tab.id, windowId, phase: 'opened', strategy: s.windowStrategy, lastBeat: Date.now() });
  await log(`mở tab ${tab.id} (cửa sổ ${windowId}, kiểu ${s.windowStrategy}) cho job ${job.id}`);
}

async function closeJobWindow(a) {
  const s = await getSettings();
  if (s.keepOpen || !a) return;
  try {
    if (a.strategy === 'tab' && a.tabId != null) await chrome.tabs.remove(a.tabId);
    else if (a.windowId != null) await chrome.windows.remove(a.windowId);
  } catch (e) { await log('đóng cửa sổ: ' + e.message, 'WARN'); }
}

// ---------- job lifecycle ----------
async function startJob(job, local) {
  if (!['selftest', 'intercept', 'selfcheck'].includes(job.mode)) { // post mode is disabled in this step
    await log(`từ chối job ${job.id}: chế độ "${job.mode}" bị tắt`, 'WARN');
    if (!local) await api('/api/result', { method: 'POST', body: { id: job.id, nonce: job.nonce, outcome: 'failed', definite: true, reason: 'mode-disabled' } }).catch((e) => log('gửi từ chối lỗi: ' + e.message, 'WARN'));
    return;
  }
  const claimed = await locked(async () => {
    const { activeJob, lastDoneId } = await chrome.storage.local.get(['activeJob', 'lastDoneId']);
    if (activeJob) return { ok: false, resume: activeJob.id === job.id };
    if (lastDoneId === job.id) return { ok: false, resume: false };
    await chrome.storage.local.set({
      activeJob: {
        id: job.id, nonce: job.nonce, mode: job.mode, job, local: !!local, phase: 'opening', openingAt: Date.now(),
        startedAt: Date.now(), lastBeat: Date.now(), tabId: null, windowId: null, authorized: false, finished: false,
      },
    });
    return { ok: true };
  });
  if (!claimed.ok) {
    if (!claimed.resume) await log(`bỏ qua job ${job.id}: đang có job khác hoặc đã xong`);
    return;
  }
  await log(`nhận job ${job.id} (${job.mode})`);
  try { await openJobWindow(job); } catch (e) {
    await finishJob(job.id, { outcome: 'failed', definite: true, reason: 'open-window-failed', detail: e.message });
  }
}

async function finishJob(id, result) {
  const a = await patchActive({ finished: true, result, finishedAt: Date.now() }, id);
  // patchActive returned null -> no such active job
  if (!a) return { ok: false, reason: 'no-active-job' };
  const full = Object.assign({ id, nonce: a.nonce, elapsed_ms: Date.now() - a.startedAt, authorized: a.authorized }, result);
  await log(`kết quả job ${id}: ${full.outcome}${full.reason ? ' (' + full.reason + ')' : ''}`);
  await chrome.storage.local.set({ lastResult: full });
  if (full.identity && full.identity.value) await chrome.storage.local.set({ account: full.identity.value });
  await closeJobWindow(a);
  if (!a.local && !(await deliverResult(a, full))) return { ok: true, pending: true };
  await locked(async () => { await chrome.storage.local.set({ lastDoneId: id }); await chrome.storage.local.remove('activeJob'); });
  return { ok: true };
}

const isGone = (e) => e && (e.status === 404 || e.status === 403);

// Drop a job the server no longer knows (404/403): keep the result for diagnosis, never retry it.
async function dropOrphan(a, result, why) {
  await log(`máy chủ không còn việc này, bỏ kết quả (${why})`, 'WARN');
  if (result) await chrome.storage.local.set({ lastOrphanResult: { id: a.id, result, at: Date.now() } });
  await closeJobWindow(a);
  await locked(async () => { await chrome.storage.local.set({ lastDoneId: a.id }); await chrome.storage.local.remove('activeJob'); });
}

// true = delivered or dropped (job cleared); false = transient failure, retry later with capped backoff.
async function deliverResult(a, full) {
  try {
    await api('/api/result', { method: 'POST', body: full, timeoutMs: 20000 });
    return true;
  } catch (e) {
    if (isGone(e)) { await dropOrphan(a, full, e.message); return false; }
    const tries = (a.resultTries || 0) + 1;
    const delay = Math.min(2000 * 2 ** tries, 30000);
    await patchActive({ resultTries: tries, nextResultTry: Date.now() + delay }, a.id);
    await log(`gửi kết quả lỗi (${e.message}), thử lại sau ${delay / 1000}s`, 'WARN');
    return false;
  }
}

async function findJobTab(a) {
  const tabs = await chrome.tabs.query({ url: 'https://www.tiktok.com/*' });
  return tabs.find((x) => (x.url || '').includes('#autotok=' + encodeURIComponent(a.id))) || tabs.find((x) => x.windowId === a.windowId && a.strategy !== 'tab') || null;
}

// Called on every tick and every wake-up: reconcile durable state with reality.
async function recover() {
  const a = await getActive();
  if (!a) return false;
  if (a.finished) { // result not delivered yet
    if (!a.local && Date.now() >= (a.nextResultTry || 0)) {
      const full = Object.assign({ id: a.id, nonce: a.nonce, authorized: a.authorized }, a.result);
      if (await deliverResult(a, full)) await locked(async () => { await chrome.storage.local.set({ lastDoneId: a.id }); await chrome.storage.local.remove('activeJob'); });
    } else if (a.local) {
      await locked(async () => { await chrome.storage.local.set({ lastDoneId: a.id }); await chrome.storage.local.remove('activeJob'); });
    }
    return true;
  }
  const now = Date.now();
  if (a.tabId == null) {
    const tabs = await chrome.tabs.query({ url: 'https://www.tiktok.com/tiktokstudio/*' });
    const t = tabs.find((x) => (x.url || '').includes('#autotok=' + encodeURIComponent(a.id)));
    if (t) { await patchActive({ tabId: t.id, windowId: t.windowId, phase: 'opened' }, a.id); await log('khôi phục tab ' + t.id); }
    else if (now - a.openingAt > 20000) { // window creation never finished and no tab exists: nothing was sent
      await openJobWindow(a.job);
    }
    return true;
  }
  let gone = false;
  try { await chrome.tabs.get(a.tabId); if (a.missingSince) await patchActive({ missingSince: null }, a.id); } catch (_) { gone = true; }
  if (gone) { // the tab id may have changed (prerender/discard): look it up by URL hash / window first
    const t = await findJobTab(a);
    if (t) { await log(`tìm lại tab theo URL/cửa sổ: ${a.tabId} -> ${t.id}`, 'WARN'); await patchActive({ tabId: t.id, windowId: t.windowId, missingSince: null }, a.id); return true; }
    if (!a.missingSince) { await patchActive({ missingSince: now }, a.id); return true; }
    if (now - a.missingSince < CLOSE_GRACE_MS) return true;
    await finishJob(a.id, a.authorized
      ? { outcome: 'uncertain', reason: 'tab-closed-after-authorization' }
      : { outcome: 'failed', definite: true, reason: 'tab-closed-before-authorization', detail: 'missing for ' + (now - a.missingSince) + ' ms, no tab with the job hash in window ' + a.windowId });
    return true;
  }
  if (now - a.startedAt > JOB_DEADLINE_MS || now - a.lastBeat > STALL_MS) {
    const why = now - a.startedAt > JOB_DEADLINE_MS ? 'job-deadline' : 'tab-stalled';
    await finishJob(a.id, a.authorized ? { outcome: 'uncertain', reason: why + '-after-authorization' }
      : { outcome: 'failed', definite: true, reason: why });
  }
  return true;
}

// ---------- polling ----------
let polling = false;
let lastPollState = '';
const setPoll = async (state) => { if (state !== lastPollState) { lastPollState = state; await chrome.storage.local.set({ poll: { at: Date.now(), state } }); } };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function pollLoop() {
  if (polling) return;
  polling = true;
  try {
    for (;;) {
      try {
        const s = await getSettings();
        if (!s.polling || !s.token) { await setPoll(s.token ? 'tắt' : 'chưa có token'); return; }
        if (await recover()) { await wait(4000); continue; }
        await setPoll('đang chờ job');
        const job = await api('/api/next?wait=20', { timeoutMs: 30000 });
        if (job) await startJob(job, false);
      } catch (e) {
        // includes "No SW" when Chrome tears the worker down mid-await: log, back off, alarm restarts us
        console.warn('[autotok] pollLoop', e);
        try { await setPoll('lỗi: ' + e.message); } catch (_) { return; }
        await wait(5000);
      }
    }
  } finally { polling = false; }
}

// ---------- content-script messages ----------
async function jobFor(sender, msg) {
  const a = await getActive();
  if (!a || a.finished || !sender.tab || a.tabId !== sender.tab.id) return null;
  if (msg.nonce && msg.nonce !== a.nonce) return null;
  return a;
}

const handlers = {
  async hello(msg, sender) {
    let a = await getActive();
    const t = sender.tab;
    if (a && !a.finished && t && !a.authorized && a.tabId !== t.id) {
      const byHash = (t.url || '').includes('#autotok=' + encodeURIComponent(a.id));
      const byWindow = a.windowId != null && t.windowId === a.windowId && a.strategy !== 'tab';
      if (a.tabId == null ? byHash : (byHash || byWindow)) {
        await log(`hello từ tab ${t.id} (${byHash ? 'hash' : 'cùng cửa sổ'}), nhận làm tab của job (trước: ${a.tabId})`, 'WARN');
        a = await patchActive({ tabId: t.id, windowId: t.windowId, phase: 'opened', missingSince: null }, a.id);
      }
    }
    a = a && !a.finished && t && a.tabId === t.id ? a : null;
    if (!a) return { role: 'none' };
    if (a.authorized) { // tab reloaded after the Post click was authorized: never redo
      await finishJob(a.id, { outcome: 'uncertain', reason: 'tab-reloaded-after-authorization' });
      return { role: 'none' };
    }
    if (!a.local) { // resume only while the server still considers the job active
      let st = null;
      try { st = await api('/api/job_state?id=' + encodeURIComponent(a.id), { timeoutMs: 5000 }); } catch (e) { await log('job_state: ' + e.message, 'WARN'); }
      if (!st || st.state === 'cancelled' || st.state === 'done' || st.authorized) {
        await log(`không tiếp tục job ${a.id}: server=${st && st.state}${st && st.authorized ? ' đã cấp quyền' : ''}`, 'WARN');
        await chrome.storage.local.set({ lastDoneId: a.id }); await chrome.storage.local.remove('activeJob');
        return { role: 'none' };
      }
    }
    await patchActive({ phase: 'hello', lastBeat: Date.now() }, a.id);
    return { role: a.mode === 'selfcheck' ? 'selfcheck' : 'job', job: a.job, nonce: a.nonce };
  },

  async ready(msg, sender) { // content script injected: log + tell the dev server immediately
    const a = await getActive();
    const mine = !!(a && !a.finished && sender.tab && (a.tabId === sender.tab.id || (sender.tab.url || '').includes('#autotok=' + encodeURIComponent(a.id))));
    await log(`content script ${msg.stage} tab=${sender.tab && sender.tab.id} ${msg.where} job=${mine ? a.id : '-'}`);
    if (mine && !a.local) api('/api/progress', { method: 'POST', body: { id: a.id, nonce: a.nonce, phase: 'content-ready', msg: msg.stage + ' ' + msg.where, extra: { tabId: sender.tab.id, state: msg.state } } })
      .catch((e) => (isGone(e) ? dropOrphan(a, null, 'ready ' + e.message) : log('gửi ready lỗi: ' + e.message, 'WARN')));
    return { ok: true };
  },

  async progress(msg, sender) {
    const a = await jobFor(sender, msg);
    if (!a) return { ok: false };
    await patchActive({ phase: msg.phase, pct: msg.pct == null ? null : msg.pct, lastBeat: Date.now() }, a.id);
    if (msg.phase === 'identity' && msg.extra && msg.extra.account) await chrome.storage.local.set({ account: msg.extra.account });
    await log(`[${msg.phase}] ${msg.msg || ''}${msg.pct != null ? ' ' + msg.pct + '%' : ''}`);
    if (!a.local) api('/api/progress', { method: 'POST', body: { id: a.id, nonce: a.nonce, phase: msg.phase, msg: msg.msg, pct: msg.pct, extra: msg.extra } })
      .catch((e) => (isGone(e) ? dropOrphan(a, null, 'progress ' + e.message) : log('gửi tiến độ lỗi: ' + e.message, 'WARN')));
    return { ok: true };
  },

  async videoMeta(msg, sender) {
    const a = await jobFor(sender, msg);
    if (!a || a.local) return { ok: false, error: 'no job' };
    const m = await api('/api/video/meta?id=' + encodeURIComponent(a.id));
    return { ok: true, meta: Object.assign({}, m, { chunk: CHUNK }) };
  },

  async videoChunk(msg, sender) {
    const a = await jobFor(sender, msg);
    if (!a || a.local) return { ok: false, error: 'no job' };
    const start = msg.index * CHUNK;
    const end = Math.min(start + CHUNK, msg.size) - 1;
    const r = await api('/api/video?id=' + encodeURIComponent(a.id), { raw: true, timeoutMs: 120000, headers: { Range: `bytes=${start}-${end}` } });
    if (r.status !== 206) return { ok: false, error: 'HTTP ' + r.status + ' (cần 206 Partial Content)' };
    const buf = await r.arrayBuffer();
    if (buf.byteLength !== end - start + 1) return { ok: false, error: `độ dài sai ${buf.byteLength}` };
    await patchActive({ lastBeat: Date.now() }, a.id);
    return { ok: true, b64: b64(buf), len: buf.byteLength };
  },

  // One-time permission to click Post. Persist FIRST (conservative: a crash after this point = uncertain).
  async authorize() { return { ok: false, reason: 'post-disabled' }; }, // no publish path exists in this step

  async result(msg, sender) {
    const a = await jobFor(sender, msg);
    if (!a) return { ok: false };
    return finishJob(a.id, msg.result);
  },
};

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const h = msg && handlers[msg.type];
  if (!h) return false; // popup messages are handled below
  h(msg, sender).then(sendResponse, (e) => { log(`handler ${msg.type}: ${e.message}`, 'ERR'); sendResponse({ ok: false, error: e.message }); });
  return true;
});

// ---------- popup messages ----------
const popup = {
  async status() {
    const d = await chrome.storage.local.get(['activeJob', 'log', 'lastResult', 'poll']);
    return { settings: await getSettings(), active: d.activeJob || null, log: d.log || [], lastResult: d.lastResult || null, poll: d.poll || null };
  },
  async saveSettings(msg) {
    await chrome.storage.local.set({ settings: Object.assign(await getSettings(), msg.settings) });
    pollLoop().catch((e) => console.warn('[autotok] pollLoop', e));
    return { ok: true };
  },
  async selfcheck() {
    const id = 'selfcheck-' + Date.now();
    await startJob({ id, nonce: Math.random().toString(36).slice(2), mode: 'selfcheck', caption: '', visibility: 'public', schedule_time: null }, true);
    return { ok: true, id };
  },
  async clear() { // abandon the active job (e.g. after a test); does not post anything
    const a = await getActive();
    if (a) {
      if (!a.local && !a.finished) await api('/api/cancel', { method: 'POST', body: { id: a.id, nonce: a.nonce }, timeoutMs: 5000 }).catch((e) => log('cancel lỗi (xoá local tiếp): ' + e.message, 'WARN'));
      try { if (a.strategy === 'tab' && a.tabId != null) await chrome.tabs.remove(a.tabId); else if (a.windowId != null) await chrome.windows.remove(a.windowId); } catch (e) { await log('đóng cửa sổ: ' + e.message, 'WARN'); }
      await chrome.storage.local.set({ lastDoneId: a.id });
    }
    await chrome.storage.local.remove(['activeJob', 'log']);
    await log('đã xoá job đang chạy và log');
    return { ok: true };
  },
  async poll() { pollLoop().catch((e) => console.warn('[autotok] pollLoop', e)); return { ok: true }; },
};
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.popup || !popup[msg.popup]) return false;
  popup[msg.popup](msg).then(sendResponse, (e) => sendResponse({ ok: false, error: e.message }));
  return true;
});

// ---------- wake-up sources ----------
chrome.alarms.create('autotok-tick', { periodInMinutes: 0.5 });
const kick = () => pollLoop().catch((e) => console.warn('[autotok] pollLoop', e));
chrome.alarms.onAlarm.addListener(() => { recover().catch((e) => log('recover: ' + e.message, 'ERR')); kick(); });
chrome.runtime.onStartup.addListener(kick);
chrome.runtime.onInstalled.addListener(kick);

// Who closed / replaced the job tab? Log it; recover() decides after a grace period.
chrome.tabs.onRemoved.addListener(async (tabId, info) => {
  const a = await getActive();
  if (a && !a.finished && a.tabId === tabId) {
    await log(`tab ${tabId} bị đóng: isWindowClosing=${info.isWindowClosing} windowId=${info.windowId}`, 'WARN');
    await patchActive({ missingSince: Date.now() }, a.id);
  }
});
chrome.tabs.onReplaced.addListener(async (added, removed) => {
  const a = await getActive();
  if (a && !a.finished && a.tabId === removed) {
    await log(`tab ${removed} được thay bằng ${added} (prerender/discard)`, 'WARN');
    await patchActive({ tabId: added, missingSince: null, lastBeat: Date.now() }, a.id);
  }
});
log('SW khởi động');
kick();
