"""Tiny dev server for the AutoTok P0 extension prototype (stdlib only).

Serves ONE job (more via POST /api/jobs) and its video to the extension, and records what the
extension reports. Bearer token = static, from the command line. Binds 127.0.0.1 only.

    python devserver.py --token T --video C:\\path\\clip.mp4 --mode selftest --caption "xin chào #tag"
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# Post mode needs BOTH --allow-post and a job that is mode=post, private, unscheduled, with expect_account.
MODES = ("selftest", "intercept", "post")
VISIBILITY = ("public", "friends", "private")


class State:
    def __init__(self, token: str, video: Path, log_path: Path | None, allow_post: bool = False, state_path: Path | None = None):
        self.token = token
        self.allow_post = allow_post
        self.state_path = state_path
        self.video = video
        self.stale_s = 120.0
        self.log_path = log_path
        self.lock = threading.Lock()
        self.log_lock = threading.Lock()
        self.jobs: dict[str, dict] = {}
        self.order: list[str] = []
        self._load()

    def prior_post_for_video(self):
        """(job id, state) of an earlier post job for the same video (name + size) that may have posted, else None."""
        v = {"name": self.video.name, "size": self.video.stat().st_size if self.video.is_file() else None}
        for jid in self.order:
            e = self.jobs[jid]
            j = e["job"]
            if j.get("mode") != "post" or (j.get("video") or {}).get("name") != v["name"] or (j.get("video") or {}).get("size") != v["size"]:
                continue
            outcome = (e.get("result") or {}).get("outcome")
            if e["state"] in ("authorized", "uncertain") or e["authorized"] or (e["state"] == "done" and outcome in (None, "posted", "uncertain")):
                return jid, e["state"]
        return None

    # ---- durable state (authorization must survive a restart) ----
    def _persist(self) -> None:
        """Write the job table atomically (temp file + os.replace). Caller holds self.lock. Raises on failure."""
        if not self.state_path:
            return
        keep = ("job", "state", "claims", "authorized", "authorized_at", "auth_sha", "auth_creation_id", "cancel_requested",
                "late_result", "result")
        data = {"jobs": {i: {k: self.jobs[i].get(k) for k in keep} for i in self.order}}
        tmp = self.state_path.with_name(self.state_path.name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.state_path)

    def _load(self) -> None:
        if not self.state_path or not self.state_path.is_file():
            return
        raw = json.loads(self.state_path.read_text(encoding="utf-8"))
        for jid, rec in raw.get("jobs", {}).items():
            st = rec.get("state")
            if rec.get("authorized") and st != "done":
                st = "uncertain"          # a post may have been sent: never re-issue, never re-authorize
            elif st in ("queued", "claimed", "running"):
                st = "cancelled"          # abandoned by the restart; nothing was authorized
            self.jobs[jid] = {"job": rec["job"], "state": st, "claims": rec.get("claims", 0), "authorized": bool(rec.get("authorized")),
                              "authorized_at": rec.get("authorized_at"), "auth_sha": rec.get("auth_sha"),
                              "auth_creation_id": rec.get("auth_creation_id"), "cancel_requested": bool(rec.get("cancel_requested")),
                              "late_result": rec.get("late_result"), "result": rec.get("result"), "progress": [], "last_seen": 0.0}
            self.order.append(jid)

    def log(self, event: str, **data) -> None:
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **data}
        line = json.dumps(rec, ensure_ascii=False)
        # Console may be cp1252 on Windows: never let printing break a request.
        print(line.encode("ascii", "backslashreplace").decode("ascii"), flush=True)
        if self.log_path:
            with self.log_lock, open(self.log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")

    def add_job(self, caption: str, mode: str = "selftest", visibility: str = "private",
                schedule_time: str | None = None, expect_account: str | None = None,
                chunk_credentials: str = "omit", expect_user_id: str | None = None) -> dict:
        if mode not in MODES:
            raise ValueError(f"mode must be one of {MODES}")
        if visibility not in VISIBILITY:
            raise ValueError(f"visibility must be one of {VISIBILITY}")
        if chunk_credentials not in ("omit", "include"):
            raise ValueError("chunk_credentials must be 'omit' or 'include'")
        if not self.video.is_file():
            raise ValueError(f"video not found: {self.video}")
        if mode == "post":
            if not self.allow_post:
                raise ValueError("mode 'post' needs the server to be started with --allow-post")
            if visibility != "private" or schedule_time:
                raise ValueError("post is limited to visibility=private and no schedule in this prototype")
            if not expect_account:
                raise ValueError("post needs expect_account")
        job = {
            "id": "job-" + secrets.token_hex(4), "nonce": secrets.token_hex(8), "caption": caption,
            "visibility": visibility, "schedule_time": schedule_time, "mode": mode,
            "expect_account": expect_account, "chunk_credentials": chunk_credentials, "expect_user_id": expect_user_id,
            "video": {"name": self.video.name, "size": self.video.stat().st_size,
                      "type": mimetypes.guess_type(self.video.name)[0] or "video/mp4"},
        }
        with self.lock:
            entry = {"job": job, "state": "queued", "claims": 0, "authorized": False,
                                    "authorized_at": None, "auth_sha": None, "auth_creation_id": None,
                                    "cancel_requested": False, "late_result": None,
                                    "result": None, "progress": [], "last_seen": 0.0}
            self.jobs[job["id"]] = entry
            self.order.append(job["id"])
            try:
                self._persist()
            except OSError:                       # not durable => never served
                del self.jobs[job["id"]]
                self.order.remove(job["id"])
                raise
        self.log("job-added", id=job["id"], mode=mode, visibility=visibility, schedule_time=schedule_time)
        return job


def make_server(state: State, port: int = 8799) -> ThreadingHTTPServer:
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):  # we log our own events
            pass

        # ---- helpers ----
        def _json(self, code: int, obj) -> None:
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _empty(self, code: int) -> None:
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _auth(self) -> bool:
            state.log("request", method=self.command, path=self.path, range=self.headers.get("Range"),
                      auth=self.headers.get("Authorization", "")[:7] == "Bearer ")
            if self.headers.get("Authorization", "") == "Bearer " + state.token:
                return True
            state.log("auth-denied", path=self.path)
            self._json(401, {"error": "bad token"})
            return False

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}

        def _entry(self, job_id: str, nonce: str | None = None):
            e = state.jobs.get(job_id)
            if e is None:
                self._json(404, {"error": "unknown job"})
                return None
            if nonce is not None and nonce != e["job"]["nonce"]:
                state.log("nonce-mismatch", id=job_id)
                self._json(403, {"error": "bad nonce"})
                return None
            return e

        # ---- routes ----
        def do_GET(self):
            if not self._auth():
                return
            u = urlparse(self.path)
            q = parse_qs(u.query)
            jid = (q.get("id") or [""])[0]
            if u.path == "/api/next":
                return self._next(float((q.get("wait") or ["0"])[0]))
            if u.path == "/api/status":
                with state.lock:
                    return self._json(200, {i: {k: v for k, v in state.jobs[i].items() if k != "progress"}
                                            | {"progress_count": len(state.jobs[i]["progress"])} for i in state.order})
            if u.path == "/api/job_state":
                e = self._entry(jid)
                return e and self._json(200, {"state": e["state"], "authorized": e["authorized"]})
            if u.path == "/api/video/meta":
                e = self._entry(jid)
                return e and self._json(200, e["job"]["video"])
            if u.path == "/api/video":
                e = self._entry(jid)
                return e and self._video()
            self._json(404, {"error": "no route"})

        def do_POST(self):
            if not self._auth():
                return
            try:
                body = self._body()
            except (ValueError, UnicodeDecodeError) as exc:
                return self._json(400, {"error": f"bad json: {exc}"})
            path = urlparse(self.path).path
            if path == "/api/jobs":
                try:
                    job = state.add_job(body.get("caption", ""), body.get("mode", "selftest"), body.get("visibility", "private"),
                                        body.get("schedule_time"), body.get("expect_account"),
                                        body.get("chunk_credentials", "omit"), body.get("expect_user_id"))
                except ValueError as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(200, job)
            e = self._entry(str(body.get("id", "")), str(body.get("nonce") or ""))   # a missing nonce never matches
            if e is None:
                return
            if path == "/api/progress":
                with state.lock:
                    if e["state"] == "cancelled":
                        return self._json(200, {"ok": False, "cancelled": True})
                    if e["state"] == "done":
                        return self._json(200, {"ok": True, "done": True})
                    e["progress"].append(body)
                    e["last_seen"] = time.time()
                    if e["state"] == "claimed":
                        e["state"] = "running"
                state.log("progress", id=e["job"]["id"], phase=body.get("phase"), msg=body.get("msg"), pct=body.get("pct"), extra=body.get("extra"))
                return self._json(200, {"ok": True})
            if path == "/api/authorize":
                return self._authorize(e, body)
            if path == "/api/cancel":
                with state.lock:
                    if e["state"] == "authorized":
                        e["cancel_requested"] = True          # recorded only: an authorization is never undone
                    elif e["state"] not in ("done", "uncertain", "cancelled"):
                        e["state"] = "cancelled"
                    state._persist()
                    st = e["state"]
                state.log("cancel", id=e["job"]["id"], state=st, cancel_recorded=e["cancel_requested"])
                return self._json(200, {"ok": True, "state": st})
            if path == "/api/result":
                with state.lock:
                    if e["state"] == "cancelled":
                        return self._json(200, {"ok": True, "cancelled": True})
                    dup = e["state"] == "done"
                    if not dup:
                        if e["state"] == "uncertain":
                            e["late_result"] = True           # the real outcome arrived after a restart
                        e["state"], e["result"] = "done", body
                        state._persist()
                state.log("result-duplicate" if dup else "result", id=e["job"]["id"], result=body)
                return self._json(200, {"ok": True, "duplicate": dup})
            self._json(404, {"error": "no route"})

        def _authorize(self, e, body) -> None:
            """ready -> AUTHORIZED: conditional, one-time, persisted BEFORE the reply."""
            sha, cid = body.get("body_sha256"), body.get("creation_id")
            with state.lock:
                if not state.allow_post:
                    reason = "post-disabled"
                elif e["job"]["mode"] != "post":
                    reason = "not-post-mode"
                elif e["state"] == "authorized" or e["authorized"]:
                    reason = "already-authorized"
                elif e["state"] not in ("claimed", "running"):
                    reason = e["state"] if e["state"] in ("cancelled", "done", "uncertain") else "not-ready"
                elif not (isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha)) or not (isinstance(cid, str) and cid):
                    reason = "bad-binding"
                else:
                    reason = None
                if reason is None:
                    prev = (e["state"], e["authorized"], e["authorized_at"], e["auth_sha"], e["auth_creation_id"])
                    e["state"], e["authorized"], e["authorized_at"], e["auth_sha"], e["auth_creation_id"] = "authorized", True, time.time(), sha, cid
                    try:
                        state._persist()
                    except OSError as exc:                  # not durable => not granted
                        e["state"], e["authorized"], e["authorized_at"], e["auth_sha"], e["auth_creation_id"] = prev
                        state.log("authorize", id=e["job"]["id"], ok=False, reason="persist-failed", error=str(exc))
                        return self._json(500, {"ok": False, "reason": "persist-failed"})
            state.log("authorize", id=e["job"]["id"], ok=reason is None, reason=reason, sha=(sha or "")[:12], creation_id=cid)
            return self._json(200, {"ok": reason is None, "reason": reason})

        def _next(self, wait: float) -> None:
            end = time.time() + min(max(wait, 0), 30)
            while True:
                with state.lock:
                    for jid in state.order:
                        e = state.jobs[jid]
                        live = e["state"] in ("claimed", "running") and time.time() - e["last_seen"] < state.stale_s
                        if e["state"] in ("queued", "claimed", "running") and not live:   # never authorized/uncertain
                            e["claims"] += 1
                            e["last_seen"] = time.time()
                            if e["state"] == "queued":
                                e["state"] = "claimed"
                            if e["claims"] > 1:
                                state.log("job-reissued", id=jid, claims=e["claims"])
                            else:
                                state.log("job-claimed", id=jid)
                            return self._json(200, e["job"])
                if time.time() >= end:
                    return self._empty(204)
                time.sleep(0.25)

        def _video(self) -> None:
            size = state.video.stat().st_size
            start, end, code = 0, size - 1, 200
            rng = self.headers.get("Range")
            if rng:
                m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
                if not m or (not m.group(1) and not m.group(2)):
                    return self._json(416, {"error": "bad range"})
                if m.group(1):
                    start = int(m.group(1))
                    end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
                else:  # suffix range
                    start = max(size - int(m.group(2)), 0)
                if start >= size or start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                code = 206
            length = end - start + 1
            self.send_response(code)
            self.send_header("Content-Type", mimetypes.guess_type(state.video.name)[0] or "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if code == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            with open(state.video, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    buf = f.read(min(1 << 20, left))
                    if not buf:
                        break
                    self.wfile.write(buf)
                    left -= len(buf)

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    return srv


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--token", required=True)
    ap.add_argument("--video", required=True, type=Path)
    ap.add_argument("--mode", choices=MODES, default="selftest")
    ap.add_argument("--caption", default="")
    ap.add_argument("--visibility", choices=VISIBILITY, default="private")
    ap.add_argument("--schedule", default=None, help="ISO time with offset, e.g. 2026-10-30T20:30:00+07:00")
    ap.add_argument("--expect-account", default=None, help="TikTok unique id the page must be logged in as")
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--log", type=Path, default=Path(__file__).with_name("logs") / "autotok-dev.jsonl")
    ap.add_argument("--allow-post", action="store_true", help="REQUIRED for --mode post (really posts to TikTok, one private video)")
    ap.add_argument("--expect-user-id", default=None, help="numeric TikTok user_id_str the page must be logged in as")
    ap.add_argument("--state", type=Path, default=Path(__file__).with_name("logs") / "state.json", help="durable job/authorization state")
    ap.add_argument("--i-know-this-reposts", action="store_true", help="allow queuing a post job for a video that already has an authorized/uncertain/posted post job in state.json")
    ap.add_argument("--chunk-credentials", choices=("omit", "include"), default="omit", help="fetch credentials mode for the storage host")
    a = ap.parse_args(argv)
    if a.log:
        a.log.parent.mkdir(parents=True, exist_ok=True)
    a.state.parent.mkdir(parents=True, exist_ok=True)
    state = State(a.token, a.video.resolve(), a.log, a.allow_post, a.state)
    if a.mode == "post" and not a.i_know_this_reposts:
        prior = state.prior_post_for_video()
        if prior:
            print(f"error: state.json already has a post job for this video ({prior[0]}, state={prior[1]}). Its outcome is "
                  "unknown or it was posted; check the TikTok account first. Re-run with --i-know-this-reposts to post again.", file=sys.stderr)
            return 2
    try:
        state.add_job(a.caption, a.mode, a.visibility, a.schedule, a.expect_account, a.chunk_credentials, a.expect_user_id)
    except ValueError as exc:
        print("error:", exc, file=sys.stderr)
        return 2
    srv = make_server(state, a.port)
    state.log("listening", port=a.port, log=str(a.log))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
