#!/usr/bin/env python3
"""Local HTTP server for the photo frame web app.

The browser talks to 127.0.0.1 only. Private photos and message files are read
from FRAME_DATA_DIR, normally a local rclone mirror of OneDrive/Fotoframe.
"""

from __future__ import annotations

import json
import mimetypes
import os
import sys
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import kiosk_common  # noqa: E402


kiosk_common.load_env_file()
LOG = kiosk_common.setup_logging("photoframe_server")

ROOT_DIR = Path(__file__).resolve().parents[2]
APP_DIR = ROOT_DIR / "app"
EXAMPLES_DIR = ROOT_DIR / "examples"
DATA_DIR = Path(os.environ.get("FRAME_DATA_DIR", str(Path.home() / "frame-data"))).expanduser()
PORT = int(os.environ.get("PHOTOFRAME_PORT", "8765"))

PHOTO_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
DEFAULT_CONFIG = {
    "schema_version": 1,
    "photo_seconds": 20,
    "content_reload_seconds": 60,
    "interstitial_every_minutes": 10,
    "interstitial_duration_seconds": 40,
    "priority_rotation_seconds": 45,
    "livecam_enabled": True,
    "livecam_url": "https://www.greifenseewetter.ch/Kamera/greifensee2.jpg",
    "livecam_every_minutes": 45,
    "livecam_duration_seconds": 35,
    "livecam_min_refresh_minutes": 15,
    "quiz_enabled": True,
    "quiz_every_minutes": 10,
    "quiz_block_size": 3,
    "quiz_question_seconds": 12,
    "quiz_answer_seconds": 8,
    "background": "#050506",
}


def safe_join(root: Path, rel: str) -> Path | None:
    decoded = urllib.parse.unquote(rel).replace("\\", "/").lstrip("/")
    candidate = (root / decoded).resolve()
    root_resolved = root.resolve()
    try:
        candidate.relative_to(root_resolved)
    except ValueError:
        return None
    return candidate


def load_json_file(path: Path, fallback: dict) -> dict:
    if not path.exists():
        return fallback
    try:
        with path.open("r", encoding="utf-8") as fh:
            value = json.load(fh)
        return value if isinstance(value, dict) else fallback
    except Exception as exc:  # noqa: BLE001 - written to kiosk log for diagnosis
        LOG.warning("Invalid JSON %s: %r", path, exc)
        return fallback


def list_photos() -> list[dict]:
    photo_dir = DATA_DIR / "photos"
    if not photo_dir.exists():
        return []
    items = []
    for path in photo_dir.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in PHOTO_EXTS:
            continue
        try:
            rel = path.relative_to(photo_dir).as_posix()
            stat = path.stat()
        except OSError:
            continue
        items.append({
            "name": path.name,
            "url": "/data/photos/" + urllib.parse.quote(rel),
            "mtime": int(stat.st_mtime),
            "size": stat.st_size,
        })
    items.sort(key=lambda item: (item["mtime"], item["name"]), reverse=True)
    return items


def content_payload() -> dict:
    config = {**DEFAULT_CONFIG}
    config.update(load_json_file(EXAMPLES_DIR / "config.json", {}))
    config.update(load_json_file(DATA_DIR / "config.json", {}))
    return {
        "generated_at": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        "data_dir": str(DATA_DIR),
        "config": config,
        "photos": list_photos(),
        "news": load_json_file(DATA_DIR / "news.json", {"schema_version": 1, "items": []}),
        "info_images": load_json_file(DATA_DIR / "info-images.json", {"schema_version": 1, "items": []}),
        "quiz": load_json_file(DATA_DIR / "quiz.json", load_json_file(EXAMPLES_DIR / "quiz.json", {"schema_version": 1, "items": []})),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "PhotoFrameHTTP/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        LOG.info("%s - %s", self.address_string(), fmt % args)

    def send_no_cache_headers(self, content_type: str) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")

    def send_json(self, value: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_no_cache_headers("application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path: Path) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        try:
            body = path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        self.send_response(HTTPStatus.OK)
        self.send_no_cache_headers(mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/health":
            self.send_json({"ok": True, "data_dir": str(DATA_DIR), "photos": len(list_photos())})
            return

        if path == "/api/content":
            self.send_json(content_payload())
            return

        if path.startswith("/data/photos/"):
            target = safe_join(DATA_DIR / "photos", path.removeprefix("/data/photos/"))
            self.send_file(target) if target else self.send_error(HTTPStatus.FORBIDDEN)
            return

        if path.startswith("/data/info/"):
            target = safe_join(DATA_DIR / "info", path.removeprefix("/data/info/"))
            self.send_file(target) if target else self.send_error(HTTPStatus.FORBIDDEN)
            return

        rel = "index.html" if path in {"/", ""} else path.lstrip("/")
        target = safe_join(APP_DIR, rel)
        self.send_file(target) if target else self.send_error(HTTPStatus.FORBIDDEN)


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "photos").mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "info").mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "command").mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    LOG.info("photoframe server starting on http://127.0.0.1:%d/ data=%s", PORT, DATA_DIR)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("photoframe server stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
