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


def capture(command, timeout):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_group(process)
        output, _ = process.communicate()
        return output.decode(errors="replace") + "\nEVIDENCE COLLECTION TIMED OUT\n"
    return output.decode(errors="replace")


def process_tree(root):
    rows = capture(["ps", "-axo", "pid=,ppid=,pgid=,stat=,etime=,comm="], 2)
    parsed = []
    for line in rows.splitlines():
        parts = line.strip().split(None, 5)
        if len(parts) == 6 and all(x.isdecimal() for x in parts[:3]):
            parsed.append((int(parts[0]), int(parts[1]), line))
    owned = {root}
    while True:
        added = {pid for pid, parent, _ in parsed if parent in owned}
        if added <= owned:
            break
        owned |= added
    return owned, "\n".join(line for pid, _, line in parsed if pid in owned) + "\n"


def collect(evidence, process, owned, budget):
    deadline = time.monotonic() + budget
    remaining = lambda: max(0.01, deadline - time.monotonic())
    current, rows = process_tree(process.pid)
    owned |= current
    (evidence / "processes.txt").write_text(rows)
    # One deepest observed child, rather than an unbounded stack walk.
    target = max(owned)
    if shutil.which("sample"):
        (evidence / "stack.txt").write_text(capture(["sample", str(target), "1"], remaining()))
    elif shutil.which("gdb"):
        (evidence / "stack.txt").write_text(capture(["gdb", "-p", str(target), "-batch", "-ex", "thread apply all bt"], remaining()))
    else:
        (evidence / "stack.txt").write_text("NOT AVAILABLE: no sample/gdb\n")
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
