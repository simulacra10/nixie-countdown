#!/usr/bin/env bash
# Build Nixie Countdown and install it into your user OBS plugin folder.
# Works on Debian, Ubuntu, Fedora, Arch and their derivatives: if build tools,
# OBS or Qt development files are missing, it offers to install them.
#
# Usage: ./dev-install.sh           build and install
#        ./dev-install.sh --clean   wipe the build folder first
#        ./dev-install.sh --run     install, then launch OBS and show plugin log lines
#        ./dev-install.sh --yes     install missing packages without asking
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
YES=0

for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --run) RUN=1 ;;
    --yes) YES=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Dependencies

# Prints apt, dnf, pacman or unknown.
package_manager() {
  local ids=""
  if [ -r /etc/os-release ]; then
    ids="$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")"
  fi
  case " $ids " in
    *" debian "*|*" ubuntu "*) echo apt; return ;;
    *" fedora "*|*" rhel "*|*" centos "*) echo dnf; return ;;
    *" arch "*) echo pacman; return ;;
  esac
  for pm in apt-get dnf pacman; do
    if command -v "$pm" >/dev/null; then echo "${pm%-get}"; return; fi
  done
  echo unknown
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

PM="$(package_manager)"
case "$PM" in
  apt) packages=(obs-studio libobs-dev qt6-base-dev cmake ninja-build gcc g++ pkg-config) ;;
  dnf) packages=(obs-studio obs-studio-devel qt6-qtbase-devel cmake ninja-build gcc gcc-c++ pkgconf-pkg-config) ;;
  # OBS's CMake files need SIMDe, which Arch's obs-studio doesn't pull in.
  pacman) packages=(obs-studio qt6-base simde cmake ninja gcc pkgconf) ;;
  *) packages=() ;;
esac

missing=()
for cmd in cmake ninja gcc g++ pkg-config obs; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
[ -f /usr/include/obs/obs-module.h ] || missing+=("OBS development files")
[ -f /usr/include/obs/obs-frontend-api.h ] || missing+=("OBS frontend API development files")
[ -f /usr/include/simde/simde-common.h ] || missing+=("SIMDe headers")
compgen -G "/usr/lib*/cmake/Qt6/Qt6Config.cmake" >/dev/null ||
  compgen -G "/usr/lib/*/cmake/Qt6/Qt6Config.cmake" >/dev/null || missing+=("Qt 6 development files")

if [ ${#missing[@]} -gt 0 ]; then
  info "Missing: ${missing[*]}"
  if [[ " ${missing[*]} " == *" obs "* ]] && flatpak list 2>/dev/null | grep -qi com.obsproject.Studio; then
    info "Only the Flatpak OBS was found. Building needs the native OBS package as well."
  fi
  [ ${#packages[@]} -gt 0 ] ||
    fail "Install OBS, its development files, Qt 6 development files, CMake, Ninja, GCC and pkg-config, then run this script again."
  answer=n
  if [ "$YES" -eq 1 ]; then
    answer=y
  elif [ -t 0 ]; then
    read -r -p "Install ${packages[*]} with $PM now? (y/n) " answer
  fi
  [[ "$answer" =~ ^[yY] ]] || fail "Install them with: sudo $PM install ${packages[*]}"
  case "$PM" in
    apt) as_root apt-get update -qq && as_root apt-get install -y "${packages[@]}" ;;
    dnf) as_root dnf install -y "${packages[@]}" ;;
    pacman) as_root pacman -S --needed --noconfirm "${packages[@]}" ;;
  esac
fi
ok "Build dependencies present"

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
