# Changelog

<!-- One section per version: `## 0.1.0 (2026-10-09)`. Notes for the next
     release go under `## Unreleased`. -->

## Unreleased

## 0.2.1 (2026-10-13)

Fixes from running 0.2.0's test runner on a larger app. Run `simless init` once to update SimlessKit (needed for the faster `test all`).

- **No more false hangs.** Interleaved test output can put invisible U+200B characters into lines, and parameterized tests finish as "with N test cases passed". simless didn't recognize those "passed" lines, so finished tests looked hung and `--timeout` stopped the run. Lines are now matched after removing invisible characters, anywhere in the line. The watchdog also only fires when the run has gone silent, not just because a test looks unfinished.
- **Crashes are reported.** A crashing test used to show up as "1 passed, 0 failed" and then FAILED. Now each crash prints as it happens with the trap's message and file (for example `T.swift:10: Fatal error: boom`) and the tests that were running, once even though xcodebuild retries it twice, and the summary counts crashes.
- **`test all` is much faster for many package targets.** Package targets that run whole now share one launch of the app instead of one each, so the app's startup runs once. On the demo app, 7 targets went from 16.4 s to 9.8 s. A crash in the shared launch makes simless run those targets again, one launch each, to say which crashed.
- **Render crashes.** A screen that crashes the render host is reported with the crash's first frames in your code or SwiftUI, read from the macOS crash report (or the trap message from the host's output when macOS skips the report), and `render all` carries on with the other screens. The phone idiom's iPad-idiom retry uses the same path, and `Stepper` is now documented as able to crash under the iPad idiom too.
- **`--skip` check.** When a skipped test still ran, simless says the id didn't match and shows the id formats.

## 0.2.0 (2026-10-12)

Fixes and features from running simless on a larger app with most of its tests in a local Swift package. Run `simless init` once to update SimlessKit; it keeps `.simless.json` and your fixtures now.

- **Local package tests.** `simless test MyKitTests` runs a local Swift package's test target. Xcode won't run a hostless test bundle on "My Mac (Designed for iPad)" and `swift test` fails on iOS-only imports, so simless builds the package's tests for iOS and hosts them in the slot app. `simless test all` runs every app and package test target.
- **Tests can read the repository.** Reading files next to `#filePath` (project files, xcconfigs, fixtures, copy) failed with "Code=257". simless now grants the app read-only access to the repository through a sandbox extension. An entitlement can't do it: installd rejects any the profile doesn't allow.
- **App groups and embedded bundles.** Group containers resolve to a private folder per group, so writes work instead of failing with "Code=513". App extensions and the watch app stay in the slot under the slot's id, so tests can find them. Their extensions are set to "ignore" so they never show up in the widget gallery.
- **Unattended test runs.** `simless test` prints failures as they happen and progress every 10 s. Each test has a time limit (`--timeout`, default 300 s), and a test that hangs stops the run and is named. `--skip` (repeatable) and `tests.skip` in `.simless.json` skip tests.
- **Device-only tests.** `targetEnvironment(simulator)` is false on the Mac. The docs now say to gate such tests on `isiOSAppOnMac` or `SIMLESS_HEADLESS`.
- **`--locale` and `--text-size`.** `simless render Home --locale hr --text-size ax5` renders in another language without a fixture per locale, at a given Dynamic Type size. Text itself doesn't scale on the Mac (every text style resolves to its default size there), so renders say that layout follows the size but text doesn't.
- **`--idiom phone`.** Phone canvases can use the phone idiom. Only `Stepper` crashes under it (not `Form`, `Toggle` or `Picker`, as 0.1.2 said). When it does, simless restarts the host and renders that screen with the iPad idiom. It's opt-in, because on the demo app it didn't close the other differences.
- **Configurable checks.** `checks.minTapTarget` sets the tap-target threshold and `checks.ignore` drops matching issues. Renders say how many were ignored. UIKit's own bar buttons are no longer reported for their size.
- **Split views on iPad.** A split view's column resize handle is no longer in the tree. It caused false "cut off at the left edge" and overlap issues with the sidebar button. Long role names (`adjustable`) are no longer cut off in the tree.
- **Calibration simulator.** `simless calibrate --runtime 26.5 --sim-device "iPhone 16e"` (or `calibrate` in `.simless.json`) picks the simulator. Both sides render at that simulator's screen size and safe areas.
- **Hot reload without remote packages.** In projects with no remote Swift package dependencies, every patch got a bogus module map path (an error message from `find`) and fell back to a full build. Those projects now hot-reload, the demo app in about 1.2 s.
- **Fixture edits hot-reload.** Adding or changing a fixture in `SimlessFixtures.swift` used to force a full build.
- **Smaller fixes.** Local packages added after `simless init` are picked up. With several development teams, simless picks the only one with a usable wildcard profile. `simless test` before a successful `simless up` says so instead of failing on a missing log.

