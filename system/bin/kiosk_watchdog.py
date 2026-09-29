#!/usr/bin/env python3
"""Self-healing watchdog for the photo frame kiosk."""

from __future__ import annotations

import fcntl
import os
import subprocess
import time
import urllib.request
from pathlib import Path

import kiosk_common


kiosk_common.load_env_file()
LOG = kiosk_common.setup_logging("photoframe_watchdog")

HOME = Path.home()
FRAME_DATA_DIR = Path(os.environ.get("FRAME_DATA_DIR", str(HOME / "frame-data"))).expanduser()
PORT = int(os.environ.get("PHOTOFRAME_PORT", "8765"))
DISPLAY_OUTPUT = os.environ.get("DISPLAY_OUTPUT", "").strip()
DISPLAY_MODE = os.environ.get("DISPLAY_MODE", "").strip()

LOOP_INTERVAL = 30
REBOOT_FILES = [
    FRAME_DATA_DIR / "mint2" / "command" / "neustart.txt",
    FRAME_DATA_DIR / "command" / "neustart.txt",
]
REBOOT_STAMP_FILE = kiosk_common.STATE_DIR / "neustart_zuletzt.txt"
REBOOT_MAX_LEN = 200

# Derselbe Mechanismus fuer ein Code-Update. Zwei Unterschiede zum Neustart,
# beide Absicht:
#
#   * update.txt liegt in **Google Drive**, neustart.txt in OneDrive. Der
#     Notweg haengt damit nicht am selben Strang wie der Weg, der ihn
#     kaputtmachen kann.
#   * Der Drive-Durchgang ist auf 30 Minuten gedrosselt (Googles
#     Minutenkontingent, siehe onedrive_sync.sh). Ein Update kommt also mit bis
#     zu einer halben Stunde Verzoegerung an, ein Neustart in zwei Minuten.
#     Das ist die richtige Reihenfolge der Dringlichkeiten.
UPDATE_FILES = [
    FRAME_DATA_DIR / "mint2" / "command" / "update.txt",
    FRAME_DATA_DIR / "command" / "update.txt",
]
UPDATE_STAMP_FILE = kiosk_common.STATE_DIR / "update_zuletzt.txt"
UPDATE_SCRIPT = Path(__file__).resolve().parent / "photoframe_selfupdate.sh"

# Dieselbe Sperrdatei, die photoframe_selfupdate.sh haelt, solange es
# arbeitet. Sie beantwortet die Frage "laeuft gerade ein Deploy?" -- und damit
# ein Rennen: der Neustart darf nicht mitten in eine Installation fallen.
UPDATE_LOCK_FILE = kiosk_common.STATE_DIR / "photoframe-selfupdate.lock"

# ...aber nicht unbegrenzt. Der Neustart ist der Notweg; haengt ein Deploy,
# darf es ihn nicht auf Dauer verstellen.
UPDATE_WAIT_MAX_SEC = 600

# Seit wann ein laufendes Update den Neustart zurueckhaelt. 0 = kein Update.
_update_wartet_seit = 0.0


def _run(cmd: list[str], timeout: int = 8) -> subprocess.CompletedProcess[str]:
    return kiosk_common.run(cmd, timeout=timeout, env=kiosk_common.x11_env())


def _firefox_window_id() -> str:
    result = _run(["wmctrl", "-lx"], timeout=3)
    if result.returncode != 0:
        return ""
    for line in result.stdout.splitlines():
        if "firefox" in line.lower():
            return line.split()[0]
    return ""


def _focus_fullscreen() -> None:
    win = _firefox_window_id()
    if not win:
        return
    _run(["wmctrl", "-ia", win], timeout=3)
    _run(["wmctrl", "-ir", win, "-b", "add,fullscreen"], timeout=3)


def _check_server() -> None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/health", timeout=5) as res:
            if res.status == 200:
                return
    except Exception:
        pass
    kiosk_common.service_restart("linuxmintphotoframe-server.service", LOG)


def _check_browser() -> None:
    win = _firefox_window_id()
    if win:
        _focus_fullscreen()
        return
    kiosk_common.service_restart("linuxmintphotoframe-browser.service", LOG)


def _check_dpms() -> None:
    _run(["xset", "-dpms"], timeout=3)
    _run(["xset", "s", "off"], timeout=3)
    _run(["xset", "s", "noblank"], timeout=3)


def _check_display_mode() -> None:
    if not DISPLAY_OUTPUT or not DISPLAY_MODE:
        return
    result = _run(["xrandr"], timeout=4)
    if result.returncode != 0:
        return
    active_line = ""
    for line in result.stdout.splitlines():
        if line.startswith(f"{DISPLAY_OUTPUT} ") and " connected" in line:
            active_line = line
            break
    if not active_line:
        LOG.info("Display output %s not connected", DISPLAY_OUTPUT)
        return
    if DISPLAY_MODE in active_line:
        return
    reset = _run(["xrandr", "--output", DISPLAY_OUTPUT, "--mode", DISPLAY_MODE], timeout=8)
    if reset.returncode == 0:
        LOG.warning("INTERVENTION: display reset to %s on %s", DISPLAY_MODE, DISPLAY_OUTPUT)
    else:
        LOG.warning("Display reset failed: %s", (reset.stderr or reset.stdout).strip())


