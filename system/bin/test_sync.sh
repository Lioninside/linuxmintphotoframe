#!/usr/bin/env bash
# Selbsttest fuer onedrive_sync.sh.
#
# Prueft die Zwei-Quellen-Logik gegen ein falsches rclone, ohne Netz, ohne
# echte Remotes und ohne irgendetwas ausserhalb eines temporaeren HOME zu
# beruehren.  Die wichtigen Faelle:
#
#   * Drive noch nicht autorisiert -> uebersprungen, Rahmen laeuft weiter
#   * Drive faellt aus             -> Fotos und Befehle kommen trotzdem
#   * info-images.json aus Drive, mint2/info/ aus OneDrive — die beiden
#     lesen sich aehnlich und duerfen sich nicht vertauschen
#   * nur --filter, nie --include neben --exclude: rclone wertet die zwei
#     in unbestimmter Reihenfolge aus, und genau darauf beruht die Trennung
#   * die Drive-Drosselung, die Googles Minutenkontingent schont
#
# Aufruf:  bash system/bin/test_sync.sh
set -uo pipefail

SKRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onedrive_sync.sh"
ARBEIT="$(mktemp -d)"
trap 'rm -rf "${ARBEIT}"' EXIT
FEHLER=0

# Gibt jeden Aufruf als "quelle | [regel][regel]..." aus.  Die eckigen Klammern
# halten Regeln mit Leerzeichen zusammen ("+ /common/**").
cat > "${ARBEIT}/rclone" <<'FAKE'
#!/bin/bash
if [[ "$1" == "listremotes" ]]; then printf '%s\n' ${FAKE_REMOTES:-}; exit 0; fi
if [[ "$1" == "copy" ]]; then
  src="$2"; shift 3
  regeln=""; roh=""
  while (( $# )); do
    case "$1" in
      --filter) regeln+="[$2]"; shift ;;
      --include|--exclude) roh+="[$1 $2]"; shift ;;
    esac
    shift
  done
  printf '%s | %s | %s\n' "${src}" "${regeln}" "${roh}" >> "${FAKE_CALLS}"
  [[ " ${FAKE_FAIL:-} " == *" ${src} "* ]] && exit 7
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

# lauf <remotes> [fehlerquelle] [argumente...]
lauf() {
    export HOME="${ARBEIT}/home"
    rm -rf "${HOME}"; mkdir -p "${HOME}/state"
    neulauf "$@"
}

