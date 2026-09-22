# Linux Mint Photo Frame Kiosk

Schlanker Linux-Mint-Kiosk fuer einen digitalen Bilderrahmen:

- Fotos kommen privat aus einem OneDrive-Ordner.
- Textmeldungen und Info-Bilder kommen ebenfalls aus diesem OneDrive-Ordner.
- Firefox zeigt lokal eine Fotoframe-Webapp im Kiosk-Modus.
- Ein Watchdog haelt Browser, Fullscreen, Display und Remote-Neustart stabil.

Git enthaelt nur Code, Setup und Beispiele. Private Inhalte bleiben in OneDrive.

## Zielbild

```text
OneDrive/Fotoframe/
  photos/
    ferien-01.jpg
    familie-02.jpg
  news.json
  info-images.json
  info/
    pommes.png
    arzttermin.png
  command/
    neustart.txt
```

Auf Mint wird dieser Ordner per `rclone` nach lokal gespiegelt:

```text
/home/<user>/frame-data/
```

Die lokale Webapp liest dann nur noch lokale Dateien ueber einen kleinen Server:

```text
http://127.0.0.1:8765/
```

## Installation auf Mint

Einmalig `rclone` fuer OneDrive konfigurieren. Empfohlener Remote-Name:

```bash
rclone config
# Name: onedrive
# Type: Microsoft OneDrive
```

Wenn der Kiosk bereits laeuft und Firefox/Fullscreen das Terminal verdeckt:

```bash
systemctl --user stop linuxmintphotoframe-watchdog.service
pkill -TERM -f 'firefox/firefox|firefox-esr/firefox-esr' || true
```

Nach der Einrichtung wieder starten:

```bash
systemctl --user start linuxmintphotoframe-watchdog.service
systemctl --user start linuxmintphotoframe-browser.service
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

Das Setup behaelt `~/.config/linuxmintphotoframe/env` bei. OneDrive-Konfig,
lokale Daten unter `~/frame-data` und die rclone-Anmeldung bleiben erhalten.

Das Setup schreibt bei Bedarf:

```text
~/.config/linuxmintphotoframe/env
```

Standardwerte:

```bash
FRAME_DATA_DIR=/home/<user>/frame-data
RCLONE_SOURCE=onedrive:Fotoframe
PHOTOFRAME_PORT=8765
DISPLAY_OUTPUT=
DISPLAY_MODE=
```

Wenn der OneDrive-Ordner anders heisst, `RCLONE_SOURCE` dort anpassen und danach:

```bash
systemctl --user restart linuxmintphotoframe-sync.service
systemctl --user restart linuxmintphotoframe-server.service
```

### OneDrive-Ordner initialisieren

Wenn der Remote `onedrive` eingerichtet ist, aber der Ordner `Fotoframe` noch
nicht existiert:

```bash
rclone mkdir onedrive:Fotoframe
rclone mkdir onedrive:Fotoframe/photos
rclone mkdir onedrive:Fotoframe/info
rclone mkdir onedrive:Fotoframe/command

