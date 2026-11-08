<#
.SYNOPSIS
Verifies an installed Nixie Countdown plugin on Windows and writes a report.

.DESCRIPTION
Starts OBS, drives a Nixie Countdown source through OBS's built-in remote
control interface (obs-websocket), checks sizes, buttons, hotkeys, the
countdown and the blink at zero, and takes screenshots into a report folder on
the Desktop. At the end it opens a pre-filled "Test report" issue in your
browser and puts one image of all the screenshots on the clipboard to paste in;
nothing is posted until you review it and click Submit there.

Your own setup is left alone: the test runs in a temporary scene collection,
which is deleted afterwards, and the WebSocket settings are restored exactly.

Close OBS before running. Run from PowerShell in the folder with this script:
    powershell -ExecutionPolicy Bypass -File .\verify-windows.ps1

.PARAMETER ObsPath
Full path to obs64.exe, if OBS is not in the standard location.

.PARAMETER ExpectedSha256
SHA-256 of the plugin DLL you expect to be installed (from the release page).

.PARAMETER OutputDir
Where to write the report. Defaults to a new folder on the Desktop.

.PARAMETER SkipManual
Skip the one question that needs you to look at the screen.

.PARAMETER NoSubmit
Don't offer to submit the results as a GitHub test report.

.NOTES
Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT
#>

param(
    [string]$ObsPath,
    [string]$ExpectedSha256,
    [string]$OutputDir,
    [switch]$SkipManual,
    [switch]$NoSubmit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Repo = 'simulacra10/nixie-countdown'
$PluginName = 'nixie-countdown'
$SourceKind = 'nixie_countdown_source'
$SourceName = 'Nixie Verify'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# Letters and digits only: OBS drops other characters from the file name.
$CollectionName = "NixieVerify$($Stamp -replace '-', '')"
$MinObsVersion = [version]'31.0.0'

# Built-in tube image sizes (data/digits): digits 150x300, colon 50x300
$DigitW = 150
$ColonW = 50
$TubeH = 300

if (-not $OutputDir) {
    $OutputDir = Join-Path ([Environment]::GetFolderPath('Desktop')) "nixie-verify-$Stamp"
}

# ------------------------------------------------------------------
# Results
# ------------------------------------------------------------------

$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Name, [string]$Status, [string]$Details) {
    [void]$script:Results.Add([ordered]@{ name = $Name; status = $Status; details = $Details })
    $color = @{ pass = 'Green'; fail = 'Red'; skip = 'Yellow'; manual = 'Cyan' }[$Status]
    Write-Host ('  [{0,-6}] {1}' -f $Status.ToUpper(), $Name) -ForegroundColor $color
    if ($Details -and $Status -ne 'pass') { Write-Host "           $Details" }
}

