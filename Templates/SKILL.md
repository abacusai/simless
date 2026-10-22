---
name: simless
description: Fast, headless, simulator-free verification of SwiftUI iOS apps with the `simless` CLI. Use it whenever you build or change SwiftUI views and need to check that screens render correctly (layout, text, accessibility labels, dark mode, iPad/small iPhone), when the user says to test or verify UI with simless, or instead of booting the iOS Simulator for screen checks, unit tests or XCUITest UI tests.
---

# SwiftUI verification with `simless`

`simless` runs the app natively on the Mac as an invisible render host: no simulator, no windows. A screen render returns its accessibility tree in milliseconds. An edited view hot-reloads in about 2 s. Many agents can work in parallel, one host per git worktree.

**Do not boot the iOS Simulator for screen checks, unit tests or UI tests.** Use `simless`. Use the simulator only for what `simless` can't do (see Limits).

## 1. Is the repo set up?

```sh
simless status        # fails with "no .simless.json" if the repo isn't set up
```

If it isn't set up, do it yourself:

1. Run `simless init` at the repo root. It writes `.simless.json` and `<App>/Simless/SimlessKit.swift` (generated, never edit), creates `SimlessFixtures.swift`, and adds the hook to the `@main` App's `init()`. Check the hook compiles. If the project doesn't use synchronized folders, add both Simless files to the app target.
2. If app startup has side effects that a background render host shouldn't trigger (analytics, sync, network), guard them: `if !SimlessHost.isActive { ... }` (DEBUG only).
3. Register fixtures (below), then run `simless up`. The first build takes a few minutes; later ones are incremental.

`simless init` needs an Xcode project (not a workspace). A unit-test target is optional. simless needs no certificate, profile or other setup: if `simless up` asks for one, the project is in the `dfi` mode (`"mode": "dfi"` in `.simless.json`), so tell the user instead of improvising.

## 2. Fixtures: the screens simless can render

