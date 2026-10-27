// MAIN-world hook, run_at document_start (before TikTok's SDK wraps XMLHttpRequest/fetch).
// Policy for POST /tiktok/web/project/post/v1/ once armed by content.js (per-job nonce):
//   - EVERYTHING is blocked (never fabricated as success: the page sees a network error, we report 'blocked')
//     except the one XHR object api-main.js hands to allow() right before its own send. allow() is single-shot.
//   - fetch to that endpoint is always blocked (our publisher uses XHR only, as browser_publish.py does).
// Unarmed: pure pass-through.
(function () {
  if (window.__autotokHook) return;

  const POST_RE = /\/tiktok\/web\/project\/post\/v1\//;
  const MAX_BODY = 64 * 1024;
  const st = { nonce: null, allowed: null };

  const nativeFetch = window.fetch;
  const nativeOpen = XMLHttpRequest.prototype.open;
  const nativeSend = XMLHttpRequest.prototype.send;
  const meta = new WeakMap();

  function relay(kind, data) {
    window.postMessage(Object.assign({ __autotok: 1, kind, t: Date.now(), nonce: st.nonce }, data), location.origin);
  }

  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.__autotok !== 1 || d.kind !== 'arm') return;
    st.nonce = String(d.nonce || '');
    window.postMessage({ __autotok: 1, kind: 'armed', nonce: st.nonce }, location.origin);
  });

  const isPost = (method, url) => String(method).toUpperCase() === 'POST' && POST_RE.test(String(url));
  const bodyText = (b) => (typeof b === 'string' ? b.slice(0, MAX_BODY) : b == null ? '' : '[non-string body: ' + Object.prototype.toString.call(b) + ']');

  XMLHttpRequest.prototype.open = function (method, url) {
    meta.set(this, { method: String(method), url: String(url) });
    return nativeOpen.apply(this, arguments);
  };

  // The page sees a plain network error (status 0), never a success.
  function failXhr(xhr) {
    xhr.__autotokBlocked = true;
    const def = (k, v) => Object.defineProperty(xhr, k, { configurable: true, get: () => v });
    def('readyState', 4); def('status', 0); def('responseText', '');
    setTimeout(() => {
      xhr.dispatchEvent(new Event('readystatechange'));
      for (const t of ['error', 'loadend']) xhr.dispatchEvent(new ProgressEvent(t));
    }, 0);
  }

  const send = function (body) {
    const m = meta.get(this);
    if (m && st.nonce && isPost(m.method, m.url)) {
      const ok = st.allowed === this;
      st.allowed = null;                                   // single-shot, whatever happens next
      relay('req', { via: 'xhr', path: new URL(m.url, location.href).pathname, body: bodyText(body), allowed: ok });
      if (!ok) { relay('blocked', { via: 'xhr' }); failXhr(this); return; }
      return nativeSend.apply(this, arguments);
    }
    return nativeSend.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = send;

  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    const method = (init && init.method) || (input && input.method) || 'GET';
    if (st.nonce && isPost(method, url)) {
      relay('blocked', { via: 'fetch' });
      throw new TypeError('blocked by autotok (publish is XHR-only)');
    }
    return nativeFetch.apply(this, arguments);
  };

  // api-main.js uses this. `wrapperSend` lets it detect that the page's SDK wrapped XHR.send on top of ours.
  window.__autotokHook = {
    allow(xhr) { st.allowed = xhr; },
    wrapperSend: send,
    nativeSend,
    armed: () => !!st.nonce,
  };
})();
