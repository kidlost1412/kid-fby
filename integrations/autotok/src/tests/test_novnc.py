import threading
import time

import pytest
from fastapi.testclient import TestClient

from autotok.errors import LoginError
from novnc import control_server as cs

API = "http://127.0.0.1:8765"
TOKEN = "ab" * 32  # shape of the API's HMAC-SHA256 hex token


def cb(sid):
    return f"{API}/api/login/browser/{sid}/complete?token={TOKEN}"


@pytest.fixture
def client(monkeypatch):
    cs._state = cs._BrowserState()
    posted = []

    class FakeHttp:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

        def post(self, url, json, headers=None):
            assert headers == {"X-Requested-With": "autotok"}
            posted.append((url, json))

            class R:
                def raise_for_status(self):
                    pass

            return R()

    monkeypatch.setattr(cs.httpx, "Client", FakeHttp)
    monkeypatch.setenv("API_PUBLIC_URL", API)
    monkeypatch.delenv("AUTOTOK_ALLOWED_HOSTS", raising=False)
    c = TestClient(cs.app, base_url="http://127.0.0.1:17900", headers={"X-Requested-With": "autotok"})
    c.posted = posted
    return c


def _wait_for(client, sid, status, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = client.get(f"/browser/status/{sid}")
        if r.status_code == 200 and r.json()["status"] == status:
            return r.json()
        time.sleep(0.02)
    raise AssertionError(f"never reached {status}: {r.json()}")


def test_login_posts_cookies_ua_and_proxy(client, monkeypatch):
    seen = {}

    def fake_open(*, proxy, timeout, should_stop):
        seen["proxy"] = proxy
        return [{"name": "sessionid", "value": "s"}], "UA/2"

    monkeypatch.setattr(cs, "open_login_session", fake_open)
    r = client.post("/browser/start", json={"session_id": "post-a", "username": "u",
                                            "callback_url": cb("post-a"),
                                            "proxy": "http://p.example:1"})
    assert r.status_code == 202
    _wait_for(client, "post-a", "completed")
    assert seen["proxy"] == "http://p.example:1"
    assert client.posted == [(cb("post-a"), {"cookies": [{"name": "sessionid", "value": "s"}],
                                                        "user_agent": "UA/2", "proxy": "http://p.example:1"})]


def test_one_login_at_a_time_and_cancel(client, monkeypatch):
    started, finished = threading.Event(), threading.Event()

    def blocking_open(*, proxy, timeout, should_stop):
        started.set()
        try:
            while not should_stop():
                time.sleep(0.01)
            raise LoginError("login cancelled")
        finally:
            finished.set()

    monkeypatch.setattr(cs, "open_login_session", blocking_open)
    client.post("/browser/start", json={"session_id": "slot-a", "username": "u", "callback_url": cb("slot-a")})
    assert started.wait(5)
    busy = client.post("/browser/start", json={"session_id": "slot-b", "username": "u", "callback_url": cb("slot-b")})
    assert busy.status_code == 409
    assert client.delete("/browser/slot-a").status_code == 204
    assert client.get("/browser/status/slot-a").status_code == 404
    # a new login can start right away
    monkeypatch.setattr(cs, "open_login_session", lambda **k: ([{"name": "sessionid", "value": "s"}], "UA"))
    assert client.post("/browser/start", json={"session_id": "slot-c", "username": "u",
                                               "callback_url": cb("slot-c")}).status_code == 202
    _wait_for(client, "slot-c", "completed")
    # the cancelled worker stops by itself and doesn't touch the newer session
    assert finished.wait(5)
    time.sleep(0.05)
    assert client.get("/browser/status/slot-c").json()["status"] == "completed"


def test_failure_is_reported(client, monkeypatch):
    def failing_open(**k):
        raise LoginError("timed out after 600s waiting for TikTok login")

    monkeypatch.setattr(cs, "open_login_session", failing_open)
    client.post("/browser/start", json={"session_id": "fail-a", "username": "u", "callback_url": cb("fail-a")})
    body = _wait_for(client, "fail-a", "failed")
    assert "timed out" in body["error"] and not client.posted


# ---- release review P1: the control server only talks to its own API ----

def _never_open(**k):
    raise AssertionError("no browser may start for a refused request")


@pytest.mark.parametrize("callback", [
    "https://evil.example/steal?token=" + TOKEN,                                  # foreign host
    "http://127.0.0.1:9999/api/login/browser/cb-a/complete?token=" + TOKEN,       # other local port
    "http://127.0.0.1:8765@evil.example/api/login/browser/cb-a/complete?token=" + TOKEN,  # userinfo trick
    "http://127.0.0.1:8765/api/login/browser/OTHER/complete?token=" + TOKEN,      # another session's endpoint
    "http://127.0.0.1:8765/api/accounts?token=" + TOKEN,                          # other API path
    "http://127.0.0.1:8765/api/login/browser/cb-a/complete?token=" + TOKEN + "&x=1",
    "http://127.0.0.1:8765/api/login/browser/cb-a/complete",                       # no token
    "https://127.0.0.1:8765/api/login/browser/cb-a/complete?token=" + TOKEN,     # scheme differs
    "x",
])
def test_foreign_callback_is_refused_without_any_outbound_call(client, monkeypatch, callback):
    monkeypatch.setattr(cs, "open_login_session", _never_open)
    r = client.post("/browser/start", json={"session_id": "cb-a", "username": "u", "callback_url": callback,
                                            "proxy": "http://user:pass@p.example:1"})
    assert r.status_code == 400
    time.sleep(0.05)
    assert client.posted == []
    assert client.get("/browser/status/cb-a").status_code == 404  # no session was created


@pytest.mark.parametrize("host", ["evil.example", "evil.example:17900", "127.0.0.1.evil.example", ""])
def test_unknown_host_is_refused(client, monkeypatch, host):
    monkeypatch.setattr(cs, "open_login_session", _never_open)
    r = client.post("/browser/start", headers={"host": host},
                    json={"session_id": "h-a", "username": "u", "callback_url": cb("h-a")})
    assert r.status_code == 403
    assert client.get("/browser/status/h-a", headers={"host": host}).status_code == 403
    assert client.get("/browser/status/h-a").status_code == 404  # never started


def test_state_changes_without_csrf_header_are_refused(client, monkeypatch):
    monkeypatch.setattr(cs, "open_login_session", _never_open)
    plain = TestClient(cs.app, base_url="http://127.0.0.1:17900")
    r = plain.post("/browser/start", json={"session_id": "c-a", "username": "u", "callback_url": cb("c-a")})
    assert r.status_code == 403
    assert plain.get("/browser/status/c-a").status_code == 404  # GET is allowed, and nothing started
    wrong = plain.post("/browser/start", headers={"X-Requested-With": "XMLHttpRequest"},
                       json={"session_id": "c-a", "username": "u", "callback_url": cb("c-a")})
    assert wrong.status_code == 403


def test_delete_without_csrf_header_does_not_cancel(client, monkeypatch):
    started = threading.Event()

    def blocking_open(*, proxy, timeout, should_stop):
        started.set()
        while not should_stop():
            time.sleep(0.01)
        raise LoginError("login cancelled")

    monkeypatch.setattr(cs, "open_login_session", blocking_open)
    assert client.post("/browser/start", json={"session_id": "d-a", "username": "u",
                                               "callback_url": cb("d-a")}).status_code == 202
    assert started.wait(5)
    plain = TestClient(cs.app, base_url="http://127.0.0.1:17900")
    assert plain.delete("/browser/d-a").status_code == 403
    assert client.get("/browser/status/d-a").json()["status"] == "active"
    assert client.delete("/browser/d-a").status_code == 204


def test_docker_default_callback_and_host_still_work(client, monkeypatch):
    monkeypatch.delenv("API_PUBLIC_URL")
    monkeypatch.setattr(cs, "open_login_session", lambda **k: ([{"name": "sessionid", "value": "s"}], "UA"))
    url = f"http://api:8000/api/login/browser/dock-a/complete?token={TOKEN}"
    r = client.post("/browser/start", headers={"host": "novnc:7900"},
                    json={"session_id": "dock-a", "username": "u", "callback_url": url})
    assert r.status_code == 202
    _wait_for(client, "dock-a", "completed")
    assert [u for u, _ in client.posted] == [url]


def test_api_client_sends_csrf_header_to_control_server(monkeypatch):
    from api.services import novnc_client
    seen = []

    class FakeHttp:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

        def post(self, url, json, headers=None):
            seen.append(("POST", headers))

            class R:
                def raise_for_status(self):
                    pass

                def json(self):
                    return {}

            return R()

        def delete(self, url, headers=None):
            seen.append(("DELETE", headers))

    monkeypatch.setattr(novnc_client.httpx, "Client", FakeHttp)
    novnc_client.start_browser("s", "u", cb("s"))
    novnc_client.stop_browser("s")
    assert seen == [("POST", {"X-Requested-With": "autotok"}), ("DELETE", {"X-Requested-With": "autotok"})]
