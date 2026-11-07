<#
.SYNOPSIS
Builds and runs the Nixie Countdown unit tests on Windows, then offers to
submit the results as a GitHub test report.

.DESCRIPTION
Works from a clone of the project, or on its own: if the project source is
not next to this script, it downloads the exact commit from GitHub into a
temporary folder (about 3 MB) and removes it afterwards.

It needs CMake and the Microsoft C compiler (Visual Studio Build Tools). If
either is missing, it offers to install it with winget. OBS is not needed.

At the end it opens a pre-filled "Test report" issue in your browser. Nothing
is posted until you review it and click Submit there.

Run from PowerShell in the folder with this script:
    powershell -ExecutionPolicy Bypass -File .\run-tests.ps1

.PARAMETER Clean
Rebuild from scratch (only matters inside a project clone).

.PARAMETER Ref
Branch, tag or commit to download and test when run on its own. Defaults to
main. The script only accepts commits that are part of main, the tip of one
of this repository's branches, or tagged, because the downloaded code is
compiled and run on your machine.

.PARAMETER NoSubmit
Don't offer to submit the results.

.NOTES
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT
#>

param(
    [switch]$Clean,
    [string]$Ref = 'main',
    [switch]$NoSubmit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'simulacra10/obs-nixie-countdown'
$TestExeName = 'test-nixie-logic.exe'
# In CI there is nobody to answer questions.
$Interactive = -not $env:CI

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor White
}

function Stop-Script([string]$Message, [int]$Code = 2) {
    Write-Host $Message -ForegroundColor Red
    exit $Code
}

function Confirm-Choice([string]$Question) {
    if (-not $Interactive) { return $false }
    return (Read-Host "$Question (y/n)") -match '^[yY]'
}

# Pick up PATH changes made by an installer without opening a new window.
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-WithWinget([string]$Id, [string[]]$Extra = @()) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Stop-Script ('winget is not available. Install "App Installer" from the Microsoft Store, ' +
            'or install the tool yourself, then run this script again.')
    }
    $wingetArgs = @('install', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements') + $Extra
    & winget @wingetArgs
    if ($LASTEXITCODE -ne 0) { Stop-Script "winget could not install $Id (exit code $LASTEXITCODE)." }
    Update-SessionPath
}

# GitHub serves commits from forks through this repository's URLs too, so a
# commit ID alone could point at anyone's code. Only accept commits that are
# part of main, are the tip of one of this repository's branches, or are tagged.
function Assert-TrustedCommit([string]$Sha, [string]$Agent) {
    $api = "https://api.github.com/repos/$Repo"
    $compare = Invoke-RestMethod -Uri "$api/compare/main...$Sha" -UserAgent $Agent
    if ($compare.status -eq 'identical' -or $compare.status -eq 'behind') { return }
    $heads = Invoke-RestMethod -Uri "$api/commits/$Sha/branches-where-head" -UserAgent $Agent
    if (@($heads | Where-Object { $_ -and $_.name }).Count -gt 0) { return }
    $tags = Invoke-RestMethod -Uri "$api/tags?per_page=100" -UserAgent $Agent
    if (@($tags | Where-Object { $_ -and $_.commit.sha -eq $Sha }).Count -gt 0) { return }
    Stop-Script ("Commit $Sha is not part of main, a branch or a tag of github.com/$Repo, so it was not downloaded. " +
        'It may come from a fork. Only test code from this repository.')
}

