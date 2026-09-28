# Linux Mint Photo Frame Kiosk

Schlanker Linux-Mint-Kiosk fuer einen digitalen Bilderrahmen:

- Fotos kommen privat aus einem OneDrive-Ordner.
- Textmeldungen und Info-Bilder kommen ebenfalls aus diesem OneDrive-Ordner.
- Firefox zeigt lokal eine Fotoframe-Webapp im Kiosk-Modus.
- Ein Watchdog haelt Browser, Fullscreen, Display und Remote-Neustart stabil.

Git enthaelt nur Code, Setup und Beispiele. Private Inhalte bleiben in OneDrive.

## Zielbild

```text
Thusis OneDrive/KioskContent/
  common/
    news.json
    suggestions.json
    recurring.json
    archive/
      news-archiv.json
  mint2/
    config.json
    info-images.json
    quiz.json
    photos/
      ferien-01.jpg
      familie-02.jpg
    info/
      pommes.png
      arzttermin.png
    command/
      neustart.txt
```

Auf Mint wird nur `common/` und `mint2/` per `rclone` nach lokal kopiert:

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

Einmalig `rclone` fuer den **Thusis-OneDrive** konfigurieren. Empfohlener
Remote-Name:

```bash
rclone config
# Name: thusis
# Type: Microsoft OneDrive
```

Wichtig: Auf dem Windows-Arbeitsgeraet gibt es mehrere OneDrives. Fuer diesen
Kiosk zaehlt nur der Thusis-OneDrive auf dem Mint-Geraet. STC/work und
Lioninside/private Clemens-OneDrive nicht fuer KioskContent verwenden.

Wenn der Kiosk bereits installiert ist und Firefox/Fullscreen das Terminal verdeckt:

```bash
maintenance 10
# falls die Shell den Befehl noch nicht kennt:
~/.local/bin/maintenance 10
```

Das stoppt Browser und Watchdog fuer 10 Minuten. Der lokale Server und OneDrive-Sync laufen weiter. Vorzeitig wieder starten:

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

Das Setup behaelt `~/.config/linuxmintphotoframe/env` bei. OneDrive-Konfig,
lokale Daten unter `~/frame-data` und die rclone-Anmeldung bleiben erhalten.

Das Setup schreibt bei Bedarf:

```text
~/.config/linuxmintphotoframe/env
```

Standardwerte:

```bash
FRAME_DATA_DIR=/home/<user>/frame-data
RCLONE_SOURCE=thusis:KioskContent
PHOTOFRAME_PORT=8765
DISPLAY_OUTPUT=
DISPLAY_MODE=
```

Wenn der rclone-Remote anders heisst, `RCLONE_SOURCE` dort anpassen und danach:

```bash
systemctl --user restart linuxmintphotoframe-sync.service
systemctl --user restart linuxmintphotoframe-server.service
```

### OneDrive-Ordner initialisieren oder migrieren

Wenn der Remote `thusis` eingerichtet ist, aber `KioskContent/mint2` noch nicht
existiert:

```bash
rclone mkdir thusis:KioskContent/common
rclone mkdir thusis:KioskContent/common/archive
rclone mkdir thusis:KioskContent/mint2/photos
rclone mkdir thusis:KioskContent/mint2/info
rclone mkdir thusis:KioskContent/mint2/command

rclone copyto ~/linuxmintphotoframe/examples/config.json thusis:KioskContent/mint2/config.json
rclone copyto ~/linuxmintphotoframe/examples/info-images.json thusis:KioskContent/mint2/info-images.json
rclone copyto ~/linuxmintphotoframe/examples/quiz.json thusis:KioskContent/mint2/quiz.json

# Nur falls common/news.json noch nicht durch Mint1/PAC existiert:
if ! rclone lsf thusis:KioskContent/common | grep -qx 'news.json'; then
  rclone copyto ~/linuxmintphotoframe/examples/news.json thusis:KioskContent/common/news.json
fi
```

Pruefen:

```bash
rclone lsf -R thusis:KioskContent | sort
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh
ls -la ~/frame-data
```

Wenn bereits der alte Ordner `Fotoframe` existiert, die Mint2-spezifischen
Dateien einmalig verschieben/kopieren:

