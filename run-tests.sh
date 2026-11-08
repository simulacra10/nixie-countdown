#!/usr/bin/env bash
# Build and run the Nixie Countdown unit tests on Linux or macOS, then offer to
# submit the results as a GitHub test report. OBS is not required.
#
# Works from a clone of the project, or on its own: if the project source is
# not next to this script, it downloads the exact commit from GitHub into a
# temporary folder and removes it afterwards. If CMake or a C compiler is
# missing, it offers to install them (apt, dnf, pacman, or Homebrew and the
# Xcode Command Line Tools on macOS).
#
# Usage: ./run-tests.sh                build and run the tests
#        ./run-tests.sh --clean        rebuild from scratch (inside a clone)
#        ./run-tests.sh --ref <name>   branch, tag or commit to download (default: main)
#        ./run-tests.sh --yes          install missing tools without asking
#        ./run-tests.sh --no-submit    don't offer to submit the results
#
# Copyright (c) 2026 DMX Digital
# SPDX-License-Identifier: MIT
set -euo pipefail

REPO="simulacra10/nixie-countdown"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN=0
REF="main"
YES=0
SUBMIT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=1 ;;
    --ref) REF="${2:?--ref needs a branch, tag or commit}"; shift ;;
    --yes) YES=1 ;;
    --no-submit) SUBMIT=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# In CI, or without a terminal, there is nobody to answer questions.
INTERACTIVE=1
if [ -n "${CI:-}" ] || [ ! -t 0 ]; then INTERACTIVE=0; fi

ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[!!]\033[0m %s\n' "$*" >&2; exit 2; }

confirm() {
  [ "$YES" -eq 1 ] && return 0
  [ "$INTERACTIVE" -eq 1 ] || return 1
  local answer
  read -r -p "$1 (y/n) " answer
  [[ "$answer" =~ ^[yY] ]]
}

# ------------------------------------------------------------------
# Tools
# ------------------------------------------------------------------

# Prints apt, dnf, pacman or brew.
package_manager() {
  if [ "$(uname -s)" = "Darwin" ]; then echo brew; return; fi
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

install_packages() {
  local pm="$1"; shift
  case "$pm" in
    apt) as_root apt-get update -qq && as_root apt-get install -y "$@" ;;
    dnf) as_root dnf install -y "$@" ;;
    pacman) as_root pacman -S --needed --noconfirm "$@" ;;
    brew) brew install "$@" ;;
  esac
}

PM="$(package_manager)"
need_cmds=(cmake cc make)
[ -f "$SRC/tests/CMakeLists.txt" ] || need_cmds+=(curl tar)
missing=()
for cmd in "${need_cmds[@]}"; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
  info "Missing: ${missing[*]}"
  if [ "$PM" = "brew" ]; then
    if [[ " ${missing[*]} " == *" cc "* || " ${missing[*]} " == *" make "* ]]; then
      echo "The C compiler comes with Apple's Command Line Tools. Install them with: xcode-select --install" >&2
      echo "Then run this script again." >&2
      exit 2
    fi
    command -v brew >/dev/null || fail "Install CMake from https://cmake.org/download/ (or Homebrew from https://brew.sh), then run this script again."
    packages=(cmake)
  else
    case "$PM" in
      apt) packages=(cmake build-essential curl tar) ;;
      dnf) packages=(cmake gcc make curl tar) ;;
      pacman) packages=(cmake gcc make curl tar) ;;
      *) fail "Install CMake, a C compiler (gcc or clang), make and curl, then run this script again." ;;
    esac
  fi
  confirm "Install ${packages[*]} with $PM now?" ||
    fail "These tools are needed. Install them with your package manager and run this script again."
  install_packages "$PM" "${packages[@]}"
  for cmd in "${need_cmds[@]}"; do
    command -v "$cmd" >/dev/null || fail "$cmd is still missing after installing."
  done
fi
CMAKE_VERSION="$(cmake --version | head -1 | sed 's/^cmake version //')"
COMPILER="$(cc --version 2>/dev/null | head -1)"
ok "CMake $CMAKE_VERSION, $COMPILER"

# ------------------------------------------------------------------
# Source
# ------------------------------------------------------------------

DOWNLOADED=""
cleanup() { [ -z "$DOWNLOADED" ] || rm -rf "$DOWNLOADED"; }
trap cleanup EXIT

AGENT="nixie-countdown-run-tests"
api() { curl -fsSL -A "$AGENT" "https://api.github.com/repos/$REPO/$1"; }

# GitHub serves commits from forks through this repository's URLs too, so a
# commit ID alone could point at anyone's code. Only accept commits that are
# part of main, are the tip of one of this repository's branches, or are tagged.
assert_trusted_commit() {
  local sha="$1" status
  # The API answers with JSON on one line, so take the first match only (the
  # top-level field comes before any nested ones).
  status="$(api "compare/main...$sha" | grep -o '"status": *"[a-z]*"' | head -1 | grep -o '[a-z]*"$' | tr -d '"')" || true
  [ "$status" = "identical" ] || [ "$status" = "behind" ] && return 0
  api "commits/$sha/branches-where-head" | grep -q '"name":' && return 0
  api "tags?per_page=100" | grep -q "\"sha\": *\"$sha\"" && return 0
  fail "Commit $sha is not part of main, a branch or a tag of github.com/$REPO, so it was not downloaded. It may come from a fork. Only test code from this repository."
}

if [ -f "$SRC/tests/CMakeLists.txt" ]; then
  ROOT="$SRC"
  BUILD="$SRC/build_tests"
  VERSION="local project folder"
  if command -v git >/dev/null && sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
    VERSION="commit $sha (local clone)"
  fi
  info "Using the project folder this script is in ($VERSION)"