# Runs a program, shows its output and keeps it for the report.
$script:Log = New-Object System.Collections.ArrayList
function Invoke-Logged([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object {
        $line = "$_"
        Write-Host $line
        [void]$script:Log.Add($line)
    }
    return $LASTEXITCODE
}

Write-Host 'Nixie Countdown unit tests (Windows)' -ForegroundColor White

# ------------------------------------------------------------------
# Tools
# ------------------------------------------------------------------

Write-Step 'Checking tools'

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    $default = Join-Path $env:ProgramFiles 'CMake\bin'
    if (Test-Path (Join-Path $default 'cmake.exe')) { $env:Path = "$default;$env:Path" }
}
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    Write-Host '  CMake is not installed.'
    if (-not (Confirm-Choice '  Install CMake now with winget? (about 35 MB)')) {
        Stop-Script 'CMake is needed. Install it from https://cmake.org/download/ and run this script again.'
    }
    Install-WithWinget 'Kitware.CMake'
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        Stop-Script 'CMake was installed but is not on the PATH yet. Open a new PowerShell window and run this script again.'
    }
}
$cmakeVersion = ((& cmake --version) | Select-Object -First 1) -replace '^cmake version ', ''
Write-Host "  CMake $cmakeVersion"

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
function Get-CompilerName {
    if (-not (Test-Path $vswhere)) { return $null }
    $name = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property displayName
    if ($name) { return "$name" }
    return $null
}
$compiler = Get-CompilerName
if (-not $compiler) {
    Write-Host '  The Microsoft C compiler (Visual Studio Build Tools) is not installed.'
    Write-Host '  It is a large download (about 2-3 GB) and Windows will ask for administrator permission.'
    if (-not (Confirm-Choice '  Install Visual Studio Build Tools now with winget?')) {
        Stop-Script ('A C compiler is needed. Install "Build Tools for Visual Studio" with the "Desktop development ' +
            'with C++" workload from https://visualstudio.microsoft.com/downloads/ and run this script again.')
    }
    Install-WithWinget 'Microsoft.VisualStudio.2022.BuildTools' @('--override',
        '--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
    $compiler = Get-CompilerName
    if (-not $compiler) { Stop-Script 'The Build Tools installer finished, but the C compiler was not found.' }
}
Write-Host "  $compiler"

# ------------------------------------------------------------------
# Source
# ------------------------------------------------------------------

Write-Step 'Getting the test source'

$downloaded = $null
if (Test-Path (Join-Path $PSScriptRoot 'tests\CMakeLists.txt')) {
    $root = $PSScriptRoot
    $build = Join-Path $root 'build_tests'
    $version = 'local project folder'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $sha = & git -C $root rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) { $version = "commit $sha (local clone)" }
    }
    Write-Host "  Using the project folder this script is in ($version)."
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12
    $agent = 'nixie-countdown-run-tests'
    # Branch, tag or commit names only, so -Ref can't change which API is called.
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref -match '\.\.') {
        Stop-Script "'$Ref' is not a valid branch, tag or commit name."
    }
    try {
        $commit = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/commits/$Ref" -UserAgent $agent).sha
        if ($commit -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned an unexpected commit ID" }
        Assert-TrustedCommit $commit $agent
    } catch {
        Stop-Script "Could not look up '$Ref' on GitHub: $($_.Exception.Message)"
    }
    $downloaded = Join-Path $env:TEMP "nixie-countdown-tests-$commit"
    if (Test-Path $downloaded) { Remove-Item -Recurse -Force $downloaded }
    New-Item -ItemType Directory -Path $downloaded | Out-Null
    $zip = Join-Path $downloaded 'source.zip'
    Write-Host "  Downloading $Ref (commit $($commit.Substring(0, 7))) from github.com/$Repo"
    Invoke-WebRequest -Uri "https://github.com/$Repo/archive/$commit.zip" -OutFile $zip -UseBasicParsing -UserAgent $agent
    Expand-Archive -Path $zip -DestinationPath $downloaded
    $root = Join-Path $downloaded "obs-nixie-countdown-$commit"
    if (-not (Test-Path (Join-Path $root 'tests\CMakeLists.txt'))) { Stop-Script "The download for '$Ref' has no tests folder." }
    $build = Join-Path $downloaded 'build'
    $version = "commit $($commit.Substring(0, 7)) ($Ref)"
}

# ------------------------------------------------------------------
# Build and run
# ------------------------------------------------------------------

$exitCode = 1
try {
    if ($Clean -and (Test-Path $build)) { Remove-Item -Recurse -Force $build }

    Write-Step 'Building the tests'
    if ((Invoke-Logged cmake @('-S', (Join-Path $root 'tests'), '-B', $build)) -ne 0) { Stop-Script 'CMake could not configure the tests.' }
    if ((Invoke-Logged cmake @('--build', $build, '--config', 'Release')) -ne 0) { Stop-Script 'The tests did not build.' }
    $msvc = $script:Log | Where-Object { $_ -match 'The C compiler identification is (.+)$' } | Select-Object -First 1
    if ($msvc -match 'identification is (.+)$') { $compiler = "$compiler ($($Matches[1]))" }

    Write-Step 'Running the tests'
    $exe = Get-ChildItem -Path $build -Recurse -Filter $TestExeName | Select-Object -First 1
    if (-not $exe) { Stop-Script "Built, but $TestExeName was not found." }
    $script:Log.Clear()
    $exitCode = Invoke-Logged $exe.FullName @()
} finally {
    if ($downloaded -and (Test-Path $downloaded)) {
        Remove-Item -Recurse -Force $downloaded -ErrorAction SilentlyContinue
    }
}

