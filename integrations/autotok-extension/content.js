// Content script (isolated world) for TikTok Studio. Runs the whole job in the tab, so a stopped
// service worker does not interrupt it (every SW call is a stateless request/response).
// Only acts when the tab was opened by the extension (URL hash '#autotok=<job id>') AND the SW confirms
// it owns this tab; a normal manual visit to Studio is left alone.
(function () {
  'use strict';
  if (window.top !== window || window.__autotokContent) return;
  window.__autotokContent = true;
  const hasHash = /[#&]autotok=/.test(location.hash);
  // Tell the SW we exist (document_start and again when loaded), even when the hash was lost to a redirect.
  const where = () => location.pathname + (hasHash ? '#autotok' : ' (no hash)');
  chrome.runtime.sendMessage({ type: 'ready', stage: 'document_start', where: where(), state: document.readyState }).catch(() => {});
  window.addEventListener('load', () => chrome.runtime.sendMessage({ type: 'ready', stage: 'load', where: where(), state: document.readyState }).catch(() => {}));

  const S = self.AutotokSel;
  const CFG = {
    identityMs: 30000, fileInputMs: 90000, acceptMs: 60000, processMs: 25 * 60000,
    editorMs: 60000, uiStepMs: 15000, interceptWaitMs: 45000, postWaitMs: 180000,
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  let JOB = null, NONCE = null, CLICKED = false, CLICK_T = 0;
  const seen = { identity: [], req: [], res: [], armed: false };
  let lagMax = 0;

  class StepError extends Error {
    constructor(code, detail) { super(code + (detail ? ': ' + detail : '')); this.code = code; this.detail = detail; }
  }

  // ---- timer lag monitor (background throttling evidence) ----
  let lastTick = Date.now();
  setInterval(() => { const now = Date.now(); lagMax = Math.max(lagMax, now - lastTick - 1000); lastTick = now; }, 1000);

  // ---- SW messaging ----
  async function send(type, payload) {
    for (let i = 0; i < 3; i++) {
      try {
        const r = await chrome.runtime.sendMessage(Object.assign({ type, nonce: NONCE }, payload));
        if (r === undefined) throw new Error('empty reply');
        return r;
      } catch (e) {
        if (/context invalidated/i.test(e.message)) throw new StepError('extension-reloaded', e.message);
        if (i === 2) throw e;
        await sleep(500 * (i + 1));
      }
    }
  }
  function mem() { const m = performance.memory; return m ? { usedMB: Math.round(m.usedJSHeapSize / 1048576), limitMB: Math.round(m.jsHeapSizeLimit / 1048576) } : null; }
  function report(phase, msg, pct, extra) {
    const x = Object.assign({ vis: document.visibilityState, lagMaxMs: lagMax, mem: mem() }, extra);
    lagMax = 0;
    return send('progress', { phase, msg, pct, extra: x }).catch((e) => console.warn('[autotok] progress', e));
  }

  // ---- hook messages (MAIN world) ----
  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.__autotok !== 1) return;
    if (d.kind === 'armed' && d.nonce === NONCE) seen.armed = true;
    else if (d.nonce !== NONCE) return;
    else if (d.kind === 'identity') seen.identity.push(d);
    else if (d.kind === 'req') seen.req.push(d);
    else if (d.kind === 'res') seen.res.push(d);
  });

  // ---- generic helpers ----
  async function waitFor(fn, { timeout, interval = 500, what }) {
    const t0 = Date.now();
    for (;;) {
      let v; try { v = await fn(); } catch (_) { v = null; }
      if (v) return v;
      if (Date.now() - t0 > timeout) throw new StepError('timeout', what + ' (' + Math.round(timeout / 1000) + 's)');
      await sleep(interval);
    }
  }
  function realClick(el) {
    el.scrollIntoView({ block: 'center' });
    const o = { bubbles: true, cancelable: true, view: window };
    for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
      el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, o));
    }
  }
  const norm = (s) => String(s).replace(/ /g, ' ').replace(/\r\n?/g, '\n').split('\n').map((l) => l.replace(/\s+$/, '')).join('\n').replace(/\s+$/, '');
  const loose = (s) => norm(s).split('\n').filter((l) => l.length).join('\n');
  const isDisabled = (el) => el.disabled === true || el.getAttribute('aria-disabled') === 'true';
  const need = (key, what) => { const r = S.find(key); if (!r.el) throw new StepError('selector-missing', key + (what ? ' (' + what + ')' : '')); return r.el; };

  function deepFind(o, names, depth, out) {
    out = out || []; if (!o || typeof o !== 'object' || depth < 0) return out;
    for (const k of Object.keys(o)) {
      if (names.includes(k) && o[k] != null && typeof o[k] !== 'object') out.push(String(o[k]));
      else if (typeof o[k] === 'object') deepFind(o[k], names, depth - 1, out);
    }
    return out;
  }

  // ---- identity: which TikTok account is logged in on this page ----
  async function getIdentity() {
    const c = [];
    const add = (source, value) => { if (typeof value === 'string' && value.trim()) c.push({ source, value: value.replace(/^@/, '').trim() }); };
    try {
      const el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
      if (el) {
        const j = JSON.parse(el.textContent);
        const ctx = (j.__DEFAULT_SCOPE__ || {})['webapp.app-context'] || {};
        deepFind(ctx, ['uniqueId', 'unique_id', 'username'], 4).forEach((v) => add('rehydration', v));
      } else c.push({ source: 'rehydration', error: 'no __UNIVERSAL_DATA_FOR_REHYDRATION__ script' });
    } catch (e) { c.push({ source: 'rehydration', error: e.message }); }
    try {
      const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 8000);
      const r = await fetch('/passport/web/account/info/?aid=1988', { credentials: 'include', signal: ctl.signal });
      clearTimeout(t);
      const j = await r.json();
      const d = (j && j.data) || {};
      add('passport.username', d.username); add('passport.screen_name', d.screen_name);
      c.push({ source: 'passport.keys', value: Object.keys(d).slice(0, 20).join(',') });
    } catch (e) { c.push({ source: 'passport', error: e.message }); }
    for (const a of S.findAll('accountLink').els.slice(0, 5)) {
      const m = /\/@([^/?#]+)/.exec(a.getAttribute('href') || '');
      if (m) add('dom', decodeURIComponent(m[1]));
    }
    for (const m of seen.identity) for (const [k, v] of m.found || []) add('network:' + m.src + ':' + k, v);
    const rank = ['passport.username', 'rehydration', 'dom', 'network'];
    const good = c.filter((x) => x.value && !x.source.endsWith('keys') && !x.source.endsWith('screen_name'));
    good.sort((a, b) => rank.findIndex((r) => a.source.startsWith(r)) - rank.findIndex((r) => b.source.startsWith(r)));
    return { value: good.length && good[0].value ? good[0].value.toLowerCase() : null, source: good.length ? good[0].source : null, all: c };
  }

  async function checkIdentity(job) {
    const id = await waitFor(async () => { const i = await getIdentity(); return i.value ? i : null; }, { timeout: CFG.identityMs, interval: 2000, what: 'tài khoản đăng nhập' })
      .catch(async (e) => { throw new StepError('identity-unknown', JSON.stringify((await getIdentity()).all)); });
    if (job.expect_account && id.value !== String(job.expect_account).replace(/^@/, '').toLowerCase()) {
      throw new StepError('identity-mismatch', `trang đang đăng nhập "${id.value}", job cần "${job.expect_account}"`);
    }
    return id;
  }

  // ---- video bytes: pulled chunk by chunk through the SW (stateless range fetches) ----
  function decode(b) { const bin = atob(b); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }

  async function buildFile() {
    const m = await send('videoMeta');
    if (!m.ok) throw new StepError('video-meta', m.error);
    const meta = m.meta; const n = Math.ceil(meta.size / meta.chunk);
    const parts = []; const t0 = Date.now(); const mem0 = mem();
    for (let i = 0; i < n; i++) {
      let ok = false;
      for (let a = 1; a <= 3 && !ok; a++) {
        const r = await send('videoChunk', { index: i, size: meta.size }).catch((e) => ({ ok: false, error: e.message }));
        if (r.ok) { parts.push(decode(r.b64)); ok = true; await sleep(0); } else await sleep(1000 * a);
      }
      if (!ok) throw new StepError('video-chunk', 'chunk ' + i + '/' + n);
      if (i % 4 === 3 || i === n - 1) await report('transfer', `video ${i + 1}/${n} chunk`, Math.round(((i + 1) / n) * 100), { elapsedMs: Date.now() - t0 });
    }
    const file = new File(parts, meta.name, { type: meta.type || 'video/mp4', lastModified: Date.now() });
    if (file.size !== meta.size) throw new StepError('video-size', `${file.size} != ${meta.size}`);
    return { file, stats: { bytes: meta.size, chunks: n, ms: Date.now() - t0, memBefore: mem0, memAfter: mem() } };
  }

  function setFiles(file, method) {
    const dt = new DataTransfer(); dt.items.add(file);
    if (method === 'input') {
      const input = need('fileInput');
      input.files = dt.files;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return input.files.length;
    }
    const zone = (S.find('fileInput').el || document.body).closest('[class*="upload"], [data-e2e*="upload"]') || document.body;
    for (const t of ['dragenter', 'dragover', 'drop']) zone.dispatchEvent(new DragEvent(t, { bubbles: true, cancelable: true, dataTransfer: dt }));
    return 1;
  }
  const UPLOADED_RE = /(đã tải lên|uploaded)\s*\(?\d/i;
  const uploadedText = () => UPLOADED_RE.test(document.body.innerText || '');
  const started = () => uploadedText() || !!S.find('uploadedMarker').el || pageProgress() != null || !!S.find('postButton').el;
  // Studio may ignore the first attach right after the window opens: wait for readiness, retry (max 3), never double-upload.
  async function attachWithRetry(file) {
    await waitFor(() => S.find('fileInput').el && document.readyState === 'complete', { timeout: CFG.fileInputMs, what: 'trang upload sẵn sàng' });
    await sleep(2000);
    for (const [i, method] of ['input', 'input', 'drop'].entries()) {
      if (started()) { await report('attach', `Studio đã bắt đầu upload (trước lần ${i + 1})`); return method; }
      const n = setFiles(file, method);
      await report('attach', `lần ${i + 1}/3 cách ${method}: đã gán (${n})`, null, { attempt: i + 1, method });
      const t0 = Date.now();
      while (Date.now() - t0 < 8000) { if (started()) return method; await sleep(500); }
    }
    throw new StepError('attach-ignored', 'Studio không nhận file sau 3 lần');
  }

  // ---- upload + processing ----
  function pageProgress() {
    const bar = document.querySelector('[role="progressbar"][aria-valuenow]');
    if (bar) return Number(bar.getAttribute('aria-valuenow'));
    const m = /(\d{1,3})\s?%/.exec(document.body.innerText || '');
    return m ? Number(m[1]) : null;
  }
  const UPLOAD_FAIL_RE = /(upload failed|tải lên thất bại|couldn.t upload|failed to upload|không thể tải lên)/i;
  function uploadDiag() {
    const busy = {};
    for (const k of ['uploadBusy']) { const r = S.findAll(k); busy[k] = { n: r.els.length, via: r.via }; }
    const bar = document.querySelector('[role="progressbar"]');
    const node = [...document.querySelectorAll('div,span')].find((e) => e.children.length < 6 && /\.(mp4|mov|webm)|MB\)/i.test(e.textContent || '') && (e.textContent || '').length < 300);
    const card = node && (node.parentElement || node);
    return { card: card ? card.textContent.trim().slice(0, 200) : null,
      bar: bar ? { now: bar.getAttribute('aria-valuenow'), w: bar.style.width || (bar.firstElementChild && bar.firstElementChild.style.width) || null } : null,
      busy, cancel: !!S.find('cancelUpload').el };
  }
  async function waitProcessed() {
    const t0 = Date.now(); let lastRep = 0, lastDiag = 0, okSince = 0;
    for (;;) {
      const txt = document.body.innerText || '';
      const m = UPLOAD_FAIL_RE.exec(txt);
      if (m) throw new StepError('upload-failed', m[0]);
      const post = S.find('postButton').el, editor = S.find('editor').el;
      const pct = pageProgress();
      const uploaded = uploadedText() || (pct === 100 && !S.find('cancelUpload').el);
      const ready = post && editor && !isDisabled(post) && uploaded;
      okSince = ready ? (okSince || Date.now()) : 0;
      if (ready && Date.now() - okSince > 3000) return { elapsedMs: Date.now() - t0 };
      if (Date.now() - t0 > CFG.processMs) throw new StepError('timeout', 'xử lý video quá ' + Math.round(CFG.processMs / 60000) + ' phút');
      if (Date.now() - lastRep > 5000) {
        lastRep = Date.now();
        const extra = { post: !!post, postDisabled: post ? isDisabled(post) : null, uploaded };
        if (Date.now() - lastDiag > 15000) { lastDiag = Date.now(); extra.diag = uploadDiag(); }
        await report('processing', `chờ upload/xử lý, ${Math.round((Date.now() - t0) / 1000)}s`, pct, extra);
      }
      await sleep(1000);
    }
  }

  // ---- caption ----
  async function fillCaption(text) {
    const editor = need('editor');
    editor.focus();
    document.execCommand('selectAll', false); document.execCommand('delete', false);
    await sleep(200);
    const popupAfter = [];
    const lines = text.split('\n');
    for (let li = 0; li < lines.length; li++) {
      if (li > 0) { document.execCommand('insertParagraph', false); await sleep(100); }
      for (const p of lines[li].split(/(#[^\s#]+)/u)) {
        if (!p) continue;
        document.execCommand('insertText', false, p); await sleep(80);
        if (p[0] === '#') {
          await sleep(400); // let the suggestion popup appear, then dismiss it
          for (const t of ['keydown', 'keyup']) editor.dispatchEvent(new KeyboardEvent(t, { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
          await sleep(200);
          const pop = S.find('hashtagPopup').el;
          popupAfter.push({ tag: p, popupStillOpen: !!(pop && S.visible(pop)) });
        }
      }
    }
    await sleep(500);
    const actual = editor.innerText;
    return { exact: norm(actual) === norm(text), loose: loose(actual) === loose(text), actual: norm(actual), popupAfter };
  }

  // ---- visibility ----
  async function setVisibility(v) {
    if (!['public', 'friends', 'private'].includes(v)) throw new StepError('bad-visibility', v);
    const dd = need('visibilityDropdown');
    const re = S.SEL.visibilityOptions[v][0].re;
    if (re.test((dd.textContent || '').trim()) && v === 'public') return { already: true, text: dd.textContent.trim() };
    realClick(dd); await sleep(500);
    const opt = await waitFor(() => S.find('visibilityOptions', document, v).el, { timeout: CFG.uiStepMs, what: 'mục quyền riêng tư ' + v });
    realClick(opt); await sleep(500);
    const after = (S.find('visibilityDropdown').el || dd).textContent.trim();
    return { clicked: opt.textContent.trim(), after, ok: re.test(after) };
  }

  // ---- schedule (best effort; real selectors unverified) ----
  const pad = (n) => String(n).padStart(2, '0');
  const readVal = (el) => (el.value !== undefined && el.value !== '' ? el.value : el.textContent || '').trim();
  function parseYMD(s) { const m = /(\d{4})\D+(\d{1,2})\D+(\d{1,2})/.exec(s); return m ? { y: +m[1], m: +m[2], d: +m[3] } : null; }
  function parseHM(s) { const m = /(\d{1,2}):(\d{2})/.exec(s); return m ? { h: +m[1], mi: +m[2] } : null; }

  async function setSchedule(iso) {
    const want = new Date(iso);
    if (isNaN(want)) throw new StepError('bad-schedule-time', iso);
    const y = want.getFullYear(), mo = want.getMonth() + 1, d = want.getDate(), h = want.getHours(), mi = want.getMinutes();
    const tog = need('scheduleToggle');
    const on = tog.checked === true || tog.getAttribute('aria-checked') === 'true';
    if (!on) realClick(tog);
    await waitFor(() => S.find('scheduleDate').el && S.find('scheduleTime').el, { timeout: CFG.uiStepMs, what: 'ô ngày/giờ lên lịch' });
    // date
    const di = S.find('scheduleDate').el;
    const cur = parseYMD(readVal(di));
    if (!cur) throw new StepError('schedule-date-format', readVal(di));
    realClick(di);
    await waitFor(() => S.findAll('calendarDay').els.length, { timeout: CFG.uiStepMs, what: 'lịch chọn ngày' });
    let diff = (y * 12 + mo) - (cur.y * 12 + cur.m);
    for (let i = 0; i < Math.min(Math.abs(diff), 12); i++) {
      const b = S.find(diff > 0 ? 'calendarNext' : 'calendarPrev').el;
      if (!b) throw new StepError('selector-missing', 'calendarNext/Prev');
      realClick(b); await sleep(300);
    }
    const day = S.findAll('calendarDay').els.find((e) => e.textContent.trim() === String(d));
    if (!day) throw new StepError('schedule-day-missing', 'ngày ' + d + ' không chọn được (quá 10 ngày/đã qua?)');
    realClick(day); await sleep(500);
    const gotD = parseYMD(readVal(S.find('scheduleDate').el));
    if (!gotD || gotD.y !== y || gotD.m !== mo || gotD.d !== d) throw new StepError('schedule-date-not-set', readVal(S.find('scheduleDate').el));
    // time
    realClick(S.find('scheduleTime').el);
    const hr = await waitFor(() => S.findAll('timeHourOption').els.find((e) => e.textContent.trim() === pad(h)), { timeout: CFG.uiStepMs, what: 'giờ ' + pad(h) });
    realClick(hr); await sleep(300);
    const mins = S.findAll('timeMinuteOption').els;
    const mn = mins.find((e) => e.textContent.trim() === pad(mi));
    if (!mn) throw new StepError('schedule-minute-unavailable', pad(mi) + ' not in [' + mins.map((e) => e.textContent.trim()).join(',') + ']');
    realClick(mn); await sleep(500);
    const gotT = parseHM(readVal(S.find('scheduleTime').el));
    return { want: iso, wantLocal: `${y}-${pad(mo)}-${pad(d)} ${pad(h)}:${pad(mi)}`, date: readVal(S.find('scheduleDate').el), time: readVal(S.find('scheduleTime').el), timeOk: !!gotT && gotT.mi === mi && (gotT.h === h || gotT.h === h % 12) };
  }

  // ---- post stage ----
  function summarizeBody(text, caption) {
    let j = null; try { j = JSON.parse(text); } catch (_) { return { raw: text.slice(0, 2000), parsed: false }; }
    const names = ['text', 'schedule_time', 'visibility_type', 'privacy_level', 'allow_comment', 'allow_duet', 'allow_stitch', 'aigc_label_type', 'creation_id', 'video_id'];
    const fields = {}; for (const n of names) { const v = deepFind(j, [n], 8); if (v.length) fields[n] = v.length === 1 ? v[0] : v; }
    const t = deepFind(j, ['text'], 8)[0];
    return { parsed: true, fields, captionEquals: t !== undefined && norm(t) === norm(caption), body: j };
  }

  async function postStage(job) {
    const btn = need('postButton');
    if (isDisabled(btn)) throw new StepError('post-disabled', 'nút Đăng đang bị khoá');
    // Identity again right before authorization (X3): the page must still be the job's account.
    const id = await checkIdentity(job);
    const auth = await send('authorize');
    if (!auth.ok) throw new StepError('authorize-denied', auth.reason);
    CLICK_T = Date.now(); CLICKED = true;
    await report('post', `ĐÃ bấm Đăng (${job.mode})`, null, { identity: id.value });
    btn.click(); // exactly one click on Post
    const waitMs = job.mode === 'post' ? CFG.postWaitMs : CFG.interceptWaitMs;
    let confirmed = false;
    const t0 = Date.now();
    while (Date.now() - t0 < waitMs) {
      const res = seen.res.find((r) => r.reqT >= CLICK_T - 1000);
      if (res) return { res, req: seen.req.find((r) => r.t >= CLICK_T - 1000 && r.t <= res.t), identity: id };
      if (!confirmed) {
        const c = S.find('confirmPostButton').el;
        if (c && !isDisabled(c)) { confirmed = true; await report('post', 'bấm xác nhận trong hộp thoại: ' + c.textContent.trim()); c.click(); }
      }
      await sleep(300);
    }
    return { res: null, req: seen.req.find((r) => r.t >= CLICK_T - 1000) || null, identity: id };
  }

  function mapPostResult(job, p) {
    const base = { identity: p.identity && p.identity.value };
    if (!p.res) {
      if (job.mode === 'intercept') return Object.assign(base, { outcome: 'failed', definite: true, reason: 'no-post-request-after-click', note: 'chặn nên không có gì được gửi' });
      return Object.assign(base, { outcome: 'uncertain', reason: 'no-post-response-after-click' });
    }
    const req = p.req ? summarizeBody(p.req.body, job.caption) : null;
    if (job.mode === 'intercept') return Object.assign(base, { outcome: 'intercepted', request: req, reqVia: p.req && p.req.via });
    let j = null; try { j = JSON.parse(p.res.text); } catch (_) { /* handled below */ }
    const code = j && typeof j === 'object' ? j.status_code : undefined;
    if (p.res.status !== 200 || code === undefined) return Object.assign(base, { outcome: 'uncertain', reason: 'unparseable-or-http-error', http: p.res.status, text: p.res.text.slice(0, 500), request: req });
    if (code === 0) {
      return Object.assign(base, { outcome: 'posted', status_code: 0, ids: { item_id: deepFind(j, ['item_id', 'itemId', 'aweme_id'], 6)[0] || null, creation_id: deepFind(j, ['creation_id'], 6)[0] || null },
        response: p.res.text.slice(0, 4000), request: req });
    }
    return Object.assign(base, { outcome: 'rejected', definite: true, status_code: code, status_msg: j.status_msg || null, response: p.res.text.slice(0, 2000), request: req });
  }

  // ---- main ----
  async function arm(mode) {
    window.postMessage({ __autotok: 1, kind: 'arm', nonce: NONCE, mode }, location.origin);
    await waitFor(() => seen.armed, { timeout: 5000, interval: 100, what: 'hook MAIN-world chưa cài (hook-main.js)' });
  }

  async function runSelfcheck() {
    await arm('block');
    await waitFor(() => document.readyState !== 'loading', { timeout: 20000, what: 'trang tải xong' });
    await sleep(4000);
    const id = await getIdentity();
    return { outcome: 'selfcheck_ok', url: location.pathname, identity: id, dom: S.report(), title: document.title };
  }

  async function runJob(job) {
    const R = { steps: {} };
    await waitFor(() => document.readyState !== 'loading', { timeout: 30000, what: 'trang tải xong' });
    await arm(job.mode === 'post' ? 'pass' : 'block');
    if (/\/login/.test(location.pathname)) throw new StepError('not-logged-in', location.href);
    await report('start', `bắt đầu ${job.mode}, caption ${job.caption.length} ký tự`);
    R.identity = await checkIdentity(job);
    await report('identity', 'tài khoản: ' + R.identity.value + ' (' + R.identity.source + ')', null, { account: R.identity.value });

    const { file, stats } = await buildFile();
    R.steps.transfer = stats;
    R.steps.attach = await attachWithRetry(file);
    R.steps.processing = await waitProcessed();
    await report('processed', 'upload + xử lý xong', 100, R.steps.processing);

    let cap = await fillCaption(job.caption);
    if (!cap.loose) { await report('caption', 'caption lệch, thử lại 1 lần', null, cap); cap = await fillCaption(job.caption); }
    R.steps.caption = cap;
    await report('caption', cap.loose ? (cap.exact ? 'caption khớp chính xác' : 'caption khớp (bỏ qua dòng trống)') : 'CAPTION SAI', null, { actual: cap.actual });
    if (!cap.loose) throw new StepError('caption-mismatch', JSON.stringify(cap.actual).slice(0, 400));

    R.steps.visibility = await setVisibility(job.visibility);
    await report('visibility', JSON.stringify(R.steps.visibility));
    if (job.schedule_time) {
      R.steps.schedule = await setSchedule(job.schedule_time);
      await report('schedule', JSON.stringify(R.steps.schedule));
    }
    R.dom = S.report();

    if (job.mode === 'selftest') return Object.assign(R, { outcome: 'selftest_ok', note: 'không bấm Đăng' });
    const p = await postStage(job);
    return Object.assign(R, mapPostResult(job, p));
  }

  async function main() {
    let hello = null;
    for (let i = 0; i < (hasHash ? 15 : 3); i++) { // SW may not have recorded the tab yet
      hello = await send('hello').catch(() => null);
      if (hello && hello.role !== 'none') break;
      await sleep(700);
    }
    if (!hello || hello.role === 'none') return;
    JOB = hello.job; NONCE = hello.nonce;
    let result;
    try {
      result = hello.role === 'selfcheck' ? await runSelfcheck() : await runJob(JOB);
    } catch (e) {
      let dom = null; try { dom = S.report(); } catch (_) { /* ignore */ }
      const code = e instanceof StepError ? e.code : 'exception';
      result = CLICKED
        ? { outcome: 'uncertain', reason: 'error-after-click:' + code, detail: e.message }
        : { outcome: 'failed', definite: true, reason: code, detail: e.message, dom, bodyText: (document.body.innerText || '').slice(0, 1500) };
      console.error('[autotok]', e);
    }
    await send('result', { result });
  }
  main().catch((e) => console.error('[autotok] fatal', e));
})();
