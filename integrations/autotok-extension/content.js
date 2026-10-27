// Content script (isolated world) for TikTok Studio. Bridges the service worker and the MAIN-world runner
// (api-main.js): pulls the video bytes through the SW, hands the Blob URL to MAIN, relays progress and the
// authorization request, and returns the result. No Studio UI is driven.
// Only acts when the SW confirms it owns this tab (hello); a normal manual visit to Studio is left alone.
(function () {
  'use strict';
  if (window.top !== window || window.__autotokContent) return;
  window.__autotokContent = true;
  const hasHash = /[#&]autotok=/.test(location.hash);
  // Tell the SW we exist (document_start and again when loaded), even when the hash was lost to a redirect.
  const where = () => location.pathname + (hasHash ? '#autotok' : ' (no hash)');
  chrome.runtime.sendMessage({ type: 'ready', stage: 'document_start', where: where(), state: document.readyState }).catch(() => {});
  window.addEventListener('load', () => chrome.runtime.sendMessage({ type: 'ready', stage: 'load', where: where(), state: document.readyState }).catch(() => {}));

  const PROCESS_MS = 25 * 60000;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  let JOB = null, NONCE = null;
  const seen = { armed: false };
  let lagMax = 0;
  const api = { done: null };   // messages from api-main.js (MAIN world)

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

  // ---- MAIN-world messages ----
  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.__autotok !== 1) return;
    if (d.from === 'api') {
      if (d.nonce !== NONCE) return;
      if (d.kind === 'p') report(d.phase, d.msg, d.pct, d.extra);
      else if (d.kind === 'done') api.done = d;
      else if (d.kind === 'auth-req') {
        send('authorize', { sha: d.sha, creation_id: d.creation_id, visibility_type: d.visibility_type, schedule_time: d.schedule_time, identity: d.identity })
          .catch((err) => ({ ok: false, reason: 'sw-error:' + err.message }))
          .then((r) => window.postMessage({ __autotok: 1, from: 'content', kind: 'auth-res', nonce: NONCE, ok: !!(r && r.ok), reason: r && r.reason }, location.origin));
      }
      return;
    }
    if (d.from === 'content') return;
    if (d.kind === 'armed' && d.nonce === NONCE) seen.armed = true;
  });

  async function waitFor(fn, { timeout, interval = 500, what }) {
    const t0 = Date.now();
    for (;;) {
      let v; try { v = await fn(); } catch (_) { v = null; }
      if (v) return v;
      if (Date.now() - t0 > timeout) throw new StepError('timeout', what + ' (' + Math.round(timeout / 1000) + 's)');
      await sleep(interval);
    }
  }

  // ---- video bytes: pulled chunk by chunk through the SW (stateless range fetches) ----
  function decode(b) { const bin = atob(b); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }

  // The Blob grows part by part so each decoded chunk can be released right after it is consumed.
  async function buildBlob() {
    const m = await send('videoMeta');
    if (!m.ok) throw new StepError('video-meta', m.error);
    const meta = m.meta; const n = Math.ceil(meta.size / meta.chunk);
    let blob = new Blob([], { type: meta.type || 'video/mp4' });
    const t0 = Date.now(); const mem0 = mem();
    for (let i = 0; i < n; i++) {
      let ok = false;
      for (let a = 1; a <= 3 && !ok; a++) {
        const r = await send('videoChunk', { index: i, size: meta.size }).catch((e) => ({ ok: false, error: e.message }));
        if (r.ok) { blob = new Blob([blob, decode(r.b64)], { type: blob.type }); r.b64 = null; ok = true; await sleep(0); } else await sleep(1000 * a);
      }
      if (!ok) throw new StepError('video-chunk', 'chunk ' + i + '/' + n);
      if (i % 4 === 3 || i === n - 1) await report('transfer-in', `video ${i + 1}/${n} chunk`, Math.round(((i + 1) / n) * 100), { elapsedMs: Date.now() - t0 });
    }
    if (blob.size !== meta.size) throw new StepError('video-size', `${blob.size} != ${meta.size}`);
    return { blob, meta, stats: { bytes: meta.size, chunks: n, ms: Date.now() - t0, memBefore: mem0, memAfter: mem() } };
  }

  async function arm(mode) {
    window.postMessage({ __autotok: 1, kind: 'arm', nonce: NONCE, mode }, location.origin);
    await waitFor(() => seen.armed, { timeout: 5000, interval: 100, what: 'hook MAIN-world chưa cài (hook-main.js)' });
  }

  // Local self-check ("Tự kiểm"): no job on the backend, no video. Proves the content script + hook are installed
  // and shows which TikTok account this profile is logged in as (passport self endpoint only). Uploads and posts nothing.
  async function runSelfcheck() {
    await arm('block');
    await waitFor(() => document.readyState !== 'loading', { timeout: 20000, what: 'trang tải xong' });
    let id = null, err = null;
    try {
      const j = await (await fetch('/passport/web/account/info/?aid=1988', { credentials: 'include' })).json();
      const d = (j && j.data) || {};
      if (d.username && d.user_id_str) id = { username: String(d.username).toLowerCase(), user_id: String(d.user_id_str) };
      else err = 'no username/user_id_str in passport response';
    } catch (e) { err = e.message; }
    return id ? { outcome: 'selfcheck_ok', url: location.pathname, identity: { value: id.username, user_id: id.user_id } }
      : { outcome: 'failed', definite: true, notSent: true, reason: 'identity-unknown', detail: err };
  }

  // selftest (upload only) | intercept (body built, never sent) | post (gated, see api-main.js publishOnce).
  async function runJob(job) {
    if (!['selftest', 'intercept', 'post'].includes(job.mode)) throw new StepError('mode-disabled', String(job.mode));
    const R = { steps: {} };
    await waitFor(() => document.readyState !== 'loading', { timeout: 30000, what: 'trang tải xong' });
    await arm('block');                       // safety net: any /project/post/ request is blocked, whatever the mode
    if (/\/login/.test(location.pathname)) throw new StepError('not-logged-in', location.href);
    await report('start', `bắt đầu ${job.mode}, caption ${job.caption.length} ký tự`);

    const { blob, meta, stats } = await buildBlob();
    R.steps.transfer = stats;
    let url = URL.createObjectURL(blob);
    const revoke = () => { if (url) { URL.revokeObjectURL(url); url = null; } };
    try {
      window.postMessage({ __autotok: 1, from: 'content', kind: 'run', nonce: NONCE, job, blobUrl: url, size: meta.size, name: meta.name }, location.origin);
      const t0 = Date.now();
      const done = await waitFor(() => api.done, { timeout: PROCESS_MS, interval: 500, what: 'MAIN-world runner (api-main.js)' });
      R.steps.api = { ms: Date.now() - t0 };
      return Object.assign(R, done.result);
    } finally { revoke(); }
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
      const code = e instanceof StepError ? e.code : 'exception';
      // Reported as 'failed' (not notSent): if a post was already authorized the SW downgrades this to 'uncertain'
      // (e.g. a timeout while waiting for the runner). Only api-main.js can say notSent:true.
      result = { outcome: 'failed', definite: true, reason: code, detail: e.message };
      console.error('[autotok]', e);
    }
    await send('result', { result });
  }
  main().catch((e) => console.error('[autotok] fatal', e));
})();
