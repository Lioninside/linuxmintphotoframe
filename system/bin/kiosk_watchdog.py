#!/usr/bin/env python3
"""Self-healing watchdog for the photo frame kiosk."""

from __future__ import annotations

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
REBOOT_FILE = FRAME_DATA_DIR / "command" / "neustart.txt"
REBOOT_STAMP_FILE = kiosk_common.STATE_DIR / "neustart_zuletzt.txt"
REBOOT_MAX_LEN = 200
LAUNCHER = HOME / "linuxmintphotoframe" / "system" / "bin" / "start_photoframe_kiosk.sh"


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
    if LAUNCHER.exists():
        LOG.warning("INTERVENTION: Firefox window missing, launching kiosk")
        subprocess.Popen([str(LAUNCHER)], env=kiosk_common.x11_env())
    else:
        LOG.error("Launcher missing: %s", LAUNCHER)


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


def _check_reboot_file() -> None:
    try:
        mark = REBOOT_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return
    except OSError as exc:
        LOG.warning("Cannot read reboot file %s: %r", REBOOT_FILE, exc)
        return

    if not mark or len(mark) > REBOOT_MAX_LEN:
        return

    try:
        previous = REBOOT_STAMP_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        REBOOT_STAMP_FILE.write_text(mark, encoding="utf-8")
        LOG.info("Reboot mark first seen: %r (no reboot)", mark)
        return

    if mark == previous:
        return

    REBOOT_STAMP_FILE.write_text(mark, encoding="utf-8")
    LOG.warning("INTERVENTION: new reboot mark %r (previous %r)", mark, previous)
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
            _check_reboot_file()
        except Exception as exc:  # noqa: BLE001
            LOG.error("watchdog loop failed: %r", exc)
        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    raise SystemExit(main())
