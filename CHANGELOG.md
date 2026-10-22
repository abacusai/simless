# Changelog

<!-- One section per version: `## 0.1.0 (2026-10-09)`. Notes for the next
     release go under `## Unreleased`. -->

## Unreleased

- **Hot reload works on big apps.** On a production app (702 Swift files, 19 packages), every edit fell back to a full rebuild, because even a leaf view reached 352 files on the way from the fixtures. Edit to checked screen now takes 3.2 s instead of 45.1 s for a leaf view (ScheduledTasksView) and 3.0 s instead of 37 s for a main screen (AuthenticationViewB), and both renders match a full build's exactly, PNGs included. What changed:
  - **Only what the edit changed counts.** Each edited file is compared declaration by declaration with its copy from the last full build, so an edit to one view's `body` doesn't make every type in its file edited.
  - **Only views make renders stale.** From an edited view, only the views that name it need patching. A store, model or enum that names a view doesn't render it, which is what pulled half the app in. An edited model still reaches everything that uses it.
  - **Only the fixture you render.** `reload --render X` patches X's way to the edit. Other fixtures that reach it are listed as stale until the next full build, `simless render` notes it on them, and they never trigger a rebuild. `simless reload --dry-run` shows what a reload would patch.
  - **Patches compile what they patch.** Unchanged declarations in a patched file resolve to the app's own copy, so an unchanged `extension View { func card() }` no longer makes the patch fail as ambiguous.
  - **Faster compile.** One frontend job per file (2.1 s instead of 3.5 s for that app's two-file patch), and the package module map search is cached (0.25 s per reload).
  - **Packages with C headers and static xcframeworks compile.** Patches get the header paths the app build has, so GoogleSignIn and GoogleMaps imports no longer fail.
- **Replacing `body` in place was tried and isn't safe.** `@_dynamicReplacement` swaps the code but keeps the old `some View` type, which SwiftUI would read wrong. [findings.md](docs/findings.md#hot-reload) has the test.
- **Unit tests for simless itself** (`swift test`), starting with hot-reload scoping, and CI now checks a real hot reload on the demo app: a screen that a shared store names and another screen embeds.

## Unreleased

- **Fixtures nobody has to write.** `root` renders the app's first window, as its `@main` App builds it, and every `#Preview` block (and `PreviewProvider`) is a fixture named `<File>.<preview name or number>`. `simless render all` lists them after the registered ones. On a production app, all 34 (27 `#Preview` blocks, 6 preview providers and `root`) compile in 3.2 to 5.6 s while the slot gets ready, so a warm `up` still takes 21 s, and `render all` does the 40 fixtures in 1.9 s. On a freshly generated xcodegen app with no fixture registered, `render all` covers `root` and its 4 previews, a SwiftData `.modelContainer` on the scene and `@Previewable` state included.
  - **They're built from source,** in copies of their files, so a preview's private sample data works, and compile errors leave out only that preview, with the reason in `simless up`'s output. Widget and Live Activity previews are skipped as not views. `"previews": false` turns it off.
  - **They hot-reload.** `reload --render NoteRow.Short` compiles that preview into the patch (0.9 s on the xcodegen app), and other previews that reach the edit are listed as stale, like other fixtures.
  - **A `root` that waits for the network is empty.** The App's real first screen is what renders, so an app that shows nothing until a login check finishes shows nothing here either.

## 0.6.0 (2026-10-22)

Install it and it works: simless no longer needs an Apple Development certificate, a provisioning profile, Full Disk Access for SimlessAgent, or a login session. It runs the same on a laptop, over SSH, on a CI runner and in a VM, and it's faster.

- **Native mode, the new default.** The app's iOS device build is tagged Mac Catalyst (one field in each binary's header) and signed ad hoc, then started directly. Nothing is installed or registered, and there's no xcodebuild install step. `"mode": "dfi"` keeps the signed "Designed for iPad" install for anyone who needs it.
- **No login session needed.** Hosts render without a window server: from a background launchd job (like SSH or a LaunchDaemon), every demo render, PNG, unit test and UI test came out the same as in a GUI session.
- **Faster.** On the production app (942 Swift files, a widget extension and a watch app), measured mode against mode on one Mac with every host stopped between runs: a warm `simless up` takes 25.9 to 29.4 s instead of 53.2 s (slots are ready in 3.5 s each, with no install), the 107 UI tests 432 s instead of 545 s, and the 2,345 unit tests 303 and 327 s against 320 and 320 s.
- **Same results.** Every unit and UI test has the same outcome in both modes. Of 2,358 renders (393 fixtures in light and dark on three devices), all match except nine animated screens, which differ by up to 1.7 pt between two runs of either mode too. On the demo app all 48 renders match.
- **Warm `simless up` doesn't relink or re-sign test bundles.** simless used to sign the package test bundles where Xcode built them, and Xcode then saw changed outputs and linked all of them again on the next build, which made them need signing again too. It now signs an APFS clone of each next to Xcode's (`<Name>.simless.xctest`) and leaves Xcode's alone, and prepares a clone again only when the bundle or a resource bundle changed. On the production app (40 package test bundles), warm `up` went from 39.1 to 44.2 s to 25.9 to 29.4 s: the build from 13.9 to 16.7 s to 8.8 s, 11 s of signing gone, and the test hosts ready in 4.4 to 4.9 s instead of 14.4 to 14.9 s.
- **A test host that quits while it starts gets one more try.** Once in a production run, a native test host exited before it answered, with no crash report and nothing in its log, and its targets never ran. Render hosts already started again in that case, now test hosts do too. A host that crashed (one with a crash report) still fails right away.
- **Live reload without SimlessAgent.** simless puts the patch in the host's own tmp folder, so reloads are live (about 0.2 s after the compile) with nothing to grant.
- **No unit-test target needed.** The native mode installs nothing, so `simless init` takes a project with just an app target (its kit goes next to the `@main` App when there's no folder named like the target, as in a generated project's `Sources/`), and a scheme without a test action builds with a plain `build`. `simless test` then says there's nothing to run.
- **`#if SIMLESS`.** simless builds define the `SIMLESS` compilation condition, so code can take its simulator branch under simless too: `#if targetEnvironment(simulator) || SIMLESS` (a mock store, which `targetEnvironment(simulator)` alone leaves out on the Mac's device build). Patches see it as well.
- **iPhone-only apps launch.** On the Mac they'd get the phone idiom, where SwiftUI's `Stepper` overflows the stack as soon as the app's window draws. The slot declares the iPad family too, so they get the iPad idiom every "Designed for iPad" app has.
- **UI test requests survive a dropped connection.** A native host's socket can be closed under it, and the request in flight was lost: a tap that never happened, an empty screenshot, a flaky test. Every request now has an id. The shim sends it again on a new connection, and the runtime answers a repeated id from its first attempt, so nothing runs twice and nothing is lost.
- **The text-clipped audit doesn't flag text it didn't read.** It reads the pixels inside each text element's frame, and a screen still scrolling had moved by then: it read another element's truncated text and reported a three-line paragraph as clipped, now and then. The audit waits for the app to settle first, and a read that doesn't start like the element's text gives no verdict.
- **No AppKit menus in headless hosts.** Under Mac Catalyst, UIKit shows edit and context menus as AppKit menus that wait for a click. simless already shows iPhone menus in UI tests, so AppKit's never open (one stalled a UI test 60 s).
- **PNGs match the tree and the simulator.** A "Designed for iPad" window drew its content 20 pt below the frames its tree reported. Native PNGs line up with the tree and the simulator's layout.
- **The app keeps to its slot.** Outside the sandbox it still gets a home folder of its own (documents, caches, tmp), preferences under the slot's id (suites too), and its own keychain for generic and internet passwords, all emptied before each test run without launching anything.
- **Location is denied like on an iPhone.** After the app asks, its delegate hears the change, the status reads denied and a fix request fails with `kCLErrorDenied`, so an app waiting for a location no longer waits forever.
- **`--settle <ms>`** gives a screen time for its async work (`.task`, loads) before the tree is read, for fixtures that can't inject their data. `"settle"` in `.simless.json` sets a default. Needs the kit from `simless init` (kit 4).
- **`simless up` always replaces a running host.** A host that kept running from before an `up` could keep its port and answer for the new build.
- **Undoing an edit undoes its patch.** `simless reload` after the edits were reverted said "nothing edited" while the host still showed the last patch. It now starts the host again from the build.
- **Build machines that re-sync sources** keep their builds: a worktree's slots and build cache go only after its `.simless.json` has been missing for 10 minutes, not the moment another project's command notices.
- **Explicit signing choices win (dfi mode).** `SIMLESS_TEAM`, then `"team"` in `.simless.json`, then the project's `DEVELOPMENT_TEAM`.
- **Ports are checked before they're handed out**, and the CLI finds its templates and runtime sources next to the binary it runs from (or `SIMLESS_ROOT`), so a checkout restored from a CI cache works.
- **`"isolate": true`** (or `SIMLESS_ISOLATE=1`) gives each native host a sandbox of its own, for build machines that serve many projects as one user: it writes only into its slot, reads only its worktree and build folder in the user's home, and can't reach other hosts. The demo's renders, unit and UI tests come out the same with it.
- **UI tests work on macOS 15.** Every synthesized touch threw there, because macOS 15's UIKit makes hit test contexts without the event. AppKit swallowed the exception, so each tap waited out the 240 s request timeout. Touches now use the initializer the running UIKit has. And swipes on the whole app started at its top-left corner, because the shim read the app's frame from an array literal that came out as `[Any]` of `Int` and `Double` there. And a swipe on a scrollable chart went to SwiftUI's gesture instead of the chart's scroll view, so there a swipe gets the views' own recognizers, as UIKit gives them. One gap is left on macOS 15: a press-and-drag selection on a scrollable chart doesn't select, so the demo skips that one test there.
- **A UIKit exception fails the request instead of hanging it.** Every UI request runs under a catcher, and an exception comes back as an error with its reason.
- **CI runs the demo app end to end** on GitHub's hosted macOS 15 runner (a VM with Xcode 26): build, every render, unit and UI tests, unsigned.

## 0.5.3 (2026-10-18)

The last gaps before a project can gate its merges on simless: a run never reports results for code that isn't what's on disk, and never passes with tests missing from a list.

- **Tests always run against the files on disk.** The app and its hosted test targets come from the last full build, and before, an edit to an app-hosted test target wasn't rebuilt: a planted failing assertion showed as passed. simless now records every file the build reads (under the project and the local packages, test targets included) and, when one changed, builds again before testing. If that build fails, nothing runs and the run says why. A run of package test targets after package edits alone skips it, since those build from current sources anyway.
- **An id that matches no test fails the run.** A renamed, deleted or mistyped id in a filter or a `--from` list is `not-run` now, so a list can't shrink without anyone noticing. `--allow-missing` lets it through.
- **The results file never keeps an earlier answer.** It says `ok: false` while a run goes, and an error that stops the run early (an unknown target, a failed build) leaves `ok: false` with the error in it.
- **An iPad's floating tab bar is what XCUITest on iPadOS shows**: each tab is a button, with no tab bar element around them. `app.buttons["Profile"]` works on an iPad and `app.tabBars.buttons["Profile"]` doesn't, in an iPad simulator and under simless alike. Checked by running the demo's test in an iPad simulator.
- **`--help` after any command prints that command's help** and runs nothing. `simless test --help` used to run the tests.
- **UI test bundles rebuild when their sources' content changes**, a deleted file or one put back to an older version included, not only when a file is newer than the bundle.

## 0.5.2 (2026-10-17)

This one makes simless safe to gate merges on: a run can no longer pass with tests missing. Measured on the same production app as before, now on Xcode 27.1, plus the demo app and a second app.

The whole unit suite (2,280 tests) now takes 473 s from nothing (`simless clean --all`, then `up` and `test all`) against 491 s for the simulator's build and tests, and 327 to 390 s once built against 375 s of simulator test time. All 106 UI tests that don't need a simulator pass on iPhone and iPad in 450 to 561 s, against 1,150 s on 5 simulator clones. 3 back-to-back runs of both suites on one commit gave identical results, every target present.

- **No more false green from a package's test run.** Package tests build in the app's build folder since 0.5.0, and a package test run left its own `.xctestrun` next to the app's. Three places took whichever sorted first, so after one, `simless test all` silently dropped the app's hosted test targets and still passed, `simless test ui` found no UI test targets, and `simless up` couldn't install. simless now picks the app scheme's file by name (or by the app's test target in it). The demo app has a local package with two products to reproduce it.
- **A test target that doesn't run fails the run**, whatever the cause. `simless test all` checks the app scheme's test targets (that exist) and every local package's, and a target with no test in the run is `not-run` and exits 1. A UI test target that's in the scheme but missing from the build counts the same way.
- **The two-device UI results have the same fields as one device's**: `ok`, `selected`, `notRun` and `flaky`.
- **Windows tests make get the device's safe areas.** In a unit test host, a window a test puts on the scene has an iPhone's size and insets (62 pt on top, 34 at the bottom), not the Mac window's 20 pt, and its content is laid out within them.
- **A tab view that adapts to a sidebar starts with its tab bar on an iPad**, like iPadOS, instead of an open sidebar. Checked against an iPad simulator with `simless calibrate`.
- **Same number of hosts every run.** Test hosts are planned from the Mac's core count rather than the cores macOS reports available at that moment, from the timing history of full runs rather than the last run's (a run of a few tests left times for a few targets), and every run says how many hosts it uses and why.
- **Slots install side by side** (up to 3 at once), so a cold `simless up` has its test hosts ready in 26 s instead of 38 s after the build.
- **`simless down --all` says what it stops**, worktree by worktree, and leaves the hosts of a worktree whose test run is still going.

## 0.5.1 (2026-10-17)

- **Hosts start with Xcode 27.1 on macOS 27.** Every host crashed at launch: the runtime's `infoDictionary` swap handed back an immutable copy, and Foundation now writes into that dictionary when Metal looks up its plugin as the first window opens (`-[_SwiftDeferredNSDictionary setObject:forKey:]: unrecognized selector`). It hands back the bundle's own dictionary when no id changes, and a mutable copy when one does.
- **App-hosted test bundles load with Xcode 27.1.** Xcode 27.1's `libXCTestSwiftSupport` links `_Testing_Foundation`, which xcodebuild doesn't open the app's sandbox to, so the test bundle failed to load ("file system sandbox blocked open()") and no host started. Slots now carry a copy in the app's `Frameworks` folder, with its symlinks followed, since the installer refuses a versioned framework's links.

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
