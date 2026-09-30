#!/usr/bin/env python3
"""Bounded CI child owner. Product deadlines/drain are deliberately untouched."""
import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def terminate_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # A root can exit before a noncooperative descendant. Stop only its group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return process.wait()  # single owner reaps the actual child


def capture(command, timeout, outcome=None):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_group(process)
        output, _ = process.communicate()
        if outcome is not None:
            outcome.update(exitCode=process.returncode, timedOut=True)
        return output.decode(errors="replace") + "\nEVIDENCE COLLECTION TIMED OUT\n"
    if outcome is not None:
        outcome.update(exitCode=process.returncode, timedOut=False)
    return output.decode(errors="replace")


def process_rows(rows):
    parsed = {}
    for line in rows.splitlines():
        parts = line.strip().split(None, 9)
        if len(parts) == 10 and all(x.isdecimal() for x in parts[:3]):
            parsed[int(parts[0])] = dict(parent=int(parts[1]), group=int(parts[2]),
                state=parts[3], identity=(parts[1], parts[2], *parts[4:]), row=line)
    return parsed


def process_tree(root, timeout=2):
    # lstart plus parent/group/command distinguishes a reused PID in observations.
    rows = capture(["env", "LC_ALL=C", "ps", "-axo",
                    "pid=,ppid=,pgid=,stat=,lstart=,comm="], timeout)
    parsed = process_rows(rows)
    owned = {root}
    while True:
        added = {pid for pid, node in parsed.items() if node["parent"] in owned}
        if added <= owned:
            break
        owned |= added
    return owned, "\n".join(node["row"] for pid, node in parsed.items() if pid in owned) + "\n"


def sampling_targets(nodes, root):
    active = lambda node: not node["state"].startswith(("Z", "X"))
    if root not in nodes or not active(nodes[root]) or nodes[root]["group"] != root:
        return []
    depths = {root: 0}
    while True:
        added = {pid: depths[node["parent"]] + 1 for pid, node in nodes.items()
                 if pid not in depths and node["parent"] in depths}
        if not added:
            break
        depths.update(added)
    children = [pid for pid in depths if pid != root and active(nodes[pid])]
    # PID breaks equal-depth ties only; ancestry determines depth.
    children.sort(key=lambda pid: (-depths[pid], pid))
    return [root, *children[:2]]


def collect(evidence, process, owned, budget):
    deadline = time.monotonic() + budget
    remaining = lambda: max(0, deadline - time.monotonic())
    current, rows = process_tree(process.pid, min(2, remaining()))
    owned |= current
    (evidence / "processes.txt").write_text(rows)
    nodes = process_rows(rows)
    targets = sampling_targets(nodes, process.pid)
    debugger = shutil.which("sample") or shutil.which("gdb")
    results, stacks = [], []
    for index, target in enumerate(targets):
        result = dict(pid=target, observedIdentity=nodes[target]["identity"])
        results.append(result)
        if not debugger:
            result["status"] = "unavailable_no_debugger"
            continue
        if process.poll() is not None:
            result["status"] = "unavailable_owner_exited"
            continue
        if remaining() <= 0:
            result["status"] = "unavailable_budget_exhausted"
            continue
        live, live_rows = process_tree(process.pid, min(2, remaining()))
        owned |= live
        live_nodes = process_rows(live_rows)
        if target not in live_nodes or live_nodes[target]["state"].startswith(("Z", "X")):
            result["status"] = "unavailable_target_exited"
            continue
        if (process.poll() is not None or process.pid not in live_nodes
                or live_nodes[process.pid]["identity"] != nodes[process.pid]["identity"]
                or live_nodes[target]["identity"] != nodes[target]["identity"]):
            result["status"] = "unavailable_identity_changed"
            continue
        if remaining() <= 0:
            result["status"] = "unavailable_budget_exhausted"
            continue
        allowance = remaining() / (len(targets) - index)
        command = ([debugger, str(target), "1"] if Path(debugger).name == "sample" else
                   [debugger, "-p", str(target), "-batch", "-ex", "thread apply all bt"])
        text = None
        try:
            text = capture(command, allowance, result)
            result["status"] = "timeout" if result["timedOut"] else "sampled" if result["exitCode"] == 0 else "failed"
        except OSError as error:
            result.update(status="failed_launch", errno=error.errno)
        # External debuggers attach by PID. Recheck and label an exit/reuse race;
        # this is best-effort diagnostics, not an atomic process identity claim.
        if remaining() > 0:
            live, after_rows = process_tree(process.pid, min(2, remaining()))
            owned |= live
            after = process_rows(after_rows)
            result["postCheck"] = ("same_observed_identity" if process.poll() is None
                and process.pid in after and after[process.pid]["identity"] == nodes[process.pid]["identity"]
                and target in after and after[target]["identity"] == nodes[target]["identity"]
                else "exited_or_identity_changed_during_sampling")
            if result["postCheck"] != "same_observed_identity":
                result["captureStatus"] = result["status"]
                result["status"] = "unavailable_identity_race"
        else:
            result["postCheck"] = "unavailable_budget_exhausted"
        if text is not None:
            stacks.append(f"PID {target}: {result['status']}\n{text}")
    (evidence / "sampling.json").write_text(json.dumps(dict(
        budgetSeconds=budget, targets=results, status="attempted" if targets else "unavailable_no_active_owned_tree"), indent=2) + "\n")
    (evidence / "stack.txt").write_text("\n".join(stacks) or "NOT AVAILABLE: see sampling.json\n")
    return owned


