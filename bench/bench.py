#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Abacus.AI, Inc.
"""Benchmark simless against the legacy simulator workflow on your own app.

The legacy loop is what coding agents do today to check a SwiftUI change: an
incremental `xcodebuild` for an iOS Simulator, `simctl install`, `simctl launch`,
wait for the UI, then `simctl io screenshot` for the agent to inspect. One
simulator per agent. The simless loop is `simless reload --render <fixture>`.

Both loops make the same source edit. It is a lower bound for legacy: real
agents usually drive the UI with XCUITest or Maestro, which adds more time.

    python3 -I bench/bench.py bench/config.json [--agents 1,3,5] [--cycles 3] [--skip-legacy] [--skip-simless]

config.json (all paths absolute):
{
  "repo": "/path/to/app-clone",          # a throwaway clone: worktrees are created next to it
  "project": "App.xcodeproj", "scheme": "App",
  "bundle_id": "com.example.app",
  "app_name": "App.app",
  "sim_device_type": "iPhone 17 Pro",    # simctl device type name
  "sim_runtime": "iOS-26-5",             # suffix of com.apple.CoreSimulator.SimRuntime.*
  "launch_args": ["--some-seed"],        # put the app on the screen the fixture shows
  "settle_seconds": 3,                   # legacy: wait after launch before screenshot
  "edit_file": "App/Views/Foo.swift",    # relative to repo
  "edit_pattern": "VStack\\(spacing: \\d+\\)",
  "edit_template": "VStack(spacing: {n})",
  "fixture": "Foo.empty",
  "tests": ["AppTests/SomeTests"]
}

The repo must already be set up for simless (`simless init`, fixtures registered,
committed). Results are printed and written to bench/results-<timestamp>.json.
"""
import concurrent.futures as cf
import json, os, re, shutil, statistics, subprocess, sys, threading, time

# ---------------------------------------------------------------- helpers

def run(cmd, cwd=None, log=None, check=True):
    with open(log or os.devnull, "a") as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f if log else subprocess.DEVNULL, stderr=subprocess.STDOUT)
    if check and r.returncode != 0:
        raise RuntimeError(f"failed ({r.returncode}): {' '.join(cmd)}" + (f" — see {log}" if log else ""))
    return r.returncode