else
  # Branch, tag or commit names only, so --ref can't change which API is called.
  if ! [[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || [[ "$REF" == *..* ]]; then
    fail "'$REF' is not a valid branch, tag or commit name."
  fi
  COMMIT="$(api "commits/$REF" | grep -o '"sha": *"[0-9a-f]\{40\}"' | head -1 | grep -o '[0-9a-f]\{40\}')" ||
    fail "Could not look up '$REF' on GitHub."
  assert_trusted_commit "$COMMIT"
  DOWNLOADED="$(mktemp -d "${TMPDIR:-/tmp}/nixie-countdown-tests.XXXXXX")"
  info "Downloading $REF (commit ${COMMIT:0:7}) from github.com/$REPO"
  curl -fsSL -A "$AGENT" "https://github.com/$REPO/archive/$COMMIT.tar.gz" | tar -xz -C "$DOWNLOADED"
  ROOT="$DOWNLOADED/nixie-countdown-$COMMIT"
  [ -f "$ROOT/tests/CMakeLists.txt" ] || fail "The download for '$REF' has no tests folder."
  BUILD="$DOWNLOADED/build"
  VERSION="commit ${COMMIT:0:7} ($REF)"
fi

# ------------------------------------------------------------------
# Build and run
# ------------------------------------------------------------------

[ "$CLEAN" -eq 0 ] || rm -rf "$BUILD"
info "Building the tests"
cmake -S "$ROOT/tests" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" --config Release >/dev/null
info "Running the tests"
set +e
OUTPUT="$("$BUILD/test-nixie-logic" 2>&1)"
EXIT_CODE=$?
set -e
echo "$OUTPUT"

SUMMARY="$(echo "$OUTPUT" | grep -o '[0-9]* checks, [0-9]* failed' | tail -1)"
SUMMARY="${SUMMARY:-unknown}"
echo
if [ "$EXIT_CODE" -eq 0 ]; then
  ok "All tests passed: $SUMMARY"
  RESULT="All passed ($SUMMARY)"
else
  printf '\033[31m[!!]\033[0m Tests failed: %s\n' "$SUMMARY"
  RESULT="Some failed ($SUMMARY)"
fi

# ------------------------------------------------------------------
# Submit
# ------------------------------------------------------------------

[ "$SUBMIT" -eq 1 ] && [ "$INTERACTIVE" -eq 1 ] || exit "$EXIT_CODE"

if [ "$PM" = "brew" ]; then
  PLATFORM="macOS"
  OS_TEXT="macOS $(sw_vers -productVersion) ($(uname -m))"
else
  PLATFORM="Linux"
  OS_TEXT="$( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}") ), kernel $(uname -r) ($(uname -m))"
fi
TOOLS="CMake $CMAKE_VERSION, $COMPILER"
TEST_TYPE="Unit tests (run-tests.sh)"

echo
echo "Submit the results"
echo "  This report would be posted publicly on GitHub:"
echo "    What was tested: $TEST_TYPE"
echo "    Result:          $RESULT"
echo "    System:          $OS_TEXT"
echo "    Version:         $VERSION"
echo "    Tools:           $TOOLS"
echo "    Output:          the test output shown above"
echo
echo "  It opens in your browser for you to check first. You need a free GitHub account."
read -r -p "  Open the report in your browser now? (y/N) " answer
if ! [[ "$answer" =~ ^[yY] ]]; then
  echo "  Not submitted. Thanks for running the tests!"
  exit "$EXIT_CODE"
fi
read -r -p "  Anything to add? For example your computer model (optional, press Enter to skip) " NOTES

urlencode() {
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

report_url() {
  local output="$1" body
  # The body is used by GitHub only if the Test report form isn't available.
  body="$(printf '**What was tested:** %s\n**Result:** %s\n**Operating system:** %s\n**Version or commit tested:** %s\n**Tools:** %s\n\n**Output**\n```text\n%s\n```\n\n**Notes**\n%s' \
    "$TEST_TYPE" "$RESULT" "$OS_TEXT" "$VERSION" "$TOOLS" "$output" "$NOTES")"
  printf 'https://github.com/%s/issues/new?template=test-report.yml&title=%s&test-type=%s&result=%s&os=%s&version=%s&tools=%s&output=%s&notes=%s&body=%s' \
    "$REPO" "$(urlencode "Unit tests on $PLATFORM: $RESULT")" "$(urlencode "$TEST_TYPE")" "$(urlencode "$RESULT")" \
    "$(urlencode "$OS_TEXT")" "$(urlencode "$VERSION")" "$(urlencode "$TOOLS")" "$(urlencode "$output")" \
    "$(urlencode "$NOTES")" "$(urlencode "$body")"
}

URL="$(report_url "$OUTPUT")"
SHORTENED=0
if [ ${#URL} -gt 7500 ]; then
  URL="$(report_url "$(printf '(Output shortened to the failures.)\n%s' "$(echo "$OUTPUT" | grep -E 'FAIL|checks,')")")"
  SHORTENED=1
fi

# The browser may cover this terminal once it opens, so explain first and wait.
echo
echo "  What to do in the browser:"
echo '    1. Check the report, then click "Submit new issue".'
[ "$SHORTENED" -eq 0 ] || echo "       (The output was too long for a link, so only the failures are included.)"
read -r -p "  Press Enter to open the report " _
if [ "$PM" = "brew" ]; then opener=open; else opener=xdg-open; fi
if ! "$opener" "$URL" >/dev/null 2>&1; then
  echo "  Could not open a browser. Open this link yourself:"
  echo "  $URL"
fi
echo "  Opened in your browser. Thank you for running the tests!"
exit "$EXIT_CODE"
