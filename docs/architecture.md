# Architecture

simless gives coding agents a fast, headless way to check SwiftUI screens and run unit tests without the iOS Simulator. This document explains how it works. [findings.md](findings.md) explains why it works this way.

```
 agent ──► simless CLI ──► xcodebuild (Designed-for-iPad build, unsigned)
              │                 │
              │                 ▼
              │          slot: <bundle id>.simlessN   (clone, re-signed, LSUIElement)
              │                 │  installed via a zero-test xcodebuild run
              │                 ▼
              ├──── TCP ───► render host = your app, hidden, running SimlessKit
              │                 ▲
              │   patch dylib   │ dlopen
              └──► SimlessAgent ┘ (places patches into the host's sandbox tmp)
```

## 1. Your app runs natively on the Mac ("Designed for iPad")

Apple Silicon Macs run iOS arm64 apps natively. simless builds the app's normal iOS device slice for the `platform=macOS,arch=arm64,variant=Designed for iPad` destination:
- **No simulator runtime**, so no SpringBoard or simulator daemons.
- **Third-party SDKs keep working**, because they use the iOS slice they already ship.
- **Your real views, real dependencies, and the real app target.** No porting and no separately written copies of your screens.

Xcode hides the Designed-for-iPad destination for targets that also ship native macOS. In that case simless builds from a generated sibling copy of the project (`<Name>.simless.xcodeproj`) with `macosx` removed from `SUPPORTED_PLATFORMS`. Shared schemes and test plans are copied and rewritten to point at the copy. The original project is never modified, and the generated files are added to `.git/info/exclude`.

Builds run with `CODE_SIGNING_ALLOWED=NO`. All signing happens when a slot is created (below), so builds never need provisioning and never touch the developer account.

## 2. Slots: one installed copy per worktree

macOS runs one instance per bundle id. Several agents need several hosts, so each worktree gets a **slot**: an APFS clone of the build (near-free), modified as follows:

- `CFBundleIdentifier` becomes `<bundle id>.simless<N>`.
- `PlugIns/*.appex` (and `Watch/`) are removed, because extension ids would fail the prefix check.
- `LSUIElement` is set, so the app never shows a Dock icon, not even during launch.
- It's re-signed inside-out with the team's **wildcard development profile** and only `application-identifier`, `team-identifier` and `get-task-allow`. The slot has no capabilities: rendering needs no iCloud, push or app groups.

A slot is installed through a zero-test `xcodebuild test-without-building -only-testing:<UnitTests>/SimlessInstallOnly` run (xcodebuild is the only supported installer for Designed-for-iPad apps), using a copy of the build's `.xctestrun` with the host bundle id swapped. Installs are serialized machine-wide. The host is then launched **by path** (`open -g -j <slot>/.XCInstall/<App>.app --args --simless-port N`), not by bundle id.

## 3. The render host (SimlessKit)

`SimlessKit.swift` is a single `#if DEBUG` file that `simless init` adds to the app. It does nothing unless the app is launched with `--simless-port`. When it is, it:

- **Hides the app:** sets the underlying `NSApplication` activation policy to *prohibited*, plus `hide:`, reached through the ObjC runtime. No window, no Dock icon, no focus change.
- **Turns on accessibility automation** in-process (`_AXSSetAutomationEnabled`, the approach KIF uses), so SwiftUI vends its accessibility tree.
- **Calls `simlessFixtures(_:)`**, which the app owns, to register screens.
- **Serves newline-delimited JSON on `127.0.0.1:<port>`**: `stats`, `render`, `load`, `stop`.
- **Exits after 30 idle minutes.**

`render` hosts the fixture in a `UIHostingController`:
- the canvas is sized to the requested device, in light or dark mode;
- `displayScale` is pinned to 2, because the hidden window lands on an arbitrary display;
- it returns the accessibility elements (role, label, value, identifier, frame), plus a PNG if requested.

