// Protocol v1 behaviour of the REAL sw.js against a fake backend (fetch stub, no ports): pairing, hello, need_reload,
// authorize binding, result wire format. Oracle = PROTOCOL.md.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const json = (o, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => o });
const empty = (status) => ({ ok: status >= 200 && status < 300, status, json: async () => { throw new Error('no body'); } });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ME = { data: { username: 'Me.User', user_id_str: '7000000000000000001' } };

function loadSw({ server, settings, store0 }) {
  const store = Object.assign({}, store0);
  const onMsg = [];
  const calls = [];
  const ev = () => ({ addListener() {} });
  const chrome = {
    storage: { local: {
      async get(k) { const keys = k == null ? Object.keys(store) : [].concat(k); const o = {}; for (const x of keys) if (x in store) o[x] = JSON.parse(JSON.stringify(store[x])); return o; },
      async set(o) { for (const [k, v] of Object.entries(o)) store[k] = JSON.parse(JSON.stringify(v)); },
      async remove(k) { for (const x of [].concat(k)) delete store[x]; },
    } },
    alarms: { create() {}, onAlarm: ev() },
    runtime: { onMessage: { addListener: (f) => onMsg.push(f) }, onStartup: ev(), onInstalled: ev(), getManifest: () => ({ version: '1.2.3' }) },
    tabs: { query: async () => [], get: async (id) => ({ id }), update: async () => {}, remove: async () => {}, create: async () => ({ id: 9, windowId: 1 }), onRemoved: ev(), onReplaced: ev() },
    windows: { create: async () => ({ id: 1, tabs: [{ id: 9 }] }), remove: async () => {} },
  };
  async function fetch(url, init = {}) {
    const u = new URL(url);
    const body = init.body ? JSON.parse(init.body) : null;
    const rec = { host: u.host, path: u.pathname, search: u.search, method: init.method || 'GET', body, headers: init.headers || {} };
    calls.push(rec);
    return server(u.pathname, body, rec);
  }
  const unrefTimeout = (f, ms) => { const t = setTimeout(f, ms); if (t.unref) t.unref(); return t; };
  const ctx = { chrome, fetch, setTimeout: unrefTimeout, clearTimeout, AbortController, console: { log() {}, warn() {}, error() {} }, btoa, Date, URL, Promise, Object, JSON, Math, Error, encodeURIComponent };
  vm.createContext(ctx);
  store.settings = Object.assign({ server: 'http://127.0.0.1:8765', token: 'T', clientId: 3, polling: false, windowStrategy: 'tab' }, settings);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'sw.js'), 'utf8'), ctx);
  const send = (msg, tabId = 5) => new Promise((resolve) => {
    for (const f of onMsg) if (f(msg, { tab: { id: tabId, url: 'https://www.tiktok.com/tiktokstudio/upload#autotok=ej_1', windowId: 1 } }, resolve) === true) return;
    resolve(undefined);
  });
  return { store, calls, send };
}
const active = (over) => Object.assign({ id: 'ej_1', nonce: 'N', claim_token: 'CT', mode: 'post', job: { id: 'ej_1', mode: 'post' }, local: false, phase: 'x', startedAt: Date.now(),
  openingAt: Date.now(), lastBeat: Date.now(), tabId: 5, windowId: 1, strategy: 'tab', authorized: false, finished: false }, over);
const SHA = 'd'.repeat(64);
const helloOk = (extra) => json(Object.assign({ ok: true, client_id: 3, protocol_min: 1, protocol_max: 1, need_reload: false, message: '', account: null, conflict: false }, extra));
const baseServer = (over) => async (p, body, rec) => {
  if (over && over[p]) return over[p](body, rec);
  if (p === '/passport/web/account/info/') return json(ME);
  if (p === '/api/ext/hello') return helloOk();
  if (p === '/api/ext/progress') return json({ ok: true, state: 'uploading' });
  return json({ ok: true });
};

