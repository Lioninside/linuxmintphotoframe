# Linux Mint Photo Frame Kiosk

Schlanker Linux-Mint-Kiosk fuer einen digitalen Bilderrahmen:

- Fotos kommen privat aus einem OneDrive-Ordner.
- Textmeldungen kommen aus einem Google-Drive-Ordner, den der Content-Agent
  direkt beschreiben kann.
- Firefox zeigt lokal eine Fotoframe-Webapp im Kiosk-Modus.
- Ein Watchdog haelt Browser, Fullscreen, Display und Remote-Neustart stabil.

Git enthaelt nur Code, Setup und Beispiele. Private Inhalte bleiben in der Cloud.

## Zielbild

Beide Clouds tragen denselben Baum `KioskContent`, aber jede besitzt nur einen
Teil davon. Was der Rahmen von wo holt:

```text
KioskContent/
  common/                      <- Google Drive
    news.json
    suggestions.json
    recurring.json
    archive/
      news-archiv.json
  mint2/
    config.json                <- Google Drive
    info-images.json           <- Google Drive (die Liste)
    quiz.json                  <- Google Drive
    photos/                    <- OneDrive
      ferien-01.jpg
      familie-02.jpg
    info/                      <- OneDrive (die Bilder, die die Liste nennt)
      pommes.png
      arzttermin.png
    command/                   <- OneDrive
      neustart.txt
```

Text steht in Google Drive, weil der Content-Agent dort lesen **und** schreiben
kann; er kennt damit jederzeit den aktuellen Stand der Dateien. Fotos bleiben in
OneDrive, weil sie vom Telefon direkt dorthin hochgeladen werden.

Die beiden Kopierlaeufe fassen getrennte Pfade an, koennen sich also nicht
gegenseitig ueberschreiben. Der OneDrive-Lauf ist per `--filter` auf Bilder und
Befehle beschraenkt: eine alte `news.json`, die noch in OneDrive liegt, wird
schlicht nie kopiert. (`--include` neben `--exclude` waere hier falsch — rclone
wertet die zwei in unbestimmter Reihenfolge aus.) `mint1/` holt der Rahmen von keiner der beiden Quellen —
das gehoert dem Telefon-Kiosk.

Lokal landet beides im selben Verzeichnis:

```text
/home/<user>/frame-data/
  common/
  mint2/
```

Die lokale Webapp liest dann nur noch lokale Dateien ueber einen kleinen Server:

```text
http://127.0.0.1:8765/
```

## Installation auf Mint

Einmalig **zwei** rclone-Remotes konfigurieren. Die Namen sind nicht frei
waehlbar, das Sync-Skript sucht genau nach diesen:

```bash
rclone config
# Name: thusis
# Type: Microsoft OneDrive

rclone config
# Name: gdrive
# Type: Google Drive
# Konto: huber.rosemary@gmail.com
```

Pruefen, dass beide da sind — das Skript erkennt einen Remote nur bei exakt
diesem Namen:

```bash
rclone listremotes
# gdrive:
# thusis:
```

Fehlt einer, laeuft der Rahmen trotzdem weiter: der fehlende Lauf wird mit einer
WARN-Zeile in `~/state/kiosk.log` uebersprungen, der andere kopiert normal.
Ohne `gdrive:` sieht der Rahmen allerdings keine Textaenderungen mehr.

Wichtig: Auf dem Windows-Arbeitsgeraet gibt es mehrere OneDrives. Fuer diesen
Kiosk zaehlt nur der Thusis-OneDrive auf dem Mint-Geraet. STC/work und
Lioninside/private Clemens-OneDrive nicht fuer KioskContent verwenden.

Wenn der Kiosk bereits installiert ist und Firefox/Fullscreen das Terminal verdeckt:

```bash
maintenance 10
# falls die Shell den Befehl noch nicht kennt:
~/.local/bin/maintenance 10
```

Das stoppt Browser und Watchdog fuer 10 Minuten. Der lokale Server und der Sync laufen weiter. Vorzeitig wieder starten:

```bash
maintenance off
```

Falls `maintenance` auf einem alten Stand noch nicht existiert:

```bash
systemctl --user stop linuxmintphotoframe-watchdog.service
pkill -TERM -f "$HOME/.mozilla/firefox-photoframe" || true
```

Dann deployen:

```bash
cd /tmp
rm -rf linuxmintphotoframe
git clone https://github.com/Lioninside/linuxmintphotoframe.git
cd linuxmintphotoframe
bash system/bin/kiosk_setup.sh
```

## Code und Doku aktualisieren

`~/linuxmintphotoframe` ist eine installierte Kopie, kein Git-Checkout. Darum
funktioniert dort kein `git pull`. Updates laufen wie ein frisches Deploy:

```bash
cd /tmp
rm -rf linuxmintphotoframe
git clone https://github.com/Lioninside/linuxmintphotoframe.git
cd linuxmintphotoframe
bash system/bin/kiosk_setup.sh
```

Das Setup startet Server, Watchdog, Browser und Sync-Timer danach **neu**,
nicht nur `enable --now`. Ohne das behielten die langlaufenden Dienste ihren
alten Code, obwohl die Dateien schon ersetzt waren — das Setup meldete Erfolg,
und auf dem Schirm aenderte sich nichts. Firefox gehoert dazu: er liest
`app.js` und `styles.css` beim Seitenstart.

Das Setup behaelt `~/.config/linuxmintphotoframe/env` bei. Die Cloud-Konfiguration,
lokale Daten unter `~/frame-data` und die rclone-Anmeldung bleiben erhalten.

Das Setup schreibt bei Bedarf:

