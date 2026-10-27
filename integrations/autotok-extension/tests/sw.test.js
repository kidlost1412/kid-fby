// Independent QA: loads the REAL sw.js with a stubbed chrome.* API and a fake dev server (fetch stub, no ports).
// Oracle = R1 (one publish per job; a lost authorization reply means uncertain, never a re-run).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function loadSw({ server }) {
  const store = {};
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
    runtime: { onMessage: { addListener: (f) => onMsg.push(f) }, onStartup: ev(), onInstalled: ev() },
    tabs: { query: async () => [], get: async (id) => ({ id }), update: async () => {}, remove: async () => {}, create: async () => ({ id: 9, windowId: 1 }), onRemoved: ev(), onReplaced: ev() },
    windows: { create: async () => ({ id: 1, tabs: [{ id: 9 }] }), remove: async () => {} },
  };
  async function fetch(url, init) {
    const u = new URL(url);
    const body = init && init.body ? JSON.parse(init.body) : null;
    calls.push({ path: u.pathname, body });
    return server(u.pathname, body, calls);
  }
  const ctx = { chrome, fetch, setTimeout, clearTimeout, AbortController, console: { log() {}, warn() {}, error() {} }, btoa, Date, URL, Promise, Object, JSON, Math, Error, encodeURIComponent };
  vm.createContext(ctx);
  store.settings = { server: 'http://127.0.0.1:1', token: 'T', polling: false, windowStrategy: 'tab' };
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'sw.js'), 'utf8'), ctx);
  const send = (msg, tabId = 5) => new Promise((resolve) => {
    for (const f of onMsg) if (f(msg, { tab: { id: tabId, url: 'https://www.tiktok.com/tiktokstudio/upload#autotok=job-1', windowId: 1 } }, resolve) === true) return;
    resolve(undefined);
  });
  return { store, calls, send };
}
const json = (o, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => o });
const active = (over) => Object.assign({ id: 'job-1', nonce: 'N', mode: 'post', job: { id: 'job-1', nonce: 'N', mode: 'post' }, local: false, phase: 'x', startedAt: Date.now(),
  openingAt: Date.now(), lastBeat: Date.now(), tabId: 5, windowId: 1, strategy: 'tab', authorized: false, finished: false }, over);
const SHA = 'c'.repeat(64);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('SW authorize: overlapping requests (content retry) reach the server once; exactly one grant', async () => {
  const sw = loadSw({ server: async (p) => { if (p === '/api/ext/authorize') { await sleep(50); return json({ ok: true, reason: null }); } return json({ ok: true }); } });
  sw.store.activeJob = active();
  const msg = { type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' };
  const rs = await Promise.all([sw.send(msg), sw.send(msg), sw.send(msg)]);
  assert.equal(rs.filter((r) => r && r.ok).length, 1);
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/authorize').length, 1);
  assert.equal(sw.store.activeJob.authorized, true);
});

test('SW authorize: reply lost (server unreachable) -> no grant now, and a reload later finishes as uncertain, never re-runs', async () => {
  let authCalls = 0;
  const sw = loadSw({ server: async (p) => {
    if (p === '/api/ext/authorize') { authCalls++; throw new TypeError('Failed to fetch'); }
    if (p === '/api/ext/job_state') return json({ state: 'running', authorized: false });   // server lost track; must not matter
    return json({ ok: true });
  } });
  sw.store.activeJob = active();
  const r = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' });
  assert.equal(r.ok, false);
  assert.equal(sw.store.activeJob.authorized, true);                                  // conservative: may have been granted
  const again = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' });
  assert.equal(again.ok, false);
  assert.equal(authCalls, 1);                                                          // never asked twice
  const h = await sw.send({ type: 'hello', nonce: null });                            // tab reloaded
  assert.equal(h.role, 'none');
  await sleep(20);
  const res = sw.calls.filter((c) => c.path === '/api/ext/result');
  assert.equal(res.length, 1);
  assert.equal(res[0].body.outcome, 'uncertain');
});

test('SW authorize: explicit server denial clears the local flag (nothing was sent); other tab cannot authorize', async () => {
  const sw = loadSw({ server: async (p) => (p === '/api/ext/authorize' ? json({ ok: false, reason: 'cancelled' }) : json({ ok: true })) });
  sw.store.activeJob = active();
  const r = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' });
  assert.deepEqual([r.ok, r.reason, sw.store.activeJob.authorized], [false, 'cancelled', false]);
  const other = await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' }, 77);
  assert.equal(other.ok, false);
  const wrongNonce = await sw.send({ type: 'authorize', nonce: 'X', sha: SHA, creation_id: 'C1' });
  assert.equal(wrongNonce.ok, false);
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/authorize').length, 1);      // foreign tab / wrong nonce never reach the server
});

test('SW authorize: refused for non-post and finished jobs without contacting the server', async () => {
  const sw = loadSw({ server: async () => json({ ok: true }) });
  sw.store.activeJob = active({ mode: 'intercept' });
  assert.equal((await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' })).ok, false);
  sw.store.activeJob = active({ finished: true });
  assert.equal((await sw.send({ type: 'authorize', nonce: 'N', sha: SHA, creation_id: 'C1' })).ok, false);
  assert.equal(sw.calls.filter((c) => c.path === '/api/ext/authorize').length, 0);
});