# Runs one check. The body returns a details string, or throws to fail.
function Test-Step([string]$Name, [scriptblock]$Body) {
    try {
        $details = & $Body
        Add-Result $Name 'pass' ([string]$details)
    } catch {
        Add-Result $Name 'fail' $_.Exception.Message
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# ------------------------------------------------------------------
# Image comparison (compiled once; Windows PowerShell can build C#)
# ------------------------------------------------------------------

Add-Type -AssemblyName System.Drawing
# A compiled type can't be redefined in a PowerShell session, and testers may
# run newer versions of this script in the same window. Name the type after a
# hash of its code, so a re-run reuses it and a changed version gets a new one.
$imageCode = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public class __TYPE__ {
    public int Width;
    public int Height;
    public byte[] Bgra;

    public static __TYPE__ FromPng(byte[] png) {
        using (var ms = new MemoryStream(png))
        using (var bmp = new Bitmap(ms)) {
            var img = new __TYPE__ { Width = bmp.Width, Height = bmp.Height };
            var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly,
                                    PixelFormat.Format32bppArgb);
            img.Bgra = new byte[bmp.Width * bmp.Height * 4];
            for (int y = 0; y < bmp.Height; y++)
                Marshal.Copy(data.Scan0 + y * data.Stride, img.Bgra, y * bmp.Width * 4, bmp.Width * 4);
            bmp.UnlockBits(data);
            return img;
        }
    }

    // Fraction of pixels that show anything: not transparent and not black.
    public double VisibleFraction() {
        int visible = 0;
        for (int i = 0; i < Bgra.Length; i += 4)
            if (Bgra[i + 3] > 16 && Bgra[i] + Bgra[i + 1] + Bgra[i + 2] > 60)
                visible++;
        return (double)visible / (Width * Height);
    }

    // Combine screenshots into one labeled grid image.
    public static void SaveSheet(string[] paths, string[] labels, string outPath, int columns, int tileWidth) {
        const int pad = 8, labelHeight = 20;
        var images = new Image[paths.Length];
        int tileHeight = 1;
        for (int i = 0; i < paths.Length; i++) {
            // Copy into a new bitmap: GDI+ needs the source stream for the image's lifetime.
            using (var fs = new FileStream(paths[i], FileMode.Open, FileAccess.Read))
            using (var loaded = Image.FromStream(fs))
                images[i] = new Bitmap(loaded);
            tileHeight = Math.Max(tileHeight, images[i].Height * tileWidth / Math.Max(1, images[i].Width));
        }
        int rows = (paths.Length + columns - 1) / columns;
        using (var sheet = new Bitmap(pad + columns * (tileWidth + pad), pad + rows * (labelHeight + tileHeight + pad)))
        using (var g = Graphics.FromImage(sheet))
        using (var font = new Font("Segoe UI", 9f))
        using (var text = new SolidBrush(Color.Gainsboro))
        using (var tileBack = new SolidBrush(Color.Black)) {
            g.Clear(Color.FromArgb(40, 40, 40));
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            for (int i = 0; i < images.Length; i++) {
                int x = pad + (i % columns) * (tileWidth + pad);
                int y = pad + (i / columns) * (labelHeight + tileHeight + pad);
                int h = images[i].Height * tileWidth / Math.Max(1, images[i].Width);
                g.DrawString(labels[i], font, text, x, y + 2);
                g.FillRectangle(tileBack, x, y + labelHeight, tileWidth, tileHeight);
                g.DrawImage(images[i], new Rectangle(x, y + labelHeight, tileWidth, h));
                images[i].Dispose();
            }
            sheet.Save(outPath, ImageFormat.Png);
        }
    }

    // Fraction of pixels where any channel differs by more than 40.
    public static double ChangedFraction(__TYPE__ a, __TYPE__ b) {
        if (a.Width != b.Width || a.Height != b.Height)
            return 1.0;
        int changed = 0;
        for (int i = 0; i < a.Bgra.Length; i += 4)
            for (int c = 0; c < 4; c++)
                if (Math.Abs(a.Bgra[i + c] - b.Bgra[i + c]) > 40) {
                    changed++;
                    break;
                }
        return (double)changed / (a.Width * a.Height);
    }
}
'@
$sha = [Security.Cryptography.SHA256]::Create()
$codeHash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($imageCode))[0..5] | ForEach-Object { $_.ToString('x2') })
$sha.Dispose()
$imageTypeName = "NixieImage_$codeHash"
if (-not ($imageTypeName -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $imageCode.Replace('__TYPE__', $imageTypeName)
}
$NixieImage = [type]$imageTypeName

# Identical frames render to identical pixels, so "same" allows almost no
# change; a digit change alters a few percent of the image.
$SameMax = 0.001
$DifferentMin = 0.003
$BlankMax = 0.005

# ------------------------------------------------------------------
# obs-websocket client (protocol 5)
# ------------------------------------------------------------------

$script:Ws = $null
$script:RequestCounter = 0

function Get-Sha256Base64([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
    } finally {
        $sha.Dispose()
    }
}

function Send-ObsMessage($Message) {
    $json = $Message | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $bytes)
    $task = $script:Ws.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None)
    if (-not $task.Wait(10000)) { throw 'Timed out sending to OBS' }
}

function Receive-ObsMessage([int]$TimeoutMs = 20000) {
    $buffer = New-Object byte[] 65536
    $stream = New-Object System.IO.MemoryStream
    do {
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buffer)
        $task = $script:Ws.ReceiveAsync($segment, [Threading.CancellationToken]::None)
        if (-not $task.Wait($TimeoutMs)) { throw 'Timed out waiting for OBS to answer' }
        $result = $task.Result
        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
            throw 'OBS closed the WebSocket connection'
        }
        $stream.Write($buffer, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
}

function Connect-Obs([int]$Port, [string]$Password, [int]$TimeoutSeconds = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.Options.AddSubProtocol('obswebsocket.json')
        try {
            if ($ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port", [Threading.CancellationToken]::None).Wait(3000)) {
                break
            }
        } catch {
            # OBS is still starting
        }
        $ws.Dispose()
        if ((Get-Date) -gt $deadline) {
            throw "Could not connect to OBS on port $Port within $TimeoutSeconds seconds"
        }
        Start-Sleep -Milliseconds 1000
    }
    $script:Ws = $ws

    $hello = Receive-ObsMessage
    Assert-True ($hello.op -eq 0) "Unexpected first message from OBS (op $($hello.op))"
    $identify = @{ rpcVersion = 1; eventSubscriptions = 0 }
    if ($hello.d.PSObject.Properties['authentication']) {
        $secret = Get-Sha256Base64 ($Password + $hello.d.authentication.salt)
        $identify.authentication = Get-Sha256Base64 ($secret + $hello.d.authentication.challenge)
    }
    Send-ObsMessage @{ op = 1; d = $identify }
    $identified = Receive-ObsMessage
    Assert-True ($identified.op -eq 2) 'OBS rejected the connection (wrong password?)'
}

