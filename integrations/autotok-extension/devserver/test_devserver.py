import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import devserver

TOKEN = "tok-123"
BIND = {"body_sha256": "a" * 64, "creation_id": "CrEaTiOnId_0123456789"}
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

    def start(self, allow_post=False, state_path=None):
        self.state = devserver.State(TOKEN, self.video, self.log, allow_post, state_path)
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

    def test_authorize_refused_without_allow_post_and_for_non_post_jobs(self):
        self.start(allow_post=False)
        a = self.state.add_job("c", "intercept")
        self.assertEqual(self.call("/api/authorize", {"id": a["id"], "nonce": a["nonce"], **BIND})[1], {"ok": False, "reason": "post-disabled"})
        self.start(allow_post=True)
        b = self.state.add_job("c", "intercept")
        self.call("/api/next?wait=0")
        self.assertEqual(self.call("/api/authorize", {"id": b["id"], "nonce": b["nonce"], **BIND})[1], {"ok": False, "reason": "not-post-mode"})

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

    def test_post_job_creation_rules(self):
        self.start(allow_post=False)
        with self.assertRaises(ValueError):
            self.state.add_job("c", "post", "private", None, "me")           # no --allow-post
        self.assertEqual(self.call("/api/jobs", {"caption": "c", "mode": "post", "expect_account": "me"})[0], 400)
        self.start(allow_post=True)
        for kw in ({"visibility": "public"}, {"visibility": "friends"}, {"schedule_time": "2026-10-30T20:00:00+07:00"}, {"expect_account": None}):
            args = {"caption": "c", "mode": "post", "visibility": "private", "schedule_time": None, "expect_account": "me"}
            args.update(kw)
            with self.assertRaises(ValueError, msg=str(kw)):
                self.state.add_job(**args)
        self.assertEqual(self.state.add_job("c", "post", "private", None, "me", expect_user_id="7000000000000000001")["expect_user_id"], "7000000000000000001")

    def _post_job(self, state_path=None):
        self.start(allow_post=True, state_path=state_path)
        j = self.state.add_job("c", "post", "private", None, "me")
        self.assertEqual(self.call("/api/next?wait=0")[0], 200)              # claimed
        return j

    def test_authorize_one_time_and_persisted_before_reply(self):
        sp = Path(self.tmp.name) / "s1.json"
        j = self._post_job(sp)
        req = {"id": j["id"], "nonce": j["nonce"], **BIND}
        self.assertEqual(self.call("/api/authorize", req)[1], {"ok": True, "reason": None})
        persisted = json.loads(sp.read_text(encoding="utf-8"))["jobs"][j["id"]]     # already on disk when the reply came back
        self.assertEqual((persisted["authorized"], persisted["state"], persisted["auth_sha"]), (True, "authorized", BIND["body_sha256"]))
        self.assertEqual(self.call("/api/authorize", req)[1], {"ok": False, "reason": "already-authorized"})
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)                # an authorized job is never re-issued
        self.state.jobs[j["id"]]["last_seen"] -= 9999
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)                # ...even when stale

    def test_authorize_bad_binding_nonce_and_not_ready(self):
        self.start(allow_post=True)
        j = self.state.add_job("c", "post", "private", None, "me")
        req = {"id": j["id"], "nonce": j["nonce"], **BIND}
        self.assertEqual(self.call("/api/authorize", req)[1], {"ok": False, "reason": "not-ready"})   # still queued
        self.call("/api/next?wait=0")
        self.assertEqual(self.call("/api/authorize", {**req, "body_sha256": "xyz"})[1], {"ok": False, "reason": "bad-binding"})
        self.assertEqual(self.call("/api/authorize", {**req, "creation_id": ""})[1], {"ok": False, "reason": "bad-binding"})
        self.assertEqual(self.call("/api/authorize", {**req, "nonce": "bad"})[0], 403)

    def test_authorize_when_cancelled_or_done_is_refused(self):
        j = self._post_job()
        self.call("/api/cancel", {"id": j["id"], "nonce": j["nonce"]})
        self.assertEqual(self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})[1], {"ok": False, "reason": "cancelled"})
        k = self.state.add_job("c", "post", "private", None, "me")
        self.assertEqual(self.call("/api/next?wait=0")[0], 200)
        self.call("/api/result", {"id": k["id"], "nonce": k["nonce"], "outcome": "failed"})
        self.assertEqual(self.call("/api/authorize", {"id": k["id"], "nonce": k["nonce"], **BIND})[1], {"ok": False, "reason": "done"})

    def test_cancel_after_authorization_only_records(self):
        j = self._post_job()
        self.assertTrue(self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})[1]["ok"])
        self.assertEqual(self.call("/api/cancel", {"id": j["id"], "nonce": j["nonce"]})[1], {"ok": True, "state": "authorized"})
        e = self.state.jobs[j["id"]]
        self.assertEqual((e["state"], e["authorized"], e["cancel_requested"]), ("authorized", True, True))

    def test_cancel_authorize_race_never_both(self):
        self.start(allow_post=True)
        for _ in range(40):
            j = self.state.add_job("c", "post", "private", None, "me")
            self.state.jobs[j["id"]]["state"] = "running"
            out = {}
            ts = [threading.Thread(target=lambda: out.__setitem__("a", self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})[1])),
                  threading.Thread(target=lambda: out.__setitem__("c", self.call("/api/cancel", {"id": j["id"], "nonce": j["nonce"]})[1]))]
            for t in ts:
                t.start()
            for t in ts:
                t.join()
            e = self.state.jobs[j["id"]]
            if out["a"]["ok"]:
                self.assertEqual((e["state"], e["authorized"]), ("authorized", True))      # cancel could not undo it
            else:
                self.assertEqual((out["a"]["reason"], e["state"], e["authorized"]), ("cancelled", "cancelled", False))
            self.state.jobs[j["id"]]["state"] = "done"                                        # keep _next quiet

    def test_restart_after_authorization_is_uncertain_never_reissued(self):
        sp = Path(self.tmp.name) / "s2.json"
        j = self._post_job(sp)
        self.assertTrue(self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})[1]["ok"])
        q = self.state.add_job("c", "selftest")                                         # a never-claimed job
        self.srv.shutdown(); self.srv.server_close()
        self.start(allow_post=True, state_path=sp)                                      # "restart": same state file
        self.assertEqual(self.state.jobs[j["id"]]["state"], "uncertain")
        self.assertEqual(self.state.jobs[q["id"]]["state"], "cancelled")                # abandoned, not served again
        self.assertEqual(self.call("/api/next?wait=0")[0], 204)
        self.assertEqual(self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})[1], {"ok": False, "reason": "already-authorized"})
        self.assertEqual(self.call(f"/api/job_state?id={j['id']}")[1], {"state": "uncertain", "authorized": True})
        r = self.call("/api/result", {"id": j["id"], "nonce": j["nonce"], "outcome": "posted"})[1]   # the real outcome may still arrive
        self.assertEqual(r, {"ok": True, "duplicate": False})
        self.assertTrue(self.state.jobs[j["id"]]["late_result"])

    def test_authorize_not_granted_when_persist_fails(self):
        sp = Path(self.tmp.name) / "s3.json"
        j = self._post_job(sp)
        self.state.state_path = Path(self.tmp.name) / "no-such-dir" / "s.json"
        code, body, _ = self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})
        self.assertEqual((code, body["ok"]), (500, False))
        e = self.state.jobs[j["id"]]
        self.assertEqual((e["state"], e["authorized"]), ("claimed", False))              # rolled back: not granted

    def test_prior_post_detection_and_override_flag(self):
        sp = Path(self.tmp.name) / "s4.json"
        j = self._post_job(sp)
        self.assertTrue(self.call("/api/authorize", {"id": j["id"], "nonce": j["nonce"], **BIND})[1]["ok"])
        self.assertEqual(self.state.prior_post_for_video()[0], j["id"])
        self.call("/api/result", {"id": j["id"], "nonce": j["nonce"], "outcome": "rejected", "definite": True})
        e = self.state.jobs[j["id"]]
        e["authorized"] = False                                                      # a definite rejection never posted
        self.assertIsNone(self.state.prior_post_for_video())
        e["result"]["outcome"] = "posted"
        self.assertEqual(self.state.prior_post_for_video()[1], "done")

    def test_chunk_credentials_validated_and_passed(self):
        self.start()
        self.assertEqual(self.state.add_job("c", "selftest")["chunk_credentials"], "omit")
        self.assertEqual(self.state.add_job("c", "selftest", chunk_credentials="include")["chunk_credentials"], "include")
        with self.assertRaises(ValueError):
            self.state.add_job("c", "selftest", chunk_credentials="same-origin")

if __name__ == "__main__":
    unittest.main()