```text
~/.config/linuxmintphotoframe/env
```

Standardwerte:

```bash
FRAME_DATA_DIR=/home/<user>/frame-data
RCLONE_SOURCE=thusis:KioskContent
RCLONE_TEXT_SOURCE=gdrive:KioskContent
PHOTOFRAME_PORT=8765
DISPLAY_OUTPUT=
DISPLAY_MODE=
TEXT_SYNC_MIN_INTERVAL_SEC=1800
```

Eine **bereits vorhandene** env-Datei ruehrt das Setup nicht an, dort fehlen die
zwei neuen Zeilen also weiterhin. Das ist in Ordnung: das Sync-Skript setzt
dieselben Werte selbst ein, wenn sie fehlen. Eintragen muss man sie nur, wenn
der Drive-Ordner woanders liegt oder der Takt anders sein soll.

### Warum Drive seltener als OneDrive abgefragt wird

Der Timer laeuft alle zwei Minuten, damit neue Fotos und `neustart.txt` schnell
ankommen. Google Drive wird dabei hoechstens alle `TEXT_SYNC_MIN_INTERVAL_SEC`
Sekunden angefasst (Vorgabe 30 Minuten), festgehalten in
`~/state/text-sync-last`.

Der Grund ist Googles Kontingent: ohne eigene `client_id` meldet sich rclone mit
einer OAuth-Kennung an, die sich alle rclone-Nutzer weltweit teilen. Alle zwei
Minuten reicht, um in `403 Quota exceeded ... Requests per minute` zu laufen —
beobachtet am 28.09.2026. Text aendert sich hoechstens woechentlich, halbstuendlich
ist also reichlich.

Der Zeitstempel wird **vor** dem Kopieren gesetzt, nicht danach. Ein gescheiterter
Drive-Lauf wartet damit ebenfalls das Intervall ab, statt alle zwei Minuten gegen
ein erschoepftes Kontingent zu laufen.

Fuer einen Lauf von Hand, der nicht warten soll:

```bash
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh --force
```

Wer das Kontingent ganz loswerden will, legt bei Google eine eigene `client_id`
an und traegt sie mit `rclone config` beim Remote `gdrive` ein.

Wenn ein rclone-Remote anders heisst, die passende Zeile dort anpassen und
danach:

```bash
systemctl --user restart linuxmintphotoframe-sync.service
systemctl --user restart linuxmintphotoframe-server.service
```

### Ordner initialisieren oder migrieren

> **Achtung, haeufigster Fehlgriff.** Der Baum `KioskContent` existiert in
> beiden Clouds, aber jede besitzt nur einen Teil. Wer eine JSON-Datei nach
> **OneDrive** legt, legt sie an einen Ort, den der Sync fuer Text gar nicht
> mehr liest — ohne Fehlermeldung, ohne Log-Eintrag. Die Datei liegt dann
> einfach da, und der Rahmen zeigt weiter den alten Stand.
>
> Bis 28.09.2026 stand hier genau das: `rclone copyto ... thusis:.../quiz.json`.
> Falls das jemand ausgefuehrt hat, liegen die Textdateien noch in OneDrive und
> gehoeren nach Drive verschoben — siehe unten.

**Textdateien nach Google Drive:**

```bash
rclone mkdir gdrive:KioskContent/common
rclone mkdir gdrive:KioskContent/common/archive
rclone mkdir gdrive:KioskContent/mint2
rclone mkdir gdrive:KioskContent/mint2/command

rclone copyto ~/linuxmintphotoframe/examples/config.json gdrive:KioskContent/mint2/config.json
rclone copyto ~/linuxmintphotoframe/examples/info-images.json gdrive:KioskContent/mint2/info-images.json
rclone copyto ~/linuxmintphotoframe/examples/quiz.json gdrive:KioskContent/mint2/quiz.json

# Nur falls common/news.json noch nicht durch Mint1/PAC existiert:
if ! rclone lsf gdrive:KioskContent/common | grep -qx 'news.json'; then
  rclone copyto ~/linuxmintphotoframe/examples/news.json gdrive:KioskContent/common/news.json
fi
```

**Bilder und Befehle nach OneDrive:**

```bash
rclone mkdir thusis:KioskContent/mint2/photos
rclone mkdir thusis:KioskContent/mint2/info
rclone mkdir thusis:KioskContent/mint2/command
```

Pruefen — beide Seiten, sonst sieht man nur die Haelfte:

```bash
rclone lsf -R gdrive:KioskContent | sort
rclone lsf -R thusis:KioskContent | sort
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh --force
ls -la ~/frame-data ~/frame-data/common ~/frame-data/mint2
```

#### Textdateien aus OneDrive nach Drive holen

Wenn `quiz.json`, `config.json`, `info-images.json` oder `common/*.json` noch
in OneDrive liegen — aus dem alten Ordner `Fotoframe` oder aus der frueheren
Fassung dieser Anleitung:

```bash
rclone copyto thusis:KioskContent/mint2/config.json      gdrive:KioskContent/mint2/config.json
rclone copyto thusis:KioskContent/mint2/info-images.json gdrive:KioskContent/mint2/info-images.json
rclone copyto thusis:KioskContent/mint2/quiz.json        gdrive:KioskContent/mint2/quiz.json
rclone copy   thusis:KioskContent/common                 gdrive:KioskContent/common
```

Die OneDrive-Fassungen danach loeschen. Solange sie liegenbleiben, sind sie
harmlos — kopiert werden sie nie —, aber sie sehen bei einem Blick in OneDrive
aus wie der gueltige Stand, und genau daran ist die alte Architektur
gescheitert.

