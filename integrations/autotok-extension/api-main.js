// MAIN-world job runner (needs lib.js loaded first). P0b spike: upload-only selftest + intercept (body built, never sent).
// Publishing (post mode only) goes through ONE gated path: publishOnce(). Everything else never sends /project/post/.
// Talks to content.js (isolated world) via window.postMessage {__autotok:1, nonce, ...}.
(function () {
  'use strict';
  if (window.__autotokApi) return;
  window.__autotokApi = true;
  const L = window.AutotokLib;
  const AID = 1988, REGION = 'ap-singapore-1';
  const MODES = ['selftest', 'intercept', 'post'];
  const gate = L.createPublishGate();
  let sentFlag = false;          // true from the moment xhr.send is invoked: any later problem is uncertain
  let running = false;           // single-flight: a duplicate 'run' message is ignored
  let NONCE = null;

  const mem = () => { const m = performance.memory; return m ? { usedMB: Math.round(m.usedJSHeapSize / 1048576), totalMB: Math.round(m.totalJSHeapSize / 1048576) } : null; };
  const post = (kind, data) => window.postMessage(Object.assign({ __autotok: 1, from: 'api', kind, nonce: NONCE }, data), location.origin);
  const progress = (phase, msg, pct, extra) => post('p', { phase, msg, pct, extra });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  class StepFail extends Error { constructor(step, msg, extra) { super(step + ': ' + msg); this.step = step; this.extra = extra; } }

  // Host + path only (query strings can carry signed values).
  const safeUrl = (u) => { try { const x = new URL(u, location.href); return x.host + x.pathname; } catch (_) { return '(bad url)'; } };
  const mask = (s) => (typeof s === 'string' && s.length > 8 ? s.slice(0, 3) + '…(' + s.length + ')' : '***');

  // One network step with the log fields the owner asked for. Never logs headers/bodies.
  async function step(name, url, init, { json = false } = {}) {
    const t0 = performance.now();
    const rec = { step: name, url: safeUrl(url), credentials: init.credentials, status: null, readable: false, ms: 0, mem: null };
    let r;
    try { r = await fetch(url, init); } catch (e) {
      rec.ms = Math.round(performance.now() - t0); rec.mem = mem();
      rec.error = e && e.name + ': ' + e.message;   // CORS failures surface as TypeError "Failed to fetch" (no detail available to scripts)
      progress('step', name + ' lỗi mạng/CORS', null, rec);
      throw new StepFail(name, 'network/CORS error (' + rec.error + ')', rec);
    }
    rec.status = r.status; rec.type = r.type;     // 'cors' = readable; 'opaque' would mean no-cors
    let text = null, data = null;
    try { text = await r.text(); rec.readable = true; } catch (e) { rec.error = 'body unreadable: ' + e.message; }
    if (json && text != null) { try { data = JSON.parse(text); } catch (_) { rec.error = 'non-JSON body'; } }
    rec.ms = Math.round(performance.now() - t0); rec.mem = mem();
    progress('step', `${name} HTTP ${r.status} ${rec.ms}ms`, null, rec);
    if (!r.ok) throw new StepFail(name, 'HTTP ' + r.status, rec);
    return { data, text, rec };
  }

  function creationId() {
    const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_';
    const b = crypto.getRandomValues(new Uint8Array(21));
    return Array.from(b, (x) => a[x % a.length]).join('');
  }
  const uuid = () => crypto.randomUUID();

  async function probeVideo(blob) {
    return new Promise((resolve) => {
      const url = URL.createObjectURL(blob), v = document.createElement('video');
      const done = (r) => { URL.revokeObjectURL(url); v.removeAttribute('src'); v.load(); resolve(r); };
      const timer = setTimeout(() => done(null), 10000);
      v.preload = 'metadata'; v.muted = true;
      v.onloadedmetadata = () => { clearTimeout(timer); done(v.videoWidth && v.duration ? { width: v.videoWidth, height: v.videoHeight, duration_ms: Math.round(v.duration * 1000) } : null); };
      v.onerror = () => { clearTimeout(timer); done(null); };
      v.src = url;
    });
  }

  async function upload(job, blob) {
    const ids = { creation_id: creationId() };
    const cc = job.chunk_credentials === 'include' ? 'include' : 'omit';  // storage host is not tiktok.com: Python sends no cookies there
    // 1. create project
    const cp = await step('create-project', `/api/v1/web/project/create/?creation_id=${ids.creation_id}&type=1&aid=${AID}`, { method: 'POST', credentials: 'include' }, { json: true });
    if (!cp.data || !('project' in cp.data)) throw new StepFail('create-project', 'no "project" in response', cp.rec);
    ids.project_keys = Object.keys(cp.data.project || {}).slice(0, 10);
    // 2. upload auth (STS) - secrets never leave this function
    const au = await step('upload-auth', `/api/v1/video/upload/auth/?aid=${AID}`, { credentials: 'include' }, { json: true });
    const tok = au.data && au.data.video_token_v5;
    if (!tok || !tok.access_key_id || !tok.secret_acess_key || !tok.session_token) throw new StepFail('upload-auth', 'no video_token_v5 (session expired?)', au.rec);
    const creds = { accessKeyId: tok.access_key_id, secretAccessKey: tok.secret_acess_key /* sic */, sessionToken: tok.session_token, region: REGION, service: 'vod' };
    progress('step', 'sts', null, { accessKeyId: mask(tok.access_key_id), secret: mask(tok.secret_acess_key), token: mask(tok.session_token) });
    // 3. apply (SigV4, same origin)
    const applyUrl = `/top/v1?Action=ApplyUploadInner&Version=2020-11-19&SpaceName=tiktok&FileType=video&IsInner=1&FileSize=${blob.size}&s=g158iqx8434`;
    const sA = await L.sigv4({ method: 'GET', url: location.origin + applyUrl, ...creds, now: new Date() });
    const ap = await step('apply-upload', applyUrl, { credentials: 'include', headers: sA.headers }, { json: true });
    let node, store;
    try { node = ap.data.Result.InnerUploadAddress.UploadNodes[0]; store = node.StoreInfos[0]; if (!node.Vid || !store.StoreUri || !store.Auth || !node.UploadHost || !node.SessionKey) throw 0; } catch (_) { throw new StepFail('apply-upload', 'unexpected response shape', ap.rec); }
    ids.video_id = node.Vid;
    const host = node.UploadHost, storeUri = store.StoreUri, storeAuth = store.Auth, sessionKey = node.SessionKey;
    progress('step', 'upload-node', null, { host, storeUriLen: storeUri.length, auth: mask(storeAuth) });
    // 4. chunks: one 5 MiB part in flight, sliced lazily from the Blob, released right after use
    const uploadId = uuid(), crcs = [], parts = L.splitParts(blob.size);
    if (!parts.length) throw new StepFail('upload-part', 'video is empty');
    for (let i = 0; i < parts.length; i++) {
      let buf = await blob.slice(parts[i][0], parts[i][1]).arrayBuffer();
      const crc = L.crc32Hex(buf); crcs.push(crc);
      await step(`upload-part-${i + 1}/${parts.length}`, `https://${host}/${storeUri}?partNumber=${i + 1}&uploadID=${uploadId}&phase=transfer`, {
        method: 'POST', credentials: cc, body: buf,
        headers: { Authorization: storeAuth, 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="undefined"', 'Content-Crc32': crc },
      });
      buf = null;                                  // release before the next slice
      progress('transfer', `part ${i + 1}/${parts.length}`, Math.round(((i + 1) / parts.length) * 100), { mem: mem() });
      await sleep(0);
    }
    // 5. finish: cookie-free, straight to the storage host
    await step('finish-upload', `https://${host}/${storeUri}?uploadID=${uploadId}&phase=finish&uploadmode=part`, {
      method: 'POST', credentials: 'omit', headers: { Authorization: storeAuth, 'Content-Type': 'text/plain;charset=UTF-8' },
      body: crcs.map((c, i) => `${i + 1}:${c}`).join(','),
    });
    // 6. commit (SigV4). Python's body is a str without Content-Type, which requests_auth_aws_sigv4 turns into form-urlencoded.
    const commitUrl = '/top/v1?Action=CommitUploadInner&Version=2020-11-19&SpaceName=tiktok';
    const commitBody = JSON.stringify({ SessionKey: sessionKey, Functions: [{ name: 'GetMeta' }] });
    const sC = await L.sigv4({ method: 'POST', url: location.origin + commitUrl, body: commitBody, ...creds, now: new Date() });
    await step('commit-upload', commitUrl, { method: 'POST', credentials: 'include', body: commitBody, headers: Object.assign({ 'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8' }, sC.headers) });
    return { ids, parts: parts.length, chunkCredentials: cc };
  }

  // Everything except `text`/`markup_text` content is kept; ids are not secrets. Nothing here is sent anywhere.
  async function buildBody(job, ids, blob) {
    const err = L.validateCaption(job.caption);
    if (err) throw new StepFail('validate', err);
    const vis = (() => { try { return L.visibilityCode(job.visibility); } catch (e) { throw new StepFail('validate', e.message); } })();
    let sched = null;
    if (job.schedule_time) {
      const ts = Math.floor(new Date(job.schedule_time).getTime() / 1000);
      if (!Number.isFinite(ts)) throw new StepFail('validate', 'bad schedule_time');
      try { L.resolveSchedule(ts, Math.floor(Date.now() / 1000), vis); sched = L.finalizeSchedule(ts, Math.floor(Date.now() / 1000)); } catch (e) { throw new StepFail('validate', e.message); }
    }
    const userIds = {};
    for (const name of new Set(L.mentionsIn(job.caption))) {
      try { const r = await fetch('/@' + encodeURIComponent(name), { credentials: 'include' }); const m = /"userInfo":\{"user":\{"id":"(\d+)"/.exec(await r.text()); if (m) userIds[name] = m[1]; } catch (_) { /* stays plain text, like Python */ }
    }
    const { markup, textExtra } = L.buildCaption(job.caption, userIds);
    const probe = await probeVideo(blob);
    const payload = L.buildPayload({ creationId: ids.creation_id, videoId: ids.video_id, caption: job.caption, markup, textExtra, visibility: vis, probe, scheduleTime: sched });
    return { payload, probe, resolvedMentions: Object.keys(userIds), tz: Intl.DateTimeFormat().resolvedOptions().timeZone };
  }


  // Strict identity: only the passport self endpoint decides (data.username + data.user_id_str).
  async function strictIdentity(job, when) {
    if (job.mode === 'post' && !job.expect_account) throw new StepFail('identity', 'post needs expect_account');
    let j = null;
    try { j = await (await fetch('/passport/web/account/info/?aid=' + AID, { credentials: 'include' })).json(); } catch (e) { throw new StepFail('identity', 'passport lookup failed: ' + e.message); }
    const r = L.checkIdentity(j, { username: job.expect_account, userId: job.expect_user_id });
    progress('identity', `${when}: ${r.ok ? 'ok' : r.reason} ${r.username || ''}`, null, { when, ok: r.ok, username: r.username || null, userId: r.userId ? mask(r.userId) : null });
    if (!r.ok) throw new StepFail('identity', `${r.reason}${r.username ? ` (page account ${r.username})` : ''} [${when}]`);
    return { value: r.username, user_id: r.userId };
  }

  // SDK readiness: page code replaced XHR.send on top of our wrapper (our hook is installed at document_start, so the
  // SDK wraps AFTER us). `[native code]` cannot be used because our own wrapper is not native either.
  async function waitSdk() {
    const hk = window.__autotokHook;
    if (!hk) throw new StepFail('sdk', 'hook-main.js not installed');
    const t0 = Date.now();
    while (XMLHttpRequest.prototype.send === hk.wrapperSend) {
      if (Date.now() - t0 > 30000) throw new StepFail('sdk-not-ready', 'page SDK never wrapped XMLHttpRequest.send', { byted_acrawler: typeof window.byted_acrawler });
      await sleep(500);
    }
    progress('sdk', 'SDK đã bọc XHR.send', null, { waitedMs: Date.now() - t0, byted_acrawler: typeof window.byted_acrawler });
  }

  let authResolve = null;
  function requestAuthorization(sha, creationId) {
    return new Promise((resolve) => {
      authResolve = resolve;
      post('auth-req', { sha, creation_id: creationId });
      setTimeout(() => resolve({ ok: false, reason: 'authorize-timeout' }), 30000);
    });
  }

  // The ONLY place that can send a post. Grant is bound to sha256(body)+creation_id+nonce and consumed before send.
  async function publishOnce(bodyStr) {
    const url = '/tiktok/web/project/post/v1/?app_name=tiktok_web&channel=tiktok_web&device_platform=web&tz_name='
      + encodeURIComponent(Intl.DateTimeFormat().resolvedOptions().timeZone) + '&aid=' + AID;
    try { await gate.check(bodyStr, NONCE); } catch (e) { throw new StepFail('gate', e.message, { notSent: true }); }  // refused before send: definite
    // From here the grant is consumed. No await between the check and send.
    const xhr = new XMLHttpRequest();
    const settled = new Promise((resolve) => {
      xhr.onload = () => resolve({ status: xhr.status, text: String(xhr.responseText || '') });
      xhr.onerror = () => resolve({ error: 'network', blocked: !!xhr.__autotokBlocked });
      xhr.ontimeout = () => resolve({ error: 'timeout' });
      xhr.onabort = () => resolve({ error: 'abort' });
    });
    try {
      xhr.open('POST', url, true);
      xhr.withCredentials = true;
      xhr.timeout = 180000;
      xhr.setRequestHeader('content-type', 'application/json');
    } catch (e) { return { setupError: String(e && e.message) }; }       // nothing was sent
    window.__autotokHook.allow(xhr);
    sentFlag = true;
    try { xhr.send(bodyStr); } catch (e) { return { error: 'send-threw', message: String(e && e.message) }; }   // may have reached the network
    return settled;                                   // correlated to this exact XHR object; never retried
  }

  async function doPost(job, up, body, id) {
    const bodyStr = JSON.stringify(body.payload);
    const sha = await L.sha256Hex(bodyStr);
    await waitSdk();
    await strictIdentity(job, 'before-publish');
    const auth = await requestAuthorization(sha, up.ids.creation_id);
    if (!auth.ok) throw new StepFail('authorize', 'denied: ' + auth.reason);   // nothing sent
    gate.arm({ sha, creationId: up.ids.creation_id, nonce: NONCE });
    progress('post', 'ĐÃ cấp quyền, gửi 1 lần', null, { sha: sha.slice(0, 12) });
    const res = await publishOnce(bodyStr);           // throws StepFail('gate', notSent) only when refused before send
    if (res.setupError) return { outcome: 'failed', definite: true, notSent: true, reason: 'publish-setup-failed', detail: res.setupError };
    if (res.blocked) return { outcome: 'failed', definite: true, notSent: true, reason: 'blocked-by-hook', note: 'không gì được gửi' };
    if (res.error) return { outcome: 'uncertain', reason: 'xhr-' + res.error, detail: res.message, note: 'đã gửi, không có phản hồi' };
    const m = L.mapPublishResult(res.status, res.text);
    if (m.outcome === 'uncertain') m.text = res.text.slice(0, 300);
    return Object.assign(m, { creation_id: up.ids.creation_id, video_id: up.ids.video_id, body_sha256: sha, identity: id });
  }

  async function run(msg) {
    const job = msg.job;
    if (!MODES.includes(job.mode)) return post('done', { result: { outcome: 'failed', definite: true, reason: 'mode-disabled', detail: job.mode } });
    const t0 = Date.now();
    try {
      const schedPublic = job.allow_public_schedule === true && job.visibility === 'public' && !!job.schedule_time;
      if (job.mode === 'post' && !schedPublic && (job.visibility !== 'private' || job.schedule_time)) throw new StepFail('validate', 'post is limited to private, unscheduled in this prototype');
      const resp = await fetch(msg.blobUrl);
      const blob = await resp.blob();
      post('blob-ready', {});                      // content.js may revoke the Blob URL now
      if (blob.size !== msg.size) throw new StepFail('blob', `size ${blob.size} != ${msg.size}`);
      const id0 = await strictIdentity(job, 'before-upload');     // nothing is uploaded for the wrong/unknown account
      progress('start', `${job.mode}, ${(blob.size / 1048576).toFixed(1)} MB`, 0, { mem: mem() });
      const up = await upload(job, blob);
      let result = { outcome: job.mode === 'selftest' ? 'selftest_ok' : 'intercepted', note: 'đã tải video lên TikTok, CHƯA đăng', ids: up.ids, parts: up.parts, chunkCredentials: up.chunkCredentials, identity: id0, elapsed_ms: Date.now() - t0, mem: mem() };
      if (job.mode !== 'selftest') {
        const b = await buildBody(job, up.ids, blob);
        if (job.mode === 'intercept') Object.assign(result, { sent: false, body: b.payload, probe: b.probe, resolvedMentions: b.resolvedMentions, tz: b.tz });
        else result = Object.assign({ ids: up.ids, parts: up.parts, elapsed_ms: Date.now() - t0 }, await doPost(job, up, b, id0));
      }
      post('done', { result });
    } catch (e) {
      const notSent = e instanceof StepFail && e.extra && e.extra.notSent === true;
      if (sentFlag) post('done', { result: { outcome: 'uncertain', reason: 'error-after-send', detail: String(e.message).slice(0, 400), elapsed_ms: Date.now() - t0 } });
      else post('done', { result: { outcome: 'failed', definite: true, notSent, reason: e instanceof StepFail ? 'step:' + e.step : 'exception', detail: String(e.message).slice(0, 400), step: e.extra || null, elapsed_ms: Date.now() - t0 } });
    }
  }

  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source === window && d && d.__autotok === 1 && d.from === 'content' && d.kind === 'auth-res' && d.nonce === NONCE && authResolve) { const r = authResolve; authResolve = null; r({ ok: !!d.ok, reason: d.reason }); return; }
    if (e.source !== window || !d || d.__autotok !== 1 || d.kind !== 'run' || d.from === 'api') return;
    if (running) { post('p', { phase: 'warn', msg: 'duplicate run ignored' }); return; }
    running = true; NONCE = String(d.nonce);
    run(d).catch((err) => post('done', { result: { outcome: 'failed', definite: true, reason: 'exception', detail: String(err && err.message) } }));
  });
})();