Some exist without any code: `root` (the app's first window, as the `@main` App builds it) and one per `#Preview` block, named `<File>.<preview name or number>`. `simless up` lists them. Render those first. Add fixtures for states the previews don't show.

`SimlessFixtures.swift` is normal app code:

```swift
#if DEBUG && os(iOS)
import SwiftUI

@MainActor
func simlessFixtures(_ r: SimlessRegistry) {
    r.add("Settings") { SettingsView().environmentObject(SettingsStore.preview) }
    r.add("Paywall.trialEnded") { PaywallView(state: .trialEnded, products: .fixture) }
    r.add("NoteList.empty") { NoteListView(notes: []) }
    r.add("NoteList.long") { NoteListView(notes: .fixture(count: 50, longTitles: true)) }
}
#endif
```

- **One fixture per meaningful state:** normal, empty, loading, error, long content.
- **Deterministic data only.** Use fixed dates, in-memory stores, preview/fixture objects. No network, no real user data. Reuse existing preview data or test seeds when the project has them.
- **Inject whatever the view expects** (`.environmentObject`, `.environment`, model containers).
- **Name them `Screen.state`.** When you add or change a screen, add or update its fixtures in the same change.

## 3. The loop

```sh
simless up                                   # once per worktree, and after big changes
simless reload --render <Fixture>            # after editing views: hot reload (~2 s) + render
simless render all                           # every fixture
simless act Login type "#login.email" "a@b.com" tap "Sign in"   # interact, then read the screen
simless render <Fixture> --dark --device ipad          # devices: iphone, iphone-small, iphone-max, ipad
simless render all --matrix                  # every fixture × light/dark × iphone, iphone-small, ipad
simless calibrate                            # once per app: compare every fixture with an iOS Simulator
simless render <Fixture> --png /tmp/shots/   # only when you need to see pixels
simless render <Fixture> --locale hr         # another language, without a fixture per locale
simless render <Fixture> --text-size ax5     # at a Dynamic Type size (text scales like on an iPhone)
simless test MyAppTests/SomeTests --agent    # unit tests on the Mac, no simulator; --agent: 120 s per test, not 600
simless test MyKitTests                      # a local package's test target works the same way
simless test all --skip MyAppTests/DeviceOnlyTests   # every test target, minus what needs a device
simless test ui                              # the XCUITest UI tests, no simulator
simless test MyAppUITests/LoginUITests       # one UI test class (or Target/Class/testMethod)
simless test --simulator-only                # what's marked as needing a simulator, and how to run it
simless test --from changed-tests.txt        # test ids from a file (or - for stdin), unit and UI mixed
```

`simless test` prints failures and crashes (with the trap's file and message) as they happen, and a progress line every 10 s. A test that runs past `--timeout` (default 600 s per test, like Xcode) fails, and one that hangs stops the run with its name. Skip it with `--skip`, and tell the user it needs a device. If simless says a `--skip` didn't match, fix the id (Swift Testing: `Target/Suite/test()`, XCTest: `Target/Class/testMethod`).

The exit code is 0 only when every selected test ran and passed. The results files (`test-results.json`, `ui-test-results.json`, in the work folder `simless status` shows) give every test one status. `flaky` means it failed in the full run and passed alone: say so to the user rather than calling it green. `not-run` means it was selected but never ran (or an id matched no test), and fails the run. Tests run against the files on disk: when the app's build is older than an edit, `simless test` builds again first.

`simless test ui` runs the UI tests' XCUITest code unchanged in hidden hosts. A failure prints the test's message and saves a screenshot and the element tree (the run's last line says where); read them before changing anything. A test that needs a real simulator (HealthKit sheets, StoreKit, the photo or file picker, the watch app) goes in `tests.simulatorOnly` in `.simless.json` with the reason, after you've confirmed with the user. Then tell the user to run what `simless test --simulator-only` lists in a simulator. If it says a simulator or runtime is missing, pass on its create or install command, don't pick another simulator. `--device iphone,ipad` runs UI tests on both, and `tests.uiDevices` lists the tests that only run on another device (an iPad-only class, say).

Reading a render:

```
NoteList.empty · light · iphone 402×874 · 31 ms · patch 2
  header  "No Notes"  @140,300 122×26
  button  "New Note" #notes.new  @48,360 306×50
  issues (1):
    ⚠ button without accessibility label @48,420 306×50
```

- **Lines:** each is role, label, `#identifier`, and frame in points (`@x,y w×h`) on the device canvas.
- **Check the tree first.** Is the expected text there? Are elements where they should be, not overlapping and not off-screen? Fix every listed issue: unlabeled controls, text VoiceOver reads twice, off-screen elements, tap targets under 44 pt, overlapping controls. The checks don't cover everything, so also read the frames yourself.
- **Check variants:** `--matrix` for layout changes.
- **Look at a `--png`** when the change is visual: colors, images, clipping. Read the image file.
- **Too much noise from a check?** If the user agrees the design is intended (for example small chips that Apple's accessibility audit accepts), set `checks.minTapTarget` or add the issue text to `checks.ignore` in `.simless.json`. Don't do that just to get a clean result.

**Interacting:** `simless act <Fixture> <steps>` renders the fixture, runs the steps in order and prints the tree afterwards. Steps: `tap "<label or #id>"`, `type "<#id or label>" "<text>"` (focuses the field first), `swipe up|down|left|right [on "<label>"]`, `longpress "<label>"`, `wait <ms>`. Prefer `#id`s, they don't change with copy. Each step is checked (`✓`/`✗`), and a step that finds nothing lists what's on screen. Use it to check what a tap or typing does (a toggle's value, a validation message, a button enabling) instead of adding a fixture per state. Needs the kit from `simless init` (kit 5).

`simless reload` hot-patches only the edited files plus the fixtures file. If a patch can't express a change (stored properties, function signatures, new types used elsewhere), it falls back to a full build automatically. Compiler errors point at your real `file:line`: fix them and re-run. `simless reload` with no arguments picks up every file edited since the last `simless up`.

## 4. How far to trust a result

A **failure** from simless (a test failure, an issue, a wrong label or frame) is almost always real; fix it. A **pass** is a strong signal, not proof:

- **Calibrate once per app.** Run `simless calibrate` once per app, and again after large UI changes. It renders every fixture in one iOS Simulator too and lists what differs. Trust renders of the matching fixtures; check the others in a simulator.
- **Hot reload.** Hot reload works for views in the app target and in local Swift packages, and also patches the views that embed what you edited. When it says "patch can't cover this edit", it does a full build; that's expected.
- **Scroll content.** "below the fold: N element(s)" is information, not an issue: it counts scroll content listed in the tree.
- **Device traits.** Phone canvases get phone size classes and safe areas, and every render prints its traits. The idiom stays iPad on the Mac, so code that checks `userInterfaceIdiom` takes its iPad branch in simless. `--idiom phone` switches the trait collection's idiom. A screen with a `Stepper` can crash under it, and simless then renders that screen with the iPad idiom and says so.
- **"crashed the render host".** The crash's first frames tell you where. If they're in your view, fix it. If they're only in SwiftUI (a `Stepper` can crash SwiftUI on the Mac), check that screen in a simulator instead and say so.
- **Mac differences.** Text renders 2–4% wider than on iOS (long or centered text can wrap differently), `List`/`Form` rows are a few points taller, system accent colors follow the Mac, and some controls (for example a `Menu` with a custom label) are exposed differently to accessibility. Confirm line breaks, truncation and accessibility flags on such controls with `simless calibrate`.
- **"issues: none"** only means the five automatic checks passed. Read the tree yourself.
- **`simless test`** runs app tests from the last full build (not patches), and package tests from current sources. Tests can read repository files but not write them. App-group containers are private folders. iCloud, keychain sharing and push are missing, so tests that depend on them can differ from the simulator.
- **Device-only tests.** `targetEnvironment(simulator)` is false on the Mac, so tests gated on it run here. Gate them on `ProcessInfo.processInfo.isiOSAppOnMac` (or the `SIMLESS_HEADLESS` environment variable) instead, or skip them with `--skip`.

- **UI tests.** Alerts, menus, the share sheet, compact date pickers and the keyboard are shown the iPhone way in UI tests, since the Mac shows them differently. Sharing to a target isn't emulated, and the audit is simless's own (no elementDetection or trait checks). Permission requests are denied without a dialog, so a test that needs the access (recording from the microphone, say) needs a simulator. App code behind `#if targetEnvironment(simulator)` runs its device branch, and a failing run says where such checks are.

simless can't verify:
- system UI it doesn't emulate: permission prompts, HealthKit and StoreKit sheets, photo and file pickers, the Home Screen,
- the watch app, widgets and Siri themselves (deep links into the app work),
- pixel-exact iPhone rendering.

Before you call a UI change done, say what you verified with simless and what still needs a simulator. Never claim simless verified any of the above.

## 5. Housekeeping

- **Don't clean up manually.** Hosts exit after 30 idle minutes (`simless down` stops one now; it relaunches on next use). When a worktree is deleted, `simless` removes its host, slot and caches automatically.
- `simless clean` removes this worktree's build cache. `simless status` lists hosts and whether live reload is on.
- Live reload needs nothing extra. Only in the `dfi` mode does it use SimlessAgent, which needs Full Disk Access granted once by the user (without it reloads take about 10 s). Mention it if `simless status` shows live reload off, and don't try to grant it yourself.

In your summary, report what you verified with `simless` (which fixtures, devices and modes) and what still needs a simulator.

<!-- SPDX-License-Identifier: MIT-0 · Copyright 2026 Abacus.AI, Inc. -->
