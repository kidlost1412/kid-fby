// End-to-end harness: the REAL backend (python subprocess) + the REAL extension files (sw.js, content.js, hook-main.js,
// api-main.js, lib.js) running in Node vm contexts with minimal chrome.* / page shims, against a fake TikTok per profile.
// Nothing here can reach TikTok: every tiktok.com / upload-host URL is routed to a local fake server.
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { resolveObjectURL } = require('node:buffer');
const { DatabaseSync } = require('node:sqlite');

const EXT = path.resolve(__dirname, '..', '..');
const SRC = path.resolve(EXT, '..', 'autotok', 'src');
const PY = process.env.E2E_PYTHON || 'C:\\Users\\hp\\AppData\\Local\\Temp\\claude\\D--reup-video-fb-meta\\907a531c-3a1e-4f3a-b228-0f0a3741c294\\scratchpad\\devvenv\\Scripts\\python.exe';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const unref = (f, ms) => { const t = setTimeout(f, ms); if (t.unref) t.unref(); return t; };
const ITEM_ID = '7701245450858351893';

async function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
    s.on('error', reject);
  });
}

async function waitFor(fn, { timeout = 30000, interval = 150, what = 'condition' } = {}) {
  const t0 = Date.now();
  for (;;) {
    let v; try { v = await fn(); } catch (_) { v = null; }
    if (v) return v;
    if (Date.now() - t0 > timeout) throw new Error('timeout waiting for ' + what);
    await sleep(interval);
  }
}

