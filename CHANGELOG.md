# Changelog

<!-- One section per version: `## 0.1.0 (2026-10-09)`. Notes for the next
     release go under `## Unreleased`. -->

## 0.5.0 (2026-10-14)

The goal for this one was making simless trustworthy enough to decide whether code can merge, on the same production app as 0.4.0 plus the demo app and a second app.

On the first app, the full unit suite (2,210 tests) gives the same results as the simulator in 5.2 to 5.5 min once built, against 6.3 min of simulator test time. From nothing (no build, empty caches) it takes 8.5 min against 8.2 min for the simulator's build and tests. That last number is set by one CPU-heavy test target that the Mac's Swift runtime runs about twice as slow as the simulator's. Plain CPU work runs at the simulator's speed: the demo app now has a benchmark for it. All 108 UI tests that don't need a simulator pass, on iPhone and iPad, in 7.6 min against 19.2 min on 5 simulator clones. 5 back-to-back runs of both suites on one commit passed with the same tests every time, and two worktrees ran the unit and UI suites at once without timeouts.

- **The exit code is the truth.** `simless test` exits non-zero when a selected test failed, crashed, ran out of time or never ran, and when a selection matches no test at all. Tests that are marked simulator-only, `--skip`ped or in a UI test target the scheme doesn't build are listed, but don't count against the run.
- **Results a merge script can gate on.** Both results files start with `ok`, `selected`, `notRun` and `flaky`, and every test has one status: passed, failed, crashed, skipped, flaky, not-run, simulator-only, excluded or not-built. A test that only passed when it ran again alone is `flaky` now, not plain passed.
- **Every UI test target is listed.** A UI test target the scheme doesn't build (a watch app's, say) shows up with its tests, simulator-only when marked, so nothing a merge has to run elsewhere goes missing.
- **Selection from a file.** `simless test --from <file>` (or `-` for stdin) takes test ids one per line, in the format the results use. Unit and UI ids can be mixed: both run, with one exit code.
- **Every run starts from a fresh install's data**, like a simulator's clones. Before a UI run and before each unit test host starts, the app's data container is emptied and its saved preferences are cleared (macOS keeps those in memory, so deleting the files alone gave the next launch its old values). Before this, a counter the app kept in `UserDefaults` grew run after run until UI tests hit a weekly limit on the 4th run of the same commit. And before a UI test quits the app, the app now syncs its settings, so what it saved is there when the test launches it again.
- **A broken install is installed again.** An install macOS had stopped opening failed every test on its host with "No such file or directory". The launch that empties the data now checks each slot too, a slot that won't open gets installed again, and tests whose app never launched always run again.
- **iPhone and iPad in one run.** `tests.uiDevices` adds devices and the tests that run on each (`{"ipad": ["AppUITests/IPadUITests"]}`), and `simless test ui --device iphone,ipad` runs everything on both. The results are merged: a test passes when it passed on one device and failed on none, so iPad-only tests stop getting skipped by accident. Each device keeps its own screenshots and logs.
- **The simulator-only lane runs on exactly what's configured.** The command uses a simulator named like `calibrate.device` on `calibrate.runtime` (for watchOS too). When that runtime or device isn't there, it says which, prints the command that installs or creates it, and exits 1, instead of falling back to another session's simulator.
- **Faster cold start.** Package tests build in the app's build folder with the app build's settings, so a cold `simless up` no longer compiles a big local package twice. The runtime compiles during the app build, and the test hosts get ready while the render host starts. App builds skip debug info, which nothing reads.
- **Hosts are spread by how long each target really takes.** The time from a target's first test to its last one decides where it runs, and a target that takes half again as long as any other gets a host to itself. These times are kept per repository, so a new worktree or a run after `simless clean` spreads well from the start.
- **Several sessions at once.** Test runs in different worktrees share the Mac's cores instead of each sizing itself for the whole Mac, and `simless status` shows the runs going on and the share each gets.
- **Disk stays bounded across worktrees.** Everything simless keeps is capped at 25 GB (`SIMLESS_DISK_LIMIT_GB`). Over that, `simless up` removes the builds and slots of the worktrees that used simless least recently, never one in use in the last hour, and then the shared compilation cache.
- **Small fixes.** `simless test ui <selection>` works, skipped UI tests keep their reason and time, the help says 600 s for UI tests, and `simless up` no longer leaves a `.build` folder in your local packages.

## 0.4.0 (2026-10-13)

Fixes from running 0.3.0 on the same production app, plus a second app to keep it generic. Every fix has a small SwiftUI repro in the demo app's UI tests and was checked on both apps.

