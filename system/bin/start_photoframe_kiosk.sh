#!/usr/bin/env bash
# Start or focus the local Firefox photo frame kiosk.

set -euo pipefail
IFS=$'\n\t'

APP_NAME="linuxmintphotoframe"
ENV_FILE="${HOME}/.config/${APP_NAME}/env"
STATE_DIR="${HOME}/state"
KIOSK_LOG="${STATE_DIR}/kiosk.log"
PROFILE_DIR="${HOME}/.mozilla/firefox-photoframe"
LOCK_FILE="${STATE_DIR}/photoframe-firefox.lock"

mkdir -p "${STATE_DIR}" "${PROFILE_DIR}/chrome"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

PHOTOFRAME_PORT="${PHOTOFRAME_PORT:-8765}"
URL="${1:-http://127.0.0.1:${PHOTOFRAME_PORT}/}"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { printf '%s | photoframe_launcher | %s | %s\n' "$(ts)" "$1" "$2" >> "${KIOSK_LOG}" 2>/dev/null || true; }

FIREFOX_BIN=""
if command -v firefox >/dev/null 2>&1; then
    FIREFOX_BIN="$(command -v firefox)"
elif command -v firefox-esr >/dev/null 2>&1; then
    FIREFOX_BIN="$(command -v firefox-esr)"
fi

if [[ -z "${FIREFOX_BIN}" ]]; then
    log "ERROR" "firefox binary not found"
    exit 1
fi

firefox_pids() {
    local uid f pid_dir stat_uid
    uid="$(id -u)"
    for f in /proc/*/cmdline; do
        [[ -r "$f" ]] || continue
        pid_dir="${f%/cmdline}"
        stat_uid="$(stat -c %u "${pid_dir}" 2>/dev/null)" || continue
        [[ "${stat_uid}" == "${uid}" ]] || continue
        if grep -qaE "firefox/firefox|firefox-esr/firefox-esr" "$f" 2>/dev/null; then
            printf '%s\n' "${pid_dir##*/}"
        fi
    done
    return 0
}

firefox_window_id() {
    command -v wmctrl >/dev/null 2>&1 || return 1
    local list
    list="$(wmctrl -lx 2>/dev/null)" || return 1
    printf '%s\n' "${list}" | awk 'tolower($0) ~ /firefox/ {print $1; exit}'
    return 0
}

bring_to_front() {
    command -v wmctrl >/dev/null 2>&1 || return 0
    local win
    win="$(firefox_window_id)" || true
    [[ -z "${win:-}" ]] && return 0
    wmctrl -ia "${win}"                  2>/dev/null || true
    wmctrl -ir "${win}" -b remove,hidden 2>/dev/null || true
    wmctrl -ir "${win}" -b add,fullscreen 2>/dev/null || true
}

terminate_stale_if_needed() {
    local win pids pid age stale=""
    win="$(firefox_window_id || true)"
    [[ -n "${win}" ]] && return 0
    pids="$(firefox_pids)"
    [[ -z "${pids}" ]] && return 0
    for pid in ${pids}; do
        age="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ')"
        [[ -n "${age}" && "${age}" -ge 60 ]] && stale="${stale} ${pid}"
    done
    [[ -z "${stale}" ]] && return 0
    log "WARN" "Firefox without window for over 60s, terminating:${stale}"
    # shellcheck disable=SC2086
    kill -TERM ${stale} 2>/dev/null || true
    sleep 8
    if [[ -n "$(firefox_pids)" && -z "$(firefox_window_id || true)" ]]; then
        # shellcheck disable=SC2086
        kill -KILL ${stale} 2>/dev/null || true
    fi
}

exec 9>"${LOCK_FILE}"
flock -w 5 9 || exit 0

systemctl --user start linuxmintphotoframe-server.service >/dev/null 2>&1 || true
terminate_stale_if_needed

if [[ -n "$(firefox_pids)" ]]; then
    log "INFO" "Firefox already running, focusing fullscreen"
    bring_to_front
    exit 0
fi

log "INFO" "Starting Firefox kiosk at ${URL}"
setsid -f "${FIREFOX_BIN}" \
    --no-remote \
    --new-window \
    --kiosk \
    --profile "${PROFILE_DIR}" \
    "${URL}" \
    >/dev/null 2>&1 || true

sleep 3
bring_to_front