## 0.1.2 (2026-10-10)

- **Demo app and fidelity page.** [Examples/SimlessDemo](Examples/SimlessDemo) has seven common screens, and [docs/fidelity.md](docs/fidelity.md) shows each one rendered by the iOS Simulator and by simless, side by side, with what differs.
- **Crash fix: screens with `Form`, `Toggle` or `Picker` no longer crash the host.** 0.1.1 overrode the idiom to `.phone`, which makes SwiftUI's control styles recurse until the stack overflows on the Mac. Phone canvases keep phone size classes and safe areas; the idiom stays iPad, and renders say so.
- **Accessibility trees match what VoiceOver sees.** Elements are no longer descended into, and containers that list their elements no longer also contribute their subviews. That removes duplicates such as a `Toggle` row's switch, a `Picker`'s value text and navigation titles, which accounted for over half the issues reported on the demo app.
- **Simulator render window.** In `simless calibrate`, the render window is created on first use, so a scene that connects late no longer fails every render with a misleading "unknown fixture".
- **Calibration report.** `simless calibrate --png <dir>` saves both renders of every screen and writes a side-by-side `report.md`; `--dark` adds dark mode. Text that only renders slightly wider, and elements exposed with a different role, are reported as minor instead of failing the screen.
- **Projects without a test plan.** Their test runs use the older `.xctestrun` format, which simless now also handles.
- **Signing team.** When a project sets no `DEVELOPMENT_TEAM`, simless uses `team` from `.simless.json`, `SIMLESS_TEAM`, or the only Apple Development identity in the keychain.

## 0.1.1 (2026-10-10)

Fixes found by using simless on a project laid out differently from the one it was built on.

- **Projects in a subfolder.** `simless init` finds an `.xcodeproj` in a subfolder (e.g. `ios/App.xcodeproj`). The generated build variant now retargets the project's schemes and test plans correctly; before, the copied scheme silently dropped the app target.
- **Reading build settings.** Build settings are read with the build's own destination, falling back to `-target` for schemes that report "Found no destinations". Nothing is left in the default DerivedData.
- **Swift 6.** The render host kit and the hot-reload entry point compile under Swift 6, with or without MainActor default isolation; they had data races in the socket loop and the patch entry. CI now compiles the kit in every language configuration.
- **Views in local Swift packages.** These now hot-reload instead of forcing a full build each time. Patches import every involved module with the right compiler settings. Patch scope is module-aware and ignores comments and strings, so it stays small in large codebases.
- **Scroll views.** Only elements cut off at the screen's side edges are flagged. Content below the fold is reported as a count rather than as issues.
- **Swift Testing.** `simless test` reports Swift Testing results and failures alongside XCTest's.
- **Upgrades.** The generated build variant is regenerated after a simless upgrade, so a variant made by an older version isn't reused.

## 0.1.0 (2026-10-09)

First public release.

- **Running your app:** your real SwiftUI app runs natively on the Mac as a hidden render host. It needs no iOS Simulator, and no window, Dock icon or focus change appears at any point, including during install and test runs.
- **Rendering:** `simless render` returns a screen's accessibility tree with frames, plus deterministic checks for unlabeled controls, text read twice by VoiceOver, off-screen elements, tap targets under 44 pt and overlapping controls. Phone canvases get phone traits and the device's safe areas, and every render prints the traits the view saw.
- **Hot reload:** `simless reload` hot-reloads edited views in about 2 seconds. Views that embed an edited view are patched too. Edits a patch can't trace fall back to a full build.
- **Unit tests:** `simless test` runs your unit tests on the Mac.
- **Calibration:** `simless calibrate` compares simless renders with an iOS Simulator for every fixture, so you know how far to trust them for your app.
- **Parallel agents:** many agents and projects run in parallel, one host per git worktree, using about 30 MB per host. Cleanup is automatic.
- **Live reload:** SimlessAgent, which is optional, enables live reload. It has a single, narrowly scoped write operation.
- **Agent skill:** a Claude Code skill and an `AGENTS.md` snippet teach coding agents the workflow and how far to trust its results.
