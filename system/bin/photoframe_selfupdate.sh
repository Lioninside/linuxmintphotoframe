#!/usr/bin/env bash
# Den Bilderrahmen aktualisieren, ohne dass jemand davorsitzt.
#
# Aufgerufen vom Watchdog, wenn in KioskContent/mint2/command/update.txt eine
# neue Marke steht.  Direkt von Hand geht auch:
#
#     bash ~/linuxmintphotoframe/system/bin/photoframe_selfupdate.sh
#
# Anders als beim PAC-Kiosk ist ~/linuxmintphotoframe **kein** Git-Checkout,
# sondern eine installierte Kopie.  Ein `git pull` gibt es hier also nicht; das
# Update ist ein frischer Klon nach /tmp und ein Lauf von kiosk_setup.sh, genau
# wie ein Deploy von Hand.
#
# Zwei Dinge, die hier nicht offensichtlich sind:
#
# 1. Das Skript startet sich selbst abgekoppelt neu (setsid), wenn es noch am
#    Watchdog haengt.  kiosk_setup.sh startet die User-Dienste neu, darunter
#    den Watchdog -- wer als dessen Kind laeuft, stirbt mitten im Deploy.
#
# 2. Erst wenn Klon UND Setup durch sind, gilt das Update als erledigt.
#    Scheitert etwas, bleibt die laufende Installation unangetastet: der
#    frische Klon liegt in /tmp und wird erst dort geprueft.
#
# Der Neustart-Weg bleibt unabhaengig: neustart.txt liegt in OneDrive und ist
# nicht gedrosselt, update.txt in Google Drive.  Legt ein Deploy den Rahmen
# lahm, haengt der Notweg nicht am selben Strang.

set -uo pipefail

APP_NAME="linuxmintphotoframe"
ENV_FILE="${HOME}/.config/${APP_NAME}/env"
STATE_DIR="${HOME}/state"
LOG_FILE="${STATE_DIR}/kiosk.log"
UPDATE_LOG="${STATE_DIR}/selfupdate.log"
LOCK_FILE="${STATE_DIR}/photoframe-selfupdate.lock"

mkdir -p "${STATE_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

FRAME_REPO_URL="${FRAME_REPO_URL:-https://github.com/Lioninside/linuxmintphotoframe.git}"
FRAME_REPO_BRANCH="${FRAME_REPO_BRANCH:-main}"
KLON_DIR="/tmp/linuxmintphotoframe-update.$$"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() {
    printf '%s | photoframe_selfupdate | %s | %s\n' "$(ts)" "$1" "$2" >> "${LOG_FILE}" 2>/dev/null || true
    printf '%s | %s | %s\n' "$(ts)" "$1" "$2" >> "${UPDATE_LOG}" 2>/dev/null || true
}

# --- Abkoppeln -------------------------------------------------------------
if [[ "${FRAME_SELFUPDATE_DETACHED:-0}" != "1" ]]; then
    if command -v setsid >/dev/null 2>&1; then
        export FRAME_SELFUPDATE_DETACHED=1
        setsid "$0" "$@" >/dev/null 2>&1 < /dev/null &
        exit 0
    fi
    log "WARN" "setsid nicht vorhanden, laufe angehaengt weiter — der Dienste-Neustart kann dieses Deploy abbrechen"
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "INFO" "Update laeuft bereits"
    exit 0
fi

aufraeumen() { rm -rf "${KLON_DIR}" 2>/dev/null || true; }
trap aufraeumen EXIT

if ! command -v git >/dev/null 2>&1; then
    log "ERROR" "git fehlt — Update nicht moeglich"
    exit 1
fi

log "INFO" "Update gestartet, klone ${FRAME_REPO_BRANCH} nach ${KLON_DIR}"

if ! git clone --depth 1 --branch "${FRAME_REPO_BRANCH}" \
        "${FRAME_REPO_URL}" "${KLON_DIR}" >>"${UPDATE_LOG}" 2>&1; then
    log "ERROR" "git clone fehlgeschlagen — Netz? Der Rahmen laeuft unveraendert weiter."
    exit 1
fi

stand="$(git -C "${KLON_DIR}" rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

if [[ ! -f "${KLON_DIR}/system/bin/kiosk_setup.sh" ]]; then
    log "ERROR" "Klon ${stand} enthaelt kein kiosk_setup.sh — Update abgebrochen"
    exit 1
fi

# Vor dem Ausrollen die Selbsttests des frischen Klons laufen lassen. Sie
# brauchen weder Netz noch echte Remotes; schlagen sie fehl, ist dieser Stand
# nichts, was man unbeaufsichtigt auf einen laufenden Rahmen legt.
if [[ -f "${KLON_DIR}/system/bin/test_sync.sh" ]]; then
    if ! bash "${KLON_DIR}/system/bin/test_sync.sh" >>"${UPDATE_LOG}" 2>&1; then
        log "ERROR" "Selbsttest von ${stand} fehlgeschlagen — nicht ausgerollt, Details in ${UPDATE_LOG}"
        exit 1
    fi
    log "INFO" "Selbsttest von ${stand} bestanden"
fi

log "INFO" "Rolle ${stand} aus"

if bash "${KLON_DIR}/system/bin/kiosk_setup.sh" >>"${UPDATE_LOG}" 2>&1; then
    log "INFO" "Update fertig, Rahmen laeuft auf ${stand}"
else
    rc=$?
    log "ERROR" "kiosk_setup.sh mit Exit ${rc} fehlgeschlagen — Details in ${UPDATE_LOG}. Notfalls neustart.txt."
    exit "${rc}"
fi
