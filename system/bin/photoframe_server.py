#!/usr/bin/env python3
"""Local HTTP server for the photo frame web app.

The browser talks to 127.0.0.1 only. Private photos and message files are read
from FRAME_DATA_DIR, normally a local rclone copy of Thusis OneDrive
KioskContent/{common,mint2}.
"""

from __future__ import annotations

import hashlib
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
COMMON_DIR = DATA_DIR / "common"
MINT2_DIR = DATA_DIR / "mint2"
PORT = int(os.environ.get("PHOTOFRAME_PORT", "8765"))

PHOTO_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
DEFAULT_CONFIG = {
    "schema_version": 1,
    "photo_seconds": 45,
    "content_reload_seconds": 60,
    "interstitial_every_minutes": 5,
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


def json_items(path: Path) -> list[dict]:
    doc = load_json_file(path, {"schema_version": 1, "items": []})
    items = doc.get("items")
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


def merged_news() -> dict:
    common_paths = [
        (COMMON_DIR / "news.json", "news"),
        (COMMON_DIR / "recurring.json", "news"),
        (COMMON_DIR / "suggestions.json", "filler"),
    ]
    common_exists = any(path.exists() for path, _ in common_paths)
    sources = common_paths if common_exists else [(DATA_DIR / "news.json", "news")]

    items: list[dict] = []
    for path, default_importance in sources:
        for item in json_items(path):
            normalized = dict(item)
            normalized.setdefault("importance", default_importance)
            items.append(normalized)
    return {"schema_version": 2, "items": items}


def first_json(candidates: list[Path], fallback: dict) -> dict:
    for path in candidates:
        if path.exists():
            return load_json_file(path, fallback)
    return fallback


def list_photos_in(photo_dir: Path) -> list[dict]:
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


def list_photos() -> list[dict]:
    for photo_dir in (MINT2_DIR / "photos", DATA_DIR / "photos"):
        items = list_photos_in(photo_dir)
        if items:
            return items
    return []


def send_first_existing(handler: BaseHTTPRequestHandler, roots: list[Path], rel: str) -> None:
    for root in roots:
        target = safe_join(root, rel)
        if target and target.exists():
            handler.send_file(target)
            return
    handler.send_error(HTTPStatus.NOT_FOUND)


def app_version() -> str:
    """Ein Fingerabdruck der ausgelieferten Oberflaeche.

    Firefox startet hier per `setsid -f`, haengt also in keiner systemd-Unit.
    Ein `systemctl --user restart ...-browser.service` ruft darum nur den
    Starter erneut auf; der sieht "laeuft schon", holt das Fenster nach vorn
    und ist fertig -- die *Seite* wird nie neu geladen. Nach einem
    Selbstupdate lag die neue app.js also auf der Platte, und der Rahmen
    zeigte trotzdem die alte Oberflaeche weiter. Einen naechtlichen Neustart
    gibt es hier nicht, das konnte also beliebig lange so bleiben.

    Statt Firefox dafuer abzuschiessen bekommt die Seite hier eine Kennung.
    Aendert sie sich, laedt die Seite sich beim naechsten Inhaltsabruf selbst
    neu -- innerhalb von content_reload_seconds und ohne schwarzes Bild.
    """
    h = hashlib.sha256()
    for name in ("index.html", "app.js", "styles.css"):
        try:
            h.update(f"{name}:{(APP_DIR / name).stat().st_mtime_ns}".encode())
        except OSError:
            h.update(f"{name}:-".encode())
    return h.hexdigest()[:12]


def content_payload() -> dict:
    config = {**DEFAULT_CONFIG}
    config.update(load_json_file(EXAMPLES_DIR / "config.json", {}))
    config.update(load_json_file(DATA_DIR / "config.json", {}))
    config.update(load_json_file(MINT2_DIR / "config.json", {}))
    return {
        "generated_at": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        "app_version": app_version(),
        "data_dir": str(DATA_DIR),
        "config": config,
        "photos": list_photos(),
        "news": merged_news(),
        "info_images": first_json(
            [MINT2_DIR / "info-images.json", DATA_DIR / "info-images.json"],
            {"schema_version": 1, "items": []},
        ),
        "quiz": first_json(
            [MINT2_DIR / "quiz.json", DATA_DIR / "quiz.json"],
            load_json_file(EXAMPLES_DIR / "quiz.json", {"schema_version": 1, "items": []}),
        ),
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
            send_first_existing(self, [MINT2_DIR / "photos", DATA_DIR / "photos"], path.removeprefix("/data/photos/"))
            return

        if path.startswith("/data/info/"):
            send_first_existing(self, [MINT2_DIR / "info", DATA_DIR / "info"], path.removeprefix("/data/info/"))
            return

        rel = "index.html" if path in {"/", ""} else path.lstrip("/")
        target = safe_join(APP_DIR, rel)
        self.send_file(target) if target else self.send_error(HTTPStatus.FORBIDDEN)


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    COMMON_DIR.mkdir(parents=True, exist_ok=True)
    (MINT2_DIR / "photos").mkdir(parents=True, exist_ok=True)
    (MINT2_DIR / "info").mkdir(parents=True, exist_ok=True)
    (MINT2_DIR / "command").mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    LOG.info("photoframe server starting on http://127.0.0.1:%d/ data=%s", PORT, DATA_DIR)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("photoframe server stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
