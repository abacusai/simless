# simless

**Simulator-free, headless SwiftUI checks for AI coding agents.**

Your real iOS app runs natively on your Mac as an invisible render host. Agents render any screen as a compact accessibility tree in milliseconds, hot-reload edited views in about 2 seconds, and run unit tests and your existing XCUITest UI tests, all without booting an iOS Simulator. Many agents across many projects can work in parallel on one Mac.

```
$ simless reload --render Welcome.sheet
reloaded (live) in 1.9s: compile 1.7s + apply 0.2s; files edited since `simless up`: WelcomeSheet.swift
Welcome.sheet · light · iphone 402×874 · 25 ms · patch 1
  traits: compact/regular size class, idiom pad, safe area top 62 bottom 34
  header  "Welcome to Notes" #welcome.title  @89.3,403.8 223.5×81.5
  text    "Your notes stay on this device and sync with iCloud."  @26.8,493.3 348.5×64.5
  button  "Get Started" #welcome.start  @24,779.5 354×36.5
  issues (1):
    ⚠ button "Get Started" tap target 354×36 is smaller than 44×44
```

## Why

Coding agents check UI changes by building for the iOS Simulator, installing, launching and taking screenshots. Each agent pays for its own booted simulator (we measured ~2.2 GB of private memory and ~210 processes per simulator running a real app) plus its own `xcodebuild`. With 4–5 agents in parallel, a 32 GB Mac swaps and everything slows to a crawl.

simless replaces that loop:
- **No simulator:** the app's iOS slice runs natively on Apple Silicon ("Designed for iPad"). It's your real app target, views and dependencies, at ~30 MB per host.
- **Headless:** no windows, no Dock icons, no focus stealing, including during installs and test runs.
- **Text first:** agents read an accessibility tree (~150 tokens per screen), plus automatic checks for unlabeled controls, off-screen elements, small tap targets and overlaps. PNGs are produced only on request.
- **Hot reload:** only the edited files are compiled into a patch and loaded into the running host.
- **Built for many agents:** one host per git worktree, coordinated with file locks, and everything cleaned up automatically.

## Results

Measured on a production SwiftUI app (~280 Swift files, several large Swift packages) on an M2 Pro MacBook Pro with 32 GB of RAM. Legacy means one iOS Simulator per agent, with an incremental `xcodebuild`, install, launch and screenshot for every check.

| | Legacy (simulator) | simless | |
|---|---|---|---|
| Edit → verified screen, 1 agent | 21.9 s | **2.2 s** | **10×** |
| Edit → verified screen, 5 agents in parallel | 37.4 s | **2.2 s** | **17×** |
| 5 agents start cold at once (per agent) | 732 s | **344 s** | 2.1× |
| Memory held by 5 agents (steady state) | 11.2 GB, 1,071 processes | **0.15 GB, 6 processes** | **~75×** |
| Peak load average, 5 agents starting cold | ~1,010 | **~82** | 12× |
| Unit tests (2 classes) | 13.1 s | **5.6 s** | 2.3× |
| Unit tests, whole suite (2,280 tests), nothing built, empty caches | 8.2 min | **7.9 min** | 1.0× |
| Unit tests, whole suite, already built | 6.3 min | **5.5 to 6.5 min** | 1.1× |
| 20 named tests, nothing rebuilt | 25.5 s | **about 1 s** | 25× |
| UI tests (106 XCUITests, iPhone and iPad, 5 simulator clones vs. 4 hidden hosts) | 19.2 min | **7.5 to 9.4 min** | 2.3× |

