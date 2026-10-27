"""Independent QA tests for the post gate (R1/R2/R6). Oracle = the owner's requirements, not the implementation.
Local only: ephemeral 127.0.0.1 ports, temp dirs. Never touches TikTok or the real devserver port."""
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import devserver

TOKEN = "qa-secret-bearer-token-XYZ987"
BIND = {"body_sha256": "b" * 64, "creation_id": "CrEaTiOnId_QA_00000001"}


def call(base, path, body=None, token=TOKEN):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 method="POST" if body is not None else "GET",
                                 headers={"Authorization": "Bearer " + token} if token else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else None)


class QA(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.video = self.dir / "clip tiếng việt [1].mp4"
        self.video.write_bytes(b"x" * 4096)
        self.log = self.dir / "dev.jsonl"
        self.state_path = self.dir / "state.json"

    # Run devserver.main() exactly as the owner does from the command line, on an ephemeral port.
    def run_cli(self, argv):
        holder = {}
        real = devserver.make_server

        def capture(state, port):
            srv = real(state, 0)
            holder["srv"], holder["state"] = srv, state
            return srv

        devserver.make_server = capture
        self.addCleanup(setattr, devserver, "make_server", real)
        t = threading.Thread(target=lambda: holder.__setitem__("rc", devserver.main(argv)), daemon=True)
        t.start()
        for _ in range(100):
            if "srv" in holder or "rc" in holder:
                break
            time.sleep(0.05)
        devserver.make_server = real
        if "srv" not in holder:                               # main() refused to start (a valid way to block a re-post)
            self.assertNotEqual(holder.get("rc"), 0, "server neither started nor reported an error")
            return None, None, lambda: None
        srv = holder["srv"]
        base = f"http://127.0.0.1:{srv.server_address[1]}"

        def stop():
            srv.shutdown()
            srv.server_close()
            t.join(5)
        return base, holder["state"], stop

    def cli(self):
        return ["--token", TOKEN, "--video", str(self.video), "--mode", "post", "--allow-post", "--visibility", "private",
                "--expect-account", "me.user", "--caption", "xin chào #qa", "--state", str(self.state_path), "--log", str(self.log)]

    # R1: the owner re-runs the SAME command after a crash/restart while the first post's outcome is unknown.
    def test_restart_with_same_command_never_enables_a_second_post(self):
        base, st, stop = self.run_cli(self.cli())
        code, job1 = call(base, "/api/next?wait=0")
        self.assertEqual(code, 200)
        code, r = call(base, "/api/authorize", {"id": job1["id"], "nonce": job1["nonce"], **BIND})
        self.assertEqual(r["ok"], True)                       # first post authorized; assume it was sent and the reply lost
        stop()

        base, st, stop = self.run_cli(self.cli())             # restart: identical command line
        self.addCleanup(stop)
        if base is None:
            return                                            # refused to start: no second post possible
        self.assertEqual(st.jobs[job1["id"]]["state"], "uncertain")
        code, job2 = call(base, "/api/next?wait=0")
        granted = False
        if code == 200 and job2 and job2.get("mode") == "post":
            call(base, "/api/progress", {"id": job2["id"], "nonce": job2["nonce"], "phase": "x"})
            granted = call(base, "/api/authorize", {"id": job2["id"], "nonce": job2["nonce"], **{**BIND, "creation_id": "Other_creation_000001"}})[1]["ok"]
        self.assertFalse(granted, "a second post of the same video was authorized while the first one is uncertain")

    # R1: the first post SUCCEEDED and was recorded; the owner later re-runs the same command (e.g. to look at the log).
    def test_rerun_after_recorded_post_does_not_queue_the_same_post_again(self):
        base, st, stop = self.run_cli(self.cli())
        code, job1 = call(base, "/api/next?wait=0")
        self.assertTrue(call(base, "/api/authorize", {"id": job1["id"], "nonce": job1["nonce"], **BIND})[1]["ok"])
        call(base, "/api/result", {"id": job1["id"], "nonce": job1["nonce"], "outcome": "posted", "item_id": "7300000000000000001"})
        stop()
        base, st, stop = self.run_cli(self.cli())
        self.addCleanup(stop)
        if base is None:
            return                                            # refused to start: no second post possible
        code, job2 = call(base, "/api/next?wait=0")
        self.assertFalse(code == 200 and job2 and job2.get("mode") == "post",
                         "re-running the same --mode post command queued a new post job for the already-posted video")

    # R6: the bearer token never appears in the log (right or wrong token).
    def test_bearer_token_never_logged(self):
        base, st, stop = self.run_cli(["--token", TOKEN, "--video", str(self.video), "--mode", "selftest",
                                       "--state", str(self.state_path), "--log", str(self.log)])
        self.addCleanup(stop)
        code, job = call(base, "/api/next?wait=0")
        call(base, "/api/progress", {"id": job["id"], "nonce": job["nonce"], "phase": "p"})
        call(base, "/api/next?wait=0", token=TOKEN + "-wrong")
        call(base, "/api/result", {"id": job["id"], "nonce": job["nonce"], "outcome": "selftest_ok"})
        text = self.log.read_text(encoding="utf-8") + self.state_path.read_text(encoding="utf-8")
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("XYZ987", text)

    # R2: without --allow-post, even a hand-edited/old state file with a post job can never be authorized.
    def test_no_allow_post_restart_cannot_authorize_old_post_job(self):
        base, st, stop = self.run_cli(self.cli())
        code, job1 = call(base, "/api/next?wait=0")
        stop()
        argv = [a for a in self.cli() if a != "--allow-post"]
        argv[argv.index("post")] = "selftest"
        base, st, stop = self.run_cli(argv)
        self.addCleanup(stop)
        st.jobs[job1["id"]]["state"] = "running"             # even if it were somehow live again
        self.assertEqual(call(base, "/api/authorize", {"id": job1["id"], "nonce": job1["nonce"], **BIND})[1],
                         {"ok": False, "reason": "post-disabled"})

    # Persisting a new job fails (e.g. Windows AV holds state.json): the job must not become claimable anyway.
    def test_job_that_failed_to_persist_is_not_served(self):
        st = devserver.State(TOKEN, self.video, self.log, True, self.dir / "missing-dir" / "state.json")
        srv = devserver.make_server(st, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        base = f"http://127.0.0.1:{srv.server_address[1]}"
        with self.assertRaises(OSError):
            st.add_job("c", "post", "private", None, "me.user")
        code, _ = call(base, "/api/next?wait=0")
        self.assertEqual(code, 204, "a post job whose creation raised is still handed out")

    # The grant is documented as nonce-bound: a request without the nonce must not be authorized.
    def test_authorize_without_nonce_is_refused(self):
        st = devserver.State(TOKEN, self.video, self.log, True, self.state_path)
        srv = devserver.make_server(st, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        base = f"http://127.0.0.1:{srv.server_address[1]}"
        j = st.add_job("c", "post", "private", None, "me.user")
        call(base, "/api/next?wait=0")
        code, r = call(base, "/api/authorize", {"id": j["id"], **BIND})
        self.assertFalse(code == 200 and r and r.get("ok"), "authorized without the job nonce")


if __name__ == "__main__":
    unittest.main()
