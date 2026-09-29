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
# Warum hier eine Kopie in einer *eigenen systemd-Unit* laeuft und nicht das
# Original als Kind des Watchdogs — zwei verschiedene Fallen:
#
#   * kiosk_setup.sh spielt den ganzen Baum per `cp -a` nach
#     ~/linuxmintphotoframe -- also auch ueber die Datei, die bash gerade
#     liest.  bash liest ein Skript haeppchenweise nach; wird es
#     waehrenddessen ueberschrieben, macht bash an seinem alten Byte-Offset
#     in der neuen Datei weiter und fuehrt ein Bruchstueck aus.  Die Kopie in
#     /tmp fasst niemand an.
#
#   * kiosk_setup.sh startet die User-Dienste neu, darunter den Watchdog.
#     systemd raeumt dabei die *ganze Cgroup* der Unit ab -- KillMode ist per
#     Voreinstellung control-group.  `setsid` loest nur die Prozessgruppe,
#     nicht die Cgroup.  Ein setsid-Kind des Watchdogs stirbt also mitten in
#     der Installation: kein Log, kein frame-version.txt, ein /tmp-Klon, den
#     niemand mehr wegraeumt, und beim naechsten Versuch faengt alles von vorn
#     an.  Von Hand gestartet faellt das nie auf -- dann haengt das Deploy an
#     der Login-Session und nicht am Watchdog.  Der Fehler greift
#     ausschliesslich auf dem Weg, fuer den das Skript gebaut ist.
#
#     `systemd-run --user` legt eine transiente Unit mit eigener Cgroup an.
#     Die ueberlebt den Neustart des Watchdogs.
#
# `bash <datei>` statt `<datei>`: die Kopie braucht so kein Ausfuehrbit.
if [[ "${FRAME_SELFUPDATE_DETACHED:-0}" != "1" ]]; then
    kopie="$(mktemp "${TMPDIR:-/tmp}/photoframe_selfupdate.XXXXXX")" || {
        log "ERROR" "Konnte keine Arbeitskopie anlegen — Update nicht gestartet"
        exit 1
    }
    if ! cp "$0" "${kopie}"; then
        rm -f "${kopie}"
        log "ERROR" "Konnte $0 nicht nach ${kopie} kopieren — Update nicht gestartet"
        exit 1
    fi

    if command -v systemd-run >/dev/null 2>&1 && \
       systemd-run --user --quiet --collect \
           --unit="photoframe-selfupdate-$(date +%s)-$$" \
           --description="Bilderrahmen Selbstupdate" \
           --setenv=FRAME_SELFUPDATE_DETACHED=1 \
           --setenv=FRAME_SELFUPDATE_KOPIE="${kopie}" \
           bash "${kopie}" "$@" >>"${UPDATE_LOG}" 2>&1; then
        log "INFO" "Update in eigener systemd-Unit gestartet (Kopie ${kopie})"
        exit 0
    fi

    # Zweite Wahl.  Das Deploy bleibt dabei in der Cgroup des Aufrufers und
    # kann vom Dienste-Neustart abgeschnitten werden -- FRAME_SETUP_WATCHDOG_RESTART
    # weiter unten verschiebt genau diesen Neustart ans Ende, darum ist der
    # Weg nicht hoffnungslos, aber er bleibt der schlechtere.
    if ! command -v setsid >/dev/null 2>&1; then
        rm -f "${kopie}"
        log "ERROR" "Weder systemd-run noch setsid verfuegbar — ohne Abkoppeln wuerde der Dienste-Neustart dieses Deploy abbrechen. Update nicht gestartet."
        exit 1
    fi
    log "WARN" "systemd-run nicht verfuegbar oder abgelehnt — Update laeuft per setsid, also in der Cgroup des Aufrufers"
    export FRAME_SELFUPDATE_DETACHED=1 FRAME_SELFUPDATE_KOPIE="${kopie}"
    setsid bash "${kopie}" "$@" >/dev/null 2>&1 < /dev/null &
    log "INFO" "Update abgekoppelt gestartet (PID $!, Kopie ${kopie})"
    exit 0
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "INFO" "Update laeuft bereits"
    exit 0
fi

# Ab hier haelt dieses Skript die Sperrdatei -- und an der haelt der Watchdog
# den Neustart-Notweg zurueck.  Alles, was jetzt haengt, haengt also nicht nur
# das Deploy auf, sondern auch den letzten Weg in die Maschine.

# Nichts darf auf eine Eingabe warten.  Der Watchdog hat DISPLAY, und git
# macht bei einer Passwortfrage brav ein Fenster auf -- auf einem Bildschirm,
# vor dem niemand sitzt.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
export SSH_ASKPASS=/bin/true
export SSH_ASKPASS_REQUIRE=never
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# Und nichts darf unbegrenzt dauern.  Ein haengender Klon an einer Leitung,
# die zwar steht, aber nichts liefert, kennt von sich aus kein Ende.
mit_frist() {
    local sekunden="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=30 "${sekunden}" "$@"
    else
        "$@"
    fi
}

