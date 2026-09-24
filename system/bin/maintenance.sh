#!/usr/bin/env bash
# Temporarily stop the kiosk browser/watchdog so AnyDesk administration stays visible.

set -euo pipefail
IFS=$'\n\t'

APP_NAME="linuxmintphotoframe"
INSTALL_DIR="${HOME}/${APP_NAME}"
STATE_DIR="${HOME}/state"
LOG_FILE="${STATE_DIR}/kiosk.log"
RESUME_UNIT="linuxmintphotoframe-maintenance-resume"

mkdir -p "${STATE_DIR}"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { printf '%s | maintenance | %s | %s\n' "$(ts)" "$1" "$2" >> "${LOG_FILE}" 2>/dev/null || true; }

cancel_resume_timer() {
    systemctl --user stop "${RESUME_UNIT}.timer" "${RESUME_UNIT}.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${RESUME_UNIT}.timer" "${RESUME_UNIT}.service" >/dev/null 2>&1 || true
}

stop_kiosk() {
    systemctl --user stop linuxmintphotoframe-watchdog.service >/dev/null 2>&1 || true
    systemctl --user stop linuxmintphotoframe-browser.service >/dev/null 2>&1 || true
    pkill -TERM -f "${HOME}/.mozilla/firefox-photoframe" >/dev/null 2>&1 || true
}

resume_kiosk() {
    cancel_resume_timer
    systemctl --user restart linuxmintphotoframe-server.service
    systemctl --user restart linuxmintphotoframe-browser.service
    systemctl --user restart linuxmintphotoframe-watchdog.service
    log "INFO" "maintenance ended, kiosk restarted"
    printf 'Kiosk restarted.\n'
}

usage() {
    cat <<USAGE
Usage:
  maintenance [minutes]
  maintenance off

Examples:
  maintenance 10     stop kiosk browser/watchdog for 10 minutes
  maintenance off    restart kiosk now
USAGE
}

case "${1:-10}" in
    off|resume|start)
        resume_kiosk
        exit 0
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
esac

MINUTES="${1:-10}"
if ! [[ "${MINUTES}" =~ ^[0-9]+$ ]]; then
    usage >&2
    exit 2
fi
if (( MINUTES < 1 )); then MINUTES=1; fi
if (( MINUTES > 240 )); then MINUTES=240; fi

cancel_resume_timer
if ! systemd-run --user --on-active="${MINUTES}min" --unit="${RESUME_UNIT}" --collect "${INSTALL_DIR}/system/bin/maintenance.sh" off >/dev/null; then
    log "ERROR" "could not schedule maintenance resume"
    printf 'Could not schedule automatic resume. Kiosk was not stopped.\n' >&2
    exit 1
fi

stop_kiosk
log "WARN" "maintenance started for ${MINUTES} minutes"
printf 'Maintenance mode for %s minutes. Resume now with: maintenance off\n' "${MINUTES}"