# obs-websocket accepts connections before OBS has finished loading and
# answers "not ready" (status 207) until then, so retry for up to 2 minutes.
$NotReady = 207
function Invoke-Obs([string]$Type, $Data) {
    $deadline = (Get-Date).AddSeconds(120)
    while ($true) {
        $script:RequestCounter++
        $id = "req-$($script:RequestCounter)"
        $request = @{ requestType = $Type; requestId = $id }
        if ($null -ne $Data) { $request.requestData = $Data }
        Send-ObsMessage @{ op = 6; d = $request }
        do {
            $msg = Receive-ObsMessage
        } while (-not ($msg.op -eq 7 -and $msg.d.requestId -eq $id))
        $status = $msg.d.requestStatus
        if ($status.result) {
            if ($msg.d.PSObject.Properties['responseData']) { return $msg.d.responseData }
            return $null
        }
        if ($status.code -eq $NotReady -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            continue
        }
        $comment = ''
        if ($status.PSObject.Properties['comment']) { $comment = $status.comment }
        throw "OBS request $Type failed (code $($status.code)) $comment"
    }
}

# ------------------------------------------------------------------
# Windows on screen
# ------------------------------------------------------------------

# Asks a yes/no question in a dialog that stays on top of OBS, so the tester
# sees it without switching back to this window. The dialog runs in its own
# short-lived PowerShell process, so nothing in this script's window can stall
# it, and it gives up after 5 minutes. The Popup type combines Yes/No (4),
# question icon (32), system modal (4096), set foreground (0x10000) and
# topmost (0x40000): topmost keeps it above OBS even while OBS has focus.
# If the dialog can't be shown (Windows Script Host disabled, timeout), the
# question is asked in this window instead.
function Read-YesNoOnTop([string]$Text, [string]$Title) {
    $toB64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
    $dialog = "`$utf8 = [Text.Encoding]::UTF8`n" +
        "`$text = `$utf8.GetString([Convert]::FromBase64String('$(& $toB64 $Text)'))`n" +
        "`$title = `$utf8.GetString([Convert]::FromBase64String('$(& $toB64 $Title)'))`n" +
        "exit (New-Object -ComObject WScript.Shell).Popup(`$text, 300, `$title, 4 + 32 + 4096 + 0x10000 + 0x40000)"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($dialog))
    $IDYES = 6
    $IDNO = 7
    try {
        $p = Start-Process powershell.exe -PassThru -Wait -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
        if ($p.ExitCode -eq $IDYES) { return $true }
        if ($p.ExitCode -eq $IDNO) { return $false }
    } catch {
        # fall through to asking here
    }
    Show-ThisWindow
    return (Read-Host '  The question box did not work. Do you see Start / Resume, Pause and Reset in the context bar? (y/n)') -match '^[yY]'
}

# Brings this PowerShell window back to the front after OBS closes, and beeps
# in case Windows only flashes it in the taskbar.
function Show-ThisWindow {
    try { [void](New-Object -ComObject WScript.Shell).AppActivate($PID) } catch { }
    Write-Host "`a" -NoNewline
}

# ------------------------------------------------------------------
# Source helpers
# ------------------------------------------------------------------

$script:SceneName = $null
$script:SceneItemId = $null
$script:ShotCount = 0

function Set-Source($Settings) {
    Invoke-Obs 'SetInputSettings' @{ inputName = $SourceName; inputSettings = $Settings; overlay = $true } | Out-Null
    Start-Sleep -Milliseconds 300
}

function Get-SourceSize {
    $t = (Invoke-Obs 'GetSceneItemTransform' @{ sceneName = $script:SceneName; sceneItemId = $script:SceneItemId }).sceneItemTransform
    return @([int]$t.sourceWidth, [int]$t.sourceHeight)
}

function Assert-Size([int]$Width, [int]$Height) {
    $size = Get-SourceSize
    Assert-True ($size[0] -eq $Width -and $size[1] -eq $Height) "size is $($size[0])x$($size[1]), expected ${Width}x${Height}"
    return "${Width}x${Height}"
}

function Press-Button([string]$Property) {
    Invoke-Obs 'PressInputPropertiesButton' @{ inputName = $SourceName; propertyName = $Property } | Out-Null
}

# Takes a screenshot of the source, saves it to the report and returns it.
function Get-Shot([string]$Label) {
    $data = (Invoke-Obs 'GetSourceScreenshot' @{ sourceName = $SourceName; imageFormat = 'png' }).imageData
    $png = [Convert]::FromBase64String($data.Substring($data.IndexOf(',') + 1))
    $script:ShotCount++
    $file = Join-Path $ShotsDir ('{0:D2}-{1}.png' -f $script:ShotCount, $Label)
    [IO.File]::WriteAllBytes($file, $png)
    return $NixieImage::FromPng($png)
}

function Assert-Same($A, $B, [string]$What) {
    $f = $NixieImage::ChangedFraction($A, $B)
    Assert-True ($f -le $SameMax) ("{0}: images differ ({1:P2} of pixels changed)" -f $What, $f)
}

function Assert-Different($A, $B, [string]$What) {
    $f = $NixieImage::ChangedFraction($A, $B)
    Assert-True ($f -ge $DifferentMin) ("{0}: images should differ but only {1:P2} of pixels changed" -f $What, $f)
}

# ------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------

Write-Host ''
Write-Host 'Nixie Countdown verification (Windows)' -ForegroundColor White
Write-Host "Report folder: $OutputDir"
Write-Host ''