// ---------- pairing ----------
test('pair: 6-digit code -> token stored, headers per protocol, no bearer on pair, hello follows with the passport identity', async () => {
  const sw = loadSw({ settings: { token: '' }, server: baseServer({ '/api/ext/pair': () => json({ ok: true, client_id: 3, token: 'TOK-43' }) }) });
  const r = await sw.send({ popup: 'pair', code: '123456' });
  assert.equal(r.ok, true);
  assert.deepEqual([sw.store.settings.token, sw.store.settings.clientId], ['TOK-43', 3]);
  const pair = sw.calls.find((c) => c.path === '/api/ext/pair');
  assert.deepEqual(pair.body, { code: '123456', label: 'Chrome', ext_version: '1.2.3', protocol: 1 });
  assert.equal(pair.headers.Authorization, undefined);
  assert.equal(pair.headers['X-Autotok-Protocol'], '1');
  assert.equal(pair.headers['X-Requested-With'], 'autotok');
  const hello = sw.calls.find((c) => c.path === '/api/ext/hello');
  assert.deepEqual(hello.body, { protocol: 1, ext_version: '1.2.3', identity: { username: 'me.user', user_id: '7000000000000000001' } });
  assert.equal(hello.headers.Authorization, 'Bearer TOK-43');
  assert.equal(sw.store.conn.state, 'ok');
  assert.equal(sw.store.account, 'me.user');
});

test('pair: wrong code shows the backend message and stores no token; malformed code never hits the network', async () => {
  const sw = loadSw({ settings: { token: '' }, server: baseServer({ '/api/ext/pair': () => json({ ok: false, error: 'bad_code', message: 'Mã không đúng', tries_left: 3 }, 403) }) });
  await sw.send({ popup: 'pair', code: '000000' });
  assert.equal(sw.store.settings.token, '');
  assert.equal(sw.store.pairError, 'Mã không đúng');
  const n = sw.calls.length;
  for (const bad of ['12345', 'abcdef', '1234567', '']) await sw.send({ popup: 'pair', code: bad });
  assert.equal(sw.calls.length, n);
  assert.match(sw.store.pairError, /6 chữ số/);
});

test('pair: no_code (410) is reported, not retried', async () => {
  const sw = loadSw({ settings: { token: '' }, server: baseServer({ '/api/ext/pair': () => json({ ok: false, error: 'no_code', message: 'Chưa có mã' }, 410) }) });
  await sw.send({ popup: 'pair', code: '123456' });
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/pair').length, 1);
  assert.equal(sw.store.pairError, 'Chưa có mã');
});

// ---------- need_reload ----------
test('hello need_reload: state recorded, NO claim (/next never called) but an undelivered authorized result is still delivered', async () => {
  const sw = loadSw({
    settings: { polling: true },
    store0: { activeJob: active({ authorized: true, finished: true, result: { outcome: 'posted', status_code: 0, item_id: '7701245450858351893', schedule_time: 1793367000 } }) },
    server: baseServer({ '/api/ext/hello': () => helloOk({ need_reload: true, message: 'Cần tải lại tiện ích (chrome://extensions → ⟳)' }),
      '/api/ext/next': () => json({}, 200) }),
  });
  await sleep(300);
  assert.equal(sw.store.conn.state, 'need_reload');
  assert.equal(sw.store.conn.needReload, true);
  assert.match(sw.store.conn.message, /Cần tải lại tiện ích/);
  const res = sw.calls.filter((c) => c.path === '/api/ext/result');
  assert.equal(res.length, 1);
  assert.deepEqual([res[0].body.outcome, res[0].body.item_id, res[0].body.schedule_time, res[0].body.claim_token], ['posted', '7701245450858351893', 1793367000, 'CT']);
  assert.equal(sw.store.activeJob, undefined);
  await sleep(200);
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/next').length, 0);
});

test('409 need_reload on /next stops claiming and is recorded', async () => {
  const sw = loadSw({ settings: { polling: true }, server: baseServer({ '/api/ext/next': () => json({ ok: false, error: 'need_reload', need_reload: true, message: 'x' }, 409) }) });
  await sleep(300);
  assert.equal(sw.store.conn.needReload, true);
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/next').length, 1);
});

