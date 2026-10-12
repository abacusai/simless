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

Xcode hides the Designed-for-iPad destination for targets that also ship native macOS or opt out of it. In that case simless builds from a generated sibling copy of the project (`<Name>.simless.xcodeproj`, next to the original, wherever it is in the repository) with `macosx` removed from `SUPPORTED_PLATFORMS` and Designed for iPad enabled. Shared schemes and test plans are copied and rewritten to point at the copy. The original project is never modified, and the generated files are added to `.git/info/exclude`.

Builds run with `CODE_SIGNING_ALLOWED=NO`. All signing happens when a slot is created (below), so builds never need provisioning and never touch the developer account.

## 2. Slots: one installed copy per worktree

macOS runs one instance per bundle id. Several agents need several hosts, so each worktree gets a **slot**: an APFS clone of the build (near-free), modified as follows:

- `CFBundleIdentifier` becomes `<bundle id>.simless<N>`.
- App extensions (`PlugIns/*.appex`) and the watch app (`Watch/`) stay, with every id in their Info.plists that starts with the app's id moved under the slot's (installd checks that prefix). Each extension gets the profile and its own `application-identifier`. After install, simless sets each extension to "ignore" with `pluginkit`, so a slot's widgets never reach the widget gallery. If an install with them fails, simless installs without them. `"embeddedBundles": false` always removes them.
- `LSUIElement` is set, so the app never shows a Dock icon, not even during launch.
- It's re-signed inside-out with the team's **wildcard development profile** and only `application-identifier`, `team-identifier` and `get-task-allow`. The slot has no capabilities: rendering needs no iCloud, push or app groups. installd rejects any other entitlement the profile doesn't list, sandbox temporary exceptions included.

A slot is installed through a zero-test `xcodebuild test-without-building -only-testing:<UnitTests>/SimlessInstallOnly` run (xcodebuild is the only supported installer for Designed-for-iPad apps), using a copy of the build's `.xctestrun` with the host bundle id swapped. Installs are serialized machine-wide. The host is then launched **by path** (`open -g -j <slot>/.XCInstall/<App>.app --args --simless-port N`), not by bundle id.

## 3. The render host (SimlessKit)

`SimlessKit.swift` is a single `#if DEBUG` file that `simless init` adds to the app. It does nothing unless the app is launched with `--simless-port`. When it is, it:

- **Hides the app** whenever simless launched it, including the install and unit-test runs, which carry `SIMLESS_HEADLESS=1` in their `.xctestrun`:
  - during `App.init`, before any window exists, it makes AppKit's window-ordering calls no-ops;
  - it sets the underlying `NSApplication` activation policy to *prohibited* and calls `hide:`, both through the ObjC runtime.

  Slots are also `LSUIElement` and `LSBackgroundOnly`. Measured result: no window, Dock icon or focus change, sampled every 10 ms.
- **Turns on accessibility automation** in-process (`_AXSSetAutomationEnabled`, the approach KIF uses), so SwiftUI vends its accessibility tree.
- **Calls `simlessFixtures(_:)`**, which the app owns, to register screens.
- **Opens the sandbox a little,** in every run simless starts. It consumes the read-only sandbox extensions simless issued for the repository (`sandbox_extension_issue_file` / `_consume`, the mechanism behind file panels), so tests and fixtures can read repository files. It also points `containerURL(forSecurityApplicationGroupIdentifier:)` at a private folder per group inside the slot's container, because the slot can't hold app-group entitlements.
- **Serves newline-delimited JSON on `127.0.0.1:<port>`**: `stats`, `render`, `load`, `stop`.
- **Exits after 30 idle minutes.**

`render` hosts the fixture in a `UIHostingController`:
- the canvas is sized to the requested device, in light or dark mode;
- phone canvases get compact width and, on the Mac, the device's safe-area insets; iPad canvases get regular width. The traits the view actually saw are returned with every render. The idiom stays `.pad` on the Mac unless the render asks for `.phone` (`--idiom phone`), because SwiftUI's `Stepper` recurses until the stack overflows under it. When the host dies that way, the CLI relaunches it and renders the screen with `.pad`. `UIDevice.current.userInterfaceIdiom` can't be overridden at all;
- `--text-size` sets `preferredContentSizeCategory` and `dynamicTypeSize`. Layout follows them, but text styles keep their default sizes on the Mac;
- `--locale` relaunches the host with `-AppleLanguages` and `-AppleLocale`, since the language is process-wide (string lookup, formatters, layout direction);
- `displayScale` is pinned to 2, because the hidden window lands on an arbitrary display;
- it returns the accessibility elements (role, label, value, identifier, frame), plus a PNG if requested.

