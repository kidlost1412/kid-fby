"""Start the REAL autotok FastAPI backend + scheduler tick loop for the end-to-end harness.

    python backend_launcher.py --src <integrations/autotok/src> --work <temp dir> --port <free port>

Own data dir (cwd/data/tiktok.db), own videos dir. Extension deadlines can be shortened through the
environment (the backend has no config for them; they are module constants of api.services.ext):
E2E_CLAIM_WITHIN, E2E_STALE_AFTER, E2E_UPLOAD_WITHIN, E2E_RESULT_WITHIN (seconds).

Safety: the cookie publisher is replaced by a recorder (cookie_calls.txt) and the post-link lookup is a no-op, so
nothing in this process can contact TikTok.
"""
import argparse
import os
import sys
import threading
import time
from datetime import timedelta
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--src", required=True)
ap.add_argument("--work", required=True)
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--tick", type=float, default=0.3)
a = ap.parse_args()

work = Path(a.work).resolve()
for d in ("data", "videos", "home"):
    (work / d).mkdir(parents=True, exist_ok=True)
os.chdir(work)                                   # the DB lives in cwd/data/tiktok.db
os.environ["AUTOTOK_HOME"] = str(work / "home")
os.environ["AUTOTOK_VIDEOS_DIR"] = str(work / "videos")
sys.path[:0] = [str(Path(a.src) / "web"), str(a.src)]

import logging  # noqa: E402

import uvicorn  # noqa: E402

from api.services import ext  # noqa: E402
from api.services import tiktok_adapter  # noqa: E402
from scheduler import worker  # noqa: E402

for env, attr in (("E2E_CLAIM_WITHIN", "CLAIM_WITHIN"), ("E2E_STALE_AFTER", "STALE_AFTER"),
                  ("E2E_UPLOAD_WITHIN", "UPLOAD_WITHIN"), ("E2E_RESULT_WITHIN", "RESULT_WITHIN")):
    if os.environ.get(env):
        setattr(ext, attr, timedelta(seconds=float(os.environ[env])))


def _cookie_recorder(username, video_path, title, options):
    with open(work / "cookie_calls.txt", "a", encoding="utf-8") as f:
        f.write(username + "\n")
    return tiktok_adapter.UploadOutcome(ok=False, message="e2e: cookie publisher must not be used")


tiktok_adapter.upload_from_options = _cookie_recorder
worker.links.tick = lambda: None

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
from api.db import init_db  # noqa: E402
from api.main import app  # noqa: E402

init_db()                                        # tables exist before the first scheduler tick


def scheduler_loop():
    while True:
        try:
            worker.tick()
        except Exception:
            logging.getLogger("e2e").exception("tick failed")
        time.sleep(a.tick)


threading.Thread(target=scheduler_loop, daemon=True).start()
uvicorn.run(app, host="127.0.0.1", port=a.port, log_level="warning")