// ---------------------------------------------------------------- real backend
class Backend {
  static async start(deadlines = {}) {
    const b = new Backend();
    b.work = fs.mkdtempSync(path.join(os.tmpdir(), 'autotok-e2e-'));
    b.port = await freePort();
    b.base = `http://127.0.0.1:${b.port}`;
    // AUTOTOK_CHROME_LAUNCH=off: the backend must never open the owner's real Chrome from the harness.
    const env = Object.assign({}, process.env, { PYTHONIOENCODING: 'utf-8', PYTHONPATH: '', AUTOTOK_CHROME_LAUNCH: 'off' }, {
      E2E_CLAIM_WITHIN: '10', E2E_STALE_AFTER: '60', E2E_UPLOAD_WITHIN: '60', E2E_RESULT_WITHIN: '4' }, deadlines);
    b.proc = spawn(PY, ['-I', path.join(__dirname, 'backend_launcher.py'), '--src', SRC, '--work', b.work, '--port', String(b.port)], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    b.log = '';
    for (const s of [b.proc.stdout, b.proc.stderr]) s.on('data', (d) => { b.log += d.toString(); });
    await waitFor(async () => (await fetch(b.base + '/health')).ok, { timeout: 40000, what: 'backend /health\n' + (b.log || '') });
    return b;
  }
  async gui(method, p, body) {   // the way the GUI calls: local, no Origin, CSRF header
    const init = { method, headers: { 'X-Requested-With': 'autotok' } };
    if (body !== undefined) { init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(body); }
    const r = await fetch(this.base + p, init);
    const text = await r.text();
    let json = null; try { json = JSON.parse(text); } catch (_) { /* not JSON */ }
    return { status: r.status, json, text };
  }
  db(sql, ...args) {
    const d = new DatabaseSync(path.join(this.work, 'data', 'tiktok.db'), { readOnly: true });
    try { return d.prepare(sql).all(...args); } finally { d.close(); }
  }
  cookieCalls() { try { return fs.readFileSync(path.join(this.work, 'cookie_calls.txt'), 'utf8').split('\n').filter(Boolean); } catch (_) { return []; } }
  async submit({ username, visibility = 0, scheduledFor = '', options = {}, title = 'Xin chào 🌸 #việtnam #tiktok' }) {
    const rid = crypto.randomBytes(16).toString('hex');
    const fd = new FormData();
    fd.set('request_id', rid); fd.set('username', username); fd.set('title', title); fd.set('scheduled_for', scheduledFor);
    fd.set('options_json', JSON.stringify(Object.assign({ visibility_type: visibility }, options)));
    const bytes = Buffer.alloc(1536 * 1024, 7); bytes.write('\0\0\0\x18ftypisom', 0, 'latin1');   // > one 1 MiB SW chunk
    fd.set('video', new Blob([bytes], { type: 'video/mp4' }), 'clip.mp4');
    const r = await fetch(this.base + '/api/desktop/jobs', { method: 'POST', headers: { 'X-Requested-With': 'autotok' }, body: fd });
    const j = await r.json();
    if (r.status !== 200) throw new Error('submit failed ' + r.status + ' ' + JSON.stringify(j));
    return Object.assign({ rid }, j);
  }
  async job(rid) { return (await this.gui('GET', '/api/desktop/jobs/' + rid)).json; }
  parent(scheduleId) { return this.db('SELECT status, publish_uncertain, attempts, result_text FROM scheduled_uploads WHERE id=?', scheduleId)[0]; }
  child(scheduleId) { return this.db('SELECT id, state, note, finalized_state, authorized_at, claim_client FROM extension_jobs WHERE schedule_id=? ORDER BY attempt DESC', scheduleId)[0]; }
  history(rid) { return this.db('SELECT status, publish_uncertain, prior_uncertain, post_id, tiktok_schedule_time, result_text FROM upload_history WHERE request_id=?', rid)[0]; }
  async stop() {
    if (process.env.E2E_DUMP) fs.writeFileSync(process.env.E2E_DUMP, this.log);
    try { this.proc.kill(); } catch (_) { /* gone */ }
    await sleep(300);
    try { fs.rmSync(this.work, { recursive: true, force: true }); } catch (_) { /* sqlite file may still be locked on Windows */ }
  }
}

// ---------------------------------------------------------------- fake TikTok (one per Chrome profile)
class FakeTikTok {
  constructor(identity) {
    this.identity = identity;                    // {username, userId} the passport endpoint reports
    this.counts = { passport: 0, create: 0, auth: 0, apply: 0, parts: 0, finish: 0, commit: 0, publish: 0 };
    this.publishes = [];                         // {url, body, json}
    this.onPart = null;                          // async (n) => void; may hang forever
    this.badSig = 0;
    this.itemId = ITEM_ID;
    this.publishReply = null;                    // (json) => {status, body}
  }
  async start() {
    this.server = http.createServer((req, res) => this.handle(req, res));
    this.sockets = new Set();
    this.server.on('connection', (s) => { this.sockets.add(s); s.on('close', () => this.sockets.delete(s)); });
    await new Promise((r) => this.server.listen(0, '127.0.0.1', r));
    this.base = `http://127.0.0.1:${this.server.address().port}`;
    return this;
  }
  stop() { for (const s of this.sockets) s.destroy(); this.server.close(); }
  async handle(req, res) {
    const chunks = []; for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);
    const u = new URL(req.url, 'http://x');
    const send = (code, obj) => { const t = typeof obj === 'string' ? obj : JSON.stringify(obj); res.writeHead(code, { 'content-type': 'application/json' }); res.end(t); };
    const p = u.pathname;
    if (p === '/passport/web/account/info/') { this.counts.passport++; return send(200, { data: { username: this.identity.username, user_id_str: this.identity.userId } }); }
    if (p === '/api/v1/web/project/create/') { this.counts.create++; return send(200, { project: { id: 'p1' } }); }
    if (p === '/api/v1/video/upload/auth/') { this.counts.auth++; return send(200, { video_token_v5: { access_key_id: 'AKIDFAKE', secret_acess_key: 'FAKESECRET', session_token: 'FAKETOKEN' } }); }
    if (p === '/top/v1') {
      const auth = String(req.headers.authorization || '');
      if (!auth.startsWith('AWS4-HMAC-SHA256 Credential=AKIDFAKE/') || !req.headers['x-amz-security-token'] || !req.headers['x-amz-date']) this.badSig++;
      if (u.searchParams.get('Action') === 'ApplyUploadInner') { this.counts.apply++; return send(200, { Result: { InnerUploadAddress: { UploadNodes: [{ Vid: 'v14025fake', SessionKey: 'sk-1', UploadHost: 'up.fake', StoreInfos: [{ StoreUri: 'tos/abc', Auth: 'STOREAUTH' }] }] } } }); }
      this.counts.commit++; return send(200, { Result: {} });
    }
    if (p.startsWith('/up/')) {
      if (u.searchParams.get('phase') === 'transfer') {
        const n = Number(u.searchParams.get('partNumber'));
        const crc = (zlib.crc32(body) >>> 0).toString(16).padStart(8, '0');
        if (req.headers['content-crc32'] !== crc) this.badSig++;
        this.counts.parts++;
        if (this.onPart) await this.onPart(n);
        return send(200, { ok: 1 });
      }
      this.counts.finish++; return send(200, { ok: 1 });
    }
    if (p.startsWith('/@')) { res.writeHead(200); return res.end('<html></html>'); }
    if (p === '/tiktok/web/project/post/v1/') {
      this.counts.publish++;
      let json = null; try { json = JSON.parse(body.toString('utf8')); } catch (_) { /* recorded raw */ }
      this.publishes.push({ url: req.url, body: json });
      if (this.publishReply) { const r = this.publishReply(json); return send(r.status, r.body); }
      return send(200, { status_code: 0, status_msg: '', data: { item_id: this.itemId } });
    }
    send(404, { error: 'fake: no route ' + p });
  }
}