```bash
rclone copyto thusis:Fotoframe/config.json thusis:KioskContent/mint2/config.json
rclone copyto thusis:Fotoframe/info-images.json thusis:KioskContent/mint2/info-images.json
rclone copyto thusis:Fotoframe/quiz.json thusis:KioskContent/mint2/quiz.json
rclone copy thusis:Fotoframe/photos thusis:KioskContent/mint2/photos
rclone copy thusis:Fotoframe/info thusis:KioskContent/mint2/info

if ! rclone lsf thusis:KioskContent/common | grep -qx 'news.json'; then
  rclone copyto thusis:Fotoframe/news.json thusis:KioskContent/common/news.json
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

Alles passiert im Thusis-OneDrive-Ordner `KioskContent`.
Normale Mini-Updates werden **nicht** auf dem Mint-PC gepflegt. Der Mint ist
Laufzeitgeraet und spiegelt nur. Inhalte werden ueber **OneDrive Web** auf einem
anderen PC bearbeitet und vom Kiosk danach automatisch abgeholt.

Mint-Terminal/AnyDesk wird nur fuer Setup, Migration, Diagnose, Healthcheck,
Sync-Test oder Neustart verwendet.

Fotos:

```text
mint2/photos/
```

Textmeldungen:

```text
common/news.json
common/suggestions.json
common/recurring.json
```

Info-Bilder:

```text
mint2/info-images.json
mint2/info/*.png
```

Quizfragen:

```text
mint2/quiz.json
```

Der Mint synchronisiert alle zwei Minuten. Die Anzeige prueft den lokalen Stand
regelmaessig und braucht normalerweise keinen Neustart.

Manueller Sync-Test auf Mint, nur zur Kontrolle nach einer Aenderung:

```bash
bash ~/linuxmintphotoframe/system/bin/onedrive_sync.sh
tail -50 ~/state/rclone.log
ls -la ~/frame-data
ls -la ~/frame-data/mint2/photos
```

## Content via OneDrive Web und Agent

Die einfachste Pflege laeuft so:

1. Bestehende `common/news.json`, `common/suggestions.json`,
   `common/recurring.json` oder `mint2/info-images.json` aus dem
   Thusis-OneDrive in **OneDrive Web** oeffnen.
2. Inhalt in ChatGPT/Codex einfuegen.
3. Einen der Prompts unten verwenden.
4. Der Agent gibt die **komplette neue JSON-Datei** zurueck.
5. Diese komplette Datei in OneDrive Web ersetzen und speichern.

Der Agent hat keinen direkten Zugriff auf den Thusis-OneDrive. Er darf fuer
Content-Miniupdates nicht den lokalen STC-OneDrive, Lioninside-OneDrive oder
einen Windows-Ordner verwenden. Wenn die aktuelle Datei nicht im Prompt
mitgeliefert wurde, muss der Agent nach der kompletten Datei fragen.

Wichtig:

- Immer die komplette JSON-Datei ersetzen, nicht nur einen Ausschnitt.
- Bestehende gueltige Eintraege behalten, ausser sie sollen bewusst weg.
- Datum/Uhrzeit im Format `YYYY-MM-DD` oder `YYYY-MM-DDTHH:MM:SS`.
- Zeiten sind lokale Schweizer Zeit auf dem Mint.
- IDs klein und eindeutig schreiben, z.B. `pommes_freitag_2026_09_25`.
- Keine sehr privaten Inhalte verwenden, wenn jemand anders Zugriff auf den
  OneDrive-Ordner hat.
- Jede normale Textmeldung sollte mindestens zwei Varianten haben.
- Tagesbezogene Meldungen bekommen `importance: "news"` und wenn moeglich `event_date`.
- Allgemeiner Hintergrund-Content bekommt `importance: "filler"`.

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
- Soll die Meldung dominant/priority sein?
- Soll der Text heute anders lauten als vorher?

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
Aktualisiere diese common/news.json fuer den Linux Mint Photo Frame.

Ziel:
- Neue Meldung: <was soll angezeigt werden>
- Art: <news oder filler>
- Falls news mit konkretem Tag: event_date <YYYY-MM-DD>
- Gueltig von: <Datum/Uhrzeit>
- Gueltig bis: <Datum/Uhrzeit>
- Prioritaet: <ja/nein>
- Anzeigedauer: <X> Sekunden

Regeln:
- Gib die komplette common/news.json zurueck.
- Verwende schema_version 2.
- Behalte bestehende Eintraege, ausser ich sage explizit loeschen.
- Jede neue Meldung braucht mindestens 2 Varianten.
- Bei event_date nutze variants_before und variants_today.
- Formuliere variants_today mit "Heute ...".
- Filler nutzt variants.
- Nutze klare, kurze, grosse-Bildschirm-taugliche Sprache.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle common/news.json:
<JSON EINFUEGEN>
```

### Prompt: Viele Varianten zum gleichen Thema

Gut fuer Erinnerungen, die haeufig erscheinen sollen, aber nicht immer gleich
klingen.

```text
Erstelle mehrere unterschiedliche Varianten fuer einen common/news.json-Eintrag.

Thema:
<Thema>

Art:
<news oder filler>

Falls news mit konkretem Tag:
- event_date: <YYYY-MM-DD>
- variants_before: mindestens 2 Varianten fuer vorher
- variants_today: mindestens 2 Varianten fuer den Tag selbst, mit "Heute ..."

Falls filler:
- variants: mindestens 2 Varianten

Zeitraum:
von <Datum/Uhrzeit> bis <Datum/Uhrzeit>

Anzeige:
- priority: <true/false>
- duration_sec: <X>

Ton:
- freundlich
- direkt
- sehr gut lesbar
- keine langen Saetze
- keine Emojis

Regeln:
- Jede Meldung braucht eine eindeutige id.
- Gib die komplette common/news.json zurueck.
- Verwende schema_version 2.
- Keine Erklaerung, nur JSON.

Hier ist die aktuelle common/news.json:
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

`common/news.json` unterstuetzt zwei Arten von Textinhalt:

```text
importance: "news"    aktuelle oder bevorstehende Meldung
importance: "filler"  Hintergrund-Content, wenn wenig Aktuelles da ist
```

Fuer Termine mit einem konkreten Tag `event_date` verwenden. Dann kann derselbe
Eintrag vor dem Ereignis anders klingen als am Ereignistag:

```json
{
  "id": "reinigung_freitag_2026_09_25",
  "importance": "news",
  "event_date": "2026-09-25",
  "valid_from": "2026-09-23",
  "valid_until": "2026-09-25",
  "variants_before": [
    "Am Freitag kommt die Reinigung.",
    "Diese Woche kommt am Freitag wieder die Reinigung."
  ],
  "variants_today": [
    "Heute kommt die Reinigung.",
    "Heute ist Freitag, und die Reinigung kommt."
  ],
  "priority": false,
  "duration_sec": 35
}
```

Hintergrund-Content hat kein `event_date`, sondern normale Varianten:

```json
{
  "id": "lars_sekundar",
  "importance": "filler",
  "valid_from": "2026-09-23",
  "valid_until": "2026-12-31",
  "variants": [
    "Lars ist jetzt in der Sekundarschule.",
    "Fuer Lars hat mit der Sekundarschule ein neuer Abschnitt begonnen."
  ],
  "priority": false,
  "duration_sec": 35
}
```

Auswahl:

- `priority: true` stoppt Fotos und zeigt diese Meldung dominant.
- Wenn heute gueltige News existieren, werden sie deutlich bevorzugt.
- Bevorstehende News erscheinen gelegentlich.
- Filler fuellt auf, besonders wenn keine Tages-News aktiv sind.
- Eine Meldung wird nicht direkt zweimal hintereinander gezeigt.
- Eine Variante wird ebenfalls nicht direkt zweimal hintereinander gezeigt.

### Shared suggestions und recurring

Mint2 liest zusaetzlich die gemeinsamen PAC-Dateien:

```text
common/suggestions.json
common/recurring.json
```

`common/suggestions.json` ist fuer passive, allgemeine Fuellmeldungen ohne
Buttons oder Aktionen. Eintraege koennen ueber `rules.after_time` und
`rules.before_time` zeitlich eingeschraenkt werden.

`common/recurring.json` ist fuer wiederkehrende Meldungen. Unterstuetzt sind:

```json
{ "type": "weekly", "day_of_week": "friday", "after_time": "18:00", "before_time": "20:00" }
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
  "schema_version": 2,
  "items": [
    {
      "id": "reinigung_freitag_2026_09_25",
      "importance": "news",
      "event_date": "2026-09-25",
      "valid_from": "2026-09-23",
      "valid_until": "2026-09-25",
      "variants_before": [
        "Am Freitag kommt die Reinigung.",
        "Diese Woche kommt am Freitag wieder die Reinigung."
      ],
      "variants_today": [
        "Heute kommt die Reinigung.",
        "Heute ist Freitag, und die Reinigung kommt."
      ],
      "priority": false,
      "duration_sec": 35
    },
    {
      "id": "lars_sekundar",
      "importance": "filler",
      "valid_from": "2026-09-23",
      "valid_until": "2026-12-31",
      "variants": [
        "Lars ist jetzt in der Sekundarschule.",
        "Fuer Lars hat mit der Sekundarschule ein neuer Abschnitt begonnen."
      ],
      "priority": false,
      "duration_sec": 35
    }
  ]
}
```

Alte Eintraege mit nur `text` funktionieren weiterhin. Neue Eintraege sollten
aber `variants` oder `variants_before`/`variants_today` verwenden.

## Info-Bilder

Beispiel `mint2/info-images.json`:

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
mint2/info/arzttermin.png
```

## Anzeige-Tuning

Die wichtigsten Takt- und Lesbarkeitswerte liegen in OneDrive:

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

Bei bestehenden Installationen die vorhandene `config.json` in OneDrive anpassen.
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

Datei im OneDrive-Ordner:

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
unveraendert. Neue OneDrive-Inhalte werden dann nicht mehr nachgeladen, bis
wieder Platz frei ist.

Pruefen:

```bash
df -h ~ ~/frame-data
du -sh ~/frame-data ~/frame-data/common ~/frame-data/mint2/photos ~/state
bash ~/linuxmintphotoframe/system/bin/kiosk_healthcheck.sh
```

## Neustart aus der Ferne

Remote-Neustart laeuft wie beim PAC, aber lokal ueber OneDrive:

```text
mint2/command/neustart.txt
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
