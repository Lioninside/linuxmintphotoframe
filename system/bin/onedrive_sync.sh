#!/usr/bin/env bash
# Pull the private KioskContent folders into the local frame data directory.
#
# Two sources, deliberately split by what owns the data:
#
#   RCLONE_TEXT_SOURCE   Google Drive — news, recurring, suggestions, config,
#                        info-images and quiz.  This is where the content agent
#                        writes, and therefore the source of truth for text.
#   RCLONE_SOURCE        OneDrive — the photos, the info images themselves and
#                        the command files.  Photos are uploaded from a phone
#                        straight to OneDrive and never round-trip through
#                        Drive.
#
# The two passes touch disjoint paths, so neither can overwrite the other and
# the order does not matter.  Restricting the OneDrive pass by --include is
# what makes Drive authoritative for text: a stale news.json left on OneDrive
# is simply never copied.  Note the pair that reads alike but is split:
# mint2/info-images.json (the list, from Drive) and mint2/info/ (the pictures
# it names, from OneDrive).
#
# Neither pass copies mint1/ — that belongs to the kiosk, not to the frame.
#
# Both passes are `rclone copy`, never `sync`: an incomplete or briefly
# unreachable remote must not wipe content off a stable frame.  `sync` would
# delete every photo on the first run, because the photos do not exist in the
# text source.
#
# A source whose rclone remote is not configured yet is skipped with a warning
# instead of failing the run — so this script can be rolled out before the
# Google Drive remote has been authorised.

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
RCLONE_SOURCE="${RCLONE_SOURCE:-thusis:KioskContent}"
RCLONE_TEXT_SOURCE="${RCLONE_TEXT_SOURCE:-gdrive:KioskContent}"
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

remote_configured() {
    # "gdrive:KioskContent" -> "gdrive:"
    local remote="${1%%:*}:"
    rclone listremotes 2>/dev/null | grep -qx -- "${remote}"
}

# run_copy <label> <source> [zusaetzliche rclone-Filter...]
run_copy() {
    local label="$1" source="$2"
    shift 2

    if [[ -z "${source}" ]]; then
        log "INFO" "${label}: no source configured, skipped"
        return 0
    fi
    if ! remote_configured "${source}"; then
        log "WARN" "${label}: rclone remote for ${source} is not configured, skipped"
        return 0
    fi
    copied=$((copied + 1))

    local rc=0
    rclone copy "${source}" "${FRAME_DATA_DIR}" \
        --create-empty-src-dirs \
        --exclude ".DS_Store" \
        --exclude "Thumbs.db" \
        "$@" \
        --transfers 4 \
        --checkers 8 \
        --timeout 30s \
        --contimeout 10s \
        --retries 2 \
        --low-level-retries 3 \
        --log-level INFO \
        --log-file "${RCLONE_LOG_FILE}" || rc=$?

    if (( rc == 0 )); then
        log "INFO" "${label}: copy ok from ${source}"
    else
        log "ERROR" "${label}: copy from ${source} failed with exit ${rc}; keeping existing local data"
    fi
    return "${rc}"
}

sanitize_number_settings
mkdir -p "${FRAME_DATA_DIR}/common" \
    "${FRAME_DATA_DIR}/mint2/photos" \
    "${FRAME_DATA_DIR}/mint2/info" \
    "${FRAME_DATA_DIR}/mint2/command"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "INFO" "sync already running"
    exit 0
fi

if ! command -v rclone >/dev/null 2>&1; then
    log "WARN" "rclone not installed, sync skipped"
    exit 0
fi

check_free_space
rotate_rclone_log

failed=0
copied=0

# Text und Konfiguration aus Google Drive.  mint2/*.json trifft nur die Dateien
# direkt in mint2/, also config, info-images und quiz — nicht die Ordner
# darunter.  command/ ist zusaetzlich ausgeschlossen: ein dort versehentlich
# angelegter Befehl soll nicht diesen Weg nehmen.
run_copy "text" "${RCLONE_TEXT_SOURCE}" \
    --exclude "mint2/command/**" \
    --include "common/**" \
    --include "mint2/*.json" || failed=1

# Bilder und Befehle aus OneDrive.  --include schliesst alles Uebrige
# automatisch aus — OneDrives Textdateien werden also bewusst NICHT kopiert.
# Genau das macht Google Drive zur massgebenden Quelle fuer Text.
run_copy "media" "${RCLONE_SOURCE}" \
    --include "mint2/photos/**" \
    --include "mint2/info/**" \
    --include "mint2/command/**" || failed=1

if (( failed )); then
    log "ERROR" "at least one source failed; local data left as it was"
    exit 1
fi

if (( copied == 0 )); then
    # Kein konfiguriertes Remote — der Rahmen laeuft auf dem, was lokal liegt.
    # Kein Fehler, aber auch kein Erfolg: das darf nicht wie ein gelungener
    # Abgleich aussehen.
    log "WARN" "no source was configured; local data untouched"
    exit 0
fi

log "INFO" "${copied} source(s) copied into ${FRAME_DATA_DIR}"