def _do_reboot() -> bool:
    for cmd in (["systemctl", "reboot"], ["sudo", "-n", "/sbin/reboot"]):
        try:
            result = subprocess.run(cmd, text=True, capture_output=True, timeout=10, check=False)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("Reboot command failed before execution %s: %r", cmd, exc)
            continue
        if result.returncode == 0:
            LOG.warning("INTERVENTION: reboot triggered via '%s'", " ".join(cmd))
            return True
        LOG.warning("Reboot command refused '%s': %s", " ".join(cmd), (result.stderr or result.stdout).strip())
    return False


def _new_mark(candidates: list[Path], stamp_file: Path, what: str) -> str | None:
    """Die Marke aus der ersten vorhandenen Befehlsdatei lesen, wenn sie neu ist.

    Gibt die Marke zurueck, wenn gehandelt werden soll, sonst None. Der Stempel
    wird **vorher** geschrieben: klappt die Aktion, das Schreiben danach aber
    nicht, liefe der Rahmen sonst in eine Schleife.

    Der Inhalt wird nie ausgefuehrt, nur verglichen. Er ist eine Marke, kein
    Befehl.
    """
    source = None
    try:
        for candidate in candidates:
            try:
                mark = candidate.read_text(encoding="utf-8").strip()
                source = candidate
                break
            except FileNotFoundError:
                continue
        else:
            return None
    except OSError as exc:
        LOG.warning("Cannot read %s file %s: %r", what, source or candidates[0], exc)
        return None

    if not mark or len(mark) > REBOOT_MAX_LEN:
        return None

    try:
        previous = stamp_file.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        # Erster Lauf: merken, aber NICHT handeln. Sonst loest das blosse
        # Ausrollen dieser Funktion die Aktion aus.
        stamp_file.write_text(mark, encoding="utf-8")
        LOG.info("%s mark first seen: %r (no action)", what, mark)
        return None
    except OSError:
        return None

    if mark == previous:
        return None

    stamp_file.write_text(mark, encoding="utf-8")
    LOG.warning("INTERVENTION: new %s mark %r from %s (previous %r)",
                what, mark, source, previous)
    return mark


def _update_laeuft() -> bool:
    """True, solange photoframe_selfupdate.sh seine Sperrdatei haelt.

    Nicht-blockierend: Sperre versuchen und sofort wieder hergeben. Gelingt
    sie nicht, arbeitet gerade ein Deploy.
    """
    try:
        with open(UPDATE_LOCK_FILE, "a") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return True
            fcntl.flock(fh, fcntl.LOCK_UN)
    except OSError:
        return False
    return False


def _do_update() -> bool:
    """Das Selbstupdate anstossen. True, wenn es gestartet werden konnte.

    Das Skript koppelt sich selbst ab; wir warten hier nicht darauf. Muessten
    wir es, wuerde der Watchdog blockieren, waehrend kiosk_setup.sh ihn gerade
    neu startet.
    """
    if not UPDATE_SCRIPT.exists():
        LOG.error("Update requested, but %s is missing", UPDATE_SCRIPT)
        return False
    try:
        subprocess.Popen(
            ["bash", str(UPDATE_SCRIPT)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        LOG.warning("INTERVENTION: self-update started via %s", UPDATE_SCRIPT)
        return True
    except Exception as exc:  # noqa: BLE001
        LOG.error("Could not start self-update: %r", exc)
        return False


def _check_command_files() -> None:
    """Update und Neustart pruefen -- das Update zuerst.

    Liegt beides gleichzeitig an, soll erst der neue Stand ausgerollt und dann
    neu gestartet werden, nicht umgekehrt.

    Die blosse Reihenfolge genuegt dafuer nicht. Das Deploy laeuft abgekoppelt
    weiter, waehrend diese Funktion schon zurueckkommt -- ein Neustart direkt
    danach fiele also mitten in die Installation. Solange das Deploy seine
    Sperrdatei haelt, wird die Neustart-Marke deshalb gar nicht erst gelesen;
    sie bleibt liegen und greift beim naechsten Durchlauf. Nach
    UPDATE_WAIT_MAX_SEC gewinnt der Neustart trotzdem: er ist der Notweg.
    """
    global _update_wartet_seit
    now = time.time()

    if _new_mark(UPDATE_FILES, UPDATE_STAMP_FILE, "update"):
        _do_update()
        _update_wartet_seit = now
        return

    if _update_laeuft():
        if not _update_wartet_seit:
            _update_wartet_seit = now
        gewartet = now - _update_wartet_seit
        if gewartet < UPDATE_WAIT_MAX_SEC:
            LOG.info("Update running for %ds — reboot mark left unread", int(gewartet))
            return
        LOG.warning("Update running for %ds and blocking the emergency path — "
                    "reading the reboot mark anyway", int(gewartet))
    else:
        _update_wartet_seit = 0.0

    if _new_mark(REBOOT_FILES, REBOOT_STAMP_FILE, "reboot"):
        if not _do_reboot():
            LOG.error("Reboot requested, but no reboot method worked")


def main() -> int:
    kiosk_common.STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG.info("photoframe watchdog starting, interval=%ss data=%s", LOOP_INTERVAL, FRAME_DATA_DIR)
    while True:
        try:
            _check_server()
            _check_browser()
            _check_dpms()
            _check_display_mode()
            _check_command_files()
        except Exception as exc:  # noqa: BLE001
            LOG.error("watchdog loop failed: %r", exc)
        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    raise SystemExit(main())