# Wie lauf, aber ohne HOME zu leeren — fuer den zweiten Lauf hintereinander.
neulauf() {
    export FAKE_CALLS="${ARBEIT}/calls.txt"; : > "${FAKE_CALLS}"
    export FAKE_REMOTES="$1" FAKE_FAIL="${2:-}"
    shift 2 2>/dev/null || shift $#
    PATH="${ARBEIT}:${PATH}" bash "${SKRIPT}" "$@" >/dev/null 2>&1
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
echo "=== 2) Nur OneDrive: Drive stumm uebersprungen ==="
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
pruefe "Drive holt common/"               "$(hat "${TEXT}" '[+ /common/**]')"
pruefe "Drive holt mint2/*.json"          "$(hat "${TEXT}" '[+ /mint2/*.json]')"
pruefe "Drive schliesst command/ aus"     "$(hat "${TEXT}" '[- /mint2/command/**]')"
pruefe "Drive holt keine Fotos"           "$([[ ${TEXT} != *photos* ]] && echo ja || echo nein)"
pruefe "OneDrive holt Fotos"              "$(hat "${MEDIA}" '[+ /mint2/photos/**]')"
pruefe "OneDrive holt die Infobilder"     "$(hat "${MEDIA}" '[+ /mint2/info/**]')"
pruefe "OneDrive holt Befehle"            "$(hat "${MEDIA}" '[+ /mint2/command/**]')"
pruefe "OneDrive holt keinen Text"        "$([[ ${MEDIA} != *common* && ${MEDIA} != *.json* ]] && echo ja || echo nein)"
pruefe "keine Quelle fasst mint1/ an"     "$([[ ${AUFRUFE} != *mint1* ]] && echo ja || echo nein)" \
       "das Telefon geht den Rahmen nichts an"

echo
echo "=== 4) Reihenfolge der Filter ist festgelegt ==="
# rclone wertet --include neben --exclude in unbestimmter Reihenfolge aus und
# warnt darueber.  Die ganze Trennung haengt daran, also darf keiner der
# beiden Schalter mehr vorkommen.
ROH="$(cut -d'|' -f3 "${FAKE_CALLS}" | tr -d ' \n')"
pruefe "kein --include und kein --exclude" "$([[ -z ${ROH} ]] && echo ja || echo nein)" "${ROH:-nur --filter}"
for quelle in "${TEXT}" "${MEDIA}"; do
    name="${quelle%%:*}"
    regeln="$(echo "${quelle}" | cut -d'|' -f2)"; regeln="${regeln# }"; regeln="${regeln% }"
    pruefe "schliesst mit '- *' ab"        "$([[ ${regeln} == *'[- *]' ]] && echo ja || echo nein)" \
           "${name}: ${regeln}"
    pruefe "Ausschluesse stehen zuerst"    "$([[ ${regeln} == '[- .DS_Store][- Thumbs.db]'* ]] && echo ja || echo nein)" \
           "${name}"
done

echo
echo "=== 5) Drive faellt aus: Fotos und Befehle kommen trotzdem ==="
lauf "gdrive: thusis:" "gdrive:KioskContent"
pruefe "meldet Fehler"                    "$([[ ${RC} -ne 0 ]] && echo ja || echo nein)" "exit=${RC}"
pruefe "OneDrive lief trotzdem"           "$(hat "${AUFRUFE}" 'thusis:KioskContent')"
pruefe "Fehler steht im Log"              "$(hat "${LOG}" 'text: copy from gdrive')"
pruefe "lokale Daten bleiben"             "$(hat "${LOG}" 'keeping existing local data')"

echo
echo "=== 6) Drosselung: Drive nicht bei jedem Timer-Lauf ==="
lauf "gdrive: thusis:"
pruefe "erster Lauf holt Text"            "$(hat "${AUFRUFE}" 'gdrive:KioskContent')"
neulauf "gdrive: thusis:"
pruefe "zweiter Lauf laesst Drive aus"    "$([[ ${AUFRUFE} != *gdrive* ]] && echo ja || echo nein)"
pruefe "Fotos kommen trotzdem"            "$(hat "${AUFRUFE}" 'thusis:KioskContent')"
pruefe "kein Abbruch"                     "$([[ ${RC} -eq 0 ]] && echo ja || echo nein)" "exit=${RC}"
pruefe "Log nennt die Wartezeit"          "$(hat "${LOG}" 'next in')"
neulauf "gdrive: thusis:" "" --force
pruefe "--force holt Text sofort"         "$(hat "${AUFRUFE}" 'gdrive:KioskContent')"
TEXT_SYNC_MIN_INTERVAL_SEC=0 neulauf "gdrive: thusis:"
pruefe "Intervall 0 drosselt nie"         "$(hat "${AUFRUFE}" 'gdrive:KioskContent')"

echo
echo "=== 7) Ein gescheiterter Drive-Lauf haemmert nicht gegen das Kontingent ==="
lauf "gdrive: thusis:" "gdrive:KioskContent"
neulauf "gdrive: thusis:" "gdrive:KioskContent"
pruefe "zweiter Lauf versucht Drive nicht erneut" "$([[ ${AUFRUFE} != *gdrive* ]] && echo ja || echo nein)" \
       "Stempel wird vor dem Kopieren gesetzt"
pruefe "und meldet darum keinen Fehler"   "$([[ ${RC} -eq 0 ]] && echo ja || echo nein)" "exit=${RC}"

echo
if (( FEHLER )); then
    echo "FEHLGESCHLAGEN: ${FEHLER}"
    exit 1
fi
echo "Alles in Ordnung."