Legacy gets slower with every agent you add, simless stays at ~2 s per edit. The test rows are from a second production app (about 2,200 unit tests across 41 targets, most of them in a local Swift package), against an iPhone 17 simulator on iOS 26.5, with the same results test by test. The whole unit suite's time is set by one CPU-heavy test target that the Mac's Swift runtime runs slower than the simulator does (see [Unit tests](#unit-tests)). Full method, caveats and reproduction steps: [docs/benchmarks.md](docs/benchmarks.md).

## Does it look the same?

Mostly. Here are screens from the [demo app](Examples/SimlessDemo), rendered by the iOS Simulator (the legacy workflow) and by simless:

| Welcome: iOS Simulator | Welcome: simless | Settings: iOS Simulator | Settings: simless |
|:-:|:-:|:-:|:-:|
| <img src="docs/fidelity/Welcome-light-simulator.png" width="190"> | <img src="docs/fidelity/Welcome-light-simless.png" width="190"> | <img src="docs/fidelity/Settings-light-simulator.png" width="190"> | <img src="docs/fidelity/Settings-light-simless.png" width="190"> |
| | ✓ matches within 2 pt | | ✗ toggle rows 6 pt taller, Mac accent color |

8 of 14 demo renders (7 screens, light and dark) match within 2 pt. The rest differ in row heights of `List` and `Form`, line breaks in long centered text, and system accent colors. [docs/fidelity.md](docs/fidelity.md) shows every screen side by side. Run `simless calibrate --png <dir>` to get the same comparison for your own app.

## Requirements

- An Apple Silicon Mac with Xcode 26 or later.
- A SwiftUI iOS app in an `.xcodeproj` (at the repository root or in a subfolder such as `ios/`), with an app-hosted unit-test target (simless installs hosts through it). Views can live in the app target or in local Swift packages, and both hot-reload. Swift 5 and Swift 6 language modes, with or without MainActor default isolation, are supported.
- An **Apple Development** certificate, and the team's wildcard development profile ("iOS Team Provisioning Profile: \*") that includes this Mac. Xcode creates it the first time you run any app on "My Mac (Designed for iPad)". simless never registers anything in your developer account.

## Install

```sh
git clone https://github.com/abacusai/simless && cd simless
swift build -c release
ln -s "$PWD/.build/release/simless" ~/.local/bin/simless    # any directory on your PATH
simless skill install       # optional: Claude Code skill (see "Using it from AI agents")
```

## Set up an app (once per repository)

```sh
cd <your-app-repo>
simless init
```

This creates:
- `.simless.json`
- `<App>/Simless/SimlessKit.swift`: the render host. It's generated, `#if DEBUG` only, and does nothing unless simless launches the app.
- `<App>/Simless/SimlessFixtures.swift`: your screens.

It also adds one call to your `@main` App's `init()` (pass `--no-hook` to skip that):

```swift
#if DEBUG && os(iOS)
SimlessHost.startIfRequested()
#endif
```

Register the screens agents should be able to render, each in a deterministic state:

```swift
@MainActor
func simlessFixtures(_ r: SimlessRegistry) {
    r.add("Settings") { SettingsView().environmentObject(SettingsStore.preview) }
    r.add("NoteList.empty") { NoteListView(notes: []) }
    r.add("NoteList.long") { NoteListView(notes: .fixture(count: 50)) }
}
```

Then run `simless up`. If your project doesn't use synchronized folders, add the two files to the app target first. If app startup has side effects a background host shouldn't trigger (analytics, sync), guard them with `SimlessHost.isActive`.

### Live reload (optional, recommended)

```sh
simless agent install
```

Then grant **SimlessAgent** Full Disk Access (System Settings → Privacy & Security → Full Disk Access). This takes hot reload from about 10 s to about 2 s. The agent can do exactly one thing: copy a patch built by simless into the temp folder of a simless host's sandbox container. [Why it needs this](docs/architecture.md#5-simlessagent-and-its-security-model).

## Commands

```
simless init [--no-hook]          set up a repo
simless up [--no-tests]           build, install this worktree's host, start it, and prepare local packages'
                                  tests and the test hosts, so the first `simless test` only runs tests
simless render <fixture|all>      accessibility tree + issues
      [--dark] [--device iphone|iphone-small|iphone-max|ipad] [--matrix] [--png <file|dir>] [--json]
      [--locale <lang>] [--text-size xs…xxxl|ax1…ax5] [--idiom phone]
simless reload [files...]         hot-reload everything edited since `simless up`
      [--render <fixture|all>] [--matrix] [--no-fallback]
simless test [Target/Class/method...|all]   unit tests on the Mac, local package tests included
      [--skip Target/Class/method]... [--timeout <seconds per test>] [--hosts <n>] [--jobs <tests at once>]
      [--from <file|->]               test ids from a file or stdin, unit and UI ids mixed
simless test ui [Target/Class/method...]   your XCUITest UI tests, without a simulator
      [--jobs <hosts>] [--device iphone|ipad|iphone,ipad] [--timeout <seconds per test>]
simless test --simulator-only     the tests marked as needing a simulator, and the xcodebuild command for them
simless calibrate [fixture]       compare renders with an iOS Simulator (boots one, run once per app)
      [--dark] [--png <dir>] [--runtime <iOS version>] [--sim-device <name>] [--idiom phone]
simless status                    hosts, test runs going on and their share of the Mac, disk use
simless down [--all]              stop this worktree's hosts, test and UI hosts included (--all: every worktree's,
                                  said before it stops them, except where a test run is going on)
simless clean [--all]             remove this worktree's host, slot and build cache (--all: everything)
simless agent install             install SimlessAgent (live reload)
simless skill install             install the Claude Code skill
simless version                   version, Xcode and macOS
```

`--matrix` renders light and dark on `iphone`, `iphone-small` and `ipad`.

`--locale hr` relaunches the host with that language and region (about 1 s), so one fixture covers every language. `--text-size ax5` sets the Dynamic Type size the view sees, and text scales with it like on an iPhone.

`simless test` prints failures and crashes as they happen, with the crash's message and file, and a progress line every 10 s. `simless test all` runs the app's test targets and every local package's, in warm hosts with tests in parallel. A big run is spread over several hosts (`--hosts`), because main-actor tests run one at a time per process. Targets are spread by how long each took in the last run, from its first test to its last, and a target that takes half again as long as any other gets a host to itself. Those times are kept per repository, so a new worktree or a run after `simless clean` spreads well too. A test that crashes the host or runs longer than `--timeout` (default 600 s, like Xcode) is reported with its name and the crash's frames, and a fresh host runs only what didn't finish. A few failures (up to 30) run again alone, and a test that passes then is reported as flaky. A `--skip` that didn't match anything gets a note with the id formats.

`--from <file>` (or `--from -` for stdin) takes test ids one per line, in the format the results files use, so a merge script can pass the tests a change touches. Unit and UI ids can be mixed: both kinds run, with one exit code.

`simless test ui` runs the UI test targets' XCUITest code as it is: `XCUIApplication` with launch arguments and environment, queries, `tap`, `typeText`, swipes, coordinates, alerts, `performAccessibilityAudit`, screenshots. It spreads the tests over several hidden hosts (`--jobs`, default up to 4), and for every failure saves a screenshot and the element tree. `--device iphone,ipad` runs every UI test on both, and `tests.uiDevices` adds a device that runs only the tests listed for it (an iPad-only class, say). See [UI tests](#ui-tests) for what it emulates and what still needs a simulator.

### Using simless as a merge check

`simless test` exits 0 only when every selected test ran and passed. It exits non-zero when a test failed, crashed, ran out of time or never ran, when an id in the selection matches no test (`--allow-missing` lets that through), and when a test target the run had to cover produced no tests. For `simless test all` those are the app scheme's unit test targets and every local package's test targets. Tests marked simulator-only, `--skip`ped ones and those in a UI test target the scheme doesn't build are listed but don't count against the run.

Tests always run against the files on disk. simless records every file the app's build reads (the project's folder and the local packages, test targets included), and when one has changed since the last build, `simless test` builds again first. If that build fails, nothing runs.

Results go to `test-results.json` and `ui-test-results.json` in the worktree's work folder (`simless status` shows where). They never keep an earlier run's answer: a file says `ok: false` while its run goes, and one that stopped early (an unknown target, a failed build) says `ok: false` with the error. Each starts with `ok`, `selected`, `notRun` and `flaky`, and then lists every test with its time, its reason or failure, and one status:

| Status | Meaning |
|---|---|
| `passed`, `failed`, `crashed`, `skipped` | what it says. A crash includes running out of time |
| `flaky` | failed in the full run and passed when run again alone. Doesn't fail the run, but a merge script can |
| `not-run` | selected, but nothing came back for it. Fails the run. A whole test target that didn't run (its bundle didn't load, or the build left it out) gets one `not-run` entry under its name |
| `simulator-only` | marked in `tests.simulatorOnly`, or skipped with a reason that starts with "simulator only" |
| `excluded` | matched `--skip` or `tests.skip` |
| `not-built` | in a UI test target the scheme doesn't build (a watch app's, say) |

