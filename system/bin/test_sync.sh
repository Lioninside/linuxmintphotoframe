#!/usr/bin/env bash
# Selbsttest fuer onedrive_sync.sh.
#
# Prueft die Zwei-Quellen-Logik gegen ein falsches rclone, ohne Netz, ohne
# echte Remotes und ohne irgendetwas ausserhalb eines temporaeren HOME zu
# beruehren.  Die drei wichtigen Faelle sind:
#
#   * Drive noch nicht autorisiert -> uebersprungen, Rahmen laeuft weiter
#   * Drive faellt aus             -> Fotos und Befehle kommen trotzdem
#   * info-images.json aus Drive, mint2/info/ aus OneDrive — die beiden
#     lesen sich aehnlich und duerfen sich nicht vertauschen
#
# Aufruf:  bash system/bin/test_sync.sh
set -uo pipefail

SKRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onedrive_sync.sh"
ARBEIT="$(mktemp -d)"
trap 'rm -rf "${ARBEIT}"' EXIT
FEHLER=0

cat > "${ARBEIT}/rclone" <<'FAKE'
#!/bin/bash
if [[ "$1" == "listremotes" ]]; then printf '%s\n' ${FAKE_REMOTES:-}; exit 0; fi
if [[ "$1" == "copy" ]]; then
  printf '%s | %s\n' "$2" "$(echo "${@:4}" | grep -o -- '--\(include\|exclude\) [^ ]*' | tr '\n' ' ')" \
      >> "${FAKE_CALLS}"
  [[ " ${FAKE_FAIL:-} " == *" $2 "* ]] && exit 7
  exit 0
fi
exit 0
FAKE
chmod +x "${ARBEIT}/rclone"

pruefe() {
    local name="$1" bedingung="$2" detail="${3:-}"
    if [[ "${bedingung}" == "ja" ]]; then
        printf 'PASS  %s%s\n' "${name}" "${detail:+  — ${detail}}"
    else
        printf 'FAIL  %s%s\n' "${name}" "${detail:+  — ${detail}}"
        FEHLER=$((FEHLER + 1))
    fi
}

lauf() {
    export HOME="${ARBEIT}/home"
    rm -rf "${HOME}"; mkdir -p "${HOME}/state"
    export FAKE_CALLS="${ARBEIT}/calls.txt"; : > "${FAKE_CALLS}"
    export FAKE_REMOTES="$1" FAKE_FAIL="${2:-}"
    PATH="${ARBEIT}:${PATH}" bash "${SKRIPT}" >/dev/null 2>&1
    RC=$?
    AUFRUFE="$(cat "${FAKE_CALLS}")"
    LOG="$(cat "${HOME}/state/kiosk.log" 2>/dev/null)"
}

hat() { [[ "$1" == *"$2"* ]] && echo ja || echo nein; }

echo "=== 1) Kein Remote konfiguriert: Rahmen laeuft auf lokalen Daten weiter ==="
lauf ""
pruefe "kein Abbruch" "$([[ ${RC} -eq 0 ]] && echo ja || echo nein)" "exit=${RC}"
pruefe "nichts kopiert" "$([[ -z ${AUFRUFE} ]] && echo ja || echo nein)"
pruefe "meldet sich als WARN, nicht als Erfolg" "$(hat "${LOG}" 'no source was configured')"

echo
echo "=== 2) Nur OneDrive: heutiges Verhalten, Drive stumm uebersprungen ==="
lauf "thusis:"
pruefe "kein Abbruch" "$([[ ${RC} -eq 0 ]] && echo ja || echo nein)" "exit=${RC}"
pruefe "Drive uebersprungen" "$(hat "${LOG}" 'text: rclone remote for gdrive')"
pruefe "OneDrive kopiert" "$(hat "${AUFRUFE}" 'thusis:KioskContent')"
pruefe "Drive nicht aufgerufen" "$([[ ${AUFRUFE} != *gdrive* ]] && echo ja || echo nein)"

echo
echo "=== 3) Beide Quellen: getrennte Pfade, keine Ueberschneidung ==="
lauf "gdrive: thusis:"
pruefe "kein Abbruch" "$([[ ${RC} -eq 0 ]] && echo ja || echo nein)" "exit=${RC}"
TEXT="$(grep '^gdrive:' "${FAKE_CALLS}")"
MEDIA="$(grep '^thusis:' "${FAKE_CALLS}")"
pruefe "Drive holt common/"                "$(hat "${TEXT}" -- '--include common/**')"
pruefe "Drive holt mint2/*.json"           "$(hat "${TEXT}" -- '--include mint2/*.json')"
pruefe "Drive schliesst command/ aus"      "$(hat "${TEXT}" -- '--exclude mint2/command/**')"
pruefe "Drive holt keine Fotos"            "$([[ ${TEXT} != *photos* ]] && echo ja || echo nein)"
pruefe "OneDrive holt Fotos"               "$(hat "${MEDIA}" -- '--include mint2/photos/**')"
pruefe "OneDrive holt die Infobilder"      "$(hat "${MEDIA}" -- '--include mint2/info/**')"
pruefe "OneDrive holt Befehle"             "$(hat "${MEDIA}" -- '--include mint2/command/**')"
pruefe "OneDrive holt keinen Text"         "$([[ ${MEDIA} != *common* && ${MEDIA} != *.json* ]] && echo ja || echo nein)" \
       "--include schliesst alles Uebrige aus"
pruefe "keine Quelle fasst mint1/ an"      "$([[ ${AUFRUFE} != *mint1* ]] && echo ja || echo nein)" \
       "das Telefon geht den Rahmen nichts an"

echo
echo "=== 4) Drive faellt aus: Fotos und Befehle kommen trotzdem ==="
lauf "gdrive: thusis:" "gdrive:KioskContent"
pruefe "meldet Fehler"                     "$([[ ${RC} -ne 0 ]] && echo ja || echo nein)" "exit=${RC}"
pruefe "OneDrive lief trotzdem"            "$(hat "${AUFRUFE}" 'thusis:KioskContent')"
pruefe "Fehler steht im Log"               "$(hat "${LOG}" 'text: copy from gdrive')"
pruefe "lokale Daten bleiben"              "$(hat "${LOG}" 'keeping existing local data')"

echo
if (( FEHLER )); then
    echo "FEHLGESCHLAGEN: ${FEHLER}"
    exit 1
fi
echo "Alles in Ordnung."