On the first app (iPhone 17 simulator as the baseline): all 104 UI tests that don't need a simulator pass, in 7.0 min against 19.2 min in the simulator, with no clones. A fresh worktree (with the shared compilation cache from earlier builds) goes from `simless up` to a finished `test all` in 7.6 min against 8.2 min for the simulator's build and test run, with the same results (2,189 passed, 17 skipped, 4 simulator-only). On the second app, 79 of 104 UI tests pass. Most of the rest need a simulator (recording, StoreKit products, the save panel, the Home Screen) or count on app code behind `#if targetEnvironment(simulator)`, and simless now says so.

- **Three SwiftUI patterns now behave in UI tests the way they do on an iPhone.** The demo app has a small lab screen for each and UI tests that check them (`Examples/SimlessDemo/SimlessDemoUITests`).
  - Combined elements (`.accessibilityElement(children: .combine)` or `.ignore`) keep their children's identifiers findable. simless reads `automationElements`, which is what XCUITest sees, and the audit still only looks at what VoiceOver reads.
  - A Button inside a view with its own `onTapGesture` gets the tap, also when the Button is merged into one element and inside a ScrollView.
  - Swipes run at a finger's pace and ease off before the finger lifts, and waiting for the app to settle includes a scroll view that's still gliding. Two slow swipes on a scrolling chart now move it about a month, a scrub after them selects a day instead of just stopping the glide, and swiping up until a row is hittable reaches every row of a long list. Before, one swipe could carry a list about 1,000 pt and jump right past the row.
- **Steppers.** Increment and Decrement are found by those names and tapping them changes the value.
- **More of SwiftUI behaves like on an iPhone in UI tests**, each with a lab screen and a test in the demo app:
  - A submenu in a context menu or a `Menu` is a row that opens its own items, instead of all items showing at once.
  - Choosing an option of a menu-style `Picker` works. The tap used to land on the Picker's hidden copy of the option, so the menu closed and nothing changed.
  - A long press in a text field shows the edit menu (Select, Select All, Paste) as `menuItems`.
  - A Button whose label holds a container (`.accessibilityElement(children: .contain)`) shows that container's elements inside it, so `buttons.containing(...)` finds the row by its text.
  - A confirmation dialog is an action sheet, and its buttons keep the identifiers the app gave them.
  - `XCTNSPredicateExpectation` on a query's `count` works (it never completed before).
- **No more permission popups.** A test host is a real Mac app, so asking for calendar, notifications, microphone, camera, speech, photos, contacts, location or tracking access put macOS's own dialog on your screen, and so did review requests. The runtime now answers those requests itself: access is denied, and review requests do nothing. A feature that needs the access (recording, say) needs a simulator.
- **UI test sources are compiled as iOS code.** `#if os(macOS)`, `canImport(AppKit)` and `targetEnvironment(simulator)` in UI tests now take the iPhone simulator's branch, so a macOS-only test doesn't run and fail.
- **A failing run says when the app has simulator-only code.** simless builds the app for a device, so `#if targetEnvironment(simulator)` in the app takes its device branch. When a run fails and the app has such checks, simless says where, so a test that counts on the simulator branch can be marked.
- **Skipped tests keep their reason**, and an XCTest skip no longer crashes the host.
- **Tests see the app's real bundle id.** `Bundle.main.bundleIdentifier`, a watch app's companion id in its Info.plist and `Bundle(identifier:)` all use the original id in test and UI hosts, while asset catalogs still find the app's colors and images.
- **UI tests get 600 s each by default** too, like unit tests. A heavy audit at the largest text size can take over 4 min in the simulator.
- **`simless down` stops everything**: the render host and every test and UI host of the worktree (or all of them with `--all`), including standby hosts.
- **Results for a merge script.** `test-results.json` and `ui-test-results.json` list every test with its status (passed, failed, crashed, skipped, simulator-only, load), its time and its reason or failure. Simulator-only marks that name a class or a target are listed test by test.
- **The simulator-only command fits the project.** Each target gets the shared scheme that tests it and a simulator of its platform (an Apple Watch for a watch UI test target), on the newest installed runtime or `calibrate.runtime`, with the OS in the destination.
- **Crashes without a crash report.** macOS stops writing reports after a few crashes of the same app. simless's runtime now prints the crashed thread's top frames and the test's own frames to the host's log, so the crash is still described, pinned on the right test, and SwiftUI's Stepper crash still gets its note.
- **Faster first run.** `simless up` builds local packages' tests alongside the app and prepares the test hosts, so the first `simless test all` only runs tests (`--no-tests` skips that). A run reuses a package build that covers its targets, so a narrower run after `test all` doesn't build again.
- **Less disk.** Package tests build without debug info and no index store (failures still name their file and line, crashes their functions), the shared compilation cache is cleared above 8 GB instead of 12, and `simless status` breaks the cache down by worktree with what `simless clean` would free.
- **simless cleans up after itself more thoroughly.**
  - Removing a slot empties the app's data container first. macOS protects containers from other processes, so the app is launched once to delete its own files.
  - A unit test run starts with an empty `tmp`.
  - Crash reports of simless hosts go after a day.
  - Worktrees that haven't used simless for two weeks lose their slots and builds.
  - Standby test hosts exit after 10 idle minutes, since they run the app's idle work (animations, timers) for nothing.