Aus dem alten Ordner `Fotoframe`, falls es ihn noch gibt:

```bash
rclone copyto thusis:Fotoframe/config.json      gdrive:KioskContent/mint2/config.json
rclone copyto thusis:Fotoframe/info-images.json gdrive:KioskContent/mint2/info-images.json
rclone copyto thusis:Fotoframe/quiz.json        gdrive:KioskContent/mint2/quiz.json
rclone copy   thusis:Fotoframe/photos           thusis:KioskContent/mint2/photos
rclone copy   thusis:Fotoframe/info             thusis:KioskContent/mint2/info

if ! rclone lsf gdrive:KioskContent/common | grep -qx 'news.json'; then
  rclone copyto thusis:Fotoframe/news.json gdrive:KioskContent/common/news.json
fi
```

Nach erfolgreicher Migration kann die alte lokale Root-Struktur auf Mint
aufgeraeumt werden. Erst ausfuehren, wenn `kiosk_healthcheck.sh` fuer
`common/*` und `mint2/*` gruen ist:

```bash
legacy="$HOME/state/legacy-frame-data-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$legacy"

for path in config.json news.json info-images.json quiz.json photos info command; do
  if [ -e "$HOME/frame-data/$path" ]; then
    mv "$HOME/frame-data/$path" "$legacy/"
  fi
done

bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh
bash ~/linuxmintphotoframe/system/bin/kiosk_healthcheck.sh
```

Das betrifft nur lokale Altdateien. Inhalte im Thusis-OneDrive bleiben dabei
unangetastet.

## Inhalte aktualisieren

Normale Mini-Updates werden **nicht** auf dem Mint-PC gepflegt. Der Mint ist
Laufzeitgeraet und spiegelt nur. Mint-Terminal/AnyDesk wird nur fuer Setup,
Migration, Diagnose, Healthcheck, Sync-Test oder Neustart verwendet.

Entscheidend ist, **in welcher Cloud** eine Datei bearbeitet wird. Wer die
falsche erwischt, aendert etwas, das nie kopiert wird — ohne Fehlermeldung.

Im **Thusis-OneDrive**, ueber OneDrive Web oder das Telefon:

```text
mint2/photos/          Fotos
mint2/info/*.png       die Info-Bilder selbst
mint2/command/         neustart.txt und andere Befehle
```

In **Google Drive** (`KioskContent`), direkt vom Content-Agenten:

```text
common/news.json
common/suggestions.json
common/recurring.json
mint2/info-images.json   die Liste, die die PNGs oben nennt
mint2/quiz.json
mint2/config.json
```

`mint2/info-images.json` und `mint2/info/` gehoeren inhaltlich zusammen, liegen
aber bewusst getrennt: die Liste ist Text und damit Drive, die Bilder sind
Bilder und damit OneDrive. Ein neues Info-Bild braucht deshalb beides.

Der Mint synchronisiert alle zwei Minuten. Die Anzeige prueft den lokalen Stand
regelmaessig und braucht normalerweise keinen Neustart.

Manueller Sync-Test auf Mint, nur zur Kontrolle nach einer Aenderung:

```bash
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh
tail -50 ~/state/rclone.log
ls -la ~/frame-data
ls -la ~/frame-data/mint2/photos
```

Selbsttest der Zwei-Quellen-Logik, ohne Netz und ohne echte Remotes:

```bash
bash ~/linuxmintphotoframe/system/bin/test_sync.sh
python3 ~/linuxmintphotoframe/system/bin/test_fernbefehle.py
```

Der erste prueft die Zwei-Quellen-Logik gegen ein gefaelschtes rclone, der
zweite die beiden Fernbefehle gegen lokale Befehlsdateien. Beide brauchen
weder Netz noch echte Remotes und fassen nichts ausserhalb eines temporaeren
Verzeichnisses an.

## Content via Agent

Kurzes Briefing fuer andere Agenten: `CONTENT_AGENT_BRIEF.md`.

Text pflegt der Agent direkt in Google Drive: er liest die aktuelle Datei, aendert
sie und schreibt sie zurueck. Kein Kopieren, kein Einfuegen, und vor allem kein
Ratespiel darueber, was gerade drinsteht — genau daran ist der frueher hier
beschriebene Paste-Weg gescheitert.

Fuer die Dateien, die in OneDrive bleiben (Fotos, `mint2/info/*.png`), gilt
weiterhin der Weg ueber OneDrive Web oder das Telefon. Ein Agent hat dorthin
keinen Zugriff; er kann nur die zugehoerige Liste in Drive pflegen und muss
sagen, welches Bild noch fehlt.

Wichtig:

- Immer die komplette JSON-Datei ersetzen, nicht nur einen Ausschnitt.
- Bestehende gueltige Eintraege behalten, ausser sie sollen bewusst weg.
- Datum/Uhrzeit im Format `YYYY-MM-DD` oder `YYYY-MM-DDTHH:MM:SS`.
- Zeiten sind lokale Schweizer Zeit auf dem Mint.
- IDs klein und eindeutig schreiben, z.B. `pommes_freitag_2026_09_25`.
- Keine sehr privaten Inhalte verwenden, wenn jemand anders Zugriff auf den
  OneDrive-Ordner hat.
- Gemeinsame Dateien in `common/` muessen mit Mint1/PAC kompatibel bleiben.
- Neue gemeinsame Textmeldungen verwenden `bubble`, `button_label`, `action`
  und optional `neutral_only`.
