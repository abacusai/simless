#!/usr/bin/env python3
"""Steady-state memory for N agents: N booted simulators running the app (legacy)
vs N simless hosts. Run after bench.py, which leaves the legacy builds and the
simless slots in place.

    python3 -I bench/memory.py bench/config.json [--agents 5] [--settle 45]

Reported per side: the increase in system memory in use (active + wired +
compressed, includes shared/file-backed pages) over the idle baseline, the summed
physical footprint of the processes involved (private memory, as top's MEM), and
the process count.
"""
import json, os, re, subprocess, sys, time

C = json.load(open(sys.argv[1]))
args = sys.argv[2:]
N = int(args[args.index("--agents") + 1]) if "--agents" in args else 5
SETTLE = int(args[args.index("--settle") + 1]) if "--settle" in args else 45
WORK = os.path.expanduser("~/Library/Caches/simless-bench")

def out(cmd): return subprocess.run(cmd, capture_output=True, text=True).stdout
def run(cmd, cwd=None): subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def used_gb():
    vm = out(["vm_stat"]); page = int(re.search(r"page size of (\d+)", vm).group(1))
    p = lambda k: int(re.search(rf"{k}:\s+(\d+)", vm).group(1))
    return (p("Pages active") + p("Pages wired down") + p("Pages occupied by compressor")) * page / 2**30

def pids(pattern):
    found = []
    for l in out(["ps", "-axo", "pid=,command="]).splitlines():
        pid, _, cmd = l.strip().partition(" ")
        if re.search(pattern, cmd): found.append(pid)
    return found

def processes(pattern): return len(pids(pattern))

def footprint_gb(pattern):
    """Sum of per-process physical footprint (private memory, as top's MEM column)."""
    want = set(pids(pattern)); total = 0.0
    for l in out(["top", "-l", "1", "-stats", "pid,mem"]).splitlines():
        parts = l.split()
        if len(parts) == 2 and parts[0] in want:
            m = re.match(r"([\d.]+)([BKMG])", parts[1])
            if m: total += float(m.group(1)) * {"B": 1 / 2**30, "K": 1 / 2**20, "M": 1 / 2**10, "G": 1}[m.group(2)]
    return round(total, 2)

def worktree(i): return C["repo"] if i == 0 else f"{C['repo']}-agent{i}"

def settle_and_measure(base):
    time.sleep(SETTLE)
    return round(used_gb() - base, 2)

result = {"agents": N, "settle_s": SETTLE}

# legacy: N simulators, each with the app installed and running
base = used_gb()
udids = []
for i in range(N):
    udid = out(["xcrun", "simctl", "create", f"simless-mem-{i}", C["sim_device_type"],
                f"com.apple.CoreSimulator.SimRuntime.{C['sim_runtime']}"]).strip()
    udids.append(udid)
    run(["xcrun", "simctl", "boot", udid])
for i, udid in enumerate(udids):
    run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    app = f"{WORK}/legacy-dd-{os.path.basename(worktree(i))}/Build/Products/Debug-iphonesimulator/{C['app_name']}"
    run(["xcrun", "simctl", "install", udid, app])
    run(["xcrun", "simctl", "launch", udid, C["bundle_id"], *C["launch_args"]])
result["legacy_gb"] = settle_and_measure(base)
LEGACY = r"CoreSimulator/Devices|launchd_sim|simruntime|CoreSimulatorService"
result["legacy_processes"] = processes(LEGACY)
result["legacy_footprint_gb"] = footprint_gb(LEGACY)
for udid in udids:
    run(["xcrun", "simctl", "shutdown", udid]); run(["xcrun", "simctl", "delete", udid])
time.sleep(15)

# simless: N hosts (launched by their first render)
base = used_gb()
for i in range(N):
    run(["simless", "render", C["fixture"]], cwd=worktree(i))
result["simless_gb"] = settle_and_measure(base)
result["simless_processes"] = processes(r"Wrapper/.*\.app/")
result["simless_footprint_gb"] = footprint_gb(r"Wrapper/.*\.app/")
for i in range(N):
    run(["simless", "down"], cwd=worktree(i))

print(json.dumps(result, indent=2))