With several UI devices, each test also lists its result per device, and its status is the worst of them, except that a pass on one device beats a skip on another.

What can't run here runs in a simulator: `simless test --simulator-only` prints one xcodebuild command per scheme and platform, on a simulator named like `calibrate.device` on `calibrate.runtime`. When that simulator or runtime isn't on the Mac, it says which, prints the command that creates or installs it, and exits 1. It never falls back to another simulator, such as one another session booted.

### Options in `.simless.json`

```json
{
  "checks": { "minTapTarget": 32, "ignore": ["\"Daily\" tap target", "Show Sidebar"] },
  "tests": {
    "timeout": 120, "skip": ["AppTests/DeviceOnlyTests"],
    "simulatorOnly": { "AppUITests/HealthUITests/testPermissionSheet": "the HealthKit sheet" },
    "uiJobs": 3, "uiTimeout": 180,
    "uiDevices": { "ipad": ["AppUITests/IPadLayoutUITests"] }
  },
  "calibrate": { "runtime": "26.5", "device": "iPhone 17 Pro" },
  "idiom": "phone",
  "embeddedBundles": true
}
```

- `checks.minTapTarget`: the smallest tap target in points that isn't reported (default 44).
- `checks.ignore`: issues containing any of these strings aren't reported. Renders say how many were ignored.
- `tests.timeout` and `tests.skip`: defaults for `--timeout` and `--skip`.
- `tests.simulatorOnly`: tests that need a simulator, with the reason. They're skipped and counted apart, and `simless test --simulator-only` lists them. A test skipped with a reason that starts with "simulator only" counts too.
- `tests.hosts` and `tests.jobs`: test hosts running side by side (default: up to 4 when there are 4 or more targets), and tests running at once in each. `tests.uiJobs` and `tests.uiTimeout`: hosts for UI tests, and seconds one UI test may run (default 600).
- `tests.uiSources`: a UI test target's source folder, when it isn't a synchronized folder simless can find.
- `tests.uiDevices`: more devices for `simless test ui`, each with the tests that run on it (`[]` for all of them). The device in `device` runs every UI test.
- `calibrate.runtime` and `calibrate.device`: the simulator `simless calibrate` compares against and the simulator-only command runs on (default: the newest runtime, iPhone 17 Pro).
- `idiom`: `"phone"` renders phone canvases with the phone idiom (see below).
- `embeddedBundles`: `false` removes app extensions and the watch app from the slot.

