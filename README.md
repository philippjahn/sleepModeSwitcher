# SleepModeSwitcher

A tiny macOS menu bar app that toggles the system sleep mode with one click,
so local work can continue **with the lid closed**.

| State | Icon | Meaning |
|-------|:----:|---------|
| Sleep **allowed** (normal) | 🌙 `moon.fill` | Mac sleeps normally |
| Sleep **disabled** | ⚡ `bolt.fill` | Mac stays awake, tasks keep running |

- **Left click** on the icon toggles the state immediately (no password prompt).
- **Right click** opens a menu with status, auto-off settings, login item, and quit.
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

To avoid draining the battery unnoticed while the lid is closed, the app can
automatically re-enable sleep when a threshold is reached. This is configurable
in the right-click menu. Default settings are **20% battery** and **4 hours**.

- **Auto-off on battery** – Off / 10% / 20% / 30% (only applies on battery).
- **Auto-off after time** – Off / 1 h / 2 h / 4 h / 8 h.

## Notes

- **Heat:** Under sustained load with the lid closed, heat can build up and the
  Mac may throttle. For long heavy jobs consider leaving the lid slightly open
  or accepting reduced performance.
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
  SafetyMonitor.swift   auto-off safety (battery threshold + timeout)
  LoginItem.swift       login item registration via SMAppService
scripts/
  build-app.sh          build release binary + assemble .app bundle
  install-sudoers.sh    install NOPASSWD sudoers rule
  uninstall.sh          rollback changes and remove app
