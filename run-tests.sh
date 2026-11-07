#!/usr/bin/env bash
# Build and run the Nixie Countdown unit tests on Linux or macOS.
# Needs CMake 3.16 or newer and a C compiler; OBS is not required.
#
# Usage: ./run-tests.sh           build and run the tests
#        ./run-tests.sh --clean   wipe the test build folder first
#
# Copyright (c) 2026 DMX Digital
# SPDX-License-Identifier: MIT
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SRC/build_tests"

for arg in "$@"; do
  case "$arg" in
    --clean) rm -rf "$BUILD" ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

command -v cmake >/dev/null || { echo "CMake not found. Install it first (Debian/Ubuntu: sudo apt install cmake; macOS: brew install cmake)." >&2; exit 1; }

cmake -S "$SRC/tests" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" --config Release
ctest --test-dir "$BUILD" -C Release --output-on-failure