rclone copy ~/linuxmintphotoframe/examples/config.json onedrive:Fotoframe
rclone copy ~/linuxmintphotoframe/examples/news.json onedrive:Fotoframe
rclone copy ~/linuxmintphotoframe/examples/info-images.json onedrive:Fotoframe
```

Pruefen:

```bash
rclone lsd onedrive:Fotoframe
rclone ls onedrive:Fotoframe
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh
ls -la ~/frame-data
```

## Inhalte aktualisieren

Alles passiert im OneDrive-Ordner `Fotoframe`.

Fotos:

```text
photos/
```

Textmeldungen:

```text
news.json
```

Info-Bilder:

```text
info-images.json
info/*.png
```

Der Mint synchronisiert alle zwei Minuten. Die Anzeige prueft den lokalen Stand
regelmaessig und braucht normalerweise keinen Neustart.

Manueller Sync-Test:

```bash
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh
tail -50 ~/state/rclone.log
ls -la ~/frame-data
ls -la ~/frame-data/photos
```

## Inhalte per Prompt erstellen

Die einfachste Pflege laeuft so:

1. Bestehende `news.json` oder `info-images.json` aus OneDrive oeffnen.
2. Inhalt in ChatGPT/Codex einfuegen.
3. Einen der Prompts unten verwenden.
4. Die komplette neue JSON-Datei zurueck in OneDrive speichern.

Wichtig:

- Immer die komplette JSON-Datei ersetzen, nicht nur einen Ausschnitt.
- Bestehende gueltige Eintraege behalten, ausser sie sollen bewusst weg.
- Datum/Uhrzeit im Format `YYYY-MM-DD` oder `YYYY-MM-DDTHH:MM:SS`.
- Zeiten sind lokale Schweizer Zeit auf dem Mint.
- IDs klein und eindeutig schreiben, z.B. `pommes_freitag_2026_09_25`.
- Keine sehr privaten Inhalte verwenden, wenn jemand anders Zugriff auf den
  OneDrive-Ordner hat.

### Prompt: Textmeldung

```text
Aktualisiere diese news.json fuer den Linux Mint Photo Frame.

Ziel:
- Neue Meldung: <was soll angezeigt werden>
- Gueltig von: <Datum/Uhrzeit>
- Gueltig bis: <Datum/Uhrzeit>
- Prioritaet: <ja/nein>
- Wenn keine Prioritaet: alle <X> Minuten zeigen
- Anzeigedauer: <X> Sekunden

Regeln:
- Gib die komplette news.json zurueck.
- Behalte bestehende Eintraege, ausser ich sage explizit loeschen.
- Verwende schema_version 1.
- Nutze klare, kurze, grosse-Bildschirm-taugliche Sprache.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle news.json:
<JSON EINFUEGEN>
```

### Prompt: Viele Varianten zum gleichen Thema

Gut fuer Erinnerungen, die haeufig erscheinen sollen, aber nicht immer gleich
klingen.

```text
Erstelle 10 unterschiedliche Textmeldungen fuer news.json zum gleichen Thema.

Thema:
<Thema>

Zeitraum:
von <Datum/Uhrzeit> bis <Datum/Uhrzeit>

Anzeige:
- priority: <true/false>
- every_minutes: <X>
- duration_sec: <X>

Ton:
- freundlich
- direkt
- sehr gut lesbar
- keine langen Saetze
- keine Emojis

Regeln:
- Jede Meldung braucht eine eindeutige id.
- Alle Meldungen sollen inhaltlich dasselbe Ziel haben, aber anders formuliert sein.
- Gib die komplette news.json zurueck.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle news.json:
<JSON EINFUEGEN>
```

### Prompt: Info-Bild Eintrag

Dieser Prompt erstellt nur den JSON-Eintrag. Das PNG selbst muss in OneDrive
unter `Fotoframe/info/` liegen.

```text
Aktualisiere diese info-images.json fuer den Linux Mint Photo Frame.

Neues Info-Bild:
- Dateiname im Ordner info/: <dateiname.png>
- Bildtext/Captionsatz: <kurzer Text oder leer>
- Gueltig von: <Datum/Uhrzeit>
- Gueltig bis: <Datum/Uhrzeit>
- Prioritaet: <ja/nein>
- Wenn keine Prioritaet: alle <X> Minuten zeigen
- Anzeigedauer: <X> Sekunden

Regeln:
- Gib die komplette info-images.json zurueck.
- Behalte bestehende Eintraege, ausser ich sage explizit loeschen.
- Verwende schema_version 1.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle info-images.json:
<JSON EINFUEGEN>
```

### Prompt: Info-Bild gestalten

Wenn ein neues PNG erstellt werden soll, zuerst das Bild prompten und danach den
Eintrag in `info-images.json` anlegen.

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
Fotoframe/info/<dateiname.png>
```

und `info-images.json` aktualisieren.

### Prompt: Aufraeumen

```text
Raeume diese news.json auf.

Regeln:
- Entferne abgelaufene Eintraege, deren valid_until vor <heutiges Datum> liegt.
- Behalte zukuenftige und aktuell gueltige Eintraege.
- Sortiere nach valid_from.
- Gib die komplette news.json zurueck.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle news.json:
<JSON EINFUEGEN>
```

## Textmeldungen

Beispiel `news.json`:

```json
{
  "schema_version": 1,
  "items": [
    {
      "id": "pommes_freitag",
      "text": "Bald werden Pommes geliefert. Unbedingt die Tuere oeffnen wenns laeutet.",
      "valid_from": "2026-09-25T18:00:00",
      "valid_until": "2026-09-25T22:00:00",
      "priority": true,
      "duration_sec": 45
    }
  ]
}
```

`priority: true` stoppt die Fotos und zeigt die Meldung dominant. Ohne Prioritaet
erscheint die Meldung als Zwischeneinblendung.

## Info-Bilder

Beispiel `info-images.json`:

```json
{
  "schema_version": 1,
  "items": [
    {
      "id": "arzttermin",
      "image": "arzttermin.png",
      "caption": "Heute Nachmittag kommt Claudia vorbei.",
      "valid_from": "2026-09-25T08:00:00",
      "valid_until": "2026-09-25T12:00:00",
      "priority": false,
      "every_minutes": 10,
      "duration_sec": 30
    }
  ]
}
```

Die Datei `arzttermin.png` liegt dann unter:

```text
info/arzttermin.png
```

## Neustart aus der Ferne

Remote-Neustart laeuft wie beim PAC, aber lokal ueber OneDrive:

```text
command/neustart.txt
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