- `neutral_only: true` nur fuer nuechterne Erinnerungen, Termine,
  medizinische/admin Themen oder technische Hinweise verwenden. Fuer warme,
  persoenliche oder erfreuliche Meldungen `false` verwenden oder weglassen.
- Keine Mint2-only Felder wie `variants`, `variants_today`,
  `variants_before`, `importance` oder `event_date` in `common/` einfuehren.
- Fuer Varietaet mehrere Eintraege mit unterschiedlichen `id` und `bubble`
  erstellen.

### Agenten-Regeln bei News/Suggestions

Wenn der Nutzer eine neue Meldung promptet, muss der Agent zuerst die richtige
Datei bestimmen:

| Wunsch | Datei |
|---|---|
| Einmaliger Termin, Besuch, Ereignis, Erinnerung mit Datum | `common/news.json` |
| Bevorstehende oder heutige wichtige Meldung | `common/news.json` |
| Allgemeiner Hintergrund-Content ohne konkreten Termin | `common/suggestions.json` |
| Passive Idee, Frage, kleine Beschaeftigung ohne Button | `common/suggestions.json` |
| Wiederkehrende Routine, z.B. jeden Freitag Reinigung oder jaehrlich 1. August | `common/recurring.json` |
| Suggestion mit Button, Link oder Aktion | Nicht Mint2; fuer PAC/Mint1 klaeren |
| Mint2-spezifisches Info-Bild | `mint2/info-images.json` plus Bild in `mint2/info/` |
| Quizfrage | `mint2/quiz.json` |
| Foto | `mint2/photos/` |
| Kiosk-Taktung, Quiz-/Livecam-Intervalle | `mint2/config.json` |

Der Agent muss im Zweifel fragen, bevor er JSON erstellt. Typische Rueckfragen:

- Soll die Meldung auf beiden Screens erscheinen oder nur auf Mint2?
- Ist es ein einmaliger Termin, wiederkehrend oder nur ein Fuelltext?
- Welches Start- und Enddatum gilt?
- Gibt es eine Uhrzeit oder ein Zeitfenster?
- Soll der Text heute anders lauten als vorher?
- Soll es einen Button, Link oder eine Aktion geben?

Der Agent darf nicht raten, wenn diese Entscheidung die Datei oder die
Gueltigkeit veraendert. Wenn die Datei klar ist, soll er die bestehende
komplette JSON-Datei validieren, den Eintrag einfuegen, bestehende gueltige
Eintraege behalten und die komplette neue JSON-Datei zurueckgeben.

Reine Textmeldungen in `common/` erscheinen auf Mint1 und Mint2. Wenn der Nutzer
eine reine Textmeldung **nur fuer Mint2** will, muss der Agent nachfragen. Mint2
hat dafuer aktuell keine eigene Textdatei; moegliche Wege sind ein Info-Bild in
`mint2/info-images.json` oder eine bewusste Code-/Strukturerweiterung.

### Prompt: Textmeldung

```text
Aktualisiere diese JSON-Datei fuer den Thusis KioskContent.

Ziel:
- Neue Meldung: <was soll angezeigt werden>
- Datei: <common/news.json oder common/suggestions.json oder common/recurring.json>
- Gueltig von: <Datum/Uhrzeit>
- Gueltig bis: <Datum/Uhrzeit>
- Wiederholung: <keine/daily/weekly/annual>
- Falls weekly: <wochentag>
- Falls annual: <monat und tag>
- Falls Tageswechsel noetig: <vorher-text und heute-text separat>

Regeln:
- Gib die komplette JSON-Datei zurueck.
- Behalte bestehende Eintraege, ausser ich sage explizit loeschen.
- Die Datei ist shared fuer Mint1 und Mint2.
- Verwende das PAC-kompatible Format mit bubble/button_label/action.
- Keine variants/variants_today/variants_before verwenden.
- Fuer Varietaet mehrere Eintraege mit verschiedenen ids und bubble-Texten erstellen.
- Nutze klare, kurze, grosse-Bildschirm-taugliche Sprache.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle Datei:
<JSON EINFUEGEN>
```

### Prompt: Mehrere Texte zum gleichen Thema

Gut fuer Erinnerungen, die haeufig erscheinen sollen, aber nicht immer gleich
klingen.

```text
Erstelle mehrere unterschiedliche Eintraege fuer diese gemeinsame KioskContent-Datei.

Thema:
<Thema>

Datei:
<common/news.json oder common/suggestions.json oder common/recurring.json>

Zeitraum:
von <Datum/Uhrzeit> bis <Datum/Uhrzeit>

Anzahl:
<mindestens X Eintraege>

Ton:
- freundlich
- direkt
- sehr gut lesbar
- keine langen Saetze
- keine Emojis

Kompatibilitaet:
- Mint1 und Mint2 lesen diese Datei.
- Verwende bubble/button_label/action.
- Keine variants-Felder.

Rueckgabe:
- Jede Meldung braucht eine eindeutige id.
- Gib die komplette JSON-Datei zurueck.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle Datei:
<JSON EINFUEGEN>
```

### Prompt: Info-Bild Eintrag

Dieser Prompt erstellt nur den JSON-Eintrag. Das PNG selbst muss im
Thusis-OneDrive unter `KioskContent/mint2/info/` liegen.

```text
Aktualisiere diese mint2/info-images.json fuer den Linux Mint Photo Frame.

Neues Info-Bild:
- Dateiname im Ordner info/: <dateiname.png>
- Bildtext/Captionsatz: <kurzer Text oder leer>
- Gueltig von: <Datum/Uhrzeit>
- Gueltig bis: <Datum/Uhrzeit>
- Prioritaet: <ja/nein>
- Wenn keine Prioritaet: alle <X> Minuten zeigen
- Anzeigedauer: <X> Sekunden

Regeln:
- Gib die komplette mint2/info-images.json zurueck.
- Behalte bestehende Eintraege, ausser ich sage explizit loeschen.
- Verwende schema_version 1.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle mint2/info-images.json:
<JSON EINFUEGEN>
```

