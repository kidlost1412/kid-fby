// Independent QA: runs the REAL lib.js + hook-main.js + api-main.js in one simulated page (MAIN world) against a fake
// TikTok (fetch + XHR stubs; nothing leaves the process). The fake "SDK" wraps XHR.send on top of our hook, as Studio does.
// Oracle = the owner's requirements R1-R7, not the implementation.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const POST_RE = /\/tiktok\/web\/project\/post\/v1\//;
const STS = { access_key_id: 'AKIDTESTKEY0001', secret_acess_key: 'SECRETvalueDoNotLog123', session_token: 'SESSIONtokenDoNotLog456' };
const STORE_AUTH = 'STOREauthDoNotLog789';
const ME = { username: 'me.user', user_id_str: '7000000000000000001' };

// opts: identities: [passport json per call], auth: (n) => {ok, reason}, xhr: (xhr, body) => void (native send behaviour),
//       sdk: 'wrap' | 'wrap-throw-after' | 'none'
function page(opts = {}) {
  const net = [];            // every request that reached the "network" (native fetch / native XHR send)
  const msgs = [];           // every window.postMessage payload (what other page scripts can see)
  const listeners = [];
  const authReqs = [];
  let passportCalls = 0;
  let doneResolve; const done = new Promise((r) => { doneResolve = r; });
  const video = new Blob([new Uint8Array(1000).fill(7)], { type: 'video/mp4' });

  class XHR extends EventTarget {
    constructor() { super(); this.readyState = 0; this.status = 0; this.responseText = ''; this.withCredentials = false; this.timeout = 0; }
    open(m, u) { this.m = m; this.u = u; this.readyState = 1; }
    setRequestHeader() {}
    send(body) {             // the browser's native send
      net.push({ via: 'xhr', method: this.m, url: String(this.u), body });
      const x = this;
      setTimeout(() => (opts.xhr || ((xx) => xx.reply(200, '{"status_code":0,"data":{"item_id":"7300000000000000001"}}')))(x, body), 5);
    }
    reply(status, text) { this.readyState = 4; this.status = status; this.responseText = text; for (const t of ['readystatechange', 'load', 'loadend']) this.dispatchEvent(new Event(t)); }
    fail(type = 'error') { this.readyState = 4; this.status = 0; for (const t of ['readystatechange', type, 'loadend']) this.dispatchEvent(new Event(t)); }
    dispatchEvent(e) { const h = this['on' + e.type]; if (typeof h === 'function') h.call(this, e); return super.dispatchEvent(e); }
  }

  const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
  async function nativeFetch(input, init = {}) {
    const url = typeof input === 'string' ? input : input.url;
    net.push({ via: 'fetch', method: init.method || 'GET', url, body: init.body });
    if (url.startsWith('blob:')) return new Response(video);
    if (url.startsWith('/passport/web/account/info/')) {
      const ids = opts.identities || [{ data: ME }];
      const j = ids[Math.min(passportCalls++, ids.length - 1)];
      return json(j);
    }
    if (url.startsWith('/api/v1/web/project/create/')) return json({ project: { id: 'p1' } });
    if (url.startsWith('/api/v1/video/upload/auth/')) return json({ video_token_v5: STS });
    if (url.startsWith('/top/v1?Action=ApplyUploadInner')) return json({ Result: { InnerUploadAddress: { UploadNodes: [{ Vid: 'v0123', SessionKey: 'sk-1', UploadHost: 'up.example', StoreInfos: [{ StoreUri: 'tos/abc', Auth: STORE_AUTH }] }] } } });
    if (url.startsWith('https://up.example/')) return json({ ok: 1 });
    if (url.startsWith('/top/v1?Action=CommitUploadInner')) return json({ Result: {} });
    if (url.startsWith('/@')) return new Response('<html></html>');
    return new Response('not found', { status: 404 });
  }

  const win = {
    XMLHttpRequest: XHR, fetch: nativeFetch, location: { origin: 'https://www.tiktok.com', href: 'https://www.tiktok.com/tiktokstudio/upload' },
    URL, Blob, Response, Event, ProgressEvent: Event, EventTarget, TextEncoder, crypto: globalThis.crypto, performance: { now: () => performance.now() },
    setTimeout, clearTimeout, Intl, console,
    document: { createElement: () => { const v = { removeAttribute() {}, load() {} }; Object.defineProperty(v, 'src', { set() { setTimeout(() => v.onerror && v.onerror(), 0); } }); return v; } },
    addEventListener: (t, f) => { if (t === 'message') listeners.push(f); },
    postMessage: (m) => { msgs.push(JSON.parse(JSON.stringify(m))); setTimeout(() => listeners.slice().forEach((f) => f({ source: inner, data: m })), 0); },
  };
  vm.createContext(win);
  const inner = vm.runInContext('globalThis', win);          // what `window` means inside the page
  win.window = inner;
  for (const f of ['lib.js', 'hook-main.js', 'api-main.js']) vm.runInContext(SRC(f), win, { filename: f });

  // The page's signing SDK wraps XHR.send AFTER our document_start hook.
  const below = win.XMLHttpRequest.prototype.send;
  if ((opts.sdk || 'wrap') === 'wrap') win.XMLHttpRequest.prototype.send = function (b) { return below.call(this, b); };
  if (opts.sdk === 'wrap-throw-after') win.XMLHttpRequest.prototype.send = function (b) { below.call(this, b); throw new Error('sdk post-send bookkeeping failed'); };

  // content.js stand-in (isolated world): answers auth-req via the "SW", records done.
  listeners.push((e) => {
    const d = e.data;
    if (!d || d.__autotok !== 1 || d.from !== 'api') return;
    if (d.kind === 'auth-req') {
      authReqs.push(d);
      const r = (opts.auth || (() => ({ ok: true })))(authReqs.length, d);
      const answer = () => win.postMessage({ __autotok: 1, from: 'content', kind: 'auth-res', nonce: d.nonce, ok: !!r.ok, reason: r.reason });
      answer();
      if (opts.duplicateAuthRes) { answer(); setTimeout(answer, 50); }
    } else if (d.kind === 'done') doneResolve(d.result);
  });

  const job = (over) => Object.assign({ id: 'job-1', nonce: 'N1', mode: 'post', visibility: 'private', schedule_time: null,
    caption: 'Xin chào \u{1F338} #việt', expect_account: 'me.user', expect_user_id: null, chunk_credentials: 'omit' }, over);
  function run(over, nonce = 'N1') {
    win.postMessage({ __autotok: 1, kind: 'arm', nonce, mode: 'block' });                       // content.js arms first
    const j = job(over);
    win.postMessage({ __autotok: 1, from: 'content', kind: 'run', nonce, job: j, blobUrl: 'blob:https://www.tiktok.com/x', size: video.size });
    return j;
  }
  const posts = () => net.filter((r) => POST_RE.test(r.url));
  const timeout = (ms) => new Promise((_, rej) => setTimeout(() => rej(new Error('no done within ' + ms + ' ms')), ms));
  return { win, net, msgs, authReqs, run, posts, done: (ms = 8000) => Promise.race([done, timeout(ms)]), XHR };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- R1 / R5: the happy path sends exactly one publish and maps status 0 -> posted ----------
test('post: exactly one publish request, mapped to posted with item id', async () => {
  const p = page();
  p.run();
  const r = await p.done();
  assert.equal(r.outcome, 'posted', JSON.stringify(r));
  assert.equal(r.item_id, '7300000000000000001');
  assert.equal(p.posts().length, 1);
  assert.equal(p.authReqs.length, 1);
});

// ---------- R7: the body that actually went out (hand-computed values) ----------
test('post: body sent has private visibility, caption text and UTF-16 hashtag offsets', async () => {
  const p = page();
  p.run();
  await p.done();
  const sent = JSON.parse(p.posts()[0].body);
  const f = sent.feature_common_info_list[0];
  const info = sent.single_post_req_list[0].single_post_feature_info;
  assert.equal(f.privacy_setting_info.visibility_type, 1);           // private
  assert.equal('schedule_time' in f, false);                          // no schedule
  assert.equal(info.text, 'Xin chào \u{1F338} #việt');
  // "Xin chào " = 9 units, flower = 2 units, space = 1 -> hashtag at 12, "#việt" = 5 units -> end 17
  assert.deepEqual(info.text_extra, [{ end: 17, hashtag_name: 'việt', start: 12, tag_id: '0', type: 1, user_id: '' }]);
  assert.equal(info.markup_text, 'Xin chào \u{1F338} <h id="0">#việt</h>');
  assert.equal(sent.single_post_req_list[0].video_id, 'v0123');
  assert.equal(f.vedit_common_info.video_id, 'v0123');
});

// ---------- R1: duplicate run / duplicate auth answers ----------
test('post: duplicate run messages and duplicate auth answers still send at most one publish', async () => {
  const p = page({ duplicateAuthRes: true });
  p.run(); p.run(); p.run({}, 'N2');
  const r = await p.done();
  await sleep(300);
  assert.equal(p.posts().length, 1, JSON.stringify(r));
  assert.equal(p.authReqs.length, 1);
  assert.equal(p.net.filter((x) => x.url.startsWith('/api/v1/web/project/create/')).length, 1);   // one upload, too
});

// ---------- R1/R2: authorization denied -> nothing sent ----------
test('post: authorization denied by server -> nothing sent, definite failure', async () => {
  const p = page({ auth: () => ({ ok: false, reason: 'post-disabled' }) });
  p.run();
  const r = await p.done();
  assert.deepEqual([r.outcome, r.definite, p.posts().length], ['failed', true, 0]);
});

// ---------- R2: public / scheduled / no expect_account are refused before any upload ----------
for (const [name, over] of [['public', { visibility: 'public' }], ['scheduled', { schedule_time: '2026-11-01T10:00:00+07:00' }],
  ['no expect_account', { expect_account: null }], ['friends', { visibility: 'friends' }]]) {
  test(`post: ${name} job is refused before upload and never authorized`, async () => {
    const p = page();
    p.run(over);
    const r = await p.done();
    assert.deepEqual([r.outcome, r.definite], ['failed', true]);
    assert.equal(p.posts().length, 0);
    assert.equal(p.authReqs.length, 0);
    assert.equal(p.net.filter((x) => x.url.startsWith('/api/v1/web/project/create/')).length, 0);
  });
}

// ---------- R3: identity ----------
test('identity: passport without user_id_str -> nothing uploaded, nothing sent', async () => {
  const p = page({ identities: [{ data: { username: 'me.user' } }] });
  p.run();
  const r = await p.done();
  assert.deepEqual([r.outcome, r.definite], ['failed', true]);
  assert.equal(p.net.filter((x) => x.url.startsWith('/api/v1/web/project/create/')).length, 0);
  assert.equal(p.posts().length, 0);
});

test('identity: account switched during upload -> second check refuses, nothing sent, never authorized', async () => {
  const p = page({ identities: [{ data: ME }, { data: { username: 'other.acc', user_id_str: '7000000000000000002' } }] });
  p.run();
  const r = await p.done();
  assert.deepEqual([r.outcome, r.definite], ['failed', true]);
  assert.match(r.detail, /identity-mismatch/);
  assert.equal(p.authReqs.length, 0);
  assert.equal(p.posts().length, 0);
});

test('identity: expect_user_id conflicts with passport user_id_str -> refused before upload', async () => {
  const p = page();
  p.run({ expect_user_id: '7000000000000000999' });
  const r = await p.done();
  assert.deepEqual([r.outcome, r.definite], ['failed', true]);
  assert.equal(p.net.filter((x) => x.url.startsWith('/api/v1/web/project/create/')).length, 0);
});

// ---------- R4: selftest / intercept never send, even if the page itself tries ----------
for (const mode of ['selftest', 'intercept']) {
  test(`${mode}: no publish request in any path; a page-initiated publish is blocked, not reported as success`, async () => {
    const p = page();
    p.run({ mode, expect_account: 'me.user' });
    // Studio's own code tries to publish while we are armed
    const x = new p.win.XMLHttpRequest(); let ok = false, err = false;
    x.onload = () => { ok = true; }; x.onerror = () => { err = true; };
    await sleep(20);
    x.open('POST', '/tiktok/web/project/post/v1/?aid=1988'); x.send('{}');
    await assert.rejects(p.win.fetch('/tiktok/web/project/post/v1/', { method: 'POST', body: '{}' }));
    const r = await p.done();
    await sleep(50);                                     // the blocked XHR's error event is dispatched asynchronously
    assert.equal(r.outcome, mode === 'selftest' ? 'selftest_ok' : 'intercepted');
    assert.equal(p.posts().length, 0);
    assert.equal(p.authReqs.length, 0);
    assert.deepEqual([ok, err], [false, true]);
    if (mode === 'intercept') assert.equal(r.sent, false);
  });
}

// ---------- R5: result mapping on the real send path ----------
for (const [name, xhr, want] of [
  ['HTTP 503', (x) => x.reply(503, ''), 'uncertain'],
  ['HTTP 429', (x) => x.reply(429, ''), 'uncertain'],
  ['HTTP 408', (x) => x.reply(408, ''), 'uncertain'],
  ['non-JSON 200', (x) => x.reply(200, '<html>oops</html>'), 'uncertain'],
  ['network error after send', (x) => x.fail('error'), 'uncertain'],
  ['timeout after send', (x) => x.fail('timeout'), 'uncertain'],
  ['status_code 5', (x) => x.reply(200, '{"status_code":5,"status_msg":"Invalid parameters"}'), 'rejected'],
]) {
  test(`publish result: ${name} -> ${want}`, async () => {
    const p = page({ xhr });
    p.run();
    const r = await p.done();
    assert.equal(r.outcome, want, JSON.stringify(r));
    assert.equal(p.posts().length, 1);
    if (want === 'rejected') assert.equal(r.definite, true);
    else assert.notEqual(r.definite, true);
  });
}

// R1 "a lost result means uncertain": the request reached the network, then the page's send wrapper threw.
test('publish result: request handed to the network, then the SDK send wrapper throws -> must be uncertain, not definite', async () => {
  const p = page({ sdk: 'wrap-throw-after' });
  p.run();
  const r = await p.done();
  assert.equal(p.posts().length, 1);                    // it WAS sent
  assert.equal(r.outcome, 'uncertain', JSON.stringify({ outcome: r.outcome, definite: r.definite, reason: r.reason, detail: r.detail }));
});

// Python parity (_publish_in_browser: status <= 0 -> PublishUncertainError): a response with status 0 is not a rejection.
test('publish result: load event with HTTP status 0 -> uncertain (Python: status <= 0 is uncertain)', async () => {
  const p = page({ xhr: (x) => x.reply(0, '') });
  p.run();
  const r = await p.done();
  assert.equal(p.posts().length, 1);
  assert.equal(r.outcome, 'uncertain', JSON.stringify(r));
});

// ---------- SDK readiness ----------
test('SDK never wraps send -> nothing authorized, nothing sent (definite)', { timeout: 40000 }, async () => {
  const p = page({ sdk: 'none' });
  p.run();
  const r = await p.done(36000);
  assert.deepEqual([r.outcome, r.definite, p.authReqs.length, p.posts().length], ['failed', true, 0, 0]);
  assert.match(r.reason, /sdk-not-ready/);
});

// ---------- R6: secrets never reach postMessage (page-visible, forwarded to the SW/dev server log) ----------
test('no STS secret, session token or storage Auth in any message leaving the MAIN world', async () => {
  const p = page();
  p.run();
  const r = await p.done();
  const all = JSON.stringify(p.msgs) + JSON.stringify(r);
  for (const s of [STS.secret_acess_key, STS.session_token, STORE_AUTH, STS.access_key_id]) assert.equal(all.includes(s), false, 'leaked ' + s.slice(0, 6));
});