- **A full disk is reported as a full disk**, instead of "no error lines found". A compilation cache it left damaged is cleared, and the build runs again.
- **UI tests use up to 4 hosts** (one per two cores), and failures rerun to rule out load on all hosts side by side.
- **Help and skill.** `simless --help` lists `test ui`, `--simulator-only`, `--hosts`, `--jobs` and the 600 s timeout. `simless skill install` links the skill instead of copying it, so it stays current, and `simless up` says when an installed copy is out of date.

## 0.3.0 (2026-10-13)

The goal for this one was replacing the simulator for a whole test suite, unit and UI tests, on a production app with about 2,200 unit tests and 115 UI tests. The full unit suite now runs in 5.8 min against 8.9 min in the simulator (build included), with the same results. The UI tests run in 7.8 min against 51 min of test time on one simulator, without any simulator clones. 101 of the 104 that don't need a simulator pass. The 3 that don't: a chart that scrolls less per swipe than on an iPhone, a SwiftUI `Button` inside a view with its own `onTapGesture` (the outer gesture wins), and Vision reading a photographed document differently in one language. I'll keep digging into the first two.

- **UI tests without a simulator.** `simless test ui` runs your XCUITest code as it is. The test sources are compiled for the Mac with simless's own `XCUIApplication`, `XCUIElement` and queries, which drive the real app in hidden hosts. Launch arguments and environment, terminate and relaunch, queries, taps, typing, swipes, coordinates, alerts, screenshots and `performAccessibilityAudit` all work. Tests are spread over several hosts by their last durations (`--jobs`), and every failure saves a screenshot and the element tree.
- **SwiftUI gestures work with synthesized touches.** `onTapGesture`, drags and chart scrubbing used to ignore them on the Mac. Their recognizers live in gesture containers that aren't views, and simless now adds them to each touch the way UIKit does for a real one.
- **iPhone UI where the Mac differs.** Alerts, confirmation dialogs, context menus, `Menu`, the share sheet, compact date pickers and the keyboard with its toolbar show up in tests the way they do on an iPhone, instead of as AppKit windows or not at all.
- **Simulator-only tests are marked, not failed.** List them in `tests.simulatorOnly` with the reason (HealthKit sheets, StoreKit, pickers, the watch app). They're counted apart, and `simless test --simulator-only` prints them with the xcodebuild command to run them in a simulator.
- **Dynamic Type scales text now.** iOS apps on the Mac resolve every text style to one size, below SwiftUI in CoreText. simless's runtime makes CoreText use iOS's sizes, so text at AX5 is as big as on an iPhone, in tests and in renders. 15 Dynamic Type tests that failed before now pass.
- **Warm test hosts instead of xcodebuild.** Unit tests run in long-lived hosts that load the test bundles themselves, Swift Testing in parallel. A big run is spread over several hosts (`--hosts`), because tests on the main actor run one at a time per process and heavy rendering tests would hold everything else up. A 20-test selection takes 3.4 s instead of 40 s.
- **One bad test doesn't cost the run.** A crash or a timeout is reported with the test's name and the crash's frames, and a fresh host runs only what didn't finish. If the crash's stack names one of the running tests, that's the culprit. Otherwise the others run again together and get split in half until the crash lands on one test, instead of all running one at a time. Tests that only ran out of time because the machine was busy run again alone and are reported as load.
- **Same results as the simulator.** Extensions and the watch app report their real bundle ids, hosts aren't slowed down by App Nap, and a test run can keep more than 256 files open. In UI tests, `mailto:` and `tel:` links have no handler and a watch session is supported, like on an iPhone simulator.
- **Tests get 600 s by default**, like Xcode's execution time allowance, instead of 300 s. A parameterized test's cases count as one test, and a heavy one could run past 300 s on a busy Mac.
- **Stepper crashes say what they are.** A test that hits SwiftUI's `Stepper` crash on the Mac gets a note to mark it simulator-only.
- **`simless status`** shows each host's role (renders, unit tests, UI tests), memory and CPU, and the cache's size on disk.

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
