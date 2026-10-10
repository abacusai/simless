# Changelog

<!-- One section per version: `## 0.1.0 (2026-10-09)`. Notes for the next
     release go under `## Unreleased`. -->

## Unreleased

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
