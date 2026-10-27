import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import devserver

TOKEN = "tok-123"
VIDEO_BYTES = bytes(range(256)) * 40 + b"end"  # 10243 bytes, hand-known


class DevServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.video = Path(cls.tmp.name) / "clip tiếng việt.mp4"  # space + Vietnamese in the name
        cls.video.write_bytes(VIDEO_BYTES)
        cls.log = Path(cls.tmp.name) / "log.jsonl"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def start(self, allow_post=False):
        self.state = devserver.State(TOKEN, self.video, self.log, allow_post)
        self.srv = devserver.make_server(self.state, 0)
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def call(self, path, body=None, token=TOKEN, headers=None):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                                     method="POST" if body is not None else "GET",
                                     headers={**({"Authorization": "Bearer " + token} if token else {}), **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if r.headers.get("Content-Type", "").startswith("application/json") and raw else raw), r.headers
        except urllib.error.HTTPError as e:
            raw = e.read()
            return e.code, (json.loads(raw) if raw and e.headers.get("Content-Type", "").startswith("application/json") else raw), e.headers

    def test_token_required(self):
        self.start()
        self.assertEqual(self.call("/api/next", token=None)[0], 401)
        self.assertEqual(self.call("/api/next", token="wrong")[0], 401)
        self.assertEqual(self.call("/api/video?id=x", token="wrong")[0], 401)

    def test_next_empty_is_204(self):
        self.start()
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)

    def test_job_roundtrip_and_vietnamese_caption(self):
        self.start()
        cap = "Xin chào 🌸 #việtnam #tiktok\ndòng hai"
        job = self.state.add_job(cap, "intercept", "private", "2026-10-30T20:30:00+07:00")
        code, got, _ = self.call("/api/next?wait=1")
        self.assertEqual(code, 200)
        self.assertEqual(got["caption"], cap)
        self.assertEqual(got["schedule_time"], "2026-10-30T20:30:00+07:00")
        self.assertEqual(got["video"]["size"], len(VIDEO_BYTES))
        self.assertEqual(got["id"], job["id"])
        # a fresh claim is not re-issued; staleness re-issue is tested separately
        code, again, _ = self.call("/api/next?wait=0")
        self.assertEqual(code, 204)  # fresh claim is not re-issued

    def test_video_range_exact_bytes(self):
        self.start()
        job = self.state.add_job("c", "selftest")
        code, data, h = self.call(f"/api/video?id={job['id']}", headers={"Range": "bytes=10-19"})
        self.assertEqual(code, 206)
        self.assertEqual(data, VIDEO_BYTES[10:20])
        self.assertEqual(h["Content-Range"], f"bytes 10-19/{len(VIDEO_BYTES)}")
        code, data, _ = self.call(f"/api/video?id={job['id']}", headers={"Range": "bytes=10240-99999"})  # tail clamps
        self.assertEqual((code, data), (206, VIDEO_BYTES[10240:]))
        code, _, _ = self.call(f"/api/video?id={job['id']}", headers={"Range": "bytes=99999-"})
        self.assertEqual(code, 416)
        code, data, _ = self.call(f"/api/video?id={job['id']}")
        self.assertEqual((code, data), (200, VIDEO_BYTES))

    def test_authorize_is_one_time_and_selftest_never(self):
        self.start()
        a = self.state.add_job("c", "intercept")
        b = self.state.add_job("c", "selftest")
        self.assertEqual(self.call("/api/authorize", {"id": a["id"], "nonce": a["nonce"]})[1], {"ok": True, "reason": None})
        self.assertEqual(self.call("/api/authorize", {"id": a["id"], "nonce": a["nonce"]})[1], {"ok": False, "reason": "already-authorized"})
        self.assertEqual(self.call("/api/authorize", {"id": b["id"], "nonce": b["nonce"]})[1]["ok"], False)

    def test_nonce_checked(self):
        self.start()
        a = self.state.add_job("c", "intercept")
        self.assertEqual(self.call("/api/progress", {"id": a["id"], "nonce": "nope", "phase": "x"})[0], 403)
        self.assertEqual(self.call("/api/progress", {"id": "job-unknown", "nonce": "n"})[0], 404)
        self.assertEqual(self.call("/api/progress", {"id": a["id"], "nonce": a["nonce"], "phase": "upload", "pct": 5})[0], 200)

    def test_result_idempotent_and_ends_reissue(self):
        self.start()
        a = self.state.add_job("c", "selftest")
        r = {"id": a["id"], "nonce": a["nonce"], "outcome": "selftest_ok"}
        self.assertEqual(self.call("/api/result", r)[1], {"ok": True, "duplicate": False})
        self.assertEqual(self.call("/api/result", r)[1], {"ok": True, "duplicate": True})
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)
        lines = [json.loads(l) for l in self.log.read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any(l["event"] == "result" and l["result"]["outcome"] == "selftest_ok" for l in lines))

    def test_no_reissue_while_heartbeat_fresh_then_reissue_when_stale(self):
        self.start()
        a = self.state.add_job("c", "selftest")
        self.assertEqual(self.call("/api/next?wait=0")[0], 200)
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)  # fresh claim: not re-issued
        self.call("/api/progress", {"id": a["id"], "nonce": a["nonce"], "phase": "x"})
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)  # fresh progress
        self.state.jobs[a["id"]]["last_seen"] -= 121
        code, got, _ = self.call("/api/next?wait=0")
        self.assertEqual((code, got["id"]), (200, a["id"]))
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)  # re-claim refreshed the heartbeat

    def test_cancel_is_terminal_and_checks_nonce(self):
        self.start()
        a = self.state.add_job("c", "selftest")
        self.assertEqual(self.call("/api/next?wait=0")[0], 200)
        self.assertEqual(self.call("/api/cancel", {"id": a["id"], "nonce": "bad"})[0], 403)
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)
        self.assertEqual(self.call("/api/cancel", {"id": a["id"], "nonce": a["nonce"]})[1], {"ok": True, "state": "cancelled"})
        self.state.jobs[a["id"]]["last_seen"] -= 9999
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)  # never issued again, even when stale
        self.assertEqual(self.call(f"/api/job_state?id={a['id']}")[1]["state"], "cancelled")
        self.assertEqual(self.call("/api/result", {"id": a["id"], "nonce": a["nonce"], "outcome": "x"})[1].get("cancelled"), True)

    def test_post_mode_needs_allow_flag(self):
        self.start(allow_post=False)
        with self.assertRaises(ValueError):
            self.state.add_job("c", "post")
        self.assertEqual(self.call("/api/jobs", {"caption": "c", "mode": "post"})[0], 400)
        self.state.allow_post = True
        self.assertEqual(self.call("/api/jobs", {"caption": "c", "mode": "post"})[0], 200)


if __name__ == "__main__":
    unittest.main()
