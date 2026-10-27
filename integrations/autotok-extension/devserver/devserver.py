"""Tiny dev server for the AutoTok P0 extension prototype (stdlib only).

Serves ONE job (more via POST /api/jobs) and its video to the extension, and records what the
extension reports. Bearer token = static, from the command line. Binds 127.0.0.1 only.

    python devserver.py --token T --video C:\\path\\clip.mp4 --mode selftest --caption "xin chào #tag"
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

MODES = ("selftest", "intercept", "post")
VISIBILITY = ("public", "friends", "private")


class State:
    def __init__(self, token: str, video: Path, log_path: Path | None, allow_post: bool):
        self.token = token
        self.video = video
        self.allow_post = allow_post
        self.log_path = log_path
        self.lock = threading.Lock()
        self.log_lock = threading.Lock()
        self.jobs: dict[str, dict] = {}
        self.order: list[str] = []

    def log(self, event: str, **data) -> None:
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **data}
        line = json.dumps(rec, ensure_ascii=False)
        print(line, flush=True)
        if self.log_path:
            with self.log_lock, open(self.log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")

    def add_job(self, caption: str, mode: str = "selftest", visibility: str = "private",
                schedule_time: str | None = None, expect_account: str | None = None) -> dict:
        if mode not in MODES:
            raise ValueError(f"mode must be one of {MODES}")
        if visibility not in VISIBILITY:
            raise ValueError(f"visibility must be one of {VISIBILITY}")
        if mode == "post" and not self.allow_post:
            raise ValueError("mode 'post' needs the server to be started with --allow-post")
        if not self.video.is_file():
            raise ValueError(f"video not found: {self.video}")
        job = {
            "id": "job-" + secrets.token_hex(4), "nonce": secrets.token_hex(8), "caption": caption,
            "visibility": visibility, "schedule_time": schedule_time, "mode": mode,
            "expect_account": expect_account,
            "video": {"name": self.video.name, "size": self.video.stat().st_size,
                      "type": mimetypes.guess_type(self.video.name)[0] or "video/mp4"},
        }
        with self.lock:
            self.jobs[job["id"]] = {"job": job, "state": "queued", "claims": 0, "authorized": False,
                                    "result": None, "progress": []}
            self.order.append(job["id"])
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
                                        body.get("schedule_time"), body.get("expect_account"))
                except ValueError as exc:
                    return self._json(400, {"error": str(exc)})
                return self._json(200, job)
            e = self._entry(str(body.get("id", "")), body.get("nonce"))
            if e is None:
                return
            if path == "/api/progress":
                with state.lock:
                    e["progress"].append(body)
                    if e["state"] == "claimed":
                        e["state"] = "running"
                state.log("progress", id=e["job"]["id"], phase=body.get("phase"), msg=body.get("msg"), pct=body.get("pct"), extra=body.get("extra"))
                return self._json(200, {"ok": True})
            if path == "/api/authorize":
                with state.lock:
                    mode = e["job"]["mode"]
                    if mode == "selftest":
                        ok, reason = False, "selftest-never-authorizes"
                    elif e["authorized"]:
                        ok, reason = False, "already-authorized"
                    elif e["state"] == "done":
                        ok, reason = False, "job-done"
                    else:
                        e["authorized"] = True
                        ok, reason = True, None
                state.log("authorize", id=e["job"]["id"], ok=ok, reason=reason)
                return self._json(200, {"ok": ok, "reason": reason})
            if path == "/api/result":
                with state.lock:
                    dup = e["state"] == "done"
                    if not dup:
                        e["state"], e["result"] = "done", body
                state.log("result-duplicate" if dup else "result", id=e["job"]["id"], result=body)
                return self._json(200, {"ok": True, "duplicate": dup})
            self._json(404, {"error": "no route"})

        def _next(self, wait: float) -> None:
            end = time.time() + min(max(wait, 0), 30)
            while True:
                with state.lock:
                    for jid in state.order:
                        e = state.jobs[jid]
                        if e["state"] in ("queued", "claimed", "running"):
                            e["claims"] += 1
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
    ap.add_argument("--allow-post", action="store_true", help="REQUIRED for --mode post (really posts to TikTok)")
    a = ap.parse_args(argv)
    if a.log:
        a.log.parent.mkdir(parents=True, exist_ok=True)
    state = State(a.token, a.video.resolve(), a.log, a.allow_post)
    try:
        state.add_job(a.caption, a.mode, a.visibility, a.schedule, a.expect_account)
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
