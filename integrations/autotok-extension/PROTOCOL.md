# Kid FB.Y backend <-> Chrome extension protocol (v1)

Binding contract between the autotok backend (`integrations/autotok/src/web`, FastAPI on
`http://127.0.0.1:8765`) and the AutoTok Chrome extension. It replaces the prototype dev server
protocol (`devserver/`, which stays a test tool only).

- Protocol version: **1**. The backend accepts the range `[PROTOCOL_MIN, PROTOCOL_MAX] = [1, 1]`.
- Extension origin (the only CORS origin): `chrome-extension://pomofdinonmfmpnpjdneihgklgdkidmc`.
- All bodies are JSON (`Content-Type: application/json; charset=utf-8`), UTF-8, times are UTC.

## 1. Headers

| Header | When | Value |
| --- | --- | --- |
| `Authorization` | every `/api/ext/*` call except `pair` | `Bearer <token>` from pairing |
| `X-Autotok-Protocol` | every `/api/ext/*` call | `1` (integer). Missing = 0 = unsupported |
| `X-Requested-With` | every POST | `autotok` (the backend's CSRF guard refuses POSTs without it, 403) |
| `Range` | `GET /api/ext/video` | `bytes=<start>-<end>` |

CORS: the backend answers preflights and adds `Access-Control-Allow-Origin` only for the
extension origin and only on the extension endpoints (section 3). Allowed request headers:
`Authorization, Content-Type, X-Requested-With, X-Autotok-Protocol, Range`. Exposed response
headers: `Content-Range, Content-Length, Accept-Ranges`. The GUI-only endpoints (section 4) never
get CORS headers and refuse any request that carries an `Origin` header (403).

## 2. Errors

Extension endpoints answer errors as `{"ok": false, "error": "<code>", "message": "<Vietnamese text>"}`.

| HTTP | `error` | Meaning / what the extension does |
| --- | --- | --- |
| 400 | `bad_request` | malformed body or field. Fix the client; never retry blindly |
| 401 | `unauthorized` | token missing, unknown, or the client was removed in the GUI. Show "Cần ghép nối lại", stop polling |
| 403 | `bad_nonce` | `nonce` or `claim_token` does not match the job. Drop the job locally, never retry |
| 403 | `bad_code` | pairing code wrong; body has `tries_left` |
| 403 | `csrf` | missing `X-Requested-With` (body uses FastAPI `detail`) |
| 404 | `unknown_job` | no such job id. Keep the result locally for diagnosis, drop the job |
| 409 | `need_reload` | protocol out of range. Body has `need_reload: true`. See section 7 |
| 409 | `identity_conflict` | another active Chrome profile reports the same TikTok user. No jobs until the owner removes one in the GUI |
| 409 | `no_identity` | the last `hello` had no TikTok identity (not logged in). Log in, send `hello` again |
| 410 | `no_code` | no pairing code active (none issued, expired, used, or burnt after 5 wrong tries) |
| 500 | `persist_failed` | the backend could not write durably. For `authorize`: NOT granted, never send |

## 3. Extension endpoints (CORS for the extension origin)

### 3.1 `POST /api/ext/pair` (no bearer)
Request: `{"code": "123456", "label": "Chrome Vườn", "ext_version": "1.0.0", "protocol": 1}`
Response 200: `{"ok": true, "client_id": 3, "token": "<43 url-safe chars>"}`. The token is shown
once; the backend stores only `sha256(token)`. The extension keeps it in `chrome.storage.local`.
Errors: 403 `bad_code` (`tries_left`), 410 `no_code`, 409 `need_reload`, 400 `bad_request`.

### 3.2 `POST /api/ext/hello`
Send at startup, right after pairing, after every TikTok login change, and at least every 60 s.
Request: `{"protocol": 1, "ext_version": "1.0.0", "identity": {"username": "mt.tri.2.pin", "user_id": "7012345678901234567"} | null}`.
`identity` comes from the passport endpoint only (`data.username`, `data.user_id_str`); null when
not logged in or unknown.
Response 200:
```json
{"ok": true, "client_id": 3, "protocol_min": 1, "protocol_max": 1, "need_reload": false,
 "message": "", "server_time": "2026-10-27T09:00:00Z",
 "account": {"id": 5, "username": "mt.tri.2.pin", "publisher": "chrome"} ,
 "conflict": false}
```
`account` is the backend account bound to this identity (`accounts.chrome_user_id == user_id`), or
null. `conflict` true = another client seen in the last 90 s reports the same `user_id`.
With an unsupported protocol the answer is still 200 with `need_reload: true` and a Vietnamese
`message`; the backend records the version so the GUI can show the reminder.

### 3.3 `GET /api/ext/next?wait=<0..25>`
Long poll (seconds, capped at 25). Every call counts as "seen" for readiness. Returns the oldest
`queued` job for the account bound to this client's last reported `user_id`.
- 200: the job (below). The job is now `claimed` by this client; it is never served again (no
  re-issue). The extension must keep it in durable storage and resume it after a restart.
- 204: nothing to do.
- 409 `need_reload` / `identity_conflict` / `no_identity`.

Job object:
```json
{"id": "ej_3f2a...", "nonce": "<32 hex>", "claim_token": "<32 hex>", "mode": "post", "attempt": 1,
 "caption": "xin chào #tag", "visibility": "public", "visibility_type": 0,
 "schedule_time": "2026-10-30T13:30:00Z", "schedule_unix": 1793367000,
 "options": {"allow_comment": 1, "allow_duet": 0, "allow_stitch": 0, "ai_label": 0},
 "expect_account": "mt.tri.2.pin", "expect_user_id": "7012345678901234567",
 "video": {"name": "kid-....mp4", "size": 20971520, "type": "video/mp4"},
 "limits": {"claim_within_s": 120, "heartbeat_every_s": 60, "stale_after_s": 120,
            "upload_within_s": 900, "result_within_s": 180,
            "schedule_min_ahead_s": 900, "schedule_max_shift_s": 600}}
```
- `schedule_time`/`schedule_unix` null = immediate post. Otherwise TikTok-native schedule: put
  `schedule_unix` in `feature_common_info_list[0].schedule_time`, except that when, at publish time,
  it is less than 15 min (`schedule_min_ahead_s`) away, use `now + 15 min` if that moves it by at
  most 10 min (`schedule_max_shift_s`), else fail definitely BEFORE authorize
  (`reason: "schedule-expired"`, text "Tải video quá lâu, giờ hẹn không còn hợp lệ — hãy chọn giờ mới").
  Never turn a scheduled job into an immediate post.
- `options` map 1:1 to `privacy_setting_info.allow_comment/allow_duet/allow_stitch` (0/1) and
  `ai_label: 1` -> `aigc_info: {"aigc_label_type": 1}` (absent when 0), exactly as
  `autotok/uploader.py::_payload`. `visibility_type` 0 = public, 1 = private. Friends visibility and
  private + schedule never reach the extension (refused by the backend before dispatch).
- `expect_account` + `expect_user_id`: the strict passport identity check before upload and
  before publish. Mismatch -> definite failure, nothing sent.

### 3.4 `GET /api/ext/video/meta?id=<job>` and `GET /api/ext/video?id=<job>`
Only for a job claimed by this client, in state
`claimed`, `uploading` or `ready`. Meta: `{"name", "size", "type"}`. Video: 200 full or 206 with
`Range` (`Content-Range: bytes s-e/size`), 416 for an unsatisfiable range. Read-only copy in the
backend library.

### 3.5 `POST /api/ext/progress` (heartbeat)
Request: `{"id", "nonce", "claim_token", "phase": "upload", "msg": "...", "pct": 40, "extra": {...}}`.
At least every 60 s while the job runs. Effects: `heartbeat_at = now`; `claimed -> uploading` on
the first progress; `phase: "ready"` moves `uploading|claimed -> ready` (upload finished and
committed, identity re-checked, body built; send it right before `authorize`).
Response: `{"ok": true, "state": "uploading"}`. If the job was revoked:
`{"ok": false, "state": "revoked", "cancelled": true}` -> stop, close the tab, do NOT authorize, send
a `failed` result if anything is left to report. Progress for an `authorized` job is accepted
(`ok: true`) but does not extend the result deadline.

### 3.6 `POST /api/ext/authorize`
Request:
```json
{"id": "ej_...", "nonce": "...", "claim_token": "...",
 "body_sha256": "<64 lowercase hex>", "creation_id": "<creation id in the body>",
 "visibility_type": 0, "schedule_time": 1793367000,
 "identity": {"username": "mt.tri.2.pin", "user_id": "7012345678901234567"}}
```
`schedule_time` = the exact unix seconds in the body, or null for an immediate post. `identity` =
the passport identity just re-checked.
Granted only by ONE conditional database update, durable before the reply:
`state='ready' AND claim_token AND nonce match AND attempt = current attempt of the parent AND
parent.status='waiting_ext'`, plus: protocol in range, no identity conflict, `identity.user_id ==
expect_user_id`, `visibility_type` equal to the job's, `schedule_time` null for an immediate job,
and for a scheduled job `schedule_unix <= schedule_time <= schedule_unix + 600` and
`schedule_time >= now + 15 min - 60 s`.
Response 200 `{"ok": true}` or `{"ok": false, "reason": "<code>"}` with reason one of
`not-ready`, `already-authorized`, `revoked`, `terminal`, `superseded`, `bad-binding`,
`identity-mismatch`, `visibility-mismatch`, `schedule-mismatch`, `need-reload`, `identity-conflict`.
500 `persist_failed` = not granted. Only `ok: true` allows the single publish XHR. Authorization is
one-time and never undone; after it the job is never re-run.

### 3.7 `POST /api/ext/result`
Request (fields the extension knows; unknown fields are ignored):
```json
{"id", "nonce", "claim_token",
 "outcome": "posted" | "rejected" | "uncertain" | "failed",
 "definite": true, "not_sent": true, "reason": "status_code", "detail": "...",
 "http": 200, "status_code": 0, "status_msg": "", "item_id": "7701245450858351893",
 "creation_id": "...", "video_id": "v0...", "schedule_time": 1793367000,
 "response": {"...": "sanitized TikTok answer, <= 8 KiB"}, "elapsed_ms": 9876}
```
`schedule_time` = the unix seconds actually submitted (null for immediate). `not_sent` (alias
`notSent`) true = the extension knows nothing reached the publish endpoint.
Response 200 `{"ok": true, "duplicate": false, "state": "posted"}`. The first result wins and is
stored durably; later ones return `duplicate: true` and change nothing. A result is accepted from
any paired client with the right `nonce` + `claim_token`, whatever its protocol version (skew), in
every state, including after a backend restart and after the result deadline (late result).
Errors: 404 `unknown_job`, 403 `bad_nonce`. On network failure, retry with backoff until 200, 404 or 403.

Mapping to the app's job outcome:

| Child state before | `outcome` | Child state after | Parent (scheduled job) |
| --- | --- | --- | --- |
| authorized | posted | posted | succeeded (post id kept, link from `item_id`) |
| authorized | rejected | rejected | failed, definite |
| authorized | uncertain, or failed without `not_sent` | uncertain | failed + `publish_uncertain` |
| authorized | failed with `not_sent: true` | failed | failed, definite |
| claimed/uploading/ready | failed / rejected | failed | failed, definite (nothing sent) |
| claimed/uploading/ready | posted / uncertain (gate bypassed) | posted / uncertain | as for authorized; logged as an anomaly |
| uncertain (result deadline missed) | any | the real outcome | late result: see section 5 |
| revoked, posted, rejected, failed | any | unchanged | duplicate / anomaly recorded in history |

### 3.8 `POST /api/ext/cancel`
Request: `{"id", "nonce", "claim_token", "reason": "..."}`. Pre-authorization: the job is revoked
(`revoked`) and the parent fails definitely. Authorized: nothing changes, `cancel_recorded: true`.
Response `{"ok": true, "state": "revoked" | "authorized" | <terminal state>, "cancel_recorded": bool}`.

### 3.9 `GET /api/ext/job_state?id=<job>`
Response `{"ok": true, "state": "...", "authorized": bool}`. 404 `unknown_job`.

## 4. GUI-only endpoints (local app; no CORS; refused with 403 when an `Origin` header is present)

- `POST /api/ext/pair-code` -> `{"code": "123456", "expires_at": "...Z", "valid_s": 300}`. A new code
  replaces the previous one. Single use, 5 min, at most 5 wrong tries, then burnt. Kept in API
  memory only (a restart forgets it).
- `GET /api/ext/clients` -> `[{"id", "label", "tiktok_username", "tiktok_user_id", "ext_version",
  "protocol", "need_reload", "last_seen_at", "online", "conflict", "created_at"}]`
  (`online` = seen in the last 90 s; removed clients are not listed).
- `DELETE /api/ext/clients/{id}` -> 204. The token stops working at once (401). A job the client
  already claimed keeps its deadlines (and its result is still accepted from any paired client
  that holds the nonce and claim token).
- `POST /api/accounts/from-chrome {"client_id": 3}` -> 201 `AccountRead`. Creates an account with
  `publisher='chrome'`, `chrome_user_id` = the client's `user_id`, username = the client's TikTok
  username, no cookie file (`cookie_path` = ""). 409 if an account already has that username or
  that `chrome_user_id`; 409 if the client is offline, has no identity, or is in conflict.
- `PATCH /api/accounts/{id} {"publisher": "chrome", "client_id": 3, "confirm_username_mismatch": false}`
  binds the account to the client's TikTok user. Cookies are untouched. Needs the client online
  with an identity and no conflict; if the TikTok username differs from the account username,
  needs `confirm_username_mismatch: true` (else 409). `{"publisher": "cookies"}` switches back
  (409 if the account has no cookie file, or has `pending_ext`/`waiting_ext` jobs).
- `AccountRead` gains `publisher`, `chrome_user_id`, `ready`, `ready_reason`:
  cookies -> `ready = has_valid_session`, reason `ok` | `no_session`;
  chrome -> ready when a bound client was seen < 90 s ago, protocol in range, no conflict; reason
  `ok` | `chrome_unbound` | `chrome_offline` | `chrome_need_reload` | `chrome_conflict`.
  `has_valid_session` keeps its meaning (cookie session only).
- `/health` gains `"chrome_ext": 1, "ext_protocol_min": 1, "ext_protocol_max": 1`.

## 5. States

Child job (`extension_jobs.state`):
`queued -> claimed -> uploading -> ready -> authorized -> posted | rejected | uncertain`;
terminal side exits `revoked` (pre-authorization cancel or missed deadline) and `failed`
(definite, nothing sent). `uncertain` can still become `posted|rejected|failed` when a late result
arrives. Terminal: `posted, rejected, uncertain, revoked, failed`.

Parent (`scheduled_uploads.status`) for accounts with `publisher='chrome'`:
`pending -> running` (claimed by the scheduler, attempt + 1) `-> pending_ext` (waiting for the
account to be free) `-> waiting_ext` (child created in the same transaction for this attempt)
`-> succeeded | failed`. Old backend versions only claim `pending`, so they never touch
`pending_ext`/`waiting_ext` rows (rollback safety).

Deadlines (checked by `reconcile_ext` on every scheduler tick, at startup, on `/next` and after
each result):
- queued and not claimed 120 s after creation -> revoke -> parent failed "Chrome chưa sẵn sàng".
- claimed/uploading/ready: no heartbeat for 120 s, or 15 min since claim -> revoke -> parent failed
  definite.
- authorized and no result 180 s after authorization -> child `uncertain` -> parent failed +
  `publish_uncertain` (check TikTok before retrying). Never definite.
- A late result for the same attempt fixes the parent (posted -> succeeded with post id; rejected /
  not-sent -> failed definite; the history keeps `prior_uncertain`). A late success for a
  superseded or deleted parent is written to the history with its post id and a warning and never
  changes the newer attempt; a late success while the parent waits for a manual retry (`pending`,
  same attempt) marks it succeeded so the retry does not post again.

Per account: at most one non-terminal child (partial unique index). Further jobs wait in
`pending_ext`, FIFO by `scheduled_for`, then id. Other accounts are independent.

## 6. Pairing flow

1. Owner clicks "Kết nối Chrome" in the app; the GUI calls `POST /api/ext/pair-code` and shows the 6 digits.
2. Owner types them in the extension popup; the extension calls `POST /api/ext/pair`.
3. The extension stores `token` + `client_id`, calls `hello` with its passport identity.
4. The GUI lists the client (`GET /api/ext/clients`) and offers "Tạo tài khoản từ Chrome"
   (`from-chrome`) or "Đăng qua Chrome" on an existing account (`PATCH publisher`).

## 7. Version skew and `need_reload`

- Every call carries `X-Autotok-Protocol`; `hello`/`pair` also carry `protocol` in the body.
- Out of range: `hello` answers 200 with `need_reload: true` and
  `message: "Cần tải lại tiện ích (chrome://extensions → ⟳)"`; `next` and `authorize` are refused
  (409 `need_reload` / reason `need-reload`); `pair` is refused (409).
- Still accepted during skew: `progress`, `result`, `cancel`, `job_state`, `video*` for jobs the
  client already holds, so an authorized job in flight still reports its outcome.
- The popup shows the message; the GUI shows the same reminder when a client's `need_reload` is true.

## 8. Not in v1

- Direct immediate uploads (`/api/uploads/*`) answer 409 "Tài khoản đăng qua Chrome — dùng lịch/hẹn"
  for chrome accounts; use schedules / the desktop bridge.
- YouTube sources for chrome accounts are refused definitely at dispatch (nothing sent).
- The per-job `proxy` option is ignored on the Chrome path (Chrome uses its own network).
- No backend endpoint for the extension self-test ("Kiểm tra"); it stays local to the extension.

## 9. Deviations from the plan contracts (C1-C6)

- C1 authorize: the conditional update also requires the protocol, identity, visibility and
  schedule checks above (stricter, never looser).
- No job re-issue (the prototype re-issued stale pre-authorization jobs): a stale job is revoked
  and fails definitely instead. Simpler; the extension resumes from its own storage.
- C4 `cookie_path`: sentinel `""` for chrome-only accounts, no table rebuild.
- C4 PATCH to chrome takes an explicit `client_id`, and a username mismatch needs
  `confirm_username_mismatch` (the account username may be a label, not the TikTok handle).
- Publisher is decided when the scheduler claims the job; a job already in `pending_ext` whose
  account was switched back to cookies fails definitely (nothing sent, owner retries); switching
  back is refused while such jobs exist.
