// Pure helpers ported from integrations/autotok (uploader.py, captions.py). Loaded in the page's MAIN world
// (globalThis.AutotokLib) and in Node for the offline parity tests (module.exports). No DOM, no network.
(function (root) {
  'use strict';
  const enc = new TextEncoder();
  const CHUNK_SIZE = 5 * 1024 * 1024;            // uploader.py:86
  const MAX_CAPTION_LENGTH = 2200;               // uploader.py:78
  const MIN_SCHEDULE_S = 15 * 60;                // uploader.py:79
  const MAX_SCHEDULE_S = 30 * 24 * 3600;         // uploader.py:80
  const MAX_SCHEDULE_SHIFT_S = 10 * 60;          // uploader.py:84

  const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
  const sha256Hex = async (data) => hex(await crypto.subtle.digest('SHA-256', typeof data === 'string' ? enc.encode(data) : data));
  async function hmac(key, msg) {
    const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
  }

  // ---- CRC32 (uploader.py:261): lower-case 8-digit hex ----
  const TABLE = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
  function crc32Hex(bytes) {
    const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    let c = 0xFFFFFFFF;
    for (let i = 0; i < u.length; i++) c = TABLE[(c ^ u[i]) & 0xFF] ^ (c >>> 8);
    return ((c ^ 0xFFFFFFFF) >>> 0).toString(16).padStart(8, '0');
  }

  // ---- part splitting (uploader.py:493-515): [start, end) ranges; an empty file has no parts ----
  function splitParts(size, part) {
    part = part || CHUNK_SIZE;
    const out = [];
    for (let s = 0; s < size; s += part) out.push([s, Math.min(s + part, size)]);
    return out;
  }

  // ---- AWS SigV4 exactly as requests_auth_aws_sigv4 0.7 does it (see parity fixtures) ----
  // Signed headers: host + every x-amz-* header. Query values are used as-is (not re-encoded).
  async function sigv4({ method, url, body, accessKeyId, secretAccessKey, sessionToken, region, service, now }) {
    const u = new URL(url);
    const d = now instanceof Date ? now : new Date();
    const amzdate = d.toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
    const datestamp = amzdate.slice(0, 8);
    const qs = new Map();
    if (u.search.length > 1) for (const kv of u.search.slice(1).split('&')) { const i = kv.indexOf('='); qs.set(kv.slice(0, i), kv.slice(i + 1)); }
    const canonicalQuery = Array.from(qs.entries()).sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0)).map((p) => p.join('=')).join('&');
    const payloadHash = await sha256Hex(method === 'GET' || !body ? '' : body);
    const h = { host: u.hostname, 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzdate };
    if (sessionToken != null) h['x-amz-security-token'] = sessionToken;
    const names = Object.keys(h).sort();
    const canonicalHeaders = names.map((n) => n + ':' + h[n] + '\n').join('');
    const signedHeaders = names.join(';');
    const canonicalRequest = [method, u.pathname, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join('\n');
    const scope = [datestamp, region, service, 'aws4_request'].join('/');
    const stringToSign = ['AWS4-HMAC-SHA256', amzdate, scope, await sha256Hex(canonicalRequest)].join('\n');
    let k = await hmac(enc.encode('AWS4' + secretAccessKey), datestamp);
    for (const m of [region, service, 'aws4_request']) k = await hmac(k, m);
    const signature = hex(await hmac(k, stringToSign));
    const headers = { 'x-amz-date': amzdate, 'x-amz-content-sha256': payloadHash,
      Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}` };
    if (sessionToken != null) headers['x-amz-security-token'] = sessionToken;
    return { headers, canonicalRequest, stringToSign, signature };
  }

  // ---- Python semantics that differ from JS ----
  // str.strip() whitespace (str.isspace) vs String.trim(): explicit set from `chr(c).isspace()`.
  const PY_SPACE = /^[\t-\r\x1c-\x20\x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\t-\r\x1c-\x20\x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/g;
  const pyStrip = (s) => s.replace(PY_SPACE, '');
  const codePointLength = (s) => Array.from(s).length;       // Python len(str)

  function validateCaption(caption) {
    if (typeof caption !== 'string' || !pyStrip(caption)) return 'caption is required';
    if (codePointLength(caption) > MAX_CAPTION_LENGTH) return `caption must be at most ${MAX_CAPTION_LENGTH} characters`;
    return null;
  }

  // ---- caption markup (captions.py:17-71). Python \w on str == str.isalnum() or '_' ----
  const TOKEN_RE = () => /#([\p{L}\p{N}_]+)|@([A-Za-z0-9_.]*[A-Za-z0-9_])/gu;
  function mentionsIn(text) { const out = []; for (const m of text.matchAll(TOKEN_RE())) if (m[2]) out.push(m[2]); return out; }

  // userIds: {username: numericId} for mentions that resolved; anything else stays plain text.
  function buildCaption(text, userIds) {
    const markup = [], extras = [];
    let offset = 0, last = 0, nextId = 0;
    for (const m of text.matchAll(TOKEN_RE())) {
      const plain = text.slice(last, m.index);
      markup.push(plain);
      offset += plain.length;                       // JS length == UTF-16 units == Python utf16_len
      const token = m[0];
      if (m[1]) {
        extras.push({ end: offset + token.length, hashtag_name: m[1], start: offset, tag_id: String(nextId), type: 1, user_id: '' });
        markup.push(`<h id="${nextId}">${token}</h>`); nextId++;
      } else {
        const uid = userIds && userIds[m[2]];
        if (uid) {
          extras.push({ end: offset + token.length, hashtag_name: '', start: offset, tag_id: String(nextId), type: 0, user_id: String(uid) });
          markup.push(`<m id="${nextId}">${token}</m>`); nextId++;
        } else markup.push(token);
      }
      offset += token.length;
      last = m.index + token.length;
    }
    markup.push(text.slice(last));
    return { markup: markup.join(''), textExtra: extras };
  }

  // ---- visibility / schedule (uploader.py:253, 234-252, 416-428) ----
  function visibilityCode(v) {
    const map = { public: 0, private: 1 };
    if (!Object.prototype.hasOwnProperty.call(map, v)) throw new Error("visibility must be 'public' or 'private' (friends is not supported)");
    return map[v];
  }
  // Returns the unix timestamp to send, or null for an immediate post. Throws on invalid input.
  function resolveSchedule(scheduleSec, nowSec, vis) {
    if (scheduleSec == null) return null;
    const delay = scheduleSec - nowSec;
    if (delay < MIN_SCHEDULE_S || delay > MAX_SCHEDULE_S) throw new Error('TikTok only accepts schedules between 15 minutes and 30 days ahead');
    if (vis === 1) throw new Error('TikTok does not allow scheduling private videos');
    return scheduleSec;
  }
  // Called after the upload: the time may have slipped under 15 min.
  function finalizeSchedule(scheduleSec, nowSec) {
    const earliest = nowSec + MIN_SCHEDULE_S;
    if (scheduleSec >= earliest) return scheduleSec;
    if (earliest - scheduleSec > MAX_SCHEDULE_SHIFT_S) throw new Error('Tải video quá lâu, giờ hẹn không còn hợp lệ — hãy chọn giờ mới');
    return earliest;
  }

  // ---- post body (uploader.py:543-598) ----
  function buildPayload({ creationId, videoId, caption, markup, textExtra, visibility, allowComment = true, allowDuet = false, allowStitch = false, aiLabel = false, probe = null, scheduleTime = null }) {
    const feature = {
      geofencing_regions: [], playlist_name: '', playlist_id: '', tcm_params: '{"commerce_toggle_info":{}}',
      sound_exemption: 0, music_copyright: { result: 1 }, anchors: [],
      vedit_common_info: { draft: '', video_id: videoId },
      privacy_setting_info: { visibility_type: visibility, allow_duet: +!!allowDuet, allow_stitch: +!!allowStitch, allow_comment: +!!allowComment, allow_content_reuse: 1, allow_ai_remix: 2 },
      content_check_id: '',
    };
    if (aiLabel) feature.aigc_info = { aigc_label_type: 1 };
    const info = { text: caption, text_extra: textExtra, markup_text: markup, music_info: { origin_volume: '100' }, poster_delay: 0,
      cloud_edit_is_use_video_canvas: false, is_upload_audio_track: false, mature_theme_type: 0 };
    if (probe) {
      if (probe.width && probe.height) { info.cloud_edit_video_width = probe.width; info.cloud_edit_video_height = probe.height; }
      if (probe.duration_ms) info.video_track_time_range_list = [{ start_time_in_ms: 0, end_time_in_ms: probe.duration_ms }];
      if ('has_audio' in probe) info.has_original_audio = probe.has_audio ? 1 : 0;
    }
    if (scheduleTime != null) feature.schedule_time = scheduleTime;
    return { post_common_info: { creation_id: creationId, enter_post_page_from: 8, post_type: 3 }, feature_common_info_list: [feature],
      single_post_req_list: [{ batch_index: 0, video_id: videoId, is_long_video: 0, single_post_feature_info: info }] };
  }

  const api = { CHUNK_SIZE, MAX_CAPTION_LENGTH, crc32Hex, splitParts, sigv4, sha256Hex, pyStrip, codePointLength, validateCaption, TOKEN_RE, mentionsIn,
    buildCaption, visibilityCode, resolveSchedule, finalizeSchedule, buildPayload };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.AutotokLib = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