// ---------------------------------------------------------------- Chrome profile: real sw.js + pages
class Page {
  constructor(profile, tabId, windowId, url) {
    this.profile = profile; this.tabId = tabId; this.windowId = windowId; this.url = url; this.closed = false;
    const fake = profile.fake;
    const listeners = [];
    const self = this;
    class XHR extends EventTarget {
      constructor() { super(); this.readyState = 0; this.status = 0; this.responseText = ''; this.withCredentials = false; this.timeout = 0; }
      open(m, u) { this.m = m; this.u = u; this.readyState = 1; }
      setRequestHeader() {}
      send(body) {            // the browser's native send: goes to the fake TikTok through the profile's network
        self.fetchImpl(this.u, { method: this.m, body }).then(async (r) => { this.status = r.status; this.responseText = await r.text(); this.readyState = 4; for (const t of ['readystatechange', 'load', 'loadend']) this.dispatchEvent(new Event(t)); },
          () => { this.readyState = 4; for (const t of ['readystatechange', 'error', 'loadend']) this.dispatchEvent(new Event(t)); });
      }
      dispatchEvent(e) { const h = this['on' + e.type]; if (typeof h === 'function') h.call(this, e); return super.dispatchEvent(e); }
    }
    const win = {
      XMLHttpRequest: XHR, fetch: (u, i) => this.fetchImpl(u, i), URL, Blob, Response, Event, ProgressEvent: Event, EventTarget, TextEncoder, TextDecoder,
      crypto: globalThis.crypto, atob, btoa, AbortController, Intl, performance: { now: () => performance.now() },
      setTimeout: unref, clearTimeout, setInterval: (f, ms) => { const t = setInterval(f, ms); t.unref(); return t; }, clearInterval,
      console: { log() {}, warn() {}, error() {}, info() {} },
      location: { origin: 'https://www.tiktok.com', href: url, pathname: new URL(url).pathname, hash: new URL(url).hash },
      document: { readyState: 'complete', visibilityState: 'hidden',
        createElement: () => { const v = { videoWidth: 720, videoHeight: 1280, duration: 15.2, removeAttribute() {}, load() {} }; Object.defineProperty(v, 'src', { set() { setTimeout(() => v.onloadedmetadata && v.onloadedmetadata(), 0); } }); return v; } },
      chrome: { runtime: { sendMessage: (m) => profile.dispatch(m, { tab: { id: tabId, url, windowId } }) } },
      addEventListener: (t, f) => { if (t === 'message') listeners.push(f); },
      postMessage: (m) => { if (self.closed) return; const data = JSON.parse(JSON.stringify(m)); setTimeout(() => listeners.slice().forEach((f) => f({ source: inner, data })), 0); },
    };
    vm.createContext(win);
    const inner = vm.runInContext('globalThis', win);
    win.window = inner; win.top = inner;
    this.win = win;
    for (const f of ['lib.js', 'hook-main.js', 'api-main.js']) vm.runInContext(fs.readFileSync(path.join(EXT, f), 'utf8'), win, { filename: f });
    const below = win.XMLHttpRequest.prototype.send;                         // the page's signing SDK wraps send AFTER our hook
    win.XMLHttpRequest.prototype.send = function (b) { return below.call(this, b); };
    this.publishUrls = [];
    vm.runInContext(fs.readFileSync(path.join(EXT, 'content.js'), 'utf8'), win, { filename: 'content.js' });
  }
  async fetchImpl(url, init) {
    if (this.closed) throw new TypeError('Failed to fetch (page closed)');
    return this.profile.routedFetch(url, init, 'page');
  }
  close() { this.closed = true; }
}

