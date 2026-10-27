// MAIN-world hook, run_at document_start (before TikTok's SDK wraps XMLHttpRequest/fetch).
// - Unarmed: pure pass-through, only watches JSON responses for account identity.
// - Armed by content.js with a per-job nonce: captures POST /tiktok/web/project/post/v1/
//   (request body + response) and relays to content.js via window.postMessage.
//   mode 'block' (selftest/intercept): the request is NOT sent; the page gets a fake success response.
//   mode 'pass' (post): the request goes through and the real response is relayed.
(function () {
  if (window.__autotokHook) return;
  window.__autotokHook = true;

  const POST_RE = /\/tiktok\/web\/project\/post\/v1\//;
  const IDENT_URL_RE = /(account|user|creator|profile|passport)/i;
  const MAX_BODY = 64 * 1024;
  const MAX_RESP = 16 * 1024;
  const st = { nonce: null, mode: 'off', pending: [] };

  const nativeFetch = window.fetch;
  const nativeOpen = XMLHttpRequest.prototype.open;
  const nativeSend = XMLHttpRequest.prototype.send;
  const meta = new WeakMap();

  function relay(kind, data) {
    const msg = Object.assign({ __autotok: 1, kind, t: Date.now() }, data);
    if (kind === 'identity' && !st.nonce) { if (st.pending.length < 30) st.pending.push(msg); return; }
    msg.nonce = st.nonce;
    window.postMessage(msg, location.origin);
  }

  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.__autotok !== 1 || d.kind !== 'arm') return;
    st.nonce = String(d.nonce || '');
    st.mode = d.mode === 'pass' ? 'pass' : 'block'; // anything unknown is the safe choice
    for (const m of st.pending.splice(0)) { m.nonce = st.nonce; window.postMessage(m, location.origin); }
    window.postMessage({ __autotok: 1, kind: 'armed', nonce: st.nonce, mode: st.mode }, location.origin);
  });

  const isPost = (method, url) => String(method).toUpperCase() === 'POST' && POST_RE.test(String(url));

  function bodyText(b) {
    if (typeof b === 'string') return b.slice(0, MAX_BODY);
    if (b == null) return '';
    return '[non-string body: ' + Object.prototype.toString.call(b) + ']';
  }

  function scanIdentity(url, text) {
    try {
      if (!IDENT_URL_RE.test(url) || !text || text.length > 200000 || text[0] !== '{') return;
      const j = JSON.parse(text);
      const found = [];
      (function walk(o, depth) {
        if (!o || typeof o !== 'object' || depth > 4) return;
        for (const k of Object.keys(o)) {
          const v = o[k];
          if (typeof v === 'string' && /^(unique_?id|username|user_?name)$/i.test(k) && v.length < 40) found.push([k, v]);
          else if (typeof v === 'object') walk(v, depth + 1);
        }
      })(j, 0);
      if (found.length) relay('identity', { src: new URL(url, location.href).pathname, found: found.slice(0, 4) });
    } catch (_) { /* not JSON / unrelated response: ignore */ }
  }

  // ---- XHR ----
  XMLHttpRequest.prototype.open = function (method, url) {
    meta.set(this, { method: String(method), url: String(url) });
    return nativeOpen.apply(this, arguments);
  };

  function fakeXhr(xhr, url, text) {
    const def = (k, v) => Object.defineProperty(xhr, k, { configurable: true, get: () => v });
    def('readyState', 4); def('status', 200); def('statusText', 'OK');
    def('responseText', text); def('responseURL', url);
    def('response', xhr.responseType === 'json' ? JSON.parse(text) : text);
    xhr.getResponseHeader = (n) => (/content-type/i.test(n) ? 'application/json' : null);
    xhr.getAllResponseHeaders = () => 'content-type: application/json\r\n';
    setTimeout(() => {
      xhr.dispatchEvent(new Event('readystatechange'));
      for (const t of ['load', 'loadend']) xhr.dispatchEvent(new ProgressEvent(t));
    }, 0);
  }

  XMLHttpRequest.prototype.send = function (body) {
    const m = meta.get(this);
    if (m && st.nonce && isPost(m.method, m.url)) {
      const t0 = Date.now();
      const path = new URL(m.url, location.href).pathname;
      relay('req', { via: 'xhr', path, body: bodyText(body) });
      if (st.mode === 'block') {
        relay('res', { via: 'xhr', path, blocked: true, status: 200, text: '', reqT: t0 });
        fakeXhr(this, m.url, JSON.stringify({ status_code: 0, status_msg: '', autotok_intercepted: true }));
        return;
      }
      this.addEventListener('loadend', () => {
        let text = '';
        try { text = typeof this.responseText === 'string' ? this.responseText : JSON.stringify(this.response); } catch (_) { text = '[unreadable response]'; }
        relay('res', { via: 'xhr', path, blocked: false, status: this.status, text: text.slice(0, MAX_RESP), reqT: t0 });
      });
    } else if (m) {
      this.addEventListener('load', () => {
        try { if (typeof this.responseText === 'string') scanIdentity(m.url, this.responseText); } catch (_) { /* responseType not text */ }
      });
    }
    return nativeSend.apply(this, arguments);
  };

  // ---- fetch ----
  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    const method = (init && init.method) || (input && input.method) || 'GET';
    if (st.nonce && isPost(method, url)) {
      let body = init && init.body;
      if (body === undefined && input && typeof input.clone === 'function') {
        try { body = await input.clone().text(); } catch (_) { body = null; }
      }
      const t0 = Date.now();
      const path = new URL(url, location.href).pathname;
      relay('req', { via: 'fetch', path, body: bodyText(body) });
      if (st.mode === 'block') {
        relay('res', { via: 'fetch', path, blocked: true, status: 200, text: '', reqT: t0 });
        return new Response(JSON.stringify({ status_code: 0, status_msg: '', autotok_intercepted: true }),
          { status: 200, headers: { 'content-type': 'application/json' } });
      }
      const resp = await nativeFetch.apply(this, arguments);
      resp.clone().text().then((text) => relay('res', { via: 'fetch', path, blocked: false, status: resp.status, text: text.slice(0, MAX_RESP), reqT: t0 }),
        () => relay('res', { via: 'fetch', path, blocked: false, status: resp.status, text: '[unreadable response]', reqT: t0 }));
      return resp;
    }
    const resp = await nativeFetch.apply(this, arguments);
    if (IDENT_URL_RE.test(url) && /json/i.test(resp.headers.get('content-type') || '')) {
      resp.clone().text().then((t) => scanIdentity(url, t), () => {});
    }
    return resp;
  };
})();