$ShotsDir = Join-Path $OutputDir 'screenshots'
New-Item -ItemType Directory -Force -Path $ShotsDir | Out-Null

if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) {
    Write-Host 'OBS is running. Close it and run this script again.' -ForegroundColor Red
    exit 2
}

if (-not $ObsPath) {
    $installDir = $null
    try { $installDir = (Get-ItemProperty 'HKLM:\SOFTWARE\OBS Studio' -ErrorAction Stop).'(default)' } catch { }
    if ($installDir) { $ObsPath = Join-Path $installDir 'bin\64bit\obs64.exe' }
    if (-not $ObsPath -or -not (Test-Path $ObsPath)) {
        $ObsPath = Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'
    }
}
if (-not (Test-Path $ObsPath)) {
    Write-Host "OBS not found at $ObsPath. Pass its location with -ObsPath." -ForegroundColor Red
    exit 2
}

$os = Get-CimInstance Win32_OperatingSystem
$report = [ordered]@{
    tool = 'verify-windows.ps1'
    date = (Get-Date).ToString('o')
    os = "$($os.Caption) $($os.Version) (build $($os.BuildNumber)) $($os.OSArchitecture)"
    obs_path = $ObsPath
    obs_version = $null
    obs_websocket_version = $null
    plugin_version = $null
    plugin_dll = $null
    plugin_dll_sha256 = $null
    results = $script:Results
}

Write-Host 'Installation'
$pluginDir = Join-Path $env:ProgramData "obs-studio\plugins\$PluginName"
$dll = Join-Path $pluginDir "bin\64bit\$PluginName.dll"

Test-Step 'Plugin DLL installed' {
    Assert-True (Test-Path $dll) "not found: $dll"
    $report.plugin_dll = $dll
    $report.plugin_dll_sha256 = (Get-FileHash -Algorithm SHA256 $dll).Hash.ToLower()
    "SHA-256 $($report.plugin_dll_sha256)"
}

# The plugin used to be called obs-nixie-countdown. If that is still
# installed, OBS loads both and they claim the same source type.
Test-Step 'Old obs-nixie-countdown plugin removed' {
    $old = @((Join-Path $env:ProgramData 'obs-studio\plugins\obs-nixie-countdown'),
        (Join-Path $env:ProgramFiles 'obs-studio\obs-plugins\64bit\obs-nixie-countdown.dll')) | Where-Object { Test-Path $_ }
    Assert-True (@($old).Count -eq 0) "remove the old plugin first: $($old -join ', ')"
    'not installed'
}

Test-Step 'Plugin data files installed' {
    $missing = @()
    foreach ($f in @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'colon')) {
        if (-not (Test-Path (Join-Path $pluginDir "data\digits\$f.png"))) { $missing += "$f.png" }
    }
    if (-not (Test-Path (Join-Path $pluginDir 'data\locale\en-US.ini'))) { $missing += 'locale\en-US.ini' }
    Assert-True ($missing.Count -eq 0) "missing: $($missing -join ', ')"
    'all 11 tube images and the locale file'
}

if ($ExpectedSha256) {
    Test-Step 'Plugin DLL matches the expected build' {
        Assert-True ($report.plugin_dll_sha256 -eq $ExpectedSha256.ToLower()) "expected $($ExpectedSha256.ToLower())"
        'hash matches'
    }
}

if (-not (Test-Path $dll)) {
    Write-Host 'The plugin is not installed, so OBS checks were skipped.' -ForegroundColor Red
    exit 2
}

# Turn on the WebSocket server for this run with a one-time port and password.
$listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$Port = $listener.LocalEndpoint.Port
$listener.Stop()
# Get-Random isn't guaranteed to be cryptographically secure in Windows
# PowerShell 5.1, so use the system's secure random generator (NIXIE-2026-008).
function New-Password([int]$Length = 32) {
    $alphabet = [char[]]((48..57) + (65..90) + (97..122))
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $byte = New-Object byte[] 1
    $result = New-Object System.Text.StringBuilder
    try {
        while ($result.Length -lt $Length) {
            $rng.GetBytes($byte)
            # 248 is the largest multiple of 62 below 256; skipping higher values avoids bias.
            if ($byte[0] -lt 248) { [void]$result.Append($alphabet[$byte[0] % 62]) }
        }
    } finally {
        $rng.Dispose()
    }
    return $result.ToString()
}
$Password = New-Password

$wsConfig = Join-Path $env:APPDATA 'obs-studio\plugin_config\obs-websocket\config.json'
$wsConfigOriginal = $null
if (Test-Path $wsConfig) { $wsConfigOriginal = [IO.File]::ReadAllBytes($wsConfig) }

$scenesDir = Join-Path $env:APPDATA 'obs-studio\basic\scenes'
$scenesBefore = @()
if (Test-Path $scenesDir) { $scenesBefore = @(Get-ChildItem $scenesDir -File | ForEach-Object { $_.Name }) }

$obs = $null
$launchTime = Get-Date
$originalCollection = $null