def out(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def timed(fn, *a, **k):
    t = time.perf_counter(); fn(*a, **k); return time.perf_counter() - t

ENV = dict(os.environ)
if "CommandLineTools" in out(["xcode-select", "-p"]) and os.path.exists("/Applications/Xcode.app"):
    ENV["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
os.environ.update(ENV)

class Sampler(threading.Thread):
    """System memory in use (active + wired + compressed), swap and load, every second."""
    def __init__(self):
        super().__init__(daemon=True); self.samples = []; self.stop = False
    @staticmethod
    def used_gb():
        vm = out(["vm_stat"]); page = int(re.search(r"page size of (\d+)", vm).group(1))
        pages = lambda k: int(re.search(rf"{k}:\s+(\d+)", vm).group(1))
        return (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * page / 2**30
    @staticmethod
    def swap_gb():
        m = re.search(r"used = ([\d.]+)M", out(["sysctl", "vm.swapusage"])); return float(m.group(1)) / 1024 if m else 0
    @staticmethod
    def load1():
        return float(out(["sysctl", "-n", "vm.loadavg"]).split()[1])
    def run(self):
        while not self.stop:
            self.samples.append((time.time(), self.used_gb(), self.swap_gb(), self.load1())); time.sleep(1)
    def summary(self, baseline):
        if not self.samples: return {}
        return {"peak_mem_gb": round(max(s[1] for s in self.samples) - baseline["mem"], 2),
                "peak_swap_gb": round(max(s[2] for s in self.samples) - baseline["swap"], 2),
                "peak_load1": round(max(s[3] for s in self.samples), 1)}

def measure(label, fn):
    base = {"mem": Sampler.used_gb(), "swap": Sampler.swap_gb()}
    s = Sampler(); s.start(); t = time.perf_counter()
    try:
        result = fn()
    finally:
        s.stop = True; s.join()
    r = {"wall_s": round(time.perf_counter() - t, 1), **s.summary(base), **(result or {})}
    print(f"  {label}: {r}", flush=True)
    return r

def stats(xs):
    xs = sorted(xs)
    return {"median_s": round(statistics.median(xs), 1), "max_s": round(xs[-1], 1), "n": len(xs)}

# ---------------------------------------------------------------- setup

C = json.load(open(sys.argv[1]))
args = sys.argv[2:]
AGENTS = [int(x) for x in (args[args.index("--agents") + 1] if "--agents" in args else "1,3,5").split(",")]
CYCLES = int(args[args.index("--cycles") + 1]) if "--cycles" in args else 3
WORK = os.path.expanduser("~/Library/Caches/simless-bench")
os.makedirs(WORK, exist_ok=True)
LOG = f"{WORK}/bench.log"

def worktree(i):
    """Agent i's worktree (agent 0 is the repo itself)."""
    if i == 0: return C["repo"]
    path = f"{C['repo']}-agent{i}"
    if not os.path.exists(path):
        run(["git", "-C", C["repo"], "worktree", "add", "--detach", path, "HEAD"], log=LOG)
    return path

def edit(wt, n):
    p = os.path.join(wt, C["edit_file"])
    s = open(p).read()
    s2, k = re.subn(C["edit_pattern"], C["edit_template"].replace("{n}", str(n)), s, count=1)
    assert k == 1, f"edit_pattern not found in {p}"
    open(p, "w").write(s2)

def reset(wt):
    run(["git", "-C", wt, "checkout", "--", C["edit_file"]], log=LOG)

# ---------------------------------------------------------------- legacy (simulator)

def sim_create(i):
    name = f"simless-bench-{i}"
    for line in out(["xcrun", "simctl", "list", "devices"]).splitlines():
        if name + " (" in line:
            return re.search(r"\(([0-9A-F-]{36})\)", line).group(1)
    return out(["xcrun", "simctl", "create", name, C["sim_device_type"],
                f"com.apple.CoreSimulator.SimRuntime.{C['sim_runtime']}"]).strip()

def sims_cleanup():
    for line in out(["xcrun", "simctl", "list", "devices"]).splitlines():
        m = re.search(r"simless-bench-\d+ \(([0-9A-F-]{36})\)", line)
        if m:
            run(["xcrun", "simctl", "shutdown", m.group(1)], check=False)
            run(["xcrun", "simctl", "delete", m.group(1)], check=False)

def legacy_dd(wt): return f"{WORK}/legacy-dd-{os.path.basename(wt)}"

def legacy_build(wt, udid):
    run(["xcodebuild", "build-for-testing", "-project", C["project"], "-scheme", C["scheme"],
         "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", legacy_dd(wt),
         "-skipMacroValidation", "-skipPackagePluginValidation"], cwd=wt, log=f"{WORK}/legacy-build-{os.path.basename(wt)}.log")

def legacy_check(wt, udid, shot):
    """Build → install → launch → settle → screenshot: one 'verify the screen' step."""
    legacy_build(wt, udid)
    app = f"{legacy_dd(wt)}/Build/Products/Debug-iphonesimulator/{C['app_name']}"
    run(["xcrun", "simctl", "install", udid, app], log=LOG)
    run(["xcrun", "simctl", "terminate", udid, C["bundle_id"]], log=LOG, check=False)
    run(["xcrun", "simctl", "launch", udid, C["bundle_id"], *C["launch_args"]], log=LOG)
    time.sleep(C.get("settle_seconds", 3))
    run(["xcrun", "simctl", "io", udid, "screenshot", shot], log=LOG)

def legacy_cold(i):
    """New agent: fresh DerivedData, new simulator boot, first screen check."""
    wt = worktree(i); udid = sim_create(i)
    shutil.rmtree(legacy_dd(wt), ignore_errors=True)
    t = time.perf_counter()
    run(["xcrun", "simctl", "boot", udid], log=LOG, check=False)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], log=LOG)
    legacy_check(wt, udid, f"{WORK}/legacy-{i}-cold.png")
    return time.perf_counter() - t

def legacy_cycles(i):
    wt = worktree(i); udid = sim_create(i); times = []
    for c in range(CYCLES):
        edit(wt, 20 + 4 * c + i)
        times.append(timed(legacy_check, wt, udid, f"{WORK}/legacy-{i}-{c}.png"))
    reset(wt)
    return times

def legacy_tests(wt, udid):
    return timed(run, ["xcodebuild", "test-without-building", "-project", C["project"], "-scheme", C["scheme"],
                       "-destination", f"platform=iOS Simulator,id={udid}", "-derivedDataPath", legacy_dd(wt),
                       "-parallel-testing-enabled", "NO"] + [f"-only-testing:{t}" for t in C["tests"]],
                 cwd=wt, log=f"{WORK}/legacy-test.log")

# ---------------------------------------------------------------- simless

def sl(wt, *a, log=None):
    return run(["simless", *a], cwd=wt, log=log or f"{WORK}/simless-{os.path.basename(wt)}.log")

def simless_cold(i):
    wt = worktree(i)
    run(["simless", "clean"], cwd=wt, log=LOG, check=False)
    return timed(sl, wt, "up")

def simless_cycles(i):
    wt = worktree(i); times = []
    for c in range(CYCLES):
        edit(wt, 20 + 4 * c + i)
        times.append(timed(sl, wt, "reload", "--render", C["fixture"]))
    reset(wt)
    return times

# ---------------------------------------------------------------- scenarios

def parallel(fn, n):
    with cf.ThreadPoolExecutor(n) as ex:
        return list(ex.map(fn, range(n)))

results = {"config": {k: C[k] for k in ("sim_device_type", "sim_runtime", "settle_seconds")},
           "machine": {"model": out(["sysctl", "-n", "hw.model"]).strip(),
                       "cores": int(out(["sysctl", "-n", "hw.ncpu"])),
                       "mem_gb": int(out(["sysctl", "-n", "hw.memsize"])) // 2**30,
                       "xcode": out(["xcodebuild", "-version"]).split("\n")[0]},
           "cycles": CYCLES}
n_max = max(AGENTS)
try:
    if "--skip-legacy" not in args:
        print("legacy (simulator):", flush=True)
        results["legacy_cold"] = measure(f"{n_max} agents start cold in parallel",
                                         lambda: {"per_agent": stats(parallel(legacy_cold, n_max))})
        for n in AGENTS:
            results[f"legacy_loop_{n}"] = measure(f"{n} agent(s) × {CYCLES} edit→verify",
                                                  lambda n=n: {"per_cycle": stats(sum(parallel(legacy_cycles, n), []))})
        results["legacy_tests"] = measure("unit tests", lambda: {"s": round(legacy_tests(C["repo"], sim_create(0)), 1)})
        sims_cleanup()
    if "--skip-simless" not in args:
        print("simless:", flush=True)
        results["simless_cold"] = measure(f"{n_max} agents start cold in parallel",
                                          lambda: {"per_agent": stats(parallel(simless_cold, n_max))})
        for n in AGENTS:
            results[f"simless_loop_{n}"] = measure(f"{n} agent(s) × {CYCLES} edit→verify",
                                                   lambda n=n: {"per_cycle": stats(sum(parallel(simless_cycles, n), []))})
        results["simless_tests"] = measure("unit tests", lambda: {"s": round(timed(sl, C["repo"], "test", *C["tests"]), 1)})
finally:
    sims_cleanup()
    for i in range(n_max):
        run(["simless", "down"], cwd=worktree(i), log=LOG, check=False)

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"results-{time.strftime('%Y%m%d-%H%M%S')}.json")
json.dump(results, open(path, "w"), indent=2)
print(f"\nwrote {path}")
