# Nixie Countdown

A countdown timer source that displays the time on photographic Nixie tubes. Works on Windows, macOS and Linux (only tested on Debian 13).

This is a third-party plugin for OBS Studio.

![Nixie Countdown preview](docs/preview.png)

![A 10 second countdown running in OBS](docs/countdown-demo.gif)

## Features

- Set the duration in hours, minutes and seconds
- Display formats:
  - **Automatic**: picks the smallest format that fits the duration
  - **Seconds only**: `10`
  - **Minutes and seconds**: `00:10`
  - **Hours, minutes and seconds**: `00:00:10` (up to 999 hours)
- Start / Resume, Pause and Reset buttons right in the context bar under the preview
- Hotkeys for Start/Pause and Reset
- Optional restart whenever the source goes live
- Optional blink when the timer reaches zero
- Show or hide the colons and adjust the spacing between tubes
- Transparent tubes that sit cleanly over any scene
- Use your own tube images if you want a different look

## Requirements

OBS Studio 31 or newer.

## Download and install

Get the latest version from the [Releases](../../releases) page.

**Windows**

1. Download the `windows-x64.zip` file.
2. Extract it into `C:\ProgramData\obs-studio\plugins\`. You should end up with `C:\ProgramData\obs-studio\plugins\obs-nixie-countdown\bin\64bit\obs-nixie-countdown.dll`.
3. Restart OBS.

**macOS**

1. Download and run the `macos-universal.pkg` file.
2. The package is not signed, so macOS will block it the first time. Open System Settings > Privacy & Security and click **Open Anyway**.
3. Restart OBS.

**Ubuntu 24.04** (with OBS from the official OBS PPA)

```bash
sudo apt install ./obs-nixie-countdown-*-ubuntu-24.04-x86_64.deb
```

**Other Linux distributions, including Debian**: build from source (see below).

## Usage

1. In the Sources panel, click **+** and choose **Nixie Countdown**.
2. Set the duration and display format in the properties window.
3. Select the source to get **Start / Resume**, **Pause** and **Reset** in the context bar under the preview.
4. Optional: assign hotkeys under Settings > Hotkeys > "Nixie Countdown: Start/Pause" and "Nixie Countdown: Reset".

<p>
  <img src="docs/screenshots/properties-duration.png" alt="Properties: duration" width="32%">
  <img src="docs/screenshots/properties-controls.png" alt="Properties: controls" width="32%">
  <img src="docs/screenshots/properties-display.png" alt="Properties: display options" width="32%">
</p>

Resize the source with the transform handles like any other source. Its width is fixed from the duration you set, so it never changes size while counting down.

### Custom tubes

Point **Custom tube images folder** at a folder containing `0.png` through `9.png` and `colon.png`. All digit images should be the same size, with straight (non-premultiplied) alpha. Any missing file falls back to the built-in image.

### About the context bar buttons

OBS has no official way for plugins to add buttons to the context bar, so the plugin finds that bar by its internal widget names (the same in OBS 30 and 31). If a future OBS release renames them, the buttons will not appear there, but the countdown, the Properties buttons and the hotkeys keep working.

## Building from source

Based on the official [obs-plugintemplate](https://github.com/obsproject/obs-plugintemplate). Requires CMake 3.28 or newer.

**Debian or Ubuntu (quickest)**

```bash
./dev-install.sh --run
```

This checks dependencies, builds, installs into your user plugin folder and launches OBS. Run `./dev-install.sh --help` for options.

**Any platform**

| Platform | Configure | Build |
| --- | --- | --- |
| Windows (Visual Studio 2022) | `cmake --preset windows-x64` | `cmake --build --preset windows-x64` |
| macOS (Xcode 16) | `cmake --preset macos` | `cmake --build --preset macos` |
| Linux | `cmake --preset ubuntu-x86_64` | `cmake --build --preset ubuntu-x86_64` |

The Windows and macOS presets download OBS and its dependencies automatically. On Linux, install `libobs-dev qt6-base-dev cmake ninja-build gcc g++ pkg-config` first.

Every push to `main` builds all three platforms in GitHub Actions. Pushing a version tag such as `1.2.0` creates a draft release with the packages attached.

## Reporting issues

Open an issue on the [Issues](../../issues) page. Please include your OBS version, your operating system, and the lines containing `nixie` from your OBS log (Help > Log Files > Show Log Files).

## Credits

Nixie tube photograph by DANYK, from [danyk.cz/digitrony_en.html](https://danyk.cz/digitrony_en.html), used with credit under the author's reuse terms ([danyk.cz/cado_en.html](https://danyk.cz/cado_en.html)). The digits were cut from the photograph and placed on transparent backgrounds for this plugin.

**AI disclosure:** The code for this plugin was written by Claude (Anthropic's AI model) at my direction, including the C source, the Qt context bar integration and the build scripts. Claude also cut the tube digits from the source photograph, processed them onto transparent backgrounds, and generated the colon separator image. I designed the features, directed each revision, and tested it on Debian 13 with OBS.

## License

The code is GPL-2.0-or-later. See [LICENSE](LICENSE).

The tube images in `data/digits/` are derived from DANYK's photograph and are not covered by the GPL. See [Credits](#credits).
