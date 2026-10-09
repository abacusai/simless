# Changelog

<!-- One section per version: `## 0.1.0 (2026-10-09)`. Notes for the next
     release go under `## Unreleased`. -->

## Unreleased

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