### Prompt: Info-Bild gestalten

Wenn ein neues PNG erstellt werden soll, zuerst das Bild prompten und danach den
Eintrag in `mint2/info-images.json` anlegen.

```text
Erstelle ein schlichtes 16:9 Info-Bild fuer einen grossen Kiosk-Bildschirm.

Text:
<Text>

Stil:
- sehr gut lesbar aus Distanz
- ruhiger Hintergrund
- grosse kontrastreiche Schrift
- keine kleinen Details
- keine dekorativen Ueberladungen
- Format 1920x1080 PNG
```

Danach die PNG-Datei nach OneDrive legen:

```text
KioskContent/mint2/info/<dateiname.png>
```

und `mint2/info-images.json` aktualisieren.

### Prompt: Quizfragen

`mint2/quiz.json` enthaelt Fragen und Antworten. Angezeigt wird zuerst nur die Frage,
nach einigen Sekunden die Antwort. Immer drei Fragen nacheinander.

```text
Erstelle oder aktualisiere diese mint2/quiz.json fuer den Linux Mint Photo Frame.

Neue Fragen:
<Fragen und Antworten einfuegen, z.B. aus Excel>

Regeln:
- Gib die komplette mint2/quiz.json zurueck.
- Verwende schema_version 1.
- Jeder Eintrag hat id, question und answer.
- Keine Antwortoptionen anzeigen.
- Fragen kurz und gut lesbar formulieren.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle mint2/quiz.json:
<JSON EINFUEGEN>
```

### Prompt: Aufraeumen

```text
Raeume diese common/news.json auf.

Regeln:
- Entferne abgelaufene Eintraege, deren valid_until vor <heutiges Datum> liegt.
- Behalte zukuenftige und aktuell gueltige Eintraege.
- Sortiere nach valid_from.
- Gib die komplette common/news.json zurueck.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle common/news.json:
<JSON EINFUEGEN>
```

### News-Schema

`common/news.json` ist fuer einmalige oder zeitlich begrenzte Meldungen. Diese
Datei wird von Mint1 und Mint2 gelesen. Neue Eintraege muessen deshalb das
gemeinsame PAC-kompatible Format verwenden:

```json
{
  "id": "judith_besuch_vorschau_2026_10_02",
  "valid_from": "2026-09-30",
  "valid_until": "2026-10-01",
  "bubble": "Am Freitag kommt Judith zu Besuch. Vielleicht geht ihr zusammen spazieren.",
  "button_label": null,
  "action": { "type": "none" },
  "neutral_only": false
}
```

Wenn eine Meldung am Ereignistag anders lauten soll, zwei Eintraege anlegen:

```json
{
  "id": "judith_besuch_heute_2026_10_02",
  "valid_from": "2026-10-02",
  "valid_until": "2026-10-02",
  "bubble": "Heute kommt Judith zu Besuch. Viel Spass zusammen.",
  "button_label": null,
  "action": { "type": "none" },
  "neutral_only": false
}
```

Auswahl:

- Wenn heute gueltige News existieren, werden sie deutlich bevorzugt.
- Bevorstehende News erscheinen gelegentlich.
- Allgemeiner Hintergrund-Content gehoert nach `common/suggestions.json`.
- Fuer Varietaet mehrere Eintraege mit verschiedenen `bubble`-Texten anlegen.
- Moveable Feiertage wie Ostern gehoeren als datierte News in diese Datei.

### Shared suggestions und recurring

Mint2 liest zusaetzlich die gemeinsamen PAC-Dateien:

```text
common/suggestions.json
common/recurring.json
```

`common/suggestions.json` ist fuer passive, allgemeine Fuellmeldungen ohne
Buttons oder Aktionen. Eintraege koennen ueber `rules.after_time` und
`rules.before_time` zeitlich eingeschraenkt werden:

```json
{
  "id": "fotoalbum_1",
  "bubble": "Vielleicht ist heute ein guter Moment fuer ein altes Fotoalbum.",
  "button_label": null,
  "rules": {
    "after_time": "10:00",
    "before_time": "18:00"
  },
  "action": { "type": "none" }
}
```

`common/recurring.json` ist fuer wiederkehrende Meldungen. Unterstuetzt sind:

```json
{
  "id": "reinigung_freitag",
  "type": "weekly",
  "day_of_week": "friday",
  "bubble": "Heute kommt die Reinigung.",
  "button_label": null,
  "action": { "type": "none" },
  "neutral_only": true
}
```

Auch moeglich:

```text
{ "type": "daily", "after_time": "11:00", "before_time": "12:30" }
{ "type": "annual", "month": 8, "day": 1 }
```

Wiederkehrende Eintraege werden auf Mint2 wie heutige News behandelt, sobald
sie zeitlich aktiv sind. `mint1/action-suggestions.json` wird auf Mint2 bewusst
nicht gelesen, weil Mint2 keine PAC-Buttons/Aktionen hat.

## Textmeldungen

Beispiel `common/news.json`:

