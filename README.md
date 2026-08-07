# SleepModeSwitcher

A tiny macOS menu bar app that toggles the system sleep mode with one click,
so local work can continue **with the lid closed**.

| State | Icon | Meaning |
|-------|:----:|---------|
| Sleep **allowed** (normal) | 🌙 `moon.fill` | Mac sleeps normally |
| Sleep **disabled** | ⚡ `bolt.fill` | Mac stays awake, tasks keep running |

- **Left click** on the icon toggles the state immediately (no password prompt).
- **Right click** opens a menu with status, auto-off settings, the default
  network, login item, and quit.
- Switching to *sleep disabled* asks whether to change Wi-Fi network — see
  [Network switching](#network-switching).
- Automatically registers as a login item on first launch.

The app uses `pmset -a disablesleep 1` / `0` — the only reliable method to keep
an Apple Silicon Mac awake with the lid closed, no external display, and on
battery power. `caffeinate` and power assertions do not override lid close;
Apple's own `caffeinate` manpage points to `pmset`.

## Requirements

- macOS 13+ (built/tested on macOS 14+ with Apple Silicon)
- Xcode or Command Line Tools (for `swift build`)

## Installation

```bash
# 1) Build the app
./scripts/build-app.sh

# 2) Install passwordless pmset access (prompts for sudo once)
./scripts/install-sudoers.sh

# 3) Launch
open ./SleepModeSwitcher.app
```

Optionally move the app to `/Applications` — this makes login item autostart
more stable. On first launch the app registers itself as a login item; if needed
review it under **System Settings → General → Login Items**.

### Code signing

`build-app.sh` signs with a certificate when it finds one, and falls back to
ad-hoc signing otherwise. The identity is taken from `$SIGN_IDENTITY`, else
from a `.signing-identity` file in the repository root (gitignored, one line
holding the identity name or its SHA-1 — list yours with
`security find-identity -v -p codesigning`):

```bash
SIGN_IDENTITY="My Signing" ./scripts/build-app.sh   # explicit
./scripts/build-app.sh                              # .signing-identity, else ad-hoc
```

This is not about Gatekeeper but about keeping the **Accessibility approval**
(needed for network switching) across rebuilds. macOS ties that approval to the
app's *designated requirement*:

| Signing | Designated requirement | Effect on approval |
|---|---|---|
| ad-hoc | `cdhash H"…"` — hash of the binary | invalidated by every rebuild, while System Settings still shows a ticked box |
| certificate | `identifier "…" and certificate leaf H"…"` | survives rebuilds |

Any self-signed certificate works — **Keychain Access → Certificate Assistant →
Create a Certificate**, type **Code Signing**. It does not have to be trusted,
because the requirement is a hash comparison, not a trust chain.

After switching signing identity, clear the stale approval once and grant it
again:

```bash
tccutil reset Accessibility com.philippjahn.SleepModeSwitcher
```

### App icon

`Resources/AppIcon.icns` is checked in and copied into the bundle by
`build-app.sh`, which re-renders it whenever `scripts/make-icon.swift` is newer.
The artwork is vector drawing code rather than a design file, so every size is
rendered natively — a 16pt icon downscaled from 1024 turns to mush — and the
small sizes get a thicker crescent, a fatter bolt and no stars. Render it
manually, with an optional 512px preview:

```bash
swift scripts/make-icon.swift --preview /tmp/icon.png Resources/AppIcon.icns
```

Finder caches icons per bundle; `build-app.sh` touches the app afterwards so a
changed icon actually shows up.

Note that the approval itself is per machine and never transfers; signing only
decides whether it survives rebuilds. Inspect what is stored with
`codesign -d -r- /Applications/SleepModeSwitcher.app`.

### What `install-sudoers.sh` does

It creates `/etc/sudoers.d/sleepmodeswitcher` and allows your user to run only
these two commands without a password:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

The rule is validated with `visudo -c` before it is installed. Nothing else is
given passwordless sudo access.

## Auto-off safety

Working with the lid closed means not watching the machine, so the app can
re-enable sleep on its own when a threshold is reached. All of it is
configurable in the right-click menu; defaults are **20% battery**, **4 hours**,
and **sleep as soon as the system reports serious thermal pressure**.

- **Auto-off on battery** – Off / 10% / 20% / 30% (only applies on battery).
- **Auto-off after time** – Off / 1 h / 2 h / 4 h / 8 h.
- **Auto-off on heat** – see below.

Whichever threshold fired is remembered, so the menu can say *"Last auto-off:
heat — Today, 14:32"* afterwards.

### Heat

The point of concern is the closed laptop in a bag: full load, no airflow,
nothing that ever cools it down.

**macOS covers the hardware, not the situation.** The firmware throttles as the
die heats up and, at the very end, shuts down to prevent damage. What it never
does is sleep a hot Mac — and `disablesleep` is not overridden by heat either.
Between "throttled" and "emergency shutdown" lies a long stretch of sustained
heat that buys no performance and ages the battery (noticeably above ~35 °C cell
temperature). That stretch is what this cuts short.

The trigger is `ProcessInfo.thermalState`, the same four-step pressure level
(`nominal` / `fair` / `serious` / `critical`) macOS asks apps to react to. It
needs no privileges and is the only thermal signal still supported on Apple
silicon — `pmset -g therm` fails there with `0xe00002bc`.

- **Auto-off on heat** – Off / Critical only / Serious immediately *(default)* /
  Serious after 2, 5 or 10 min. The tolerance windows are for machines that hit
  `serious` during ordinary work; `critical` never waits one out.
- Heat is ignored for the **first two minutes** after switching to "stays
  awake". Without that, enabling it on an already-hot Mac would flip straight
  back and the button would look broken. Battery and time limits start counting
  immediately.
- While sleep is disabled and the system is under thermal pressure, the menu bar
  **bolt turns orange** instead of yellow.

### Temperature readout

When die sensors are readable, the menu shows the hottest one (*"Temperature:
78 °C (serious)"*) and offers an extra **Auto-off above temperature** limit —
Off *(default)* / 90 / 95 / 100 °C, tripping after two consecutive samples so a
spike cannot.

This half rests on the private IOKit HID sensor interface (the route Stats and
macmon take: no root, no entitlement, but no guarantees either). Every symbol is
resolved at runtime, so if a future macOS drops one, the temperature line and
the °C limit simply disappear — `thermalState` keeps the safety net running on
its own. Sensor names differ per chip (an M4 Pro reports `PMU tdie1`…`tdie14`);
to check what a given machine exposes:

```bash
defaults write com.philippjahn.SleepModeSwitcher logThermalSensors -bool YES
./SleepModeSwitcher.app/Contents/MacOS/SleepModeSwitcher   # names + °C on stderr
```

## Network switching

Disabling sleep usually means working away from the desk, so every switch to
**sleep disabled** asks about the network. Three answers: **Switch** joins the
network stored as default, **Other …** offers a list of everything the Wi-Fi
menu currently shows, and **Not now** leaves the connection untouched. Nothing
is asked when switching back to sleep-allowed.

The default network is set via the right-click menu — **Network: …** — or on
the first switch, when nothing is stored yet. Picking under *Other …* is a
one-off and does not change the default.

Switching works by pressing that entry in the Wi-Fi menu through the
accessibility API — literally the manual click, automated:

- **Any listed network works**, personal hotspots included. A sleeping personal
  hotspot on your own Apple ID is woken over Bluetooth/iCloud, exactly as when
  you pick it by hand.
- **No password is ever needed.** This is the reason for the detour:
  `networksetup -setairportnetwork` and `CWInterface.associate` both fail with
  `-3900 tmpErr` on macOS 26, because the network key sits in the System
  keychain where no ordinary app can read it. The Wi-Fi menu succeeds because
  it *is* the privileged system service, credentials included.
- **Accessibility access must be allowed for the app** under **Privacy &
  Security → Accessibility**. The app asks on launch when a network is
  configured, and the failure alert offers a shortcut to the pane.

Two limits worth knowing: networks behind the collapsed **Other Networks**
section are not reachable (macOS only builds those rows once expanded), and a
network the Mac has never joined opens the system's password sheet, which the
app does not fill in.

Entries are matched on their accessibility identifier (`wifi-network-<name>`),
which is stable and unlocalized — unlike the visible description ("MyAI,
Persönlicher Hotspot, 3 Balken"). When no entry matches, the alert lists the
names the menu did offer.

If switching keeps reporting missing accessibility access although the box is
ticked, the approval belongs to an older build — see
[Code signing](#code-signing).

## Notes

- **Heat:** Under sustained load with the lid closed, heat builds up and the Mac
  throttles. The [heat auto-off](#heat) ends the worst case, but it cannot
  create airflow — for long heavy jobs, leaving the lid slightly open still
  beats being put to sleep halfway through.
- **Battery:** While sleep is disabled, the battery will continue to discharge.
  The auto-off safety settings help prevent a full drain.
- **Future-proofing:** If a future macOS update blocks this `pmset` method, a
  cheap HDMI/USB-C dummy plug is the more reliable way to keep clamshell mode
  active without a real external display.

## Uninstallation

```bash
./scripts/uninstall.sh
```

This restores normal sleep mode (`disablesleep 0`), removes the sudoers rule,
and deletes the built app. Remove any login item entry under **System Settings →
General → Login Items** if needed.

## Project structure

```
Sources/SleepModeSwitcher/
  main.swift            App bootstrap (menu bar app without Dock icon)
  AppDelegate.swift     status icon, click handling, menu
  SleepController.swift pmset control + state reading
  WiFiMenu.swift        joins a network by pressing its Wi-Fi menu entry
  SafetyMonitor.swift   auto-off safety (heat + battery threshold + timeout)
  ThermalSensor.swift   die temperature via the IOKit HID sensor interface
  LoginItem.swift       login item registration via SMAppService
scripts/
  build-app.sh          build release binary + assemble .app bundle
  make-icon.swift       draws Resources/AppIcon.icns (vector, all sizes)
  install-sudoers.sh    install NOPASSWD sudoers rule
  uninstall.sh          rollback changes and remove app
Resources/
  AppIcon.icns          Finder/Dock icon, generated by make-icon.swift
