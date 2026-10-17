# Benchmarks

simless compared with the legacy workflow coding agents use today to check SwiftUI changes, on a real production app. Reproduce on your own app with [bench/](../bench/).

## Setup

| | |
|---|---|
| Machine | MacBook Pro, Apple M2 Pro (10 cores), 32 GB RAM |
| OS / Xcode | macOS 27.0.1, Xcode 27.0 |
| App | Production SwiftUI app: ~280 Swift files, ~150 views, SwiftData + CloudKit, several large Swift packages (incl. on-device ML) |
| Legacy | One iOS 27 simulator (iPhone 17 Pro) per agent. Edit → incremental `xcodebuild` → `simctl install` → `simctl launch` → 3 s settle → `simctl io screenshot` |
| simless | One host per agent. Edit → `simless reload --render <fixture>`. Live reload (SimlessAgent with Full Disk Access) |
| Agents | 1, 3 and 5 in parallel, each in its own git worktree, 3 edit cycles each |

Other workloads were stopped. While each scenario ran, the harness sampled memory in use, swap and load every second.

## Results

| Scenario | Legacy (simulator) | simless | |
|---|---|---|---|
| **Edit → verified screen**, 1 agent | 21.9 s | **2.2 s** | **10×** |
| **Edit → verified screen**, 3 agents in parallel | 28.0 s | **2.2 s** | **13×** |
| **Edit → verified screen**, 5 agents in parallel | 37.4 s (slowest 55.1 s) | **2.2 s** (slowest 8.2 s) | **17×** |
| **5 agents start cold** at once (fresh worktrees, empty caches), time to first verified screen per agent | 732 s median, 734 s slowest | **344 s** median, 437 s slowest | **2.1×** |
| Peak extra memory during that cold start | +12.4 GB | **+6.8 GB** | 1.8× |
| Peak load average (1 min) during that cold start | ~1,010 | **~82** | 12× |
| **Steady state, 5 agents:** private memory of everything kept running | 11.2 GB | **0.15 GB** | **~75×** |
| Steady state, 5 agents: processes | 1,071 | **6** | |
| **Unit tests**, 2 classes | 13.1 s (simulator already booted) | **5.6 s** (no simulator) | 2.3× |

All times are per cycle (or per agent) medians unless noted.

### What the numbers mean

- **The legacy loop gets slower with every agent you add, simless doesn't.** Legacy goes from 21.9 s to 37.4 s per edit as agents compete for CPU and their simulators compete for memory. simless stays at 2.2 s from 1 to 5 agents, because a reload compiles one file into a small patch instead of rebuilding and reinstalling the app.
- **Memory is the bigger difference.** Five booted simulators running the app held **11.2 GB** of private memory across 1,071 processes. Five simless hosts held **0.15 GB** (~30 MB each). On a 16 GB Mac the legacy setup is out of headroom before the agents compile anything.
- **Cold start is dominated by the full build in both cases.** simless still roughly halves it: no simulator boot, and at most two full builds at a time (`buildConcurrency`) instead of five fighting for ten cores. The load average stays usable (~82 vs ~1,010) while it happens.
- **What the agent reads is different too.** Legacy hands the agent a screenshot to interpret. simless hands it an accessibility tree (~150 tokens per screen) with deterministic issue checks, and a PNG only when asked.

### Caveats

- **The legacy loop has biases in both directions.** It waits a fixed 3 s and takes a screenshot, while real agents usually drive the UI with XCUITest or Maestro, which costs more per check. But it rebuilds with `build-for-testing`, which also compiles the test bundles, and an agent only checking a screen could use a plain `build`, which is somewhat faster.
- **One trial per scenario.** Each scenario ran once (3 edit cycles per agent), and the cold starts came from separate runs, so expect run-to-run variance. The scaling trend and the memory gap are far larger than that variance, individual ratios less so.
- **Only one kind of edit.** Every cycle changed code inside one view's body, the best case for hot reload. Edits a patch can't express (stored properties, signatures) fall back to a full build (~20–110 s on this app).
- **The first reload in a new worktree is slower** (~7 s) while that worktree's module cache is built. Every later reload took ~2 s.
- **One machine, one app.** Absolute numbers depend on app size and hardware, the scaling behaviour is the point.
- **Memory "in use" is noisy.** The system-wide increase over the idle baseline varied between runs (legacy 2.7–6.8 GB, simless 0.9–2.3 GB) because it includes shared and file-backed pages. The summed per-process footprint above is the stable measure.
- **simless can't replace the simulator for everything.** System UI it doesn't emulate (HealthKit and StoreKit sheets, pickers), the watch app and exact pixels still need a simulator. See [How far to trust results](../README.md#how-far-to-trust-results).

## Test suites

A second production app: about 2,280 unit tests in 41 targets (most in a local Swift package) and about 110 XCUITests, on a 10-core M-series Mac with 32 GB. The baseline is one fixed native run on an iPhone 17 simulator, iOS 26.5, with Xcode's parallel testing (5 simulator clones for the UI tests). simless results matched it test by test.

| | Simulator | simless |
|---|---|---|
| Unit tests, nothing built and empty caches (`simless clean --all`, then `up` and `test all`) | 116 s build + 375 s tests = 491 s | 140 s `up` + 333 s = **473 s** (494 s before slots installed side by side) |
| Unit tests, already built | 375 s | **327 to 390 s** |
| 20 named tests | 25.5 s | **about 1 s** |
| UI tests, about 105 on iPhone and 4 iPad-only ones on iPad | 1,150 s on 5 clones | **450 to 561 s** on 4 hidden hosts, no clones, no swap |
| 3 back-to-back runs on one commit, unit and UI (Xcode 27.1) | | **all 6 passed**, identical results, all 41 unit test targets and both UI targets present |
| 5 back-to-back runs on one commit, unit and UI (0.5.0) | | **all 10 passed**, with the same tests passing each time. 2 of them flagged tests as flaky that passed when run again alone: wall-clock races in the app's own tests, and one UI test that also failed once under load in an earlier version |
| Unit and UI runs in two worktrees at once | | **both passed**, no timeouts: unit in 405 s, UI in 866 s on half the Mac |

- **One target sets the floor.** Both unit rows are as long as the app's slowest test target, which gets a host to itself (about 310 to 330 s). Its slowest test does fuzzy word matching in a debug build, and the Mac's Swift runtime runs that code about twice as slow as the simulator's: the same test took 180 s for its slowest case as a plain macOS program built with the same flags. The rest of the suite is done in about 130 s.
- **Plain CPU work runs at the simulator's speed.** The demo app's `CPUBenchmarkTests` (sorting and hashing a large array, and matching words with typos, 8 cases each in parallel) take 9.5 to 10.0 s under simless and 8.5 to 11.9 s in an iPhone 17 simulator on iOS 26.5, a ratio of about 1.0.
- **Cold build.** The app build (which builds the package's test bundles too) takes 107 to 130 s, about the simulator's 116 s. The rest of `simless up` is installing the slots and starting the hosts.

## Reproducing

```sh
python3 -I bench/bench.py  bench/config.json --agents 1,3,5 --cycles 3
python3 -I bench/memory.py bench/config.json --agents 5
```

See [bench/README.md](../bench/README.md) for the config format.