try {
    $config = $null
    if ($wsConfigOriginal) {
        $config = [Text.Encoding]::UTF8.GetString($wsConfigOriginal) | ConvertFrom-Json
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $wsConfig) | Out-Null
        $config = New-Object PSObject
    }
    $overrides = @{ first_load = $false; server_enabled = $true; alerts_enabled = $false; auth_required = $true
        server_port = $Port; server_password = $Password }
    foreach ($key in $overrides.Keys) {
        $config | Add-Member -NotePropertyName $key -NotePropertyValue $overrides[$key] -Force
    }
    [IO.File]::WriteAllText($wsConfig, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'Starting OBS'
    # The port and password are only in the config file above, never on the
    # command line, where other programs could read them (NIXIE-2026-007).
    $obs = Start-Process -FilePath $ObsPath -WorkingDirectory (Split-Path $ObsPath) -PassThru -ArgumentList @(
        '--disable-shutdown-check', '--disable-updater')

    Test-Step 'OBS starts and accepts the test connection' {
        Connect-Obs $Port $Password
        $v = Invoke-Obs 'GetVersion'
        $report.obs_version = $v.obsVersion
        $report.obs_websocket_version = $v.obsWebSocketVersion
        "OBS $($v.obsVersion), obs-websocket $($v.obsWebSocketVersion)"
    }
    if (-not $script:Ws) { throw 'Could not connect to OBS; see the result above.' }

    Test-Step "OBS is version $MinObsVersion or newer" {
        Assert-True ([bool]$report.obs_version) 'OBS version unknown (no connection)'
        $parsed = [version](($report.obs_version -split '[^0-9.]')[0])
        Assert-True ($parsed -ge $MinObsVersion) "found $($report.obs_version)"
        $report.obs_version
    }

    # Work in a temporary scene collection so the user's scenes are untouched.
    $originalCollection = (Invoke-Obs 'GetSceneCollectionList').currentSceneCollectionName
    Invoke-Obs 'CreateSceneCollection' @{ sceneCollectionName = $CollectionName } | Out-Null
    Start-Sleep -Seconds 2
    $script:SceneName = (Invoke-Obs 'GetCurrentProgramScene').currentProgramSceneName

    Write-Host ''
    Write-Host 'Plugin in OBS'

    Test-Step 'Nixie Countdown source type is registered' {
        $kinds = (Invoke-Obs 'GetInputKindList' @{ unversioned = $true }).inputKinds
        Assert-True ($kinds -contains $SourceKind) "OBS did not load the plugin ($SourceKind not in the source list)"
        $SourceKind
    }

    Test-Step 'Default settings' {
        $d = (Invoke-Obs 'GetInputDefaultSettings' @{ inputKind = $SourceKind }).defaultInputSettings
        Assert-True ($d.hours -eq 0 -and $d.minutes -eq 5 -and $d.seconds -eq 0) 'default duration is not 5:00'
        Assert-True ($d.format -eq 0) 'default format is not Automatic'
        Assert-True ($d.show_separators -and $d.blink_at_zero -and -not $d.auto_start) 'default switches are wrong'
        Assert-True ($d.spacing -eq 0) 'default spacing is not 0'
        '5:00, Automatic, colons on, blink on, auto restart off, spacing 0'
    }

    Test-Step 'Create a source (5 seconds, MM:SS)' {
        $r = Invoke-Obs 'CreateInput' @{ sceneName = $script:SceneName; inputName = $SourceName; inputKind = $SourceKind
            inputSettings = @{ hours = 0; minutes = 0; seconds = 5; format = 2 }; sceneItemEnabled = $true }
        $script:SceneItemId = $r.sceneItemId
        Start-Sleep -Milliseconds 500
        Assert-Size (4 * $DigitW + $ColonW) $TubeH
    }
    if (-not $script:SceneItemId) { throw 'Could not create the test source; see the result above.' }

    Write-Host ''
    Write-Host 'Display'

    Test-Step 'Seconds only format: 2 tubes' {
        Set-Source @{ format = 1 }
        Assert-Size (2 * $DigitW) $TubeH
    }
    Test-Step 'Hours, minutes and seconds format: 6 tubes and 2 colons' {
        Set-Source @{ format = 3 }
        Assert-Size (6 * $DigitW + 2 * $ColonW) $TubeH
    }
    Test-Step 'Automatic format picks seconds only for 5 seconds' {
        Set-Source @{ format = 0 }
        Assert-Size (2 * $DigitW) $TubeH
    }
    Test-Step 'Colons can be hidden' {
        Set-Source @{ format = 2; show_separators = $false }
        Assert-Size (4 * $DigitW) $TubeH
    }
    Test-Step 'Tube spacing' {
        Set-Source @{ show_separators = $true; spacing = 10 }
        Assert-Size (4 * $DigitW + $ColonW + 4 * 10) $TubeH
    }
    Test-Step 'Out of range settings are clamped (NIXIE-2026-001)' {
        Set-Source @{ hours = 99999999; spacing = 1000000; format = 3 }
        # 999 hours max gives "999:00:05": 7 tubes, 2 colons, spacing clamped to 150
        Assert-Size (7 * $DigitW + 2 * $ColonW + 8 * 150) $TubeH
        Invoke-Obs 'GetVersion' | Out-Null
        'clamped to 999 hours and spacing 150; OBS still responding'
    }
    Test-Step 'Network path for tube images is refused (NIXIE-2026-002)' {
        Set-Source @{ hours = 0; spacing = 0; format = 2; image_dir = '\\localhost\nixie-verify-test' }
        $r = Assert-Size (4 * $DigitW + $ColonW) $TubeH
        Set-Source @{ image_dir = '' }
        "built-in tubes kept ($r); log line is checked below"
    }

    Write-Host ''
    Write-Host 'Timer (screenshots are saved in the report)'
    Press-Button 'btn_reset'
    Start-Sleep -Milliseconds 300
    $s0 = Get-Shot 'reset-0005'

    Test-Step 'Tubes are drawn' {
        $v = $s0.VisibleFraction()
        Assert-True ($v -gt 0.05) ("only {0:P1} of the image shows anything" -f $v)
        "{0:P0} of the image lit" -f $v
    }

    $s1 = $null
    Test-Step 'Start / Resume button counts down' {
        Press-Button 'btn_start'
        Start-Sleep -Milliseconds 2200
        Press-Button 'btn_pause'
        Start-Sleep -Milliseconds 300
        $script:s1 = Get-Shot 'after-start-0003'
        Assert-Different $s0 $script:s1 'after 2 seconds'
        'display changed'
    }
    Test-Step 'Pause button stops the countdown' {
        Assert-True ($null -ne $script:s1) 'needs the previous step'
        Start-Sleep -Milliseconds 1500
        $s2 = Get-Shot 'paused'
        Assert-Same $script:s1 $s2 'while paused'
        'display unchanged for 1.5 seconds'
    }
    Test-Step 'Reset button returns to the full duration' {
        Press-Button 'btn_reset'
        Start-Sleep -Milliseconds 300
        $s3 = Get-Shot 'after-reset'
        Assert-Same $s0 $s3 'after reset'
        'matches the starting display'
    }
    Test-Step 'Countdown reaches zero and blinks' {
        Press-Button 'btn_start'
        Start-Sleep -Milliseconds 6000
        $visible = 0
        $blank = 0
        for ($i = 0; $i -lt 10; $i++) {
            $shot = Get-Shot "finished-$i"
            if ($shot.VisibleFraction() -le $BlankMax) { $blank++ } else { $visible++; $lit = $shot }
            Start-Sleep -Milliseconds 120
        }
        Assert-True ($visible -gt 0 -and $blank -gt 0) "expected both lit and dark frames, got $visible lit and $blank dark"
        Assert-Different $s0 $lit 'at zero compared to the start'
        "$visible lit and $blank dark frames in about 1.5 seconds"
    }

    Write-Host ''
    Write-Host 'Hotkeys'
    Press-Button 'btn_reset'
    Start-Sleep -Milliseconds 300

    Test-Step 'Start/Pause hotkey' {
        Invoke-Obs 'TriggerHotkeyByName' @{ hotkeyName = 'NixieCountdown.StartPause'; contextName = $SourceName } | Out-Null
        Start-Sleep -Milliseconds 2200
        Invoke-Obs 'TriggerHotkeyByName' @{ hotkeyName = 'NixieCountdown.StartPause'; contextName = $SourceName } | Out-Null
        Start-Sleep -Milliseconds 300
        $a = Get-Shot 'hotkey-started'
        Assert-Different $s0 $a 'after the hotkey started the timer'
        Start-Sleep -Milliseconds 1200
        $b = Get-Shot 'hotkey-paused'
        Assert-Same $a $b 'after the hotkey paused the timer'
        'starts and pauses'
    }
    Test-Step 'Reset hotkey' {
        Invoke-Obs 'TriggerHotkeyByName' @{ hotkeyName = 'NixieCountdown.Reset'; contextName = $SourceName } | Out-Null
        Start-Sleep -Milliseconds 300
        $c = Get-Shot 'hotkey-reset'
        Assert-Same $s0 $c 'after the reset hotkey'
        'returns to the full duration'
    }

    Write-Host ''
    Write-Host 'Context bar (needs you)'
    if ($SkipManual) {
        Add-Result 'Context bar buttons appear' 'skip' 'skipped with -SkipManual'
    } else {
        Write-Host '  Answer the question in the box on top of OBS.'
        $seen = Read-YesNoOnTop ("One thing to check by eye:`n`n" +
            "1. In OBS, click `"Nixie Verify`" in the Sources panel.`n" +
            "2. Look at the bar under the preview, next to Properties and Filters.`n`n" +
            "Do you see Start / Resume, Pause and Reset buttons there?`n`n" +
            '(You can drag this box aside if it covers the bar.)') 'Nixie Countdown verification'
        if ($seen) {
            Add-Result 'Context bar buttons appear' 'manual' 'tester reported: buttons visible'
        } else {
            Add-Result 'Context bar buttons appear' 'fail' 'tester reported: buttons not visible'
        }
    }
} catch {
    Add-Result 'Run completed' 'fail' $_.Exception.Message
} finally {
    Write-Host ''
    Write-Host 'Cleaning up'
    if ($script:Ws) {
        try {
            if ($script:SceneItemId) { Invoke-Obs 'RemoveInput' @{ inputName = $SourceName } | Out-Null }
            if ($originalCollection) {
                Invoke-Obs 'SetCurrentSceneCollection' @{ sceneCollectionName = $originalCollection } | Out-Null
                Start-Sleep -Seconds 2
            }
        } catch {
            Write-Host "  Could not switch back to your scene collection: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        try { $script:Ws.Dispose() } catch { }
    }
    if ($obs -and -not $obs.HasExited) {
        [void]$obs.CloseMainWindow()
        if (-not $obs.WaitForExit(30000)) {
            Write-Host '  OBS did not close on its own; stopping it.' -ForegroundColor Yellow
            $obs.Kill()
            $obs.WaitForExit(10000) | Out-Null
        }
    }
    if ($wsConfigOriginal) {
        [IO.File]::WriteAllBytes($wsConfig, $wsConfigOriginal)
    } elseif (Test-Path $wsConfig) {
        Remove-Item $wsConfig
    }
    if (Test-Path $scenesDir) {
        Get-ChildItem $scenesDir -File | Where-Object {
            $scenesBefore -notcontains $_.Name -and $_.Name -like 'NixieVerify*'
        } | Remove-Item
    }
    Write-Host '  OBS closed, WebSocket settings restored, temporary scene collection removed.'
    Show-ThisWindow
}

# ------------------------------------------------------------------
# OBS log
# ------------------------------------------------------------------

Write-Host ''
Write-Host 'OBS log'
$logDir = Join-Path $env:APPDATA 'obs-studio\logs'
$log = $null
$pluginLogLines = @()
if (Test-Path $logDir) {
    $log = Get-ChildItem $logDir -Filter '*.txt' | Where-Object { $_.LastWriteTime -ge $launchTime.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if ($log) {
    $lines = @(Get-Content $log.FullName | Where-Object { $_ -match 'nixie' })
    $lines | Set-Content (Join-Path $OutputDir 'obs-log-nixie.txt')
    # Only the plugin's own lines go into the report text, without timestamps.
    $pluginLogLines = @($lines | Where-Object { $_ -match '\[nixie-countdown\]' } |
        ForEach-Object { $_ -replace '^\d{2}:\d{2}:\d{2}\.\d{3}:\s*', '' })

    Test-Step 'Plugin reports it loaded' {
        $loaded = $lines | Where-Object { $_ -match 'plugin loaded successfully \(version ([^)]+)\)' } | Select-Object -First 1
        Assert-True ($null -ne $loaded) 'no "plugin loaded successfully" line in the OBS log'
        [void]($loaded -match 'version ([^)]+)\)')
        $report.plugin_version = $Matches[1]
        "version $($Matches[1])"
    }
    Test-Step 'Network path was refused in the log' {
        Assert-True (@($lines | Where-Object { $_ -match 'ignoring network path' }).Count -gt 0) 'no "ignoring network path" line in the OBS log'
        'log line present'
    }
    Test-Step 'No plugin errors in the log' {
        $errors = @($lines | Where-Object { $_ -match 'missing built-in image|error' })
        Assert-True ($errors.Count -eq 0) "found: $($errors[0])"
        'none'
    }
} else {
    Add-Result 'OBS log found' 'fail' "no log written since the test started in $logDir"
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------

$failed = @($script:Results | Where-Object { $_.status -eq 'fail' }).Count
$passed = @($script:Results | Where-Object { $_.status -eq 'pass' }).Count
$manual = @($script:Results | Where-Object { $_.status -eq 'manual' }).Count
$report.summary = [ordered]@{ passed = $passed; failed = $failed; tester_confirmed = $manual; total = $script:Results.Count }
$report | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'report.json')

# One image with every screenshot, so testers attach a single file.
$sheet = $null
$shots = @(Get-ChildItem $ShotsDir -Filter '*.png' | Sort-Object Name)
if ($shots.Count -gt 0) {
    $sheet = Join-Path $OutputDir 'nixie-verify-screenshots.png'
    $NixieImage::SaveSheet([string[]]@($shots | ForEach-Object { $_.FullName }),
        [string[]]@($shots | ForEach-Object { $_.BaseName }), $sheet, 4, 300)
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host "All $passed automated checks passed." -ForegroundColor Green
} else {
    Write-Host "$failed of $($script:Results.Count) checks failed." -ForegroundColor Red
}
Write-Host "Report folder: $OutputDir"
$exitCode = 0
if ($failed -ne 0) { $exitCode = 1 }

# ------------------------------------------------------------------
# Submit
# ------------------------------------------------------------------

# In CI there is nobody to answer questions.
if ($NoSubmit -or $env:CI) { exit $exitCode }

$automated = $passed + $failed
if ($failed -eq 0) {
    $result = "All passed ($passed automated checks"
    if ($manual -gt 0) { $result += ', context bar confirmed by tester' }
    $result += ')'
} else {
    $result = "Some failed ($failed of $automated checks failed)"
}
$pluginText = 'plugin version unknown'
if ($report.plugin_version) { $pluginText = "plugin $($report.plugin_version)" }
if ($report.plugin_dll_sha256) { $pluginText += ", DLL SHA-256 $($report.plugin_dll_sha256)" }
$toolsText = "OBS $($report.obs_version), obs-websocket $($report.obs_websocket_version)"
$checkLines = ($script:Results | ForEach-Object {
        $line = '[{0}] {1}' -f $_.status.ToUpper(), $_.name
        if ($_.details) { $line += " - $($_.details)" }
        $line
    }) -join "`n"
$logText = ''
if ($pluginLogLines.Count -gt 0) { $logText = "`n`nPlugin lines from the OBS log:`n" + ($pluginLogLines -join "`n") }

Write-Host ''
Write-Host 'Submit the results' -ForegroundColor White
Write-Host '  This report would be posted publicly on GitHub:'
Write-Host '    What was tested: Installed plugin (verify-windows.ps1)'
Write-Host "    Result:          $result"
Write-Host "    System:          $($report.os)"
Write-Host "    Version:         $pluginText"
Write-Host "    Tools:           $toolsText"
Write-Host '    Output:          the list of checks above and the plugin''s lines from the OBS log'
if ($sheet) { Write-Host '    Screenshots:     one image of the test source, which you paste in' }
Write-Host ''
Write-Host '  It opens in your browser for you to check first. You need a free GitHub account.'
if ((Read-Host '  Open the report in your browser now? (y/n)') -notmatch '^[yY]') {
    Write-Host "  Not submitted. The report is saved in $OutputDir. Thanks for testing!"
    exit $exitCode
}
$notes = Read-Host '  Anything to add? For example your PC model, or what looked wrong (optional, press Enter to skip)'

function Get-ReportUrl([string]$Output) {
    $fields = [ordered]@{
        template = 'test-report.yml'
        title = "Installed plugin on Windows: $result"
        'test-type' = 'Installed plugin (verify-windows.ps1)'
        result = $result
        os = $report.os
        version = $pluginText
        tools = $toolsText
        output = $Output
        notes = $notes
        # Used by GitHub only if the Test report form isn't available; with the
        # form, the fields above are used and this is ignored.
        body = ("**What was tested:** Installed plugin (verify-windows.ps1)`n**Result:** $result`n" +
            "**Operating system:** $($report.os)`n**Version or commit tested:** $pluginText`n" +
            "**Tools:** $toolsText`n`n**Output**`n``````text`n$Output`n```````n`n**Notes**`n$notes")
    }
    $query = ($fields.Keys | ForEach-Object { "$_=" + [Uri]::EscapeDataString([string]$fields[$_]) }) -join '&'
    return "https://github.com/$Repo/issues/new?$query"
}

# Browsers and GitHub reject very long links; keep only the checks that did
# not pass if needed and put the full text on the clipboard instead.
$fullOutput = $checkLines + $logText
$url = Get-ReportUrl $fullOutput
$clipboardUsed = $false
if ($url.Length -gt 7500) {
    Set-Clipboard -Value $fullOutput
    $clipboardUsed = $true
    $short = ($script:Results | Where-Object { $_.status -ne 'pass' } | ForEach-Object {
            '[{0}] {1} - {2}' -f $_.status.ToUpper(), $_.name, $_.details }) -join "`n"
    $url = Get-ReportUrl ("(Shortened to the checks that did not pass. The full list is on your clipboard; paste it here.)`n" + $short)
}

# Put the screenshot image on the clipboard: Ctrl+V in the report uploads it.
$imageOnClipboard = $false
if ($sheet -and -not $clipboardUsed -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $img = [Drawing.Image]::FromFile($sheet)
        [Windows.Forms.Clipboard]::SetImage($img)
        $img.Dispose()
        $imageOnClipboard = $true
    } catch {
        $imageOnClipboard = $false
    }
}

# The browser covers this window once it opens, so explain first and wait.
Write-Host ''
Write-Host '  What to do in the browser:' -ForegroundColor White
$step = 1
if ($clipboardUsed) {
    Write-Host "    $step. Click in the Output box and press Ctrl+V. This adds the full list of checks."
    $step++
}
if ($imageOnClipboard) {
    Write-Host "    $step. Click in the Notes box and press Ctrl+V. This adds the screenshots."
    $step++
} elseif ($sheet) {
    Write-Host "    $step. A File Explorer window opens too. Drag nixie-verify-screenshots.png from it"
    Write-Host '       into the Notes box. This adds the screenshots.'
    $step++
}
Write-Host "    $step. Check the report, then click `"Submit new issue`"."
[void](Read-Host '  Press Enter to open the report')
Start-Process $url
if (-not $imageOnClipboard -and $sheet) {
    Start-Process explorer.exe -ArgumentList "/select,`"$sheet`""
}
Write-Host '  Opened in your browser. Thank you for testing!'
exit $exitCode