## Using it from AI agents

**Claude Code:** run `simless skill install` once per machine. After that, "use simless for testing" is enough in any project. The skill teaches the agent to:
- set up a repo (`simless init`, writing fixtures),
- run the edit → `simless reload --render` loop,
- check variants with `--matrix`,
- fix the reported issues,
- say what still needs a simulator.

**Other agents:** add this to your `AGENTS.md`:

```md
## UI verification with simless (no simulator)
- `simless up` once per worktree. Never boot a simulator for screen checks.
- After editing SwiftUI views: `simless reload --render <Fixture>` (≈2 s). Read the tree and fix every issue.
- `simless render all --matrix` checks every screen in light/dark on iPhone, small iPhone and iPad.
- New screen or state? Register it in SimlessFixtures.swift with deterministic data.
- Use `--png <dir>` only when visual detail matters.
- Logic: `simless test <Target>/<Class>` (local package test targets work too, and `simless test all` runs every one).
  Exit code 0 means every selected test ran and passed. `--from <file>` takes a list of test ids.
- UI tests: `simless test ui` (or `simless test <UITarget>/<Class>`) runs the XCUITest code without a simulator.
  Mark tests that need a simulator (HealthKit, StoreKit, photo and file pickers, the watch) in
  `tests.simulatorOnly`, and run what `simless test --simulator-only` lists in a simulator.
- Tests that need a real device: gate them on `ProcessInfo.processInfo.isiOSAppOnMac` (or
  `SIMLESS_HEADLESS`), since `targetEnvironment(simulator)` is false on the Mac.
- Compile errors from `simless reload` point at your file:line.
- A pass is strong evidence, not proof. Run `simless calibrate` once per app to see which screens match
  the simulator. Say what still needs a simulator.
```

## Cleanup is automatic