test('401 marks the client unpaired-needed and stops polling', async () => {
  const sw = loadSw({ settings: { polling: true }, server: baseServer({ '/api/ext/hello': () => json({ ok: false, error: 'unauthorized', message: 'u' }, 401) }) });
  await sleep(300);
  assert.equal(sw.store.conn.state, 'unauthorized');
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/next').length, 0);
});

test('hello with no TikTok login sends identity:null and records no_identity (no claims)', async () => {
  const sw = loadSw({ settings: { polling: true }, server: baseServer({ '/passport/web/account/info/': () => json({ data: {} }), '/api/ext/hello': () => helloOk({ ok: true }) }) });
  await sleep(300);
  assert.equal(sw.calls.find((c) => c.path === '/api/ext/hello').body.identity, null);
  assert.equal(sw.store.conn.state, 'no_identity');
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/next').length, 0);
});

// ---------- authorize binding + wire format ----------
test('authorize: ready progress first, then the binding (sha, creation_id, visibility_type, schedule_time, identity) with claim_token', async () => {
  const sw = loadSw({ store0: { activeJob: active() }, server: baseServer() });
  const identity = { username: 'me.user', user_id: '7000000000000000001' };
  const r = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1', visibility_type: 0, schedule_time: 1793367000, identity });
  assert.equal(r.ok, true);
  const order = sw.calls.map((c) => c.path).filter((p) => p.startsWith('/api/ext/'));
  assert.deepEqual(order, ['/api/ext/progress', '/api/ext/authorize']);
  assert.equal(sw.calls[0].body.phase, 'ready');
  assert.deepEqual(sw.calls[1].body, { id: 'ej_1', nonce: 'N', claim_token: 'CT', body_sha256: SHA, creation_id: 'C1', visibility_type: 0, schedule_time: 1793367000, identity });
});

test('authorize: ready not confirmed (progress says revoked) -> denied, nothing authorized, job dropped', async () => {
  const sw = loadSw({ store0: { activeJob: active() }, server: baseServer({ '/api/ext/progress': () => json({ ok: false, state: 'revoked', cancelled: true }) }) });
  const r = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1', visibility_type: 1, schedule_time: null, identity: {} });
  assert.equal(r.ok, false);
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/authorize').length, 0);
});

test('authorize: HTTP 409 need_reload / 500 persist_failed = not granted (flag cleared); plain 500 = unknown (stays authorized)', async () => {
  for (const [status, code, cleared] of [[409, 'need_reload', true], [500, 'persist_failed', true], [500, 'boom', false]]) {
    const sw = loadSw({ store0: { activeJob: active() }, server: baseServer({ '/api/ext/authorize': () => json({ ok: false, error: code, message: 'm' }, status) }) });
    const r = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1', visibility_type: 1, schedule_time: null, identity: {} });
    assert.equal(r.ok, false, code);
    assert.equal(sw.store.activeJob.authorized, !cleared, code);
  }
});

test('result wire format: snake_case, not_sent, claim_token, submitted schedule, sanitized response', async () => {
  const sw = loadSw({ store0: { activeJob: active({ authorized: true }) }, server: baseServer() });
  await sw.send({ type: 'result', nonce: 'N', result: { outcome: 'failed', definite: true, notSent: true, reason: 'blocked-by-hook', response: { a: 1 } } });
  await sleep(30);
  const b = sw.calls.find((c) => c.path === '/api/ext/result').body;
  assert.deepEqual([b.outcome, b.not_sent, b.claim_token, b.nonce, b.id, b.response], ['failed', true, 'CT', 'N', 'ej_1', { a: 1 }]);
  assert.equal('notSent' in b, false);
});

test('result 404/403 drops the job (no endless retry); 5xx keeps it for a retry', async () => {
  for (const [status, kept] of [[404, false], [403, false], [503, true]]) {
    const sw = loadSw({ store0: { activeJob: active({ authorized: true }) }, server: baseServer({ '/api/ext/result': () => json({ ok: false, error: 'x' }, status) }) });
    await sw.send({ type: 'result', nonce: 'N', result: { outcome: 'uncertain', reason: 'r' } });
    await sleep(30);
    assert.equal(!!sw.store.activeJob, kept, String(status));
  }
});
