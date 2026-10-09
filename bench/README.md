# Benchmarks

`bench.py` compares simless with the legacy workflow coding agents use today to check a SwiftUI change:

| | Legacy (simulator) | simless |
|---|---|---|
| Agent starts on a fresh worktree | fresh DerivedData, boot a new simulator, build, install, launch, screenshot | `simless up` |
| Edit → verified screen | incremental `xcodebuild` (simulator), `simctl install`, `simctl launch`, settle, `simctl io screenshot` | `simless reload --render <fixture>` |
| Unit tests | `xcodebuild test-without-building` on the simulator | `simless test` |

Each scenario runs with 1, 3 and 5 agents in parallel, one git worktree each, with one simulator per agent for legacy. While a scenario runs, the harness samples memory in use (active + wired + compressed), swap and the 1-minute load average every second.

The legacy loop is a **lower bound**: it waits a fixed settle time and takes a screenshot. Real agents usually drive the UI with XCUITest or Maestro, which costs more.

## Running

1. Clone your app somewhere disposable. Worktrees are created next to it.
2. Run `simless init` there, register the fixture you'll measure, and commit.
3. Copy the config template from the top of `bench.py` to `bench/config.json` and fill it in.
4. Run:

```sh
python3 -I bench/bench.py bench/config.json --agents 1,3,5 --cycles 3
```

Results print as they finish and are written to `bench/results-<timestamp>.json`. After that, `python3 -I bench/memory.py bench/config.json --agents 5` measures steady-state memory (N booted simulators running the app vs N simless hosts). Close other simulator or Xcode workloads first, and expect the legacy part to load the machine heavily. That load is what's being measured.