simless cleans up after itself, so nothing piles up between runs or after a worktree is gone:
- **Deleted worktrees:** every command removes the hosts, slots and build cache of any worktree that no longer exists.
- **Unused worktrees:** a worktree that hasn't used simless for two weeks loses its hosts, slots and builds too (its `.simless.json` stays, and `simless up` builds again).
- **App data:** every test run starts with a fresh install's data, like a simulator's clones: the app's data container is emptied and its saved preferences cleared before a UI run and before each unit test host starts. Removing a slot empties it too. macOS lets no other process touch it, so simless launches the app once to delete its own files.
- **Hosts:** a host exits after 30 idle minutes (`hostIdleMinutes`), a standby test host after 10. `simless down` stops this worktree's hosts, test and UI hosts included.
- **Crash reports** that macOS writes for simless hosts are deleted after a day.
- **Patches:** only the newest 3 are kept, and patch files are deleted as soon as they're loaded.
- **Compile cache:** the shared Xcode compilation cache is cleared above 8 GB, and when a build finds it damaged (after a full disk, say), simless clears it and builds again.
- **Total disk:** everything simless keeps across worktrees stays under 25 GB (`SIMLESS_DISK_LIMIT_GB` changes it). When `simless up` finds more, the builds and slots of the worktrees that used simless least recently go first, never one used in the last hour, then the shared compilation cache. `simless status` shows what each worktree holds and what `simless clean` there would free.
- **Your repository** gets nothing from simless outside the two kit files and `.simless.json`: package manifests are read with SwiftPM's scratch folder in the cache, not a `.build` next to your package.
- **Timing history** (how long each test target took, per repository) is kept in `~/Library/Application Support/Simless/history`, a few KB, so a run after a clean still spreads its targets well.
- **Generated files** next to your project are git-excluded and removed by `simless clean`.

`simless status` shows what's running (memory, CPU, and the data each test host keeps) and what's on disk, by worktree, with what `simless clean` frees. `simless clean --all` removes everything simless created.

## Several sessions on one Mac

Agents often work in parallel worktrees. Each worktree has its own hosts, slots and build folder, so runs never share state or pick each other's hosts. Test runs going on at the same time share the Mac's cores: a run that starts while another is going uses half of them (fewer hosts, fewer tests at once), with three runs a third, and so on, so nobody gets slowed into timeouts. `simless status` lists the runs going on and the share each gets. A run sizes itself when it starts: one that started while another was going keeps its half after the other one ends.

## How far to trust results

**In short: simless is a fast, high-signal inner loop, not a replacement for a final simulator pass.** Run `simless calibrate` once per app to see how closely its renders match the iOS Simulator for your screens, and see [docs/fidelity.md](docs/fidelity.md) for side-by-side screenshots of a demo app. Before calling a UI change done, check it once in the simulator, especially anything below that simless can't see.

### What a result means

| Check | When it fails | When it passes |
|---|---|---|
| `simless test` (unit tests) | A real failure in your logic, unless the test depends on something listed under "Unit tests" below | Your logic works in your real app process, against Apple's iOS frameworks |
| `simless render` (tree) | A wrong element, label or frame is usually real; confirm layout-sensitive findings with `simless calibrate` | Elements, text, labels, identifiers and relative layout are right **on this canvas** |
| Automatic issue checks | Usually real, but the Mac runtime can expose some controls differently (see below) | Only that none of the five checks fired. Not that the screen is correct |

### What simless does to stay accurate

- **Hot reload patches more than the edited files.** It also patches every view between your fixtures and the edit, including views in local Swift packages, so a parent view never renders a stale subview. Edits it can't trace safely (an extension of another type, a public or top-level function) and patches that mix modules with different compiler settings fall back to a full build automatically.
- **Phone canvases get phone size classes.** That means compact width and the device's safe areas (notch, home indicator). The idiom stays iPad on the Mac unless you pass `--idiom phone`. Every render prints the traits the view saw.
- **`simless calibrate` compares against a real simulator.** It renders every fixture on the Mac and in one iOS Simulator, and reports any element or frame that differs by more than 2 pt.

### Known differences from an iPhone