```json
{
  "schema_version": 1,
  "items": [
    {
      "id": "judith_besuch_vorschau_2026_10_02",
      "valid_from": "2026-09-30",
      "valid_until": "2026-10-01",
      "bubble": "Am Freitag kommt Judith zu Besuch. Vielleicht geht ihr zusammen spazieren.",
      "button_label": null,
      "action": { "type": "none" },
      "neutral_only": false
    },
    {
      "id": "judith_besuch_heute_2026_10_02",
      "valid_from": "2026-10-02",
      "valid_until": "2026-10-02",
      "bubble": "Heute kommt Judith zu Besuch. Viel Spass zusammen.",
      "button_label": null,
      "action": { "type": "none" },
      "neutral_only": false
    }
  ]
}
```

Alte Mint2-Eintraege mit `text` oder `variants` funktionieren lokal weiterhin
als Fallback. Neue Eintraege in `common/` sollten aber bewusst beim gemeinsamen
`bubble`-Format bleiben.

## Info-Bilder

Ein Infobild ist ein PNG, das der Rahmen statt eines Fotos zeigt. Es besteht
immer aus **zwei Haelften in zwei Clouds**: der Liste
`mint2/info-images.json` in Google Drive und der Bilddatei unter
`mint2/info/` in OneDrive. Im Feld `image` steht nur der Dateiname. Fehlt eine
Haelfte, passiert nichts — wortlos.

### Ohne caption laeuft das Bild formatfuellend

Steht der Text schon im Bild, lass `caption` weg. Dann fuellt das PNG den
ganzen Schirm.

Mit caption bleibt es eine Karte in der Mitte: `max-width: 1240px`,
`max-height: 66vh`. Ein 1920x1080-PNG landet damit bei 1240x698 — 65 % der
Breite, und der Text im Bild schrumpft mit. Die vom Rahmen gerenderte caption
dagegen laeuft mit rund 140 px ueber die volle Breite.

Faustregel: **Text im Bild → keine caption. Bild rein bildlich → caption.**
Beides zusammen ist moeglich, macht den Text im Bild aber klein.

Laedt der Rahmen ein Bild nicht (Tippfehler im Namen, PNG noch nicht
synchronisiert), faellt nur das Bild weg: gibt es eine caption, zeigt er den
Text allein — "Heute kommt die Reinigung" stimmt als Satz weiterhin. Erst wenn
beides fehlt, ueberspringt er den Eintrag und zeigt weiter Fotos. Ohne caption
waere es sonst ein schwarzer Bildschirm, bei `priority` so lange wie der
Eintrag gilt.

Ein einmal gescheitertes Bild bleibt nur bis zum naechsten Inhaltsabruf
uebersprungen (`content_reload_seconds`), nicht bis zum Browser-Neustart —
der haeufigste Grund ist ein Sync, der noch laeuft, und der ist zwei Minuten
spaeter durch.

### Wochentage und Uhrzeiten

Infobilder verstehen dieselben Wiederholungsregeln wie `recurring.json`:
`type` `weekly` mit `day_of_week`, `daily`, oder `annual` mit `month`/`day`.
Dazu `after_time`/`before_time`; ein Fenster ueber Mitternacht
(`22:00`–`01:00`) ist erlaubt.

Alternativ ein einmaliger Termin ueber `valid_from`/`valid_until`, hier auch
mit Uhrzeit (`2026-09-25T08:00:00`) — diese Datei liest nur der Rahmen, der
Datum plus Zeit korrekt auswertet. In der geteilten `common/news.json` gilt
das **nicht**, siehe CLAUDE.md im PAC-Repo.

### priority ist ein Schalter, kein Regler

`false` — das Bild reiht sich in den normalen Takt ein, zwischendurch laufen
Fotos weiter. `every_minutes` setzt eine Mindestpause fuer diesen Eintrag,
`duration_sec` die Standzeit.

`true` — der Rahmen zeigt **nichts anderes mehr**: keine Fotos, kein Quiz,
keine Livecam, nur die Prioritaets-Eintraege im Wechsel alle
`priority_rotation_seconds`. Das ist ein Anschlagbrett. Ohne enges Zeitfenster
sieht die Benutzerin nie wieder ein Foto, und am Bildschirm sieht das nicht
nach einem Fehler aus.

### Der aktuelle Stand

```json
{
  "id": "pommes_freitag",
  "_text": "Heute gibt es Pommes Frites.",
  "image": "pommes.png",
  "type": "weekly",
  "day_of_week": "friday",
  "after_time": "15:00",
  "before_time": "19:00",
  "priority": false,
  "every_minutes": 60,
  "duration_sec": 30
}
```

`_text` wertet der Rahmen nicht aus. Es steht dort, weil ohne caption sonst
niemand sieht, was auf dem Bild steht, ohne es zu oeffnen.

Eingerichtet sind fuenf:

| Bild | Wann | priority |
|---|---|---|
| `reinigung.png` | Fr 09:00–11:00 | false, alle 20 Min. |
| `einkaufsspitex.png` | Mo 13:00–14:00 | **true** |
| `pommes.png` | Fr 15:00–19:00 | false, stuendlich |
| `katzenfutter.png` | taeglich 17:00–21:00 | false, stuendlich |
| `gute_nacht.png` | taeglich 22:00–01:00 | **true** |

## Anzeige-Tuning

Die wichtigsten Takt- und Lesbarkeitswerte liegen in **Google Drive**:

```text
KioskContent/mint2/config.json
```

Empfohlene Werte fuer den Sony-TV und Sehbehinderung:

```json
{
  "photo_seconds": 45,
  "interstitial_every_minutes": 5,
  "interstitial_duration_seconds": 40,
  "quiz_every_minutes": 10,
  "quiz_block_size": 3,
  "quiz_question_seconds": 12,
  "quiz_answer_seconds": 8
}
```

Hinweise:

