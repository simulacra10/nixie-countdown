# Build and run the Nixie Countdown unit tests on Windows.
# Needs CMake 3.16 or newer and Visual Studio (or the Build Tools) with C++;
# OBS is not required.
#
# Usage: .\run-tests.ps1           build and run the tests
#        .\run-tests.ps1 -Clean    wipe the test build folder first
#
# Copyright (c) 2026 DMX Digital
# SPDX-License-Identifier: MIT

param([switch]$Clean)

$ErrorActionPreference = 'Stop'
$Src = $PSScriptRoot
$Build = Join-Path $Src 'build_tests'

if (-not (Test-Path (Join-Path $Src 'tests\CMakeLists.txt'))) {
    Write-Error ("This script builds the unit tests from the project source, so it must stay in the project folder. " +
        'Download the whole project from https://github.com/simulacra10/obs-nixie-countdown/archive/refs/heads/main.zip, ' +
        'extract it and run run-tests.ps1 inside the extracted folder. To check an installed plugin instead, use verify-windows.ps1.')
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    Write-Error 'CMake not found. Install it from https://cmake.org/download/ or with: winget install Kitware.CMake'
}

if ($Clean -and (Test-Path $Build)) {
    Remove-Item -Recurse -Force $Build
}

function Invoke-Step {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Step cmake @('-S', (Join-Path $Src 'tests'), '-B', $Build)
Invoke-Step cmake @('--build', $Build, '--config', 'Release')
Invoke-Step ctest @('--test-dir', $Build, '-C', 'Release', '--output-on-failure')
