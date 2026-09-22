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

Dann deployen:

```bash
cd /tmp
rm -rf linuxmintphotoframe
git clone https://github.com/Lioninside/linuxmintphotoframe.git
cd linuxmintphotoframe
bash system/bin/kiosk_setup.sh
```

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
