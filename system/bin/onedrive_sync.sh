#!/usr/bin/env bash
# Pull the private OneDrive Fotoframe folder into the local data directory.

set -euo pipefail
IFS=$'\n\t'

APP_NAME="linuxmintphotoframe"
ENV_FILE="${HOME}/.config/${APP_NAME}/env"
STATE_DIR="${HOME}/state"
LOG_FILE="${STATE_DIR}/kiosk.log"
LOCK_FILE="${STATE_DIR}/photoframe-sync.lock"

mkdir -p "${STATE_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

FRAME_DATA_DIR="${FRAME_DATA_DIR:-${HOME}/frame-data}"
RCLONE_SOURCE="${RCLONE_SOURCE:-onedrive:Fotoframe}"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { printf '%s | onedrive_sync | %s | %s\n' "$(ts)" "$1" "$2" >> "${LOG_FILE}" 2>/dev/null || true; }

mkdir -p "${FRAME_DATA_DIR}/photos" "${FRAME_DATA_DIR}/info" "${FRAME_DATA_DIR}/command"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "INFO" "sync already running"
    exit 0
fi

if [[ -z "${RCLONE_SOURCE}" ]]; then
    log "WARN" "RCLONE_SOURCE empty, sync disabled"
    exit 0
fi

if ! command -v rclone >/dev/null 2>&1; then
    log "WARN" "rclone not installed, sync skipped"
    exit 0
fi

if rclone sync "${RCLONE_SOURCE}" "${FRAME_DATA_DIR}" \
    --create-empty-src-dirs \
    --exclude ".DS_Store" \
    --exclude "Thumbs.db" \
    --transfers 4 \
    --checkers 8 \
    --timeout 30s \
    --contimeout 10s \
    --retries 2 \
    --low-level-retries 3 \
    --log-level INFO \
    --log-file "${STATE_DIR}/rclone.log"; then
    log "INFO" "sync ok from ${RCLONE_SOURCE} to ${FRAME_DATA_DIR}"
else
    rc=$?
    log "ERROR" "sync failed with exit ${rc}; keeping existing local data"
    exit "${rc}"
fi