- **The idiom is `.pad` by default** (UI test hosts excepted, which report an iPhone's). Code that checks the trait collection's `userInterfaceIdiom` takes its iPad branch, and renders print a note about it. `--idiom phone` (or `"idiom": "phone"`) gives views the phone idiom. It's opt-in because SwiftUI's `Stepper` crashes on the Mac under it, and it has been seen crashing under the iPad idiom too. When the phone idiom crashes a screen, simless restarts the host, renders that screen with the iPad idiom and says so. On the demo app it fixed the navigation bar of a split view, but didn't close the other gaps below, so run `simless calibrate --idiom phone` to see whether it helps your screens. `UIDevice.current.userInterfaceIdiom` stays `.pad` either way.
- **Text renders 2–4% wider.** Usually lines break the same way, but long or centered text can need an extra line. Treat exact line breaks and truncation as unverified until calibration shows they match.
- **Platform rows are taller.** `List` rows came out 2 pt taller and `Form` toggle rows 6 pt taller, so content below them sits lower.
- **System colors follow the Mac.** Controls use the macOS accent color (an "on" toggle can be gray instead of green), which an accessibility tree can't show.
- **Some controls are exposed differently to accessibility.** In calibration, a `Menu` with a custom label was unlabeled in simless but labeled on iOS, so simless reported an issue that isn't one on a phone. Confirm accessibility flags on `Menu` and other platform-backed controls with `simless calibrate`.
- **Text size:** `--text-size` and `-UIPreferredContentSizeCategoryName` scale text the way an iPhone does. An iOS app on the Mac normally resolves every text style to one size. simless's runtime makes CoreText use iOS's sizes instead (body is 17 pt by default and 53 pt at AX5, as on an iPhone). Set `SIMLESS_DYNAMIC_TYPE=0` to turn that off.
- **Pixels and images:** rendering is close to, but not identical with, an iPhone, and the Mac loads and draws images its own way. Use the simulator for final pixels and image checks.
- **Crashes:** a screen that crashes the render host is reported with the crash's first frames in your code or SwiftUI, and `render all` carries on with the other screens. SwiftUI itself can crash on the Mac where an iPhone doesn't (`Stepper` is the known case), so confirm such a crash in a simulator.

### Unit tests

- **Local package tests.** Package test targets run in the slot app, like the app's own tests. simless builds them for iOS devices, in the app's build folder with the app build's settings, so the package's code is compiled once for both. Xcode won't run a test bundle without a host app on "My Mac (Designed for iPad)", and `swift test` builds for macOS, where iOS-only imports fail. The bundle links its own copy of the package, so state it shares with the app (singletons, globals) isn't shared.
- **The repository is readable.** Tests (and fixtures) can read files in the repository, for example next to `#filePath`, but not write them. The app sandbox would block it, so simless grants read access when it starts the app.
- **App groups.** `containerURL(forSecurityApplicationGroupIdentifier:)` returns a private folder per group inside the slot's container, so reads and writes work but nothing is shared with other apps.
- **Other capabilities are missing.** Hosts run without iCloud/CloudKit, keychain sharing or push. Tests that need them can fail or take other code paths.
- **App extensions and the watch app stay in the app.** They're re-identified under the slot's bundle id so tests can find them. macOS registers the extensions, and simless sets each one to "ignore" so a slot's widgets never show up in the widget gallery.
- **Device-only tests run.** `targetEnvironment(simulator)` is false on the Mac, so tests gated on it run. Gate them on `ProcessInfo.processInfo.isiOSAppOnMac` instead, or on the `SIMLESS_HEADLESS` environment variable, which is set only in simless runs.
- **Mac behavior.** Some APIs behave differently when an iOS app runs on a Mac: `UIDevice`, file-system locations, the sandbox.
- **Current build.** App tests run against a full build, never against hot-reload patches, and `simless test` builds again first when a file the build reads has changed. Package tests are built from the current sources.
- **Windows tests make** on the connected scene have the emulated device's size and safe areas (62 pt on top on an iPhone), and their content is laid out within them.
- **Bundle ids.** The app, its extensions and the watch app report their original bundle ids to tests, not the slot's, in `bundleIdentifier` and in Info.plist values such as a watch app's companion id.
- **The Mac's Swift runtime.** Tests run at the Mac's own speed: a CPU-bound benchmark in the demo app takes the same time as in an iOS 26.5 simulator. But the Mac's Swift runtime isn't the simulator's, and unoptimized generic code (a debug build's string matching, say) can run slower. In one app a test took 180 s under simless and as a plain macOS program alike, and about 95 s in the simulator. simless can't swap the Mac's runtime, so a target with tests like that sets the floor for a whole `simless test all`: it gets a host of its own, and the run can't end sooner than it does. Split such tests into smaller ones (or into their own target) to bring the whole run down.
- **Mac frameworks.** Vision, for one, reads text differently on the Mac (a superscript "10^9" came out as "1019"). Mark tests that compare such output exactly as simulator-only.

