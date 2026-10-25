"""Native Windows host for upstream API/UI/control/scheduler; no source fork."""
from __future__ import annotations
import argparse
import logging
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE / 'src'


def resolve_data_dir() -> Path:
    """AUTOTOK_DATA_DIR, else config.json "DataDir" next to this file, else %LOCALAPPDATA%\\KidFBY\\autotok-data."""
    env = os.environ.get('AUTOTOK_DATA_DIR', '').strip()
    if env:
        return Path(env)
    config = HERE / 'config.json'
    if config.is_file():
        import json
        # utf-8-sig: Windows PowerShell 5.1 writes a BOM; a corrupt file must fail loudly, not silently switch data dirs.
        value = str(json.loads(config.read_text(encoding='utf-8-sig')).get('DataDir') or '').strip()
        if value:
            return Path(value)
    return Path(os.environ.get('LOCALAPPDATA') or Path.home() / 'AppData' / 'Local') / 'KidFBY' / 'autotok-data'


def find_chrome() -> str:
    roots = [os.environ.get(k) for k in ('ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')]
    candidates = [Path(r) / 'Google' / 'Chrome' / 'Application' / 'chrome.exe' for r in roots if r]
    for c in candidates:
        if c.is_file():
            return str(c)
    raise RuntimeError('Chrome was not found in Program Files, Program Files (x86) or LocalAppData.')


DATA = resolve_data_dir()
DIST = REPO / 'web' / 'frontend' / 'dist'

if __name__ == '__main__' and '--check' in sys.argv[1:]:
    # Print resolved paths and exit; touches no service and creates nothing.
    try:
        chrome = find_chrome()
    except RuntimeError as exc:
        chrome = f'NOT FOUND ({exc})'
    print(f'SRC={REPO}\nDATA={DATA}\nDIST={DIST} index.html={(DIST / "index.html").is_file()}\nCHROME={chrome}')
    sys.exit(0)

sys.path[:0] = [str(REPO), str(REPO / 'web')]
os.environ.update({
    'AUTOTOK_HOME': str(DATA),
    'AUTOTOK_VIDEOS_DIR': str(DATA / 'videos'),
    'TIKTOK_API_DB_PATH': str(DATA / 'dashboard.db'),
    'AUTOTOK_BROWSER': 'local',
    'AUTOTOK_BROWSER_PATH': find_chrome(),
    'NOVNC_CONTROL_URL': 'http://127.0.0.1:17900',
    'NOVNC_PUBLIC_URL': '/local-browser.html',
    'API_PUBLIC_URL': 'http://127.0.0.1:8765',
    'SCHEDULER_POLL_SECONDS': '2',
})
os.chdir(REPO)
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(name)s %(levelname)s %(message)s')
logging.getLogger('httpx').setLevel(logging.WARNING)
logging.getLogger('httpcore').setLevel(logging.WARNING)

def serve_api():
    import uvicorn
    from fastapi import HTTPException
    from fastapi.responses import FileResponse, HTMLResponse
    from fastapi.staticfiles import StaticFiles
    from api.main import app

    dist = DIST
    if not (dist / 'index.html').is_file():
        raise RuntimeError('Build the original frontend before starting this host.')

    @app.get('/local-browser.html', include_in_schema=False)
    def native_browser_info():
        return HTMLResponse('''<!doctype html><html lang="vi"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font:16px/1.7 system-ui;color:#334155;background:#f8fafc;padding:48px;max-width:650px;margin:auto}
h1{font-size:24px;color:#0f172a}li{margin:12px 0}.tag{display:inline-block;color:#0f766e;background:#ccfbf1;border-radius:16px;padding:4px 12px}</style>
<span class="tag">Chạy trực tiếp trên Windows</span><h1>Đăng nhập ở cửa sổ Chrome vừa mở</h1>
<ol><li>Tìm cửa sổ Chrome riêng đang mở trang đăng nhập TikTok.</li>
<li>Đăng nhập hoặc dùng ứng dụng TikTok trên điện thoại để quét mã QR.</li>
<li>Giữ bảng điều khiển này mở. Khi đăng nhập xong, chương trình tự lưu phiên và hiện “Đã lưu phiên đăng nhập”.</li></ol>
<p>Bản chạy local dùng cửa sổ Chrome riêng. Bản Docker của repo hiển thị trình duyệt trong khung noVNC tại vị trí này.</p>
</html>''')

    app.mount('/assets', StaticFiles(directory=dist / 'assets'), name='frontend-assets')

    @app.get('/{page:path}', include_in_schema=False)
    def spa(page: str):
        if page.startswith(('api/', 'assets/', 'browser/')):
            raise HTTPException(404)
        # index.html names the hashed bundles: always revalidate so updates show up; /assets stay cacheable.
        return FileResponse(dist / 'index.html', headers={'Cache-Control': 'no-cache'})

    # Avoid logging callback query tokens or file names from API requests.
    uvicorn.run(app, host='127.0.0.1', port=8765, access_log=False)

def init_database():
    """One-shot: create/migrate the dashboard database before the services start (start.ps1),
    so the API and the scheduler never migrate a fresh file at the same moment."""
    DATA.mkdir(parents=True, exist_ok=True)
    from api.db import init_db
    init_db()

def serve_control():
    import uvicorn
    from novnc.control_server import app
    uvicorn.run(app, host='127.0.0.1', port=17900, access_log=False)

if __name__ == '__main__' and '--init-db' in sys.argv[1:]:
    init_database()
    sys.exit(0)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('service', choices=['api', 'control', 'scheduler'])
    args = parser.parse_args()
    if args.service == 'api':
        serve_api()
    elif args.service == 'control':
        serve_control()
    else:
        from scheduler.main import main
        main()
