#!/usr/bin/env python3
"""Shared helpers for the Linux Mint photo frame kiosk."""

from __future__ import annotations

import logging
import logging.handlers
import os
import subprocess
from pathlib import Path


APP_NAME = "linuxmintphotoframe"
HOME = Path.home()
STATE_DIR = HOME / "state"
LOG_FILE = STATE_DIR / "kiosk.log"
ENV_FILE = HOME / ".config" / APP_NAME / "env"


def load_env_file(path: Path = ENV_FILE) -> None:
    """Load KEY=VALUE pairs from the kiosk env file if systemd did not."""
    if not path.exists():
        return
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value
    except OSError:
        return


def setup_logging(name: str) -> logging.Logger:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    if logger.handlers:
        return logger

    handler = logging.handlers.RotatingFileHandler(
        LOG_FILE,
        maxBytes=2_000_000,
        backupCount=2,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter(
        "%(asctime)s | %(name)s | %(levelname)s | %(message)s",
        "%Y-%m-%dT%H:%M:%S",
    ))
    logger.addHandler(handler)
    return logger


def x11_env() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")

    if "XAUTHORITY" not in env:
      candidates = [
          HOME / ".Xauthority",
          Path("/run/user") / str(os.getuid()) / "gdm" / "Xauthority",
      ]
      for candidate in candidates:
          if candidate.exists():
              env["XAUTHORITY"] = str(candidate)
              break
    return env


def run(cmd: list[str], timeout: int = 8, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
        check=False,
    )


def service_restart(name: str, log: logging.Logger) -> None:
    result = run(["systemctl", "--user", "restart", name], timeout=15)
    if result.returncode == 0:
        log.warning("INTERVENTION: restarted user service %s", name)
    else:
        log.error("Failed to restart %s: %s", name, (result.stderr or result.stdout).strip())