- `photo_seconds`: hoeher = ruhigere Slideshow.
- `interstitial_every_minutes`: niedriger = News/Suggestions erscheinen haeufiger.
- Quiz wird vollflaechig dunkelblau mit sehr grosser weisser Schrift angezeigt.
- News/Suggestions werden wie Quiz vollflaechig dunkelblau mit sehr grosser
  weisser Schrift angezeigt. Das Foto im Hintergrund wird dabei ausgeblendet.

Bei bestehenden Installationen die vorhandene `config.json` in Google Drive anpassen.
Das Setup ersetzt sie nicht automatisch, damit lokale Einstellungen erhalten bleiben.

## Wartungsmodus

Fuer AnyDesk-Administration ohne stoerenden Fullscreen:

```bash
maintenance 10
```

Das stoppt Firefox-Kiosk und Watchdog fuer 10 Minuten und startet danach
automatisch wieder. Der Sync bleibt aktiv. Sofort zurueck zum Kiosk:

```bash
maintenance off
```

## Livecam Greifensee

Die Livecam ist bewusst konservativ geloest: nur ein direktes JPG, kein schweres
Webcam-Portal im Kiosk. Standard:

```json
{
  "livecam_enabled": true,
  "livecam_url": "https://www.greifenseewetter.ch/Kamera/greifensee2.jpg",
  "livecam_every_minutes": 45,
  "livecam_duration_seconds": 35,
  "livecam_min_refresh_minutes": 15
}
```

Damit wird nicht laufend ein neues Bild geladen. Wenn die Kamera stoert:
`livecam_enabled` in `config.json` auf `false` setzen.

## Quizfragen

Datei in **Google Drive**:

```text
KioskContent/mint2/quiz.json
```

Format:

```json
{
  "schema_version": 1,
  "items": [
    {
      "id": "hauptstadt_frankreich",
      "question": "Was ist die Hauptstadt von Frankreich?",
      "answer": "Paris"
    }
  ]
}
```

Standardverhalten aus `config.json`:

```json
{
  "quiz_enabled": true,
  "quiz_every_minutes": 10,
  "quiz_block_size": 3,
  "quiz_question_seconds": 12,
  "quiz_answer_seconds": 8
}
```

Es werden jeweils drei Fragen nacheinander gezeigt. Die Frage erscheint alleine,
dann die Antwort. Danach laeuft wieder der Bilderrahmen weiter.

## Speicherschutz

Der Kiosk loescht keine Fotos automatisch. Stattdessen prueft der Sync vor jedem
rclone-Lauf den freien Speicher auf dem Laufwerk von `FRAME_DATA_DIR`.

Standardwerte:

```bash
DISK_WARN_FREE_MB=10240      # Warnung unter 10 GB frei
DISK_MIN_SYNC_FREE_MB=3072   # Sync stoppt unter 3 GB frei
RCLONE_LOG_MAX_BYTES=2000000 # rclone.log wird ab ca. 2 MB gekuerzt
RCLONE_LOG_KEEP_LINES=2000   # letzte rclone-Logzeilen behalten
```

Wenn zu wenig Speicher frei ist, bleibt der bestehende lokale Datenbestand
unveraendert. Neue Inhalte werden dann aus keiner der beiden Quellen mehr
nachgeladen, bis wieder Platz frei ist.

Pruefen:

```bash
df -h ~ ~/frame-data
du -sh ~/frame-data ~/frame-data/common ~/frame-data/mint2/photos ~/state
bash ~/linuxmintphotoframe/system/bin/kiosk_healthcheck.sh
```

## Neustart aus der Ferne

Zwei Fernbefehle, derselbe Mechanismus: eine Datei, deren **Inhalt eine Marke
ist, kein Befehl**. Der Watchdog vergleicht sie mit einem Stempel in `~/state`
und handelt nur bei einem *neuen* Wert. Die Marke wird nie ausgefuehrt, die
Datei muss also nicht geloescht werden, und ein liegengebliebener Befehl kann
keine Schleife ausloesen.

| Datei | Cloud | Tut | Kommt an in |
|---|---|---|---|
| `mint2/command/neustart.txt` | OneDrive | startet den Rechner neu | ~2 Min. |
| `mint2/command/update.txt` | Google Drive | holt `main` und rollt ihn aus | bis 30 Min. |

Die Datei aendern — irgendein neuer Text, ein Datum genuegt — loest es einmal
aus.

**Warum sie in verschiedenen Clouds liegen.** `neustart.txt` ist der letzte Weg
in die Maschine, wenn sonst nichts mehr geht; er darf nicht am selben Strang
haengen wie der Weg, den ein kaputtes Deploy zerstoeren kann, und bleibt
ausserdem von der Drive-Drossel verschont. `update.txt` liegt in Drive, weil
dorthin auch ein Agent schreiben kann — ein Deploy laesst sich damit aus einem
Chat ausloesen.

**Was das Update tut**, in `photoframe_selfupdate.sh`:

1. Sich selbst aus einer `/tmp`-Kopie in einer **eigenen transienten Unit**
   neu starten (`systemd-run --user`). Zwei getrennte Gruende, siehe unten.
2. Frisch nach `/tmp` klonen. `~/linuxmintphotoframe` ist kein Checkout, hier
   gibt es kein `git pull`.
3. `test_sync.sh` und `test_fernbefehle.py` im Klon laufen lassen. Schlaegt
   einer fehl, wird nichts ausgerollt — die laufende Installation bleibt
   unberuehrt.
4. Erst dann `kiosk_setup.sh` aus dem Klon, und ganz zuletzt der Watchdog.