@contextmanager
def owned_child(command, log):
    child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        yield child
    finally:
        if child.poll() is None:
            terminate_group(child)


def run(args):
    root = Path(__file__).resolve().parent.parent
    base = Path(args.log_dir or os.environ.get("SWIFT_AGENT_CI_STAGE_LOG_DIR", str(root / ".ci-logs/stages")))
    base.mkdir(parents=True, exist_ok=True)
    label = "".join(c if c.isalnum() or c in "-_" else "_" for c in args.stage)[:80]
    evidence = Path(tempfile.mkdtemp(prefix=label + "-", dir=base))
    metadata = {
        "stage": args.stage, "command": args.command,
        "sourceCommitSHA": capture(["git", "rev-parse", "HEAD"], 2).strip(),
        "sourceTreeSHA": capture(["git", "rev-parse", "HEAD^{tree}"], 2).strip(),
        "unverifiedWorkspaceChanges": bool(capture(["git", "status", "--porcelain"], 2).strip()),
        "toolchain": capture(["swift", "--version"], 5).strip(),
        "platform": sys.platform, "runID": os.environ.get("GITHUB_RUN_ID"),
        "attempt": os.environ.get("GITHUB_RUN_ATTEMPT"), "timeoutSeconds": args.timeout,
        "coreLimit": capture(["sh", "-c", "ulimit -c"], 2).strip(),
    }
    output = evidence / "output.log"
    started = time.monotonic()
    deadline = started + args.timeout
    stopped = None
    with output.open("wb") as log, owned_child(args.command, log) as child:
        metadata["pid"] = child.pid
        owned = {child.pid}
        cancelled = []
        old_handlers = {}
        for sig in (signal.SIGTERM, signal.SIGINT):
            old_handlers[sig] = signal.signal(sig, lambda number, frame: cancelled.append(number))
        try:
            print(f"CI STAGE {args.stage}: PID={child.pid} evidence={evidence}", flush=True)
            (evidence / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
            next_observation = started
            while child.poll() is None:
                now = time.monotonic()
                if now >= next_observation:
                    observed, rows = process_tree(child.pid)
                    owned |= observed
                    (evidence / "processes-last-observed.txt").write_text(rows)
                    with (evidence / "process-observations.jsonl").open("a") as observations:
                        observations.write(json.dumps({"elapsedSeconds": now - started, "tree": rows}) + "\n")
                    next_observation = now + 2
                if cancelled or now >= deadline:
                    stopped = "cancelled" if cancelled else "timeout"
                    owned = collect(evidence, child, owned, args.evidence_timeout)
                    terminate_group(child)
                    break
                # Waiting is in this dedicated CI process, not a Swift cooperative thread.
                try:
                    child.wait(timeout=min(0.25, max(0.01, deadline - time.monotonic())))
                except subprocess.TimeoutExpired:
                    pass
            code = child.wait()
        finally:
            if child.poll() is None:
                terminate_group(child)
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
    metadata.update(durationSeconds=time.monotonic() - started, childExitCode=code,
                    result=stopped or ("pass" if code == 0 else "fail"), observedPIDs=sorted(owned))
    # Buffered output can only establish the last observed test, not the current one.
    with output.open("rb") as log:
        log.seek(max(0, output.stat().st_size - 16384))
        tail = log.read().decode(errors="replace")
    metadata["lastObservedTestLines"] = [line for line in tail.splitlines() if "Test " in line or "Test Case " in line][-10:]
    metadata["crashIndicators"] = [line for line in tail.splitlines() if any(marker in line for marker in
        ("Segmentation fault", "SIGSEGV", "signal 11", "unexpected signal code"))][-10:]
    if code < 0 or code > 128 or metadata["crashIndicators"]:
        if shutil.which("coredumpctl"):
            # Only this attempt's observed children; never copy unrelated crash reports.
            until = time.monotonic() + args.evidence_timeout
            for pid in sorted(owned):
                if time.monotonic() >= until:
                    break
                (evidence / f"core-{pid}.txt").write_text(capture(["coredumpctl", "info", str(pid), "--no-pager"], max(0.01, until - time.monotonic())))
        else:
            (evidence / "core-unavailable.txt").write_text("No coredumpctl; stack/core may be unavailable. No historical root cause inferred.\n")
    exit_code = 124 if stopped == "timeout" else 130 if stopped == "cancelled" else code if code >= 0 else 128 - code
    metadata["exitCode"] = exit_code
    (evidence / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    # Replay complete output after exit; evidence remains even if a job stops early.
    with output.open("rb") as log:
        shutil.copyfileobj(log, sys.stdout.buffer)
    print(f"CI STAGE END {args.stage}: result={metadata['result']} exit={exit_code} seconds={metadata['durationSeconds']:.3f}", flush=True)
    return exit_code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True)
    parser.add_argument("--log-dir")
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("SWIFT_AGENT_CI_CASE_TIMEOUT_SECONDS", 1200)))
    parser.add_argument("--evidence-timeout", type=float, default=10)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command or not math.isfinite(args.timeout) or not math.isfinite(args.evidence_timeout) or args.timeout <= 0 or args.evidence_timeout <= 0:
        parser.error("a command and positive finite limits are required")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