Renders take ~20–60 ms. The CLI turns the tree into compact text and runs deterministic checks:
- controls without labels,
- text exposed twice,
- elements cut off at the screen's side edges, or of zero size (content wholly below the fold is scroll content, reported as a count, not an issue),
- tap targets under 44 pt (configurable with `checks.minTapTarget`; UIKit's own bar buttons are skipped),
- overlapping controls.

`checks.ignore` in `.simless.json` drops issues containing a given string. A split view's column resize handle (an unlabeled, full-height adjustable element, partly off screen when the sidebar is hidden) is left out of the tree.

## Unit tests

`simless test` stops the host and runs `xcodebuild test-without-building` with the slot's `.xctestrun`, so tests run inside the slot app like app-hosted tests on a device. Each run gets its own copy of the `.xctestrun` with:
- `SIMLESS_SANDBOX_TOKENS`, the read-only sandbox extensions for the repository;
- XCTest's per-test time allowance (`--timeout`, default 300 s), which Swift Testing also honors;
- an entry per local package test target that was asked for.

Package test targets can't run on the Mac on their own: Xcode drops test bundles without a host app for "Designed for iPad", and `swift test` builds for macOS, where iOS-only frameworks are missing. simless builds them with `xcodebuild build-for-testing -destination generic/platform=iOS` from the package directory, copies the `.xctest` (and the package's resource bundles) into the slot app's `PlugIns`, re-signs, and adds an app-hosted entry for it. The bundle carries its own static copy of the package, so the app's copy and the tests' copy don't share state.

The CLI reads the output as it's written: failures print right away and progress every 10 s. A watchdog stops the run if one test is still running a minute or so past its allowance, which the allowance alone doesn't always manage, and names the test.

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
- **Scope:** a patch's copy of a type only takes effect where the patch itself constructs it, so an unedited parent would still embed the old subview. Before compiling, simless builds a type-reference graph of the app's sources and every local package module, and also patches every file on a path from the fixtures file to an edited file. The graph uses top-level type declarations and identifiers in code (not comments or strings). Across modules it only follows `public`/`open` types along declared package dependencies. Edits that other code can observe without naming an edited type can't be traced this way: extensions of other types, and non-private top-level functions or variables. They, and patches reaching more than 40 files, fall back to a full build. The analysis over-approximates on purpose: an extra file costs compile time, a missing one costs a wrong render.
- **Package modules:** `simless init` records the local Swift packages the project references. Each source file is mapped to its module, and each module's language mode, default isolation and upcoming features are read from `swift package dump-package`. The patch `@testable import`s every module involved and compiles with their settings. A patch mixing modules with different settings can't be one module, so it falls back to a full build.
- **Fallback:** if a patch can't compile (stored properties, signatures, or a real error) or can't be scoped, reload falls back to a full build. Errors are mapped back to the user's `file:line`.
- **Which files count as edited:** content hashes against a snapshot taken when the build started. Git checkouts that only touch mtimes don't count.
- **Relaunches:** the newest patch is re-applied whenever the host relaunches.

## Calibration

`simless calibrate` builds the app for the iOS Simulator, boots one dedicated simulator and launches the app there with the same `--simless-port` argument. The same SimlessKit then serves renders from real iOS, with the device's own safe areas and traits. For every fixture it renders on both, aligns the two accessibility trees by role, label and identifier (longest common subsequence), and reports elements present on only one side, and frames that differ by more than 2 pt. It's the only command that boots a simulator, and it deletes the device afterwards.

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

See [How far to trust results](../README.md#how-far-to-trust-results) for what a pass and a failure mean, the known ways a pass can be wrong (hot reload with nested views, device traits, safe areas, Dynamic Type), and how unit tests can differ. In brief:

- **Hot reload replaces only the edited types.** Unedited views that embed an edited type still run the previously built code until the next full build.
- **Traits aren't an iPhone's.** It's an iOS app on a Mac: text doesn't scale with Dynamic Type, and the idiom is `.pad` unless `--idiom phone` is passed. simless sets phone size classes and safe areas itself.
- **No capabilities.** Slots run without app capabilities. App-group containers are private folders.
- **Not covered:** gestures, the software keyboard, system UI and navigation flows.
- **Project shape:** needs an `.xcodeproj` (at the root or in a subfolder) with an app-hosted unit-test target.
- **Side effects:** the host runs the app's real startup; guard side effects with `SimlessHost.isActive`.
- **Private APIs:** the host uses private, DEBUG-only Apple APIs (`_AXSSetAutomationEnabled`, NSApplication activation policy via the ObjC runtime, `sandbox_extension_consume`) that an OS update could change.