### UI tests

`simless test ui` runs your XCUITest code against your real app on the Mac, at an iPhone's screen size (or an iPad's with `--device ipad`). Most of what a test does maps directly: queries, taps, typing, swipes and drags, launch arguments and environment, terminating and relaunching, deep links, orientation and appearance. Where the Mac shows things differently from an iPhone, simless shows the iPhone's version in the tree:
- **Alerts and confirmation dialogs** as an iPhone's alerts and action sheets (the Mac would show AppKit panels).
- **Context menus and `Menu`** as an iPhone menu, opened by a long press or a tap, with submenus that open on a tap.
- **A text field's edit menu** (Select, Select All, Paste) on a long press.
- **An iPad's floating tab bar** as iPadOS shows it to XCUITest: each tab a button, with no tab bar element around them (query `app.buttons["Tab"]` on an iPad, `app.tabBars.buttons["Tab"]` on an iPhone).
- **The share sheet** as a sheet with Close. Close or a swipe down cancels it. Sharing to a target isn't emulated.
- **Compact date pickers** as a button with the date or time, which opens wheels for a time.
- **The keyboard:** the keyboard's notifications, an iPhone keyboard's frame, and the keyboard toolbar above it.
- **Things only an iPhone has:** no handler for `mailto:`, `tel:` and `sms:` links (like a simulator), and a watch session that's supported but never paired.

`performAccessibilityAudit` runs simless's own checks with Xcode's audit types: hit regions under 24 pt, elements without a description, clipped text (read with Vision), text that doesn't scale with Dynamic Type, and contrast. elementDetection and trait aren't checked.

**Permission prompts never reach your screen.** The hosts are real Mac apps, so a request for calendar, notifications, microphone, camera, speech, photos, contacts, location or tracking access would show macOS's dialog, and so would a review request. The runtime answers them itself: access is denied and review requests do nothing. Granting isn't an option, because the app's next access would make macOS ask anyway. Set `SIMLESS_PERMISSIONS=ask` to let the requests through to macOS.

What needs a simulator: HealthKit permission sheets and data, the StoreKit purchase sheet and products from a StoreKit configuration file, the photo and file pickers (unless your app stubs them in UI tests), recording from the microphone, sharing to a target, the Home Screen, and the watch app. The same goes for a test that counts on app code behind `#if targetEnvironment(simulator)`, since simless runs the device branch (a failing run points it out). Mark those tests in `tests.simulatorOnly`, and `simless test --simulator-only` lists them with the command to run them in one.

### Not checked at all

Pixel-exact rendering, system UI that isn't emulated above (StoreKit sheets, pickers), Siri and widgets themselves (deep links into the app work), and multitasking on iPad.

### Other limits

- **Project types:** `.xcworkspace`, Tuist and pure Swift Package apps aren't supported yet. You need an `.xcodeproj` (anywhere in the repository) with an app-hosted unit-test target.
- **Side effects:** the host runs your app's real startup in the background. Guard analytics and network with `SimlessHost.isActive`.
- **Private APIs:** the render host relies on a few private, DEBUG-only Apple APIs (in-process accessibility automation, hiding the app, suppressing its windows, sandbox extensions for reading the repository). An OS update could break them, and they never ship in release builds.

## How it works

See [docs/architecture.md](docs/architecture.md) for the design, [docs/findings.md](docs/findings.md) for the platform behavior it relies on, and [docs/fidelity.md](docs/fidelity.md) for side-by-side renders of the [demo app](Examples/SimlessDemo) in the iOS Simulator and in simless. Benchmarks are reproducible with [bench/](bench/).

## License

Apache-2.0 ([LICENSE](LICENSE)), copyright 2026 Abacus.AI, Inc. The files in `Templates/` (the render-host kit, the fixtures template and the agent skill), which `simless init` and `simless skill install` copy into your app or machine, are licensed under [MIT No Attribution](LICENSES/MIT-0.txt), so you can ship them without notices. See [NOTICE](NOTICE).
