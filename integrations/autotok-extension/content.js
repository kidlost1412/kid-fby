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

  let JOB = null, NONCE = null;
  const seen = { identity: [], req: [], res: [], armed: false };
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

  // ---- hook messages (MAIN world) ----
  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.__autotok !== 1) return;
    if (d.from === 'api') {
      if (d.nonce !== NONCE) return;
      if (d.kind === 'p') report(d.phase, d.msg, d.pct, d.extra);
      else if (d.kind === 'done') api.done = d;
      else if (d.kind === 'auth-req') {
        send('authorize', { sha: d.sha, creation_id: d.creation_id }).catch((err) => ({ ok: false, reason: 'sw-error:' + err.message }))
          .then((r) => window.postMessage({ __autotok: 1, from: 'content', kind: 'auth-res', nonce: NONCE, ok: !!(r && r.ok), reason: r && r.reason }, location.origin));
      }
      return;
    }
    if (d.from === 'content') return;
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

  // selftest (upload only) | intercept (body built, never sent) | post (gated, see api-main.js publishOnce).
  async function runJob(job) {
    if (!['selftest', 'intercept', 'post'].includes(job.mode)) throw new StepError('mode-disabled', String(job.mode));
    const R = { steps: {} };
    await waitFor(() => document.readyState !== 'loading', { timeout: 30000, what: 'trang tải xong' });
    await arm('block');                       // safety net: any /project/post/ request is blocked, whatever the mode
    if (/\/login/.test(location.pathname)) throw new StepError('not-logged-in', location.href);
    await report('start', `bắt đầu ${job.mode}, caption ${job.caption.length} ký tự`);
    // Fallback identity sources are diagnostics only; the decision is made by api-main.js (passport user_id_str + username).
    R.identityDiag = await getIdentity().catch((e) => ({ error: e.message }));

    const { blob, meta, stats } = await buildBlob();
    R.steps.transfer = stats;
    let url = URL.createObjectURL(blob);
    const revoke = () => { if (url) { URL.revokeObjectURL(url); url = null; } };
    try {
      window.postMessage({ __autotok: 1, from: 'content', kind: 'run', nonce: NONCE, job, blobUrl: url, size: meta.size, name: meta.name }, location.origin);
      const t0 = Date.now();
      const done = await waitFor(() => api.done, { timeout: CFG.processMs, interval: 500, what: 'MAIN-world runner (api-main.js)' });
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
      let dom = null; try { dom = S.report(); } catch (_) { /* ignore */ }
      const code = e instanceof StepError ? e.code : 'exception';
      // Nothing can have been posted (no post path exists), so every failure here is definite.
      result = { outcome: 'failed', definite: true, reason: code, detail: e.message, dom };
      console.error('[autotok]', e);
    }
    await send('result', { result });
  }
  main().catch((e) => console.error('[autotok] fatal', e));
})();
