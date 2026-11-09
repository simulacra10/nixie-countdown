# Changelog

## 1.2.1

- New Debian 13 package (`debian-13-x86_64.deb`), built against Debian's own OBS. The 1.2.0 `.deb` only works on Ubuntu 24.04 with OBS from the OBS PPA, and failed to install on Debian 13.
- The Ubuntu package is now named `ubuntu-24.04-x86_64.deb`, so it's clear which system each `.deb` is for.
- Credits: the image credit notes no longer say the images are covered by the GPL (neither of the plugin's licenses covers them), and the Flatpak metadata now credits DANYK too.

## 1.2.0

- Renamed from `obs-nixie-countdown` to `nixie-countdown`, following the OBS Project's plugin naming guidelines. The display name and the source type are unchanged, so existing scenes keep working. Remove the old plugin when upgrading (see the README).
- New Flatpak package for the OBS Flatpak from Flathub
- Security hardening:
  - settings from scene collections are clamped to valid ranges
  - network paths are refused for the custom tube images folder on Windows
  - safer locking and NULL checks
- Builds against newer OBS versions (OBS 33 tested on Windows)
- Start and Start/Pause now update the display immediately
- For testers:
  - verification scripts for Windows (`verify-windows.ps1`) and Linux/macOS (`verify-linux-macos.py`) that check an installed plugin in OBS and open a pre-filled test report
  - unit tests that can run without the source (`run-tests.ps1`, `run-tests.sh`)
- `dev-install.sh` builds and installs on Debian, Ubuntu, Fedora, Arch and their derivatives
- Every change is security audited; the audits are in `security-log/`

## 1.1.0

- Start / Resume, Pause and Reset buttons in the source context bar
- Tubes are now on transparent backgrounds, with a floating colon separator
- Removed the media controls from the context bar

## 1.0.0

- First release: Nixie tube countdown source with seconds, MM:SS and HH:MM:SS formats, hotkeys, auto restart, blink at zero and custom tube images
