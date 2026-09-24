#!/usr/bin/env bash
# Pull the private OneDrive Fotoframe folder into the local data directory.

set -euo pipefail
IFS=$'\n\t'

APP_NAME="linuxmintphotoframe"
ENV_FILE="${HOME}/.config/${APP_NAME}/env"
STATE_DIR="${HOME}/state"
LOG_FILE="${STATE_DIR}/kiosk.log"
RCLONE_LOG_FILE="${STATE_DIR}/rclone.log"
LOCK_FILE="${STATE_DIR}/photoframe-sync.lock"

mkdir -p "${STATE_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

FRAME_DATA_DIR="${FRAME_DATA_DIR:-${HOME}/frame-data}"
RCLONE_SOURCE="${RCLONE_SOURCE:-onedrive:Fotoframe}"
DISK_WARN_FREE_MB="${DISK_WARN_FREE_MB:-10240}"
DISK_MIN_SYNC_FREE_MB="${DISK_MIN_SYNC_FREE_MB:-3072}"
RCLONE_LOG_MAX_BYTES="${RCLONE_LOG_MAX_BYTES:-2000000}"
RCLONE_LOG_KEEP_LINES="${RCLONE_LOG_KEEP_LINES:-2000}"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { printf '%s | onedrive_sync | %s | %s\n' "$(ts)" "$1" "$2" >> "${LOG_FILE}" 2>/dev/null || true; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

sanitize_number_settings() {
    is_uint "${DISK_WARN_FREE_MB}" || DISK_WARN_FREE_MB=10240
    is_uint "${DISK_MIN_SYNC_FREE_MB}" || DISK_MIN_SYNC_FREE_MB=3072
    is_uint "${RCLONE_LOG_MAX_BYTES}" || RCLONE_LOG_MAX_BYTES=2000000
    is_uint "${RCLONE_LOG_KEEP_LINES}" || RCLONE_LOG_KEEP_LINES=2000
}

free_mb_for_path() {
    df -Pm "$1" 2>/dev/null | awk 'NR == 2 {print $4}'
}

check_free_space() {
    local free_mb
    free_mb="$(free_mb_for_path "${FRAME_DATA_DIR}")"
    if ! is_uint "${free_mb}"; then
        log "WARN" "could not determine free disk space for ${FRAME_DATA_DIR}"
        return 0
    fi

    if (( free_mb < DISK_MIN_SYNC_FREE_MB )); then
        log "ERROR" "sync skipped: only ${free_mb} MB free, minimum is ${DISK_MIN_SYNC_FREE_MB} MB"
        exit 1
    fi

    if (( free_mb < DISK_WARN_FREE_MB )); then
        log "WARN" "low disk space: ${free_mb} MB free, warning threshold is ${DISK_WARN_FREE_MB} MB"
    fi
}

rotate_rclone_log() {
    [[ -f "${RCLONE_LOG_FILE}" ]] || return 0
    local size tmp
    size="$(wc -c < "${RCLONE_LOG_FILE}" 2>/dev/null | tr -d ' ')"
    is_uint "${size}" || return 0
    (( size > RCLONE_LOG_MAX_BYTES )) || return 0

    tmp="${RCLONE_LOG_FILE}.tmp"
    if tail -n "${RCLONE_LOG_KEEP_LINES}" "${RCLONE_LOG_FILE}" > "${tmp}" && mv "${tmp}" "${RCLONE_LOG_FILE}"; then
        log "INFO" "rotated rclone.log at ${size} bytes, kept last ${RCLONE_LOG_KEEP_LINES} lines"
    else
        rm -f "${tmp}" 2>/dev/null || true
        log "WARN" "could not rotate rclone.log"
    fi
}

sanitize_number_settings
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

check_free_space
rotate_rclone_log

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
    --log-file "${RCLONE_LOG_FILE}"; then
    log "INFO" "sync ok from ${RCLONE_SOURCE} to ${FRAME_DATA_DIR}"
else
    rc=$?
    log "ERROR" "sync failed with exit ${rc}; keeping existing local data"
    exit "${rc}"
fi
