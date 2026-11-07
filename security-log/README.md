# Security log

Each audit is recorded as one dated file in **CSAF 2.0** (OASIS Common Security Advisory Framework, also published as the international standard **ISO/IEC 20153:2025**). The files validate against the [official CSAF 2.0 JSON schema](https://docs.oasis-open.org/csaf/csaf/v2.0/csaf_json_schema.json) and can be read by CSAF tools such as [Secvisogram](https://secvisogram.github.io/).

File names follow the CSAF rule: the document's tracking ID in lower case, here `nixie-sec-YYYY-MM-DD.json`. Each finding has an ID of the form `NIXIE-YYYY-NNN` and records its CWE, location, failure scenario, fix and impact.

## Index

### [2026-11-07](nixie-sec-2026-11-07.json): severity Low, 4 found, 4 fixed

| ID | Issue | CWE | Fix |
| --- | --- | --- | --- |
| NIXIE-2026-001 | Unclamped settings from a crafted scene collection overflow `int64_t`/`int` in `nixie_update` and `layout_width` | CWE-190 | Clamp every setting to the Properties ranges on load |
| NIXIE-2026-002 | Custom image folder accepts UNC paths on Windows, which can leak the user's NTLM hash to a remote host | CWE-73 | Ignore `\\host` and `//host` folders on Windows, with a log warning |
| NIXIE-2026-003 | Texture sizes read and written without the source mutex | CWE-362 | Write sizes under the mutex in `load_textures`; read under it in `nixie_get_height` |
| NIXIE-2026-004 | CI actions referenced by movable `@v4` tags | CWE-829 | Pin each action to a commit hash |

No memory-safety, injection or secret-exposure issues were found.