Alles landet in `~/state/kiosk.log`, die Details in `~/state/selfupdate.log`.

**Warum eine eigene Unit und nicht bloss `setsid`.** `kiosk_setup.sh` startet
die User-Dienste neu, darunter den Watchdog — und der Watchdog hat das Deploy
gestartet. `systemctl restart` raeumt die **ganze Cgroup** der Unit ab,
`KillMode` steht per Voreinstellung auf `control-group`. `setsid` loest die
Prozessgruppe, nicht die Cgroup; ein `setsid`-Kind des Watchdogs stirbt also
mitten in der Installation: kein Log, kein `frame-version.txt`, ein
`/tmp`-Klon, den niemand wegraeumt, und beim naechsten Versuch faengt alles von
vorn an. Von Hand gestartet faellt das nie auf — dann haengt das Deploy an der
Login-Session. Der Fehler griff **nur** auf dem Weg, fuer den das Skript da
ist. `systemd-run --user` gibt ihm eine eigene Cgroup, die das ueberlebt. Als
zweiter Riegel setzt `photoframe_selfupdate.sh`
`FRAME_SETUP_WATCHDOG_RESTART=defer`; `kiosk_setup.sh` laesst den Watchdog dann
aus, und das Skript startet ihn selbst, sobald das Setup durch ist. Von Hand
aufgerufen ist die Variable leer und alles laeuft wie bisher.

Die `/tmp`-Kopie ist der zweite, davon unabhaengige Grund: `kiosk_setup.sh`
spielt den ganzen Baum per `cp -a` ueber `~/linuxmintphotoframe`, also auch
ueber die Datei, die bash gerade liest.

**Nichts darf auf eine Eingabe warten oder unbegrenzt dauern.** Das Skript
haelt die Sperre, an der der Neustart-Weg haengt. `GIT_TERMINAL_PROMPT=0` und
Verwandte verhindern, dass git ein Passwortfenster aufmacht; `mit_frist`
begrenzt Klon (300 s), Tests (300 s) und Setup (900 s).

**Eine Marke wird nie fuer nichts verbraucht.** Der Stempel wird *vor* dem
Handeln geschrieben, damit ein Schreibfehler keine Schleife ausloest. Laesst
sich das Deploy dann aber gar nicht starten, gaelte dieselbe Marke nie wieder
als neu — das Update waere still verloren. Der Watchdog nimmt den Stempel
darum zurueck und versucht es beim naechsten Durchlauf erneut. Aus demselben
Grund liest er waehrend eines laufenden Deploys **keine** der beiden Marken.

**Warum die neue Oberflaeche ueberhaupt sichtbar wird.** Firefox wird hier per
`setsid -f` gestartet und haengt in keiner systemd-Unit. Ein
`systemctl --user restart …-browser.service` ruft darum nur den Starter erneut
auf; der sieht "laeuft schon", holt das Fenster nach vorn — und die *Seite*
wird nie neu geladen. Einen naechtlichen Neustart gibt es auf dem Rahmen
nicht, die alte `app.js` blieb also beliebig lange stehen. Der Server liefert
deshalb in `/api/content` ein `app_version` (Fingerabdruck von `index.html`,
`app.js`, `styles.css`); aendert es sich, laedt die Seite sich beim naechsten
Inhaltsabruf selbst neu — innerhalb von `content_reload_seconds`, ohne
schwarzes Bild und ohne dass jemand Firefox abschiessen muss.

Liegen beide Marken gleichzeitig neu an, **wartet der Neustart auf das
Deploy**. Die zwei Aufrufe zu ordnen genuegt dafuer nicht: das Deploy laeuft
abgekoppelt weiter, ein Neustart direkt danach faellt also mitten in die
Installation. Solange `photoframe_selfupdate.sh` seine Sperrdatei haelt, wird
die Neustart-Marke darum gar nicht erst gelesen; sie bleibt liegen und greift
beim naechsten Durchlauf.

Nach `UPDATE_WAIT_MAX_SEC` (600 s, in `kiosk_watchdog.py`) gewinnt der Neustart
trotzdem, mit einer WARN-Zeile. Er ist der letzte Weg in die Maschine, und ein
haengendes Deploy darf ihn nicht auf Dauer verstellen.

Von Hand, ohne auf den Sync zu warten:

```bash
bash ~/linuxmintphotoframe/system/bin/photoframe_selfupdate.sh
```

Der Inhalt muss sich aendern, z.B.:

```text
2026-09-22 18:35 test1
```

Der Watchdog merkt sich die letzte Marke in `~/state/neustart_zuletzt.txt`.
Gleicher Inhalt loest keinen zweiten Neustart aus.

## Diagnose

Healthcheck:

```bash
bash ~/linuxmintphotoframe/system/bin/kiosk_healthcheck.sh
```

Log:

```bash
tail -100 ~/state/kiosk.log
```

Services:

```bash
systemctl --user status linuxmintphotoframe-server
systemctl --user status linuxmintphotoframe-watchdog
systemctl --user status linuxmintphotoframe-sync.timer
```

## Designentscheidungen

- Fotos bleiben privat in OneDrive und werden lokal gespiegelt.
- Die Webapp laeuft lokal, nicht auf einem oeffentlichen Webspace.
- Das GitHub-Repo enthaelt keine privaten Fotos oder echten Alltagsmeldungen.
- Intervallsteuerung passiert nach Minuten, nicht nach Anzahl Fotos. Das ist
  einfacher und robuster.
- Der Kiosk hat keine lokale Bedienung. Der Browser startet automatisch; es gibt
  kein Overlay mit Klick-Knopf.
