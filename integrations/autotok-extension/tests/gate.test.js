// Offline tests for the post gate: result mapping, payload-bound single-flight gate, strict identity, and the MAIN-world hook.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const L = require('../lib.js');

// ---- result mapping (hand-derived from uploader._check_publish / _extract_post_id) ----
test('mapPublishResult: succeeded / rejected / uncertain', () => {
  const ID = '7300000000000000001';
  assert.deepEqual(L.mapPublishResult(200, `{"status_code":0,"data":{"item_id":"${ID}"}}`), { http: 200, outcome: 'posted', status_code: 0, item_id: ID, no_item_id: false });
  // 19-digit JSON NUMBER must not lose precision (Number would give 7300000000000000000)
  assert.equal(L.mapPublishResult(200, `{"status_code":0,"single_post_resp_list":[{"aweme_id":${ID}}]}`).item_id, ID);
  assert.equal(L.mapPublishResult(200, '{"status_code":0,"data":{"itemId":"7300000000000000002"}}').item_id, '7300000000000000002');
  const noId = L.mapPublishResult(200, '{"status_code":0}');
  assert.deepEqual([noId.outcome, noId.item_id, noId.no_item_id], ['posted', null, true]);      // Python also treats status 0 as success
  assert.equal(L.mapPublishResult(200, '{"status_code":0,"data":{"item_id":"1234567890123456"}}').item_id, null);  // 16 digits: not an id
  const rej = L.mapPublishResult(200, '{"status_code":5,"status_msg":"Invalid parameters"}');
  assert.deepEqual([rej.outcome, rej.definite, rej.status_code, rej.status_msg], ['rejected', true, 5, 'Invalid parameters']);
  for (const [st, body] of [[200, 'not json'], [200, '{}'], [200, '{"status_code":"0"}'], [200, '{"status_code":true}'], [200, '{"status_code":0.5}'], [500, ''], [503, ''], [429, ''], [408, '']]) {
    assert.equal(L.mapPublishResult(st, body).outcome, 'uncertain', st + ' ' + body);
  }
  assert.deepEqual([L.mapPublishResult(400, '').outcome, L.mapPublishResult(403, '').definite], ['rejected', true]);
});

// ---- publish gate ----
const body = (cid) => JSON.stringify({ post_common_info: { creation_id: cid }, x: 'Việt 🌸' });
const gateFor = async (b, cid, nonce = 'n1') => { const g = L.createPublishGate(); g.arm({ sha: await L.sha256Hex(b), creationId: cid, nonce }); return g; };

test('gate: one-time, body-bound, nonce-bound', async () => {
  const b = body('C1');
  let g = await gateFor(b, 'C1');
  assert.equal(await g.check(b, 'n1'), true);
  await assert.rejects(g.check(b, 'n1'), /already used/);                         // second call
  g = await gateFor(b, 'C1');
  await assert.rejects(g.check(body('C1') + ' ', 'n1'), /does not match/);       // body mismatch
  await assert.rejects(g.check(b, 'other'), /nonce mismatch/);
  assert.equal(g.used, false);                                                     // refused checks do not consume
  assert.equal(await g.check(b, 'n1'), true);
  g = L.createPublishGate();
  await assert.rejects(g.check(b, 'n1'), /no grant/);
  g = await gateFor(b, 'DIFFERENT');                                               // right hash, wrong creation_id
  await assert.rejects(g.check(b, 'n1'), /creation_id mismatch/);
  assert.throws(() => g.arm({ sha: 'x', creationId: 'y', nonce: 'z' }), /already armed/);
});