$testOutput = ($script:Log -join "`n").Trim()
$summary = 'unknown'
if ($testOutput -match '(\d+) checks, (\d+) failed') { $summary = "$($Matches[1]) checks, $($Matches[2]) failed" }
$result = if ($exitCode -eq 0) { "All passed ($summary)" } else { "Some failed ($summary)" }

Write-Host ''
if ($exitCode -eq 0) { Write-Host "All tests passed: $summary" -ForegroundColor Green }
else { Write-Host "Tests failed: $summary" -ForegroundColor Red }

# ------------------------------------------------------------------
# Submit
# ------------------------------------------------------------------

if ($NoSubmit -or -not $Interactive) { exit $exitCode }

$os = Get-CimInstance Win32_OperatingSystem
$osText = "$($os.Caption) $($os.Version) (build $($os.BuildNumber)), $($os.OSArchitecture)"

Write-Step 'Submit the results'
Write-Host '  This report would be posted publicly on GitHub:'
Write-Host "    What was tested: Unit tests (run-tests.ps1)"
Write-Host "    Result:          $result"
Write-Host "    System:          $osText"
Write-Host "    Version:         $version"
Write-Host "    Tools:           CMake $cmakeVersion, $compiler"
Write-Host '    Output:          the test output shown above'
Write-Host ''
Write-Host '  It opens in your browser for you to check first. You need a free GitHub account.'
if (-not (Confirm-Choice '  Open the report in your browser now?')) {
    Write-Host '  Not submitted. Thanks for running the tests!'
    exit $exitCode
}
$notes = Read-Host '  Anything to add? For example your PC model, or what looked wrong (optional, press Enter to skip)'

function Get-ReportUrl([string]$Output) {
    $fields = [ordered]@{
        template = 'test-report.yml'
        title = "[Test report] Unit tests on Windows: $result"
        'test-type' = 'Unit tests (run-tests.ps1)'
        result = $result
        os = $osText
        version = $version
        tools = "CMake $cmakeVersion, $compiler"
        output = $Output
        notes = $notes
        # Used by GitHub only if the Test report form isn't available; with the
        # form, the fields above are used and this is ignored.
        body = ("**What was tested:** Unit tests (run-tests.ps1)`n**Result:** $result`n" +
            "**Operating system:** $osText`n**Version or commit tested:** $version`n" +
            "**Tools:** CMake $cmakeVersion, $compiler`n`n**Output**`n``````text`n$Output`n```````n`n**Notes**`n$notes")
    }
    $query = ($fields.Keys | ForEach-Object { "$_=" + [Uri]::EscapeDataString([string]$fields[$_]) }) -join '&'
    return "https://github.com/$Repo/issues/new?$query"
}

# Browsers and GitHub reject very long links; trim the output if needed and
# put the full text on the clipboard.
$url = Get-ReportUrl $testOutput
$clipboardUsed = $false
if ($url.Length -gt 7500) {
    Set-Clipboard -Value $testOutput
    $clipboardUsed = $true
    $failLines = ($script:Log | Where-Object { $_ -match 'FAIL|checks,' }) -join "`n"
    $url = Get-ReportUrl ("(Output shortened. The full output is on your clipboard; paste it here.)`n" + $failLines)
}

# The browser covers this window once it opens, so explain first and wait.
Write-Host ''
Write-Host '  What to do in the browser:' -ForegroundColor White
if ($clipboardUsed) {
    Write-Host '    1. Click in the Output box and press Ctrl+V. This adds the full test output.'
    Write-Host '    2. Check the report, then click "Submit new issue".'
} else {
    Write-Host '    1. Check the report, then click "Submit new issue".'
}
[void](Read-Host '  Press Enter to open the report')
Start-Process $url
Write-Host '  Opened in your browser. Thank you for running the tests!'
exit $exitCode