Renders take ~20–60 ms. The CLI turns the tree into compact text and runs deterministic checks:
- controls without labels,
- text exposed twice,
- off-screen or zero-size elements,
- tap targets under 44 pt,
- overlapping controls.

## 4. Hot reload

`simless reload` compiles **only the edited files plus the fixtures file** into a patch dylib with its own module name:

```
@testable import App          // prepended to each edited file
...                           // the patch's copies of edited types shadow the app's
@_cdecl("simless_patch_entry") func entry(registry) { simlessFixtures(registry) }
```

- **Flags:** compiler flags are reconstructed from the target's build settings (Swift version, default isolation, upcoming features, conditions, deployment target), plus `-I/-F` to the build products and every Clang module map the app imports transitively. Undefined symbols resolve at load time against the app's debug dylib (`-undefined dynamic_lookup`).
- **Applying it:** the host `dlopen`s the patch and calls the entry point. That runs the patch's copy of the fixtures, so every fixture is rebuilt from the new view code. Typical cost is ~1.7 s compile + ~0.2 s apply.
- **Getting the patch into the host:**
  - **Live (default when available):** SimlessAgent copies the patch into the host's sandbox `tmp` directory, and the host loads it from there.
  - **Warm (no permissions):** the patch is bundled into the slot app, which is re-signed, reinstalled and relaunched; the host loads it at startup. Takes ~10 s.
- **Fallback:** if a patch can't compile (stored properties, signatures, a type used elsewhere, or a real error), reload falls back to a full build. Errors are mapped back to the user's `file:line`.
- **Which files count as edited:** content hashes against a snapshot taken when the build started. Git checkouts that only touch mtimes don't count.
- **Relaunches:** the newest patch is re-applied whenever the host relaunches.

## 5. SimlessAgent and its security model

A file written by the sandboxed host is quarantined, and `dlopen` of quarantined code blocks on a Gatekeeper prompt, which would hang a headless host. Something outside the sandbox therefore has to place the patch in the host's container. Containers are protected ("App Data"), so that process needs **Full Disk Access**. SimlessAgent is that process: a tiny unsandboxed app (`ai.abacus.simless.agent`) listening on a Unix socket. It has exactly one write operation, `place`, and accepts it only when all of these hold:

- the source is a `.dylib` under `~/Library/Caches/simless/`, with no symlinks;
- the destination is `~/Library/Containers/<UUID>/Data/tmp/<file>.dylib`, with no symlinks on the path, and the write is atomic, so a planted symlink is replaced rather than followed;
- the container's `.com.apple.containermanagerd.metadata.plist` names a bundle id ending in `.simless<N>`.

Two further safeguards:
- **The host refuses to load anything quarantined.** It deletes each patch file after loading it.
- **The agent is optional.** Without it, or without Full Disk Access, reloads use warm mode.

## 6. Coordination and cleanup, without a daemon

Hosts and the agent are already long-lived processes, so the CLI coordinates with `flock`:

- **Locks:**
  - `state`: slot and port assignments in `~/Library/Caches/simless/state.json`;
  - `install`: one install machine-wide;
  - `build-<k>`: a few concurrent full builds.
- **Garbage collection** runs on every command and removes hosts, slots, LaunchServices registrations and build caches of worktrees that no longer exist.
- **Size limits:** only the newest 3 patches are kept per worktree, and the shared Xcode compilation cache is cleared above 12 GB.
- **`simless clean [--all]`** removes everything simless created.

## Limits

- **Dynamic Type:** iOS apps on the Mac ignore content-size categories.
- **Not covered:** gestures, the software keyboard, system UI (permissions, share sheets, StoreKit), and navigation flows across screens.
- **Fidelity:** not pixel-identical to an iPhone (no notch, no home indicator). Use simless for structure and layout, and the simulator for final pixels.
- **Project shape:** needs an `.xcodeproj` with an app-hosted unit-test target. Workspaces, Tuist and pure-SwiftPM apps aren't supported yet.
- **Side effects:** the host runs the app's real startup in the background. Guard analytics and network with `SimlessHost.isActive`.
