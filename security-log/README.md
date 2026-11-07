# Security log

Each audit is recorded as one dated file in **CSAF 2.0** (OASIS Common Security Advisory Framework, also published as the international standard **ISO/IEC 20153:2025**). The files validate against the [official CSAF 2.0 JSON schema](https://docs.oasis-open.org/csaf/csaf/v2.0/csaf_json_schema.json) and can be read by CSAF tools such as [Secvisogram](https://secvisogram.github.io/).

File names follow the CSAF rule: the document's tracking ID in lower case, here `nixie-sec-YYYY-MM-DD.json`, with `-2`, `-3` and so on for further audits on the same day. Each finding has an ID of the form `NIXIE-YYYY-NNN` and records its CWE, location, failure scenario, fix and impact.

## Index

### [2026-11-07 (9)](nixie-sec-2026-11-07-9.json): no findings

Audit of the fix that lets `verify-windows.ps1` run again in the same PowerShell window: the image helper's type name now comes from a hash of its code, so a re-run reuses it instead of failing.

### [2026-11-07 (8)](nixie-sec-2026-11-07-8.json): no findings

Audit of fixes after the first real test runs (#7, #8). `verify-windows.ps1` now:
- waits while OBS reports it is still starting, with a time limit
- combines the screenshots into one image placed on the clipboard
- drops the zip
- puts the plugin's own log lines in the report text, where the tester reviews them before posting

The privacy note from log 5 is updated.

### [2026-11-07 (7)](nixie-sec-2026-11-07-7.json): no findings

Audit of the report submission added to `verify-windows.ps1`: it opens a pre-filled Test report issue in the browser and shows the report zip in File Explorer. It works the same way as `run-tests.ps1` (log 6): the tester reviews and submits the report, and the script sends nothing itself.

### [2026-11-07 (6)](nixie-sec-2026-11-07-6.json): severity Medium, 1 found, 1 fixed

Audit of the standalone `run-tests.ps1` in pull request `test/windows-verify`, which installs tools with winget, downloads the test source from GitHub and opens a pre-filled test report. Found in the draft and fixed before merge:

| ID | Issue | CWE | Fix |
| --- | --- | --- | --- |
| NIXIE-2026-006 | `-Ref` accepted fork commits, which GitHub serves through this repository's URLs, so testers could be talked into building and running someone else's code | CWE-494 | Only accept commits that are part of `main`, the tip of a branch of this repository, or tagged |

### [2026-11-07 (5)](nixie-sec-2026-11-07-5.json): no findings, 2 accepted risks

Audit of pull request `test/windows-verify`, which adds `verify-windows.ps1`. The script temporarily enables obs-websocket with a random password and restores the original settings afterwards. Accepted risks: if the PowerShell window is closed mid-run, the WebSocket server stays enabled with a password nobody knows; the report can include a custom image folder path, so testers are asked to check it before posting.

### [2026-11-07 (4)](nixie-sec-2026-11-07-4.json): no findings

Audit of pull request `test/unit-tests`, which moves the timer and layout logic into `src/nixie-logic.c`, adds unit tests with `run-tests.sh` and `run-tests.ps1`, and runs them in CI on all three platforms. The refactor also makes the width calculation saturate instead of overflowing. The tests cover the earlier fixes NIXIE-2026-001 and NIXIE-2026-002.

### [2026-11-07 (3)](nixie-sec-2026-11-07-3.json): no findings

Audit of pull request `docs/macos-testers`, which removes the `paths-ignore: '**.md'` filter from the pull request workflow so documentation-only pull requests run the checks the `main` ruleset requires. Fork pull requests still get a read-only token and no secrets, so this adds no new exposure. Logged as a CSAF informational advisory, the document type for an audit with no vulnerabilities.

### [2026-11-07 (2)](nixie-sec-2026-11-07-2.json): severity Low, 1 found, 1 fixed

Audit of pull request `fix/deprecated-button-api`, which moves the Start / Pause / Reset buttons to `obs_properties_add_button2` so the Ubuntu CI build passes against newer OBS. The API change itself introduced no issues.

| ID | Issue | CWE | Fix |
| --- | --- | --- | --- |
| NIXIE-2026-005 | Button callbacks used their data pointer without a NULL check; properties built without a source instance would crash OBS if a button were pressed | CWE-476 | Return early when data is NULL |

### [2026-11-07](nixie-sec-2026-11-07.json): severity Low, 4 found, 4 fixed

| ID | Issue | CWE | Fix |
| --- | --- | --- | --- |
| NIXIE-2026-001 | Unclamped settings from a crafted scene collection overflow `int64_t`/`int` in `nixie_update` and `layout_width` | CWE-190 | Clamp every setting to the Properties ranges on load |
| NIXIE-2026-002 | Custom image folder accepts UNC paths on Windows, which can leak the user's NTLM hash to a remote host | CWE-73 | Ignore `\\host` and `//host` folders on Windows, with a log warning |
| NIXIE-2026-003 | Texture sizes read and written without the source mutex | CWE-362 | Write sizes under the mutex in `load_textures`; read under it in `nixie_get_height` |
| NIXIE-2026-004 | CI actions referenced by movable `@v4` tags | CWE-829 | Pin each action to a commit hash |

No memory-safety, injection or secret-exposure issues were found.
