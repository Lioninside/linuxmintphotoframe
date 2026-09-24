#!/usr/bin/env bash
# Quick status report for the photo frame kiosk.

set -euo pipefail
IFS=$'\n\t'

APP_NAME="linuxmintphotoframe"
ENV_FILE="${HOME}/.config/${APP_NAME}/env"
STATE_DIR="${HOME}/state"
LOG_FILE="${STATE_DIR}/kiosk.log"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

FRAME_DATA_DIR="${FRAME_DATA_DIR:-${HOME}/frame-data}"
PHOTOFRAME_PORT="${PHOTOFRAME_PORT:-8765}"
DISK_WARN_FREE_MB="${DISK_WARN_FREE_MB:-10240}"
DISK_MIN_SYNC_FREE_MB="${DISK_MIN_SYNC_FREE_MB:-3072}"

BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

ok() { printf '%s[OK]%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$1"; }
info() { printf '     %s\n' "$1"; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

sanitize_number_settings() {
    is_uint "${DISK_WARN_FREE_MB}" || DISK_WARN_FREE_MB=10240
    is_uint "${DISK_MIN_SYNC_FREE_MB}" || DISK_MIN_SYNC_FREE_MB=3072
}

free_mb_for_path() {
    df -Pm "$1" 2>/dev/null | awk 'NR == 2 {print $4}'
}

human_du() {
    local path="$1"
    [[ -e "${path}" ]] || return 0
    du -sh "${path}" 2>/dev/null | awk '{print $1 " " $2}'
}

sanitize_number_settings

printf "%sLinux Mint Photo Frame Health Check - %s%s\n" "${BOLD}" "$(date '+%Y-%m-%d %H:%M:%S')" "${RESET}"

printf "\n%sConfig%s\n" "${BOLD}" "${RESET}"
info "ENV_FILE=${ENV_FILE}"
info "FRAME_DATA_DIR=${FRAME_DATA_DIR}"
info "PHOTOFRAME_PORT=${PHOTOFRAME_PORT}"
info "RCLONE_SOURCE=${RCLONE_SOURCE:-}"
info "DISK_WARN_FREE_MB=${DISK_WARN_FREE_MB}"
info "DISK_MIN_SYNC_FREE_MB=${DISK_MIN_SYNC_FREE_MB}"

printf "\n%sServices%s\n" "${BOLD}" "${RESET}"
for svc in \
    linuxmintphotoframe-server.service \
    linuxmintphotoframe-browser.service \
    linuxmintphotoframe-watchdog.service \
    linuxmintphotoframe-sync.timer; do
    if systemctl --user is-active --quiet "${svc}"; then
        ok "${svc} active"
    else
        warn "${svc} not active"
    fi
done

printf "\n%sData%s\n" "${BOLD}" "${RESET}"
if [[ -d "${FRAME_DATA_DIR}" ]]; then
    ok "Data directory exists"
else
    fail "Data directory missing: ${FRAME_DATA_DIR}"
fi

photo_count=0
if [[ -d "${FRAME_DATA_DIR}/photos" ]]; then
    photo_count="$(find "${FRAME_DATA_DIR}/photos" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) | wc -l)"
fi
if (( photo_count > 0 )); then
    ok "Photos found: ${photo_count}"
else
    warn "No photos found yet in ${FRAME_DATA_DIR}/photos"
fi

for f in config.json news.json info-images.json quiz.json; do
    if [[ -f "${FRAME_DATA_DIR}/${f}" ]]; then
        ok "${f} present"
    else
        warn "${f} missing"
    fi
done

printf "\n%sStorage%s\n" "${BOLD}" "${RESET}"
if [[ -d "${FRAME_DATA_DIR}" ]]; then
    df -h "${FRAME_DATA_DIR}" | sed 's/^/     /'
    free_mb="$(free_mb_for_path "${FRAME_DATA_DIR}")"
    if is_uint "${free_mb}"; then
        if (( free_mb < DISK_MIN_SYNC_FREE_MB )); then
            fail "Only ${free_mb} MB free; sync minimum is ${DISK_MIN_SYNC_FREE_MB} MB"
        elif (( free_mb < DISK_WARN_FREE_MB )); then
            warn "Only ${free_mb} MB free; warning threshold is ${DISK_WARN_FREE_MB} MB"
        else
            ok "Free disk space: ${free_mb} MB"
        fi
    else
        warn "Could not determine free disk space"
    fi
    for path in "${FRAME_DATA_DIR}" "${FRAME_DATA_DIR}/photos" "${STATE_DIR}"; do
        size="$(human_du "${path}")"
        [[ -n "${size}" ]] && info "${size}"
    done
else
    warn "Storage check skipped, data directory missing"
fi

printf "\n%sLocal server%s\n" "${BOLD}" "${RESET}"
if python3 - <<PY
import json, urllib.request
with urllib.request.urlopen("http://127.0.0.1:${PHOTOFRAME_PORT}/api/health", timeout=5) as r:
    data = json.load(r)
print(data)
PY
then
    ok "Server responds"
else
    fail "Server does not respond"
fi

printf "\n%sFirefox%s\n" "${BOLD}" "${RESET}"
if pgrep -u "${USER}" -f 'firefox/firefox|firefox-esr/firefox-esr' >/dev/null 2>&1; then
    ok "Firefox process running"
else
    warn "Firefox process not found"
fi

if command -v wmctrl >/dev/null 2>&1 && wmctrl -lx 2>/dev/null | grep -qi firefox; then
    ok "Firefox window visible to wmctrl"
else
    warn "Firefox window not visible to wmctrl"
fi

printf "\n%sSync%s\n" "${BOLD}" "${RESET}"
if command -v rclone >/dev/null 2>&1; then
    ok "rclone installed"
else
    warn "rclone missing"
fi

if [[ -f "${STATE_DIR}/rclone.log" ]]; then
    info "Last rclone lines:"
    tail -5 "${STATE_DIR}/rclone.log" | sed 's/^/     /'
else
    warn "No rclone log yet"
fi

printf "\n%sRecent kiosk log%s\n" "${BOLD}" "${RESET}"
if [[ -f "${LOG_FILE}" ]]; then
    tail -12 "${LOG_FILE}" | sed 's/^/     /'
else
    warn "No kiosk log yet"
fi
