#!/usr/bin/env bash
# Build Nixie Countdown and install it into your user OBS plugin folder.
#
# Usage: ./dev-install.sh           build and install
#        ./dev-install.sh --clean   wipe the build folder first
#        ./dev-install.sh --run     install, then launch OBS and show plugin log lines
#        (options can be combined: ./dev-install.sh --clean --run)
#
# Copyright (c) 2026 DMX Digital
# SPDX-License-Identifier: MIT
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="obs-nixie-countdown"
BUILD="$SRC/build_x86_64"
DEST="$HOME/.config/obs-studio/plugins/$NAME"
CLEAN=0
RUN=0

for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --run) RUN=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Dependencies
missing=()
for cmd in cmake ninja gcc g++ pkg-config; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
[ -f /usr/include/obs/obs-module.h ] || missing+=("libobs-dev")
[ -f /usr/include/obs/obs-frontend-api.h ] || missing+=("libobs-dev (frontend API)")
dpkg-query -W -f='${Status}' qt6-base-dev 2>/dev/null | grep -q "ok installed" || missing+=("qt6-base-dev")
if [ ${#missing[@]} -gt 0 ]; then
  fail "Missing: ${missing[*]}. Install with: sudo apt install obs-studio libobs-dev qt6-base-dev cmake ninja-build gcc g++ pkg-config"
fi
ok "Build dependencies present"

if ! command -v obs >/dev/null; then
  if flatpak list 2>/dev/null | grep -qi com.obsproject.Studio; then
    fail "Only the Flatpak OBS was found. Install the native one for testing: sudo apt install obs-studio"
  fi
  fail "OBS not found. Install it with: sudo apt install obs-studio"
fi

# 2. Configure and build
if [ "$CLEAN" -eq 1 ] && [ -d "$BUILD" ]; then
  info "Removing old build folder"
  rm -rf "$BUILD"
fi

cd "$SRC"
if [ ! -f "$BUILD/build.ninja" ]; then
  info "Configuring"
  cmake --preset ubuntu-x86_64 >/dev/null
fi
info "Building"
cmake --build --preset ubuntu-x86_64
[ -f "$BUILD/$NAME.so" ] || fail "Build finished but $NAME.so was not produced"
ok "Built $BUILD/$NAME.so"

# 3. Install into the user plugin folder
mkdir -p "$DEST/bin/64bit"
ln -sf "$BUILD/$NAME.so" "$DEST/bin/64bit/$NAME.so"
rm -rf "$DEST/data"
cp -r "$SRC/data" "$DEST/data"

# 4. Verify
[ -f "$DEST/bin/64bit/$NAME.so" ] || fail "Plugin link is broken: $DEST/bin/64bit/$NAME.so"
count=$(find "$DEST/data/digits" -name '*.png' | wc -l)
[ "$count" -eq 11 ] || fail "Expected 11 tube images, found $count in $DEST/data/digits"
[ -f "$DEST/data/locale/en-US.ini" ] || fail "Language file missing in $DEST/data/locale"
ok "Installed to $DEST"

if pgrep -x obs >/dev/null; then
  info "OBS is running. Restart it to load the new build."
fi

# 5. Optional launch
if [ "$RUN" -eq 1 ]; then
  if pgrep -x obs >/dev/null; then
    fail "Close OBS first, then run again with --run"
  fi
  info "Launching OBS. Plugin log lines appear below; close OBS to return to the shell."
  obs 2>&1 | grep --line-buffered -i nixie || true
fi
