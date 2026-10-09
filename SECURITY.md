# Security policy

simless is a local developer tool. It builds your app, installs signed copies of it on your Mac, runs them as hidden render hosts, and loads code patches into them. An optional helper, SimlessAgent, runs with Full Disk Access to place those patches. This document defines the supported versions, the trust model, and the private reporting process.

## Supported versions

| Version | Security fixes |
| --- | --- |
| Latest release | Supported |
| Earlier releases and development snapshots | Not supported |

Security fixes ship in the next release. We do not maintain backport branches.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/abacusai/simless/security/advisories/new). If that form is unavailable, email [support@abacus.ai](mailto:support@abacus.ai).

Do not open a public issue for an unpatched vulnerability. Do not include signing certificates, provisioning profiles, credentials, or proprietary app code in a report.

Include:

- a concise description of the vulnerability and its impact;
- the affected release or commit, macOS version, and Xcode version;
- exact reproduction steps or a minimal proof of concept;
- the expected security boundary and how it was crossed; and
- any conditions required for exploitation (for example, whether SimlessAgent has Full Disk Access).

We may ask you to validate a fix. Coordinate public disclosure with the maintainers so users have time to update.

## Trust model

simless runs as the signed-in macOS user and trusts that account. It is not a boundary between processes of the same user.

- **Your project:** simless reads your project and writes only `.simless.json`, the two files under `<App>/Simless/`, one line in your App's `init()` (on `simless init`), generated `*.simless.xcodeproj` / `*.simless.xctestplan` next to your project, and an entry in `.git/info/exclude`.
- **Signing:**
  - simless uses your Apple Development identity and an existing team wildcard development profile from your keychain and `~/Library`.
  - It never exports keys, never contacts the Apple Developer portal, and never registers identifiers or devices.
  - Slot apps are re-signed with only `application-identifier`, `team-identifier` and `get-task-allow`.
- **Render hosts:**
  - Hosts are DEBUG builds of your app (bundle ids ending in `.simlessN`). They listen on `127.0.0.1` without authentication.
  - Any local process, including processes of other users on a shared Mac, can connect to a host port and request renders or stop it.
  - A host loads a patch only from its own sandbox temp directory, and only when that patch is not quarantined.
  - Do not run simless on a machine shared with untrusted local users.
- **SimlessAgent:**
  - The agent has Full Disk Access and listens on a Unix socket in `~/Library/Application Support/Simless/`. It has exactly one write operation.
  - It copies a `.dylib` from `~/Library/Caches/simless/` into `~/Library/Containers/<UUID>/Data/tmp/` of a container whose metadata names a `.simlessN` app. Symlinks on either path are rejected, and writes are atomic.
  - It is optional. Without it, simless falls back to reinstalling slots.
- **Patches:**
  - Hot-reload patches are compiled from your own source and signed with your identity.
  - They bypass quarantine by design, because they are placed by the agent rather than downloaded. This is why the agent's destination rules are strict.
- **Private APIs:** the render host uses private, DEBUG-only Apple APIs, for in-process accessibility automation and for hiding the app. They are never part of a release build.

## In scope

Examples of security issues include:

- SimlessAgent writing outside a `.simlessN` container's temp directory, or reading sources outside simless's cache;
- path traversal, symlink, or race conditions that redirect an agent write;
- a render host loading a file other than a patch placed in its own temp directory;
- simless modifying files in a project beyond those listed above;
- simless exposing signing identities, profiles, or keys; and
- a release build of an app containing SimlessKit code.

## Out of scope

The following are not vulnerabilities on their own:

- actions by other processes of the same macOS user, which can already act as that user;
- unauthenticated loopback access to render hosts, as documented above;
- breakage caused by macOS or Xcode changes to private APIs;
- behavior of your own app code inside a render host;
- modified or unofficial builds of simless; and
- issues that affect only an unsupported release and are fixed in the latest release.

If an issue falls outside this policy but causes a reproducible defect, use the [bug report form](https://github.com/abacusai/simless/issues/new?template=bug_report.yml).
