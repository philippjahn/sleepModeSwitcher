# SleepModeSwitcher

Ein winziges macOS-Menüleisten-Tool, das den Sleep-Modus per Klick umschaltet,
damit lokale Berechnungen **auch bei geschlossenem Deckel** weiterlaufen.

| Zustand | Icon | Bedeutung |
|--------|:----:|-----------|
| Sleep **erlaubt** (normal) | 🌙 `moon.fill` | Mac schläft wie gewohnt |
| Sleep **deaktiviert** | ⚡ `bolt.fill` | Mac bleibt wach, Berechnungen laufen weiter |

- **Linksklick** auf das Icon → schaltet sofort um (ohne Passwort-Abfrage).
- **Rechtsklick** → Menü mit Status, Auto-Aus-Einstellungen, Autostart, Beenden.
- Startet automatisch beim Login.

Technisch setzt das Tool `pmset -a disablesleep 1` / `0` — der einzige Mechanismus,
der einen Apple-Silicon-Mac bei **geschlossenem Deckel, ohne externen Monitor, im
Akkubetrieb** wach hält. (`caffeinate` und Power-Assertions reichen dafür **nicht**;
Apples eigene `caffeinate`-Manpage verweist explizit auf `pmset`.)

## Voraussetzungen

- macOS 13+ (entwickelt/getestet auf macOS 26, Apple Silicon)
- Xcode bzw. die Command Line Tools (für `swift build`)

## Installation

```bash
# 1) App bauen
./scripts/build-app.sh

# 2) Passwortlosen pmset-Zugriff einrichten (einmalig, fragt einmal nach sudo)
./scripts/install-sudoers.sh

# 3) Starten
open ./SleepModeSwitcher.app
```

Optional die App nach `/Applications` ziehen — das macht den Autostart per
Login-Item stabiler. Beim ersten Start registriert sich die App selbst als
Login-Item; ggf. unter **Systemeinstellungen → Allgemein → Anmeldeobjekte**
bestätigen.

### Was `install-sudoers.sh` macht

Es legt `/etc/sudoers.d/sleepmodeswitcher` an und erlaubt deinem Benutzer,
**ausschließlich** diese zwei Befehle ohne Passwort auszuführen:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

Die Syntax wird vorab mit `visudo -c` geprüft, bevor irgendetwas nach
`/etc/sudoers.d/` geschrieben wird. Nichts anderes wird passwortlos freigegeben.

## Auto-Aus-Sicherung

Damit der Akku bei geschlossenem Deckel nicht unbemerkt leerläuft, schaltet sich
die Sleep-Deaktivierung automatisch wieder aus, sobald eine Schwelle erreicht ist
(im Rechtsklick-Menü einstellbar, Standard: **20 % Akku** bzw. **4 Stunden**):

- **Auto-Aus bei Akku** – Aus / 10 % / 20 % / 30 % (greift nur im Akkubetrieb).
- **Auto-Aus nach Zeit** – Aus / 1 h / 2 h / 4 h / 8 h.

## Gut zu wissen

- **Wärme:** Unter Dauerlast bei komplett geschlossenem Deckel staut sich Hitze;
  der Mac drosselt dann eventuell die Leistung. Bei langen, schweren Jobs den
  Deckel leicht aufstellen oder das Throttling in Kauf nehmen.
- **Akku:** Solange Sleep deaktiviert ist, läuft der Akku weiter herunter — dafür
  gibt es die Auto-Aus-Sicherung oben.
- **100 % zukunftssicher:** Falls ein künftiges macOS-Update den reinen
  `pmset`-Weg einmal zudreht, erzwingt ein billiger HDMI-/USB-C-Dummy-Stecker
  echten Clamshell-Betrieb (funktioniert auch ohne echten Monitor, im Akkubetrieb).

## Deinstallation

```bash
./scripts/uninstall.sh
```

Setzt den Sleep-Modus zurück (`disablesleep 0`), entfernt die sudoers-Regel und
die gebaute App. Den Login-Item-Eintrag ggf. unter **Systemeinstellungen →
Allgemein → Anmeldeobjekte** entfernen.

## Projektstruktur

```
Sources/SleepModeSwitcher/
  main.swift            App-Bootstrap (Menüleiste ohne Dock-Icon)
  AppDelegate.swift     Statusicon, Klick-Handling, Menü
  SleepController.swift pmset setzen + Zustand auslesen
  SafetyMonitor.swift   Auto-Aus (Akku-Schwelle + Zeitlimit)
  LoginItem.swift       Autostart via SMAppService
scripts/
  build-app.sh          Release bauen + .app-Bundle signieren
  install-sudoers.sh    NOPASSWD-Regel installieren
  uninstall.sh          alles rückgängig machen
```