class Profile {
  // store: persistent chrome.storage (share it across Profile instances to simulate an extension update / SW restart)
  constructor({ backend, fake, store = {}, protocol = 1, name = 'profile' }) {
    this.backend = backend; this.fake = fake; this.store = store; this.name = name;
    this.inflight = new Set();
    this.requests = [];            // every backend call: {path, method}
    this.cut = false;              // Chrome gone: no request leaves the profile
    this.failIf = null;            // (path, init) => true -> that backend request is lost
    this.onMsg = []; this.pages = new Map(); this.nextId = 100; this.removedListeners = [];
    const ev = () => ({ addListener() {} });
    const tabInfo = (p) => ({ id: p.tabId, windowId: p.windowId, url: p.url });
    const open = (url, win) => { const id = this.nextId++; const wid = win ?? id + 1000; const page = new Page(this, id, wid, url); this.pages.set(id, page); return { id, wid, page }; };
    this.chrome = {
      storage: { local: {
        get: async (k) => { const keys = k == null ? Object.keys(this.store) : [].concat(k); const o = {}; for (const x of keys) if (x in this.store) o[x] = JSON.parse(JSON.stringify(this.store[x])); return o; },
        set: async (o) => { for (const [k, v] of Object.entries(o)) this.store[k] = JSON.parse(JSON.stringify(v)); },
        remove: async (k) => { for (const x of [].concat(k)) delete this.store[x]; } } },
      alarms: { create() {}, onAlarm: ev() },
      runtime: { onMessage: { addListener: (f) => this.onMsg.push(f) }, onStartup: ev(), onInstalled: ev(), getManifest: () => ({ version: '1.0.0' }) },
      tabs: {
        query: async () => [...this.pages.values()].filter((p) => !p.closed).map(tabInfo),
        get: async (id) => { const p = this.pages.get(id); if (!p || p.closed) throw new Error('No tab with id ' + id); return tabInfo(p); },
        update: async () => {}, onRemoved: { addListener: (f) => this.removedListeners.push(f) }, onReplaced: ev(),
        create: async ({ url }) => { const o = open(url); return { id: o.id, windowId: o.wid }; },
        remove: async (id) => this.closeTab(id),
      },
      windows: { create: async ({ url }) => { const o = open(url); return { id: o.wid, tabs: [{ id: o.id }] }; },
        remove: async (wid) => { for (const p of this.pages.values()) if (p.windowId === wid) this.closeTab(p.tabId); } },
    };
    let swSource = fs.readFileSync(path.join(EXT, 'sw.js'), 'utf8');
    if (protocol !== 1) { if (!swSource.includes('const PROTOCOL = 1;')) throw new Error('sw.js PROTOCOL constant not found'); swSource = swSource.replace('const PROTOCOL = 1;', `const PROTOCOL = ${protocol};`); }
    const ctx = { chrome: this.chrome, fetch: (u, i) => this.routedFetch(u, i, 'sw'), setTimeout: unref, clearTimeout, AbortController, btoa, URL,
      console: { log() {}, warn() {}, error() {} } };
    vm.createContext(ctx);
    if (!this.store.settings) this.store.settings = { server: backend.base, polling: true, windowStrategy: 'minimized' };
    vm.runInContext(swSource, ctx, { filename: 'sw.js' });
  }
  closeTab(id) { const p = this.pages.get(id); if (p) { p.close(); this.pages.delete(id); for (const f of this.removedListeners) f(id, { isWindowClosing: false, windowId: p.windowId }); } }
  dispatch(msg, sender) {
    return new Promise((resolve) => { for (const f of this.onMsg) if (f(msg, sender || {}, resolve) === true) return; resolve(undefined); });
  }
  // All profile traffic: TikTok -> this profile's fake; backend -> the real backend (with fault injection).
  async routedFetch(url, init = {}, who) {
    if (this.cut) throw new TypeError('Failed to fetch (profile cut)');
    let target = String(url);
    if (target.startsWith('blob:')) { const b = resolveObjectURL(target); if (!b) throw new TypeError('bad blob'); return new Response(b); }
    if (target.startsWith(this.backend.base)) {
      const pth = new URL(target).pathname;
      this.requests.push({ path: pth, method: init.method || 'GET', who });
      if (this.failIf && this.failIf(pth, init)) throw new TypeError('Failed to fetch (injected)');
      const ctl = new AbortController();             // Chrome closing aborts in-flight requests (see cutNow)
      this.inflight.add(ctl);
      if (init.signal) init.signal.addEventListener('abort', () => ctl.abort());
      try { return await fetch(target, Object.assign({}, init, { signal: ctl.signal })); } finally { this.inflight.delete(ctl); }
    }
    if (target.startsWith('https://up.fake/')) target = this.fake.base + '/up/' + target.slice('https://up.fake/'.length);
    else if (target.startsWith('https://www.tiktok.com/')) target = this.fake.base + target.slice('https://www.tiktok.com'.length);
    else if (target.startsWith('/')) target = this.fake.base + target;
    else throw new Error('e2e: refusing to fetch unknown URL ' + target);
    return fetch(target, init);
  }
  cutNow() { this.cut = true; for (const c of this.inflight) c.abort(); }   // Chrome exits: pending requests die with it
  send(msg) { return this.dispatch(msg, {}); }
  get conn() { return this.store.conn; }
  stop() { for (const p of this.pages.values()) p.close(); }
}

// pair through the popup path (code from the GUI endpoint), then create the account the way the GUI does
async function connect(backend, { username, userId, name, store, protocol }) {
  const fake = await new FakeTikTok({ username, userId }).start();
  const profile = new Profile({ backend, fake, store, protocol, name });
  const code = (await backend.gui('POST', '/api/ext/pair-code')).json.code;
  await profile.send({ popup: 'pair', code });
  await waitFor(() => profile.store.conn && profile.store.conn.state === 'ok', { what: 'pairing + hello ok (' + JSON.stringify(profile.store.pairError || profile.store.conn) + ')' });
  const clients = (await backend.gui('GET', '/api/ext/clients')).json;
  const client = clients.find((c) => c.tiktok_user_id === userId);
  const acct = await backend.gui('POST', '/api/accounts/from-chrome', { client_id: client.id });
  if (acct.status !== 201) throw new Error('from-chrome failed ' + acct.status + ' ' + acct.text);
  return { profile, fake, client, account: acct.json };
}

module.exports = { Backend, FakeTikTok, Profile, connect, waitFor, sleep, ITEM_ID, EXT };
