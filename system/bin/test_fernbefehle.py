#!/usr/bin/env python3
"""Prueft _check_command_files gegen die lokalen Befehlsdateien.

Zwei Ausloeser teilen sich denselben Mechanismus: neustart.txt aus OneDrive
und update.txt aus Google Drive. Beide werden nur bei einer *neuen* Marke
ausgefuehrt, beide merken sich die Marke vor dem Handeln, und sie duerfen sich
nicht gegenseitig ausloesen.

Der Update-Ausloeser startet ein Deploy auf einem Geraet, vor dem niemand
sitzt. Eine Schleife dort waere teuer, darum hat dieser Test mehr Faelle als
die Sache auf den ersten Blick verdient.

Aufruf:  python3 system/bin/test_fernbefehle.py
"""
import logging
import os
import sys
import tempfile
import types
from pathlib import Path

work = Path(tempfile.mkdtemp(prefix="fernbefehle-test-"))
data = work / "frame-data"
(data / "mint2" / "command").mkdir(parents=True)
state = work / "state"
state.mkdir()

os.environ["FRAME_DATA_DIR"] = str(data)

# Stub fuer kiosk_common, damit nichts nach ~/state schreibt.
kc = types.ModuleType("kiosk_common")
kc.STATE_DIR = state
kc.load_env_file = lambda: None
logging.basicConfig(level=logging.DEBUG, format="    %(levelname)s %(message)s")
kc.setup_logging = lambda name: logging.getLogger(name)
sys.modules["kiosk_common"] = kc

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kiosk_watchdog as w  # noqa: E402

reboots = []
updates = []
reihenfolge = []
w._do_reboot = lambda: (reboots.append(1), reihenfolge.append("reboot"), True)[2]
w._do_update = lambda: (updates.append(1), reihenfolge.append("update"), True)[2]

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f" -- {detail}" if detail else ""))
    if not cond:
        fails.append(name)


neustart = w.REBOOT_FILES[0]
update = w.UPDATE_FILES[0]
n_stamp = w.REBOOT_STAMP_FILE
u_stamp = w.UPDATE_STAMP_FILE

print(f"Neustart: {neustart}\nUpdate:   {update}\n")

check("beide liegen im selben command-Ordner", neustart.parent == update.parent)
check("getrennte Stempeldateien", n_stamp != u_stamp)

# --- nichts da -------------------------------------------------------------
w._check_command_files()
check("ohne Dateien passiert nichts", not reboots and not updates)
check("und es entstehen keine Stempel", not n_stamp.exists() and not u_stamp.exists())

# --- erste Marke merkt sich nur ------------------------------------------
update.write_text("2026-09-28 erste\n", encoding="utf-8")
neustart.write_text("2026-09-28 erste\n", encoding="utf-8")
w._check_command_files()
check("erste Marken loesen nichts aus", not updates and not reboots,
      "sonst loest das blosse Ausrollen ein Deploy aus")
check("erste Update-Marke gemerkt", u_stamp.read_text(encoding="utf-8").strip() == "2026-09-28 erste")
check("erste Neustart-Marke gemerkt", n_stamp.read_text(encoding="utf-8").strip() == "2026-09-28 erste")

# --- gleiche Marke, mehrfach ---------------------------------------------
for _ in range(3):
    w._check_command_files()
check("gleiche Marken bleiben folgenlos", not updates and not reboots,
      f"{len(updates)} Updates, {len(reboots)} Neustarts")

# --- nur das Update ist neu ----------------------------------------------
update.write_text("2026-09-28 jetzt\n", encoding="utf-8")
w._check_command_files()
check("neue Update-Marke startet genau ein Update", len(updates) == 1, f"{len(updates)}")
check("und keinen Neustart", not reboots, f"{len(reboots)}")
w._check_command_files()
check("kein zweites Update aus derselben Marke", len(updates) == 1, f"{len(updates)}")

# --- nur der Neustart ist neu --------------------------------------------
neustart.write_text("2026-09-28 jetzt\n", encoding="utf-8")
w._check_command_files()
check("neue Neustart-Marke startet genau einen Neustart", len(reboots) == 1, f"{len(reboots)}")
check("und kein weiteres Update", len(updates) == 1, f"{len(updates)}")

# --- Unfug wird ignoriert -------------------------------------------------
update.write_text("   \n", encoding="utf-8")
w._check_command_files()
check("leere Update-Datei ignoriert", len(updates) == 1)

update.write_text("x" * 5000, encoding="utf-8")
w._check_command_files()
check("zu langer Update-Inhalt ignoriert", len(updates) == 1)

update.unlink()
w._check_command_files()
check("fehlende Update-Datei loest nichts aus", len(updates) == 1)
check("Stempel bleibt nach fehlender Datei",
      u_stamp.read_text(encoding="utf-8").strip() == "2026-09-28 jetzt")

# --- beides gleichzeitig: erst ausrollen, dann neu starten ----------------
reihenfolge.clear()
update.write_text("2026-09-28 beides\n", encoding="utf-8")
neustart.write_text("2026-09-28 beides\n", encoding="utf-8")
w._check_command_files()
check("erst Update, dann Neustart", reihenfolge == ["update", "reboot"],
      f"{reihenfolge} -- sonst startet der Rahmen neu, bevor der neue Stand liegt")

# --- das Skript muss es geben --------------------------------------------
skript = Path(__file__).resolve().parent / "photoframe_selfupdate.sh"
check("photoframe_selfupdate.sh liegt daneben", skript.exists(), str(skript))
check("Watchdog sucht es genau dort", w.UPDATE_SCRIPT == skript, str(w.UPDATE_SCRIPT))

print("\nFAILED:", fails if fails else "keine")
sys.exit(1 if fails else 0)
