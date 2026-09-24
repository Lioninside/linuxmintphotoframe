#!/usr/bin/env bash
# Install/update the Linux Mint photo frame kiosk for the current user.

set -euo pipefail
IFS=$'\n\t'

APP_NAME="linuxmintphotoframe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALL_DIR="${HOME}/${APP_NAME}"
CONFIG_DIR="${HOME}/.config/${APP_NAME}"
ENV_FILE="${CONFIG_DIR}/env"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
STATE_DIR="${HOME}/state"
LOG_FILE="${STATE_DIR}/kiosk.log"
FIREFOX_PROFILE="${HOME}/.mozilla/firefox-photoframe"

GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log_file() { printf '%s | kiosk_setup | %s | %s\n' "$(ts)" "$1" "$2" >> "${LOG_FILE}" 2>/dev/null || true; }
ok() { printf '%s[OK]%s %s\n' "${GREEN}" "${RESET}" "$1"; log_file "INFO" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$1"; log_file "WARN" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$1"; log_file "ERROR" "$1"; }

mkdir -p "${CONFIG_DIR}" "${SYSTEMD_USER_DIR}" "${STATE_DIR}" "${FIREFOX_PROFILE}/chrome"

install_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "apt-get not found; package installation skipped"
        return
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found; package installation skipped"
        return
    fi

    local missing=()
    for cmd in firefox wmctrl xset xrandr rclone python3; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "Required commands already installed"
        return
    fi

    warn "Installing missing packages: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y firefox wmctrl x11-xserver-utils rclone python3
    ok "Packages installed"
}

copy_tree() {
    local src="$1"
    local dst="$2"
    mkdir -p "${dst}"
    cp -a "${src}/." "${dst}/"
}

install_files() {
    if [[ "${REPO_ROOT}" != "${INSTALL_DIR}" ]]; then
        mkdir -p "${INSTALL_DIR}"
        copy_tree "${REPO_ROOT}/app" "${INSTALL_DIR}/app"
        copy_tree "${REPO_ROOT}/examples" "${INSTALL_DIR}/examples"
        copy_tree "${REPO_ROOT}/system" "${INSTALL_DIR}/system"
        cp "${REPO_ROOT}/README.md" "${INSTALL_DIR}/README.md"
        ok "Installed files to ${INSTALL_DIR}"
    else
        ok "Running from install directory ${INSTALL_DIR}"
    fi

    chmod +x "${INSTALL_DIR}/system/bin/"*.sh
    chmod +x "${INSTALL_DIR}/system/bin/"*.py
}

write_env_if_missing() {
    if [[ -f "${ENV_FILE}" ]]; then
        ok "Keeping existing ${ENV_FILE}"
        return
    fi

    cat > "${ENV_FILE}" <<ENV_EOF
# Linux Mint Photo Frame Kiosk
FRAME_DATA_DIR=${HOME}/frame-data
RCLONE_SOURCE=onedrive:Fotoframe
PHOTOFRAME_PORT=8765

# Optional display reset. Leave empty until xrandr output/mode are known.
DISPLAY_OUTPUT=
DISPLAY_MODE=
ENV_EOF
    ok "Created ${ENV_FILE}"
}

seed_data_files() {
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    FRAME_DATA_DIR="${FRAME_DATA_DIR:-${HOME}/frame-data}"
    mkdir -p "${FRAME_DATA_DIR}/photos" "${FRAME_DATA_DIR}/info" "${FRAME_DATA_DIR}/command"

    for name in config.json news.json info-images.json quiz.json; do
        if [[ ! -f "${FRAME_DATA_DIR}/${name}" && -f "${INSTALL_DIR}/examples/${name}" ]]; then
            cp "${INSTALL_DIR}/examples/${name}" "${FRAME_DATA_DIR}/${name}"
            ok "Seeded ${FRAME_DATA_DIR}/${name}"
        fi
    done
}

install_firefox_profile() {
    cp "${INSTALL_DIR}/system/firefox/user.js" "${FIREFOX_PROFILE}/user.js"
    ok "Installed Firefox profile prefs"
}

install_systemd_units() {
    cp "${INSTALL_DIR}/system/systemd/"*.service "${SYSTEMD_USER_DIR}/"
    cp "${INSTALL_DIR}/system/systemd/"*.timer "${SYSTEMD_USER_DIR}/"
    systemctl --user daemon-reload
    systemctl --user enable --now linuxmintphotoframe-server.service
    systemctl --user enable --now linuxmintphotoframe-sync.timer
    systemctl --user enable --now linuxmintphotoframe-browser.service
    systemctl --user enable --now linuxmintphotoframe-watchdog.service
    ok "Enabled and started user services"
}

install_user_commands() {
    mkdir -p "${HOME}/.local/bin" "${HOME}/bin"
    ln -sf "${INSTALL_DIR}/system/bin/maintenance.sh" "${HOME}/.local/bin/maintenance"
    ln -sf "${INSTALL_DIR}/system/bin/maintenance.sh" "${HOME}/bin/maintenance"
    ok "Installed maintenance command"
}

install_desktop_shortcut() {
    local desktop_dir="${HOME}/Desktop"
    [[ -d "${desktop_dir}" ]] || desktop_dir="${HOME}/Schreibtisch"
    [[ -d "${desktop_dir}" ]] || return 0
    cat > "${desktop_dir}/Fotoframe.desktop" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Fotoframe
Comment=Fotoframe Kiosk starten
Exec=${INSTALL_DIR}/system/bin/start_photoframe_kiosk.sh
Icon=firefox
Terminal=false
DESKTOP_EOF
    chmod +x "${desktop_dir}/Fotoframe.desktop"
    ok "Installed desktop shortcut"
}

main() {
    install_packages
    install_files
    write_env_if_missing
    seed_data_files
    install_user_commands
    install_firefox_profile
    install_systemd_units
    install_desktop_shortcut
    printf '\n'
    bash "${INSTALL_DIR}/system/bin/kiosk_healthcheck.sh" || true
}

main "$@"