# kiosk_setup.sh soll den Watchdog nicht mitten in diesem Deploy neu starten.
# Der neue Watchdog-Code gehoert erst gestartet, wenn das Setup durch ist --
# das erledigt der letzte Block dieses Skripts.
export FRAME_SETUP_WATCHDOG_RESTART=defer

aufraeumen() {
    rm -rf "${KLON_DIR}" 2>/dev/null || true
    [[ -n "${FRAME_SELFUPDATE_KOPIE:-}" ]] && rm -f "${FRAME_SELFUPDATE_KOPIE}" 2>/dev/null
    return 0
}
trap aufraeumen EXIT

# Welcher Stand zuletzt ausgerollt wurde.  Ohne das rollt jede erneute Marke
# denselben Code nochmal aus und startet die Dienste fuer nichts neu -- beim
# PAC verhindert das der Vergleich vorher/nachher im Checkout, hier gibt es
# keinen Checkout, also merken wir es uns selbst.
VERSION_FILE="${STATE_DIR}/frame-version.txt"

if ! command -v git >/dev/null 2>&1; then
    log "ERROR" "git fehlt — Update nicht moeglich"
    exit 1
fi

log "INFO" "Update gestartet, klone ${FRAME_REPO_BRANCH} nach ${KLON_DIR}"

if ! mit_frist 300 git clone --depth 1 --branch "${FRAME_REPO_BRANCH}" \
        "${FRAME_REPO_URL}" "${KLON_DIR}" >>"${UPDATE_LOG}" 2>&1; then
    log "ERROR" "git clone fehlgeschlagen — Netz? Der Rahmen laeuft unveraendert weiter."
    exit 1
fi

stand="$(git -C "${KLON_DIR}" rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

if [[ ! -f "${KLON_DIR}/system/bin/kiosk_setup.sh" ]]; then
    log "ERROR" "Klon ${stand} enthaelt kein kiosk_setup.sh — Update abgebrochen"
    exit 1
fi

vorher="$(cat "${VERSION_FILE}" 2>/dev/null || echo "")"
if [[ -n "${vorher}" && "${vorher}" == "${stand}" ]]; then
    log "INFO" "Bereits auf ${stand} — kein Setup noetig"
    exit 0
fi

# Vor dem Ausrollen die Selbsttests des frischen Klons laufen lassen. Sie
# brauchen weder Netz noch echte Remotes; schlagen sie fehl, ist dieser Stand
# nichts, was man unbeaufsichtigt auf einen laufenden Rahmen legt.
for test in system/bin/test_sync.sh system/bin/test_fernbefehle.py; do
    [[ -f "${KLON_DIR}/${test}" ]] || continue
    case "${test}" in
        *.py) lauf=(python3 "${KLON_DIR}/${test}") ;;
        *)    lauf=(bash "${KLON_DIR}/${test}") ;;
    esac
    if ! mit_frist 300 "${lauf[@]}" >>"${UPDATE_LOG}" 2>&1; then
        log "ERROR" "Selbsttest ${test} von ${stand} fehlgeschlagen — nicht ausgerollt, Details in ${UPDATE_LOG}"
        exit 1
    fi
done
log "INFO" "Selbsttests von ${stand} bestanden"

log "INFO" "Rolle ${stand} aus"

if mit_frist 900 bash "${KLON_DIR}/system/bin/kiosk_setup.sh" >>"${UPDATE_LOG}" 2>&1; then
    printf '%s\n' "${stand}" > "${VERSION_FILE}" 2>/dev/null || \
        log "WARN" "Konnte ${VERSION_FILE} nicht schreiben — der naechste Lauf rollt ${stand} erneut aus"
    log "INFO" "Update fertig, Rahmen laeuft auf ${stand}"

    # Jetzt erst der Watchdog.  kiosk_setup.sh hat ihn wegen
    # FRAME_SETUP_WATCHDOG_RESTART=defer ausgelassen, damit er dieses Deploy
    # nicht mitnimmt.  Er laeuft die ganze Zeit weiter, nur mit dem alten
    # Code -- den holt er sich hier ab, als allerletzten Schritt.
    if systemctl --user restart linuxmintphotoframe-watchdog.service >>"${UPDATE_LOG}" 2>&1; then
        log "INFO" "Watchdog auf ${stand} neu gestartet"
    else
        log "WARN" "Watchdog-Neustart fehlgeschlagen — er laeuft mit altem Code weiter, bis jemand nachhilft"
    fi
else
    rc=$?
    log "ERROR" "kiosk_setup.sh mit Exit ${rc} fehlgeschlagen — Details in ${UPDATE_LOG}. Notfalls neustart.txt."
    exit "${rc}"
fi