test('gate: concurrent calls - exactly one passes', async () => {
  const b = body('C1');
  const g = await gateFor(b, 'C1');
  const res = await Promise.allSettled(Array.from({ length: 8 }, () => g.check(b, 'n1')));
  assert.equal(res.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(res.filter((r) => r.status === 'rejected' && /already used/.test(r.reason.message)).length, 7);
});

// ---- strict identity ----
test('checkIdentity: passport username + user_id_str only', () => {
  const ok = { data: { username: 'Me.User', user_id_str: '7000000000000000001' } };
  assert.deepEqual(L.checkIdentity(ok, { username: '@me.user' }), { ok: true, username: 'me.user', userId: '7000000000000000001' });
  assert.equal(L.checkIdentity(ok, { username: 'me.user', userId: '7000000000000000001' }).ok, true);
  assert.equal(L.checkIdentity(ok, { username: 'someone' }).reason, 'identity-mismatch');
  assert.equal(L.checkIdentity(ok, { username: 'me.user', userId: '7000000000000000002' }).reason, 'identity-mismatch');
  assert.equal(L.checkIdentity({ data: { username: 'me' } }, {}).reason, 'identity-missing');       // no user_id_str
  assert.equal(L.checkIdentity({ data: { user_id_str: '1' } }, {}).reason, 'identity-missing');
  assert.equal(L.checkIdentity({ error: 'x' }, {}).reason, 'identity-missing');
  assert.equal(L.checkIdentity(null, { username: 'me' }).reason, 'identity-missing');
  assert.equal(L.checkIdentity({ data: { username: 'x', screen_name: 'me', user_id_str: '1' } }, { username: 'me' }).reason, 'identity-mismatch'); // screen_name is ignored
});

// ---- MAIN-world hook (stubbed XHR/fetch) ----
function loadHook() {
  const sent = [], posted = [], listeners = [];
  class XHR extends EventTarget { open(m, u) { this.m = m; this.u = u; } send(b) { sent.push([this.u, b]); } }
  const win = { addEventListener: (t, f) => listeners.push(f), postMessage: (m) => { posted.push(m); setTimeout(() => listeners.forEach((f) => f({ source: win, data: m })), 0); },
    fetch: async (u) => { sent.push(['fetch', u]); return { headers: { get: () => '' }, clone() { return this; }, text: async () => '' }; } };
  const ctx = { XMLHttpRequest: XHR, window: win, location: { origin: 'https://www.tiktok.com', href: 'https://www.tiktok.com/tiktokstudio/upload' }, URL, Event, ProgressEvent: Event, TypeError, setTimeout, Object, Date, WeakMap, JSON, String };
  Object.assign(win, ctx); win.window = win;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'hook-main.js'), 'utf8'), ctx);
  return { XHR: ctx.XMLHttpRequest, win, sent, posted };
}
const tick = (ms = 20) => new Promise((r) => setTimeout(r, ms));
const POST_URL = '/tiktok/web/project/post/v1/?aid=1988';

test('hook: unallowed publish is blocked and never fabricated as success', async () => {
  const { XHR, win, sent, posted } = loadHook();
  win.postMessage({ __autotok: 1, kind: 'arm', nonce: 'n' }); await tick();
  const x = new XHR(); const events = [];
  for (const t of ['load', 'error', 'loadend']) x.addEventListener(t, () => events.push(t));
  x.open('POST', POST_URL); x.send('{}'); await tick();
  assert.equal(sent.filter((s) => s[0].includes('/project/post/')).length, 0);       // nothing reached the native send
  assert.deepEqual([x.status, x.readyState, x.responseText, x.__autotokBlocked], [0, 4, '', true]);
  assert.deepEqual(events, ['error', 'loadend']);                                    // no 'load' => no success
  assert.ok(posted.some((m) => m.kind === 'blocked'));
});

test('hook: only the allowed XHR passes, once', async () => {
  const { XHR, win, sent } = loadHook();
  win.postMessage({ __autotok: 1, kind: 'arm', nonce: 'n' }); await tick();
  const a = new XHR(); a.open('POST', POST_URL);
  win.__autotokHook.allow(a);
  const other = new XHR(); other.open('POST', POST_URL); other.send('{"o":1}');    // someone else sends first
  assert.equal(sent.length, 0);                                                      // blocked, and it consumed the single-shot allow
  a.send('{"a":1}'); await tick();
  assert.equal(sent.length, 0);                                                      // allow was spent by the intruder: a is blocked too (fail closed)
  const b = new XHR(); b.open('POST', POST_URL);
  win.__autotokHook.allow(b); b.send('{"b":1}');
  assert.deepEqual(sent, [[POST_URL, '{"b":1}']]);                                   // exactly the allowed one
  const c = new XHR(); c.open('POST', POST_URL); c.send('{"c":1}'); await tick();
  assert.equal(sent.length, 1);                                                      // single-shot: a second publish is blocked
  const n = new XHR(); n.open('POST', '/other'); n.send('z');
  assert.equal(sent.length, 2);                                                      // unrelated requests untouched
});

test('hook: fetch to the publish endpoint is blocked', async () => {
  const { win, sent } = loadHook();
  win.postMessage({ __autotok: 1, kind: 'arm', nonce: 'n' }); await tick();
  await assert.rejects(win.fetch('/tiktok/web/project/post/v1/', { method: 'POST', body: '{}' }), TypeError);
  assert.equal(sent.length, 0);
});
