# simless

**Simulator-free, headless SwiftUI checks for AI coding agents.**

Your real iOS app runs natively on your Mac as an invisible render host. Agents render any screen as a compact accessibility tree in milliseconds, hot-reload edited views in about 2 seconds, and run unit tests, all without booting an iOS Simulator. Many agents across many projects can work in parallel on one Mac.

```
$ simless reload --render Welcome.sheet
reloaded (live) in 1.9s: compile 1.7s + apply 0.2s; files edited since `simless up`: WelcomeSheet.swift
Welcome.sheet · light · iphone 402×874 · 25 ms · patch 1
  traits: compact/regular size class, idiom phone, safe area top 62 bottom 34
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

Legacy gets slower with every agent you add; simless stays at ~2 s per edit. Full method, caveats and reproduction steps: [docs/benchmarks.md](docs/benchmarks.md).

## Requirements

- An Apple Silicon Mac with Xcode 26 or later.
- A SwiftUI iOS app in an `.xcodeproj`, with an app-hosted unit-test target (simless installs hosts through it).
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
simless up                        build, install this worktree's host, start it
simless render <fixture|all>      accessibility tree + issues
      [--dark] [--device iphone|iphone-small|iphone-max|ipad] [--matrix] [--png <file|dir>] [--json]
simless reload [files...]         hot-reload everything edited since `simless up`
      [--render <fixture|all>] [--matrix] [--no-fallback]
simless test [Target/Class/method...]   unit tests on the Mac
simless calibrate [fixture]       compare renders with an iOS Simulator (boots one; run once per app)
simless status                    hosts, slots, live-reload availability
simless down [--all]              stop hosts (they relaunch in ~1 s on next use)
simless clean [--all]             remove this worktree's host, slot and build cache (--all: everything)
simless agent install             install SimlessAgent (live reload)
simless skill install             install the Claude Code skill
simless version                   version, Xcode and macOS
```

`--matrix` renders light and dark on `iphone`, `iphone-small` and `ipad`.

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
- Logic: `simless test <Target>/<Class>`. Use the simulator only for gestures, the real keyboard,
  system UI and Dynamic Type, which simless can't check.
- Compile errors from `simless reload` point at your file:line.
- A pass is strong evidence, not proof. Run `simless calibrate` once per app to see which screens match
  the simulator. Say what still needs a simulator.
```

## Cleanup is automatic

- **Deleted worktrees:** every command removes the host, slot and build cache of any worktree that no longer exists.
- **Idle hosts:** a host exits after 30 idle minutes (`hostIdleMinutes` in `.simless.json`).
- **Patches:** only the newest 3 are kept, and patch files are deleted as soon as they're loaded.
- **Compile cache:** the shared Xcode compilation cache is capped at 12 GB.
- **Generated files** next to your project are git-excluded and removed by `simless clean`.

## How far to trust results

**In short: simless is a fast, high-signal inner loop, not a replacement for a final simulator pass.** Run `simless calibrate` once per app to see how closely its renders match the iOS Simulator for your screens. Before calling a UI change done, check it once in the simulator, especially anything below that simless can't see.

### What a result means

| Check | When it fails | When it passes |
|---|---|---|
| `simless test` (unit tests) | A real failure in your logic, unless the test depends on something listed under "Unit tests" below | Your logic works in your real app process, against Apple's iOS frameworks |
| `simless render` (tree) | A wrong element, label or frame is usually real; confirm layout-sensitive findings with `simless calibrate` | Elements, text, labels, identifiers and relative layout are right **on this canvas** |
| Automatic issue checks | Usually real, but the Mac runtime can expose some controls differently (see below) | Only that none of the five checks fired. Not that the screen is correct |

### What simless does to stay accurate

- **Hot reload patches more than the edited files.** It also patches every view between your fixtures and the edit, so a parent view never renders a stale subview. Edits it can't trace safely, such as an extension of another type or a top-level function, fall back to a full build automatically.
- **Phone canvases get phone traits.** That means compact width, the phone idiom, and the device's safe areas (notch, home indicator). Every render prints the traits the view saw.
- **`simless calibrate` compares against a real simulator.** It renders every fixture on the Mac and in one iOS Simulator, and reports any element or frame that differs by more than 2 pt.

### Known differences from an iPhone

- **`UIDevice.current.userInterfaceIdiom` reports `.pad`.** That can't be overridden on the Mac, so code that reads it directly, rather than the trait collection, takes its iPad branch. Renders print a note about it.
- **Text can wrap differently.** Font metrics differ slightly between the Mac and iOS. In calibration, a two-line label came out 14 pt wider in simless. Treat exact line breaks and truncation as unverified until calibration shows they match.
- **Some controls are exposed differently to accessibility.** In calibration, a `Menu` with a custom label was unlabeled in simless but labeled on iOS, so simless reported an issue that isn't one on a phone. Confirm accessibility flags on `Menu` and other platform-backed controls with `simless calibrate`.
- **Text size:** Dynamic Type is ignored, so text that fits at the default size can still truncate at larger sizes.
- **Pixels:** rendering is close to, but not identical with, an iPhone. Use the simulator for final pixels.

### Unit tests

- **No capabilities.** Hosts run without app capabilities (iCloud/CloudKit, app groups, keychain sharing, push). Tests that need them can fail or take other code paths.
- **Mac behavior.** Some APIs behave differently when an iOS app runs on a Mac: `UIDevice`, file-system locations, the sandbox.
- **Last full build.** Tests run against the last full build, not against hot-reload patches. `simless test` warns when sources have changed since then.

### Not checked at all

Gestures and swipe actions, the software keyboard, navigation flows across screens, system UI (permissions, share sheets, StoreKit sheets) and Dynamic Type sizes.

### Other limits

- **Project types:** `.xcworkspace`, Tuist and pure Swift Package apps aren't supported yet. You need an `.xcodeproj` with an app-hosted unit-test target.
- **Side effects:** the host runs your app's real startup in the background. Guard analytics and network with `SimlessHost.isActive`.
- **Private APIs:** the render host relies on a few private, DEBUG-only Apple APIs (in-process accessibility automation, hiding the app, suppressing its windows). An OS update could break them; they never ship in release builds.

## How it works

See [docs/architecture.md](docs/architecture.md) for the design and [docs/findings.md](docs/findings.md) for the platform behavior it relies on. Benchmarks are reproducible with [bench/](bench/).

## License

Apache-2.0 ([LICENSE](LICENSE)), copyright 2026 Abacus.AI, Inc. The files in `Templates/` (the render-host kit, the fixtures template and the agent skill), which `simless init` and `simless skill install` copy into your app or machine, are licensed under [MIT No Attribution](LICENSES/MIT-0.txt), so you can ship them without notices. See [NOTICE](NOTICE).
