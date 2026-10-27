"""FastAPI application entry point.

Exposes CRUD and upload endpoints backed by SQLite. OpenAPI docs at /docs
render the Pydantic schemas defined in api.schemas — this is what satisfies
"all schemas are defined and presented in the API".
"""
from __future__ import annotations

import logging
import os

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

import autotok
import api.db as _api_db
from api.db import init_db
from api.routers import accounts, desktop, ext, history, login, proxy, schedules, uploads, videos
from api.security import allowed_hosts, hostname
from api.services import ext as ext_service
from api.services import history as history_service
from autotok import settings
from sqlmodel import Session

log = logging.getLogger("api.main")


# Browsers can't add custom headers to cross-site requests without a CORS
# preflight, which this API never approves. Requiring one on every request that
# changes something stops other web pages from driving the local API (CSRF).
CSRF_HEADER = "X-Requested-With"
CSRF_VALUE = "autotok"
_SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


def create_app() -> FastAPI:
    app = FastAPI(
        title="autotok API",
        version=autotok.__version__,
        description=(
            "REST API for managing TikTok accounts, uploading videos "
            "(local file or YouTube URL), and scheduling uploads. "
            "Backs the React web UI; shares its account store with the autotok CLI."
        ),
    )

    # The web app is served from the same origin (nginx / the Vite dev proxy),
    # so no cross-origin access is allowed unless explicitly configured.
    origins = [o.strip() for o in os.getenv("AUTOTOK_CORS_ORIGINS", "").split(",") if o.strip()]
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_methods=["*"],
            allow_headers=["*"],
            allow_credentials=False,
        )

    @app.middleware("http")
    async def _require_known_host(request: Request, call_next):
        if hostname(request.headers.get("host", "")) not in allowed_hosts():
            return JSONResponse(
                {"detail": "unknown Host header; add it to AUTOTOK_ALLOWED_HOSTS if you use this name"},
                status_code=403,
            )
        return await call_next(request)

    @app.middleware("http")
    async def _require_csrf_header(request: Request, call_next):
        if (
            request.method not in _SAFE_METHODS
            and request.url.path.startswith("/api/")
            and request.headers.get(CSRF_HEADER) != CSRF_VALUE
        ):
            return JSONResponse(
                {"detail": f"missing header {CSRF_HEADER}: {CSRF_VALUE}"}, status_code=403
            )
        return await call_next(request)

    # Outermost: CORS headers for the Chrome extension origin on /api/ext/* only.
    ext.install_cors(app)
    app.add_exception_handler(ext.ExtError, ext.ext_error_response)

    @app.on_event("startup")
    def _startup() -> None:
        # Ensure the account store and video library exist on the shared volume.
        for d in (settings.accounts_dir(), settings.videos_dir()):
            os.makedirs(d, exist_ok=True)
        init_db()
        # Recovery only reports and repairs; a failure here must not keep the API down.
        for step in (history_service.backfill, desktop.recover_on_startup, history_service.recover_direct):
            try:
                with Session(_api_db.engine) as session:
                    step(session)
            except Exception:
                log.exception("startup recovery step %s failed", step.__name__)
        try:
            ext_service.reconcile_ext()  # results stored before a restart reach their jobs
        except Exception:
            log.exception("startup recovery step reconcile_ext failed")

    def _ext_active() -> int:
        try:
            with Session(_api_db.engine) as session:
                return ext_service.active_children(session)
        except Exception:
            return -1  # unknown: callers must treat it as busy

    @app.get("/health", tags=["meta"])
    def health():
        return {"status": "ok", "desktop_bridge": 1, "history_version": 2, "video_streaming": True,
                "native_schedule": 1, "post_links": 1, "chrome_ext": 1,
                "ext_protocol_min": ext_service.PROTOCOL_MIN, "ext_protocol_max": ext_service.PROTOCOL_MAX,
                "ext_active": _ext_active()}

    app.include_router(accounts.router)
    app.include_router(desktop.router)
    app.include_router(history.router)
    app.include_router(videos.router)
    app.include_router(uploads.router)
    app.include_router(schedules.router)
    app.include_router(login.router)
    app.include_router(proxy.router)
    app.include_router(ext.router)
    return app


app = create_app()
