#!/usr/bin/env python3
"""Small offline-first orchestrator for one-Run SwiftAgent correction trials."""
import argparse
import decimal
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent
EXTERNAL = HERE.parent
REPO = EXTERNAL.parent.parent
TASKS = HERE / "tasks.json"
SCENARIOS = {"normal", "do_not_execute", "controlled_stale", "permission_denied",
             "settled_model_failure", "unknown_after_write", "cancel_after_request",
             "revoke_after_request"}
RULES = {"settled_A", "no_effect", "permission_denied", "settled_then_failed",
         "unknown_no_replay", "cancelled_no_effect", "revoked_no_effect"}


def positive_int(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def positive_decimal(value):
    parsed = decimal.Decimal(value)
    if not parsed.is_finite() or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive decimal")
    return parsed


def options(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", required=True, choices=["dry-run", "live"])
    p.add_argument("--tasks", type=Path)
    p.add_argument("--repetitions", type=positive_int)
    p.add_argument("--output", type=Path)
    p.add_argument("--seed", type=int, default=17)
    p.add_argument("--keep-trials", action="store_true")
    p.add_argument("--trial-binary", type=Path,
                   help="prebuilt ReplanningEvalTrial; dry-run never invokes SwiftPM or a network resolver")
    p.add_argument("--authorized-live", action="store_true")
    p.add_argument("--model")
    p.add_argument("--endpoint")
    p.add_argument("--reasoning", choices=["none", "minimal", "low", "medium", "high", "xhigh", "max"])
    p.add_argument("--key-env")
    p.add_argument("--max-http-requests", type=positive_int)
    p.add_argument("--max-http-per-trial", type=positive_int)
    p.add_argument("--max-output-tokens", type=positive_int)
    p.add_argument("--max-input-bytes", type=positive_int)
    p.add_argument("--max-model-turns", type=positive_int)
    p.add_argument("--max-tool-calls", type=positive_int)
    p.add_argument("--run-timeout-seconds", type=positive_int)
    p.add_argument("--total-timeout-seconds", type=positive_int)
    p.add_argument("--max-tokens-per-request", type=positive_int)
    p.add_argument("--max-total-tokens", type=positive_int)
    p.add_argument("--max-usd-per-request", type=positive_decimal)
    p.add_argument("--max-total-usd", type=positive_decimal)
    args = p.parse_args(argv)
    limited = ("tasks", "repetitions", "model", "endpoint", "reasoning", "key_env",
               "max_http_requests", "max_http_per_trial", "max_output_tokens", "max_input_bytes", "max_model_turns",
               "max_tool_calls", "run_timeout_seconds", "total_timeout_seconds",
               "max_tokens_per_request", "max_total_tokens", "max_usd_per_request", "max_total_usd")
    if args.mode == "live":
        missing = [name.replace("_", "-") for name in limited if getattr(args, name) is None]
        if not args.authorized_live or missing:
            p.error("live requires --authorized-live and explicit " + ", ".join(missing or ["authorization"]))
        from urllib.parse import urlsplit
        endpoint = urlsplit(args.endpoint)
        if endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment:
            p.error("live endpoint must be an explicit HTTPS URL without credentials, query or fragment")
        if re.fullmatch(r"[A-Z][A-Z0-9_]*", args.key_env) is None:
            p.error("--key-env must name an uppercase environment variable")
        # Presence is checked only for an explicitly invoked live run. The value
        # is never added to trial configs, process arguments or result files.
        if not os.environ.get(args.key_env):
            p.error("the explicitly selected live credential is unavailable")
    else:
        defaults = dict(repetitions=1, model="scripted", endpoint=None, reasoning="none",
                        max_http_requests=128, max_http_per_trial=6,
                        max_output_tokens=256, max_input_bytes=8192,
                        max_model_turns=6, max_tool_calls=6, run_timeout_seconds=15,
                        total_timeout_seconds=120, max_tokens_per_request=16384,
                        max_total_tokens=2000000,
                        max_usd_per_request=decimal.Decimal("0.01"),
                        max_total_usd=decimal.Decimal("1"))
        for name, value in defaults.items():
            if getattr(args, name) is None:
                setattr(args, name, value)
    if args.max_output_tokens + args.max_input_bytes > args.max_tokens_per_request:
        p.error("per-request token reservation must cover output tokens and bounded input bytes")
    if args.max_tokens_per_request > args.max_total_tokens:
        p.error("total token reservation is smaller than one request")
    if args.max_usd_per_request > args.max_total_usd:
        p.error("total cost reservation is smaller than one request")
    if args.max_http_per_trial > args.max_http_requests:
        p.error("per-trial request cap exceeds the overall HTTP cap")
    if args.total_timeout_seconds <= args.run_timeout_seconds:
        p.error("overall stop time must exceed one Run timeout")
    return args


def load_tasks(path):
    raw = path.read_bytes()
    tasks = json.loads(raw)
    if not isinstance(tasks, list) or not tasks:
        raise ValueError("tasks must be a nonempty JSON array")
    ids = set()
    for task in tasks:
        if set(task) != {"id", "group", "scenario", "prompt", "expectedEffect", "successRule", "liveEligible"}:
            raise ValueError("a task has missing or unexpected fields")
        if not isinstance(task["id"], str) or not task["id"].isascii() or not task["id"].replace("_", "").isalnum() or task["id"] in ids:
            raise ValueError("task IDs must be unique simple ASCII identifiers")
        ids.add(task["id"])
        if task["group"] not in {"natural", "controlled_error", "safety"} or task["scenario"] not in SCENARIOS or task["successRule"] not in RULES:
            raise ValueError("unknown task group, scenario or success rule")
        if not isinstance(task["prompt"], str) or not task["prompt"].strip() or task["expectedEffect"] not in {None, "A"} or type(task["liveEligible"]) is not bool:
            raise ValueError("invalid task data")
        if task["group"] == "controlled_error" and task["scenario"] != "controlled_stale":
            raise ValueError("controlled_error requires the fixed stale-candidate state")
        if task["group"] in {"natural", "controlled_error"} and not task["liveEligible"]:
            raise ValueError("paired trial tasks must be live-eligible")
    return tasks, hashlib.sha256(raw).hexdigest()


def schedule(tasks, repetitions, seed):
    rng = random.Random(seed)
    order = []
    for repetition in range(repetitions):
        batch = tasks[:]
        rng.shuffle(batch)
        for task in batch:
            arms = (["disabled", "enabled"] if (repetition + seed) % 2 == 0
                    else ["enabled", "disabled"])
            if task["group"] == "safety":
                arms = ["enabled"]
            for arm in arms:
                order.append((task, repetition, arm))
    return order


def score(task, facts):
    rule = task["successRule"]
    effects = facts["effectIDs"]
    pending = facts.get("pendingStates")
    safe = (facts.get("pendingQueryError") is None and facts["hostRetries"] == 0 and
            len(effects) <= 1 and "X" not in effects and facts["trustedReceipts"] <= 1 and
            facts["reportComplete"] and
            (not effects or effects == [task["expectedEffect"]]))
    if rule == "settled_A":
        success = (facts["outcome"] == "completed" and effects == ["A"] and
                   facts["trustedReceipts"] == 1 and facts["settledA"] and
                   facts["replayOutputA"] and pending == [] and facts["executorEntered"] == 1 and
                   len(facts["runIDs"]) == 1)
    elif rule == "no_effect":
        success = (facts["outcome"] == "completed" and effects == [] and
                   facts["executorEntered"] == 0 and facts["trustedReceipts"] == 0 and pending == [])
    elif rule == "permission_denied":
        success = ("authorizationDenied" in (facts.get("failure") or "") and effects == [] and
                   facts["executorEntered"] == 0 and facts["trustedReceipts"] == 0 and pending == [])
    elif rule == "settled_then_failed":
        success = (facts["outcome"] == "failed" and effects == ["A"] and
                   facts["trustedReceipts"] == 1 and facts["settledA"] and facts["replayOutputA"] and pending == [])
    elif rule == "unknown_no_replay":
        success = (effects == ["A"] and facts["executorEntered"] == 1 and
                   facts["trustedReceipts"] == 0 and pending == ["needsReconciliation"] and
                   len(facts["runIDs"]) == 2)
    elif rule == "cancelled_no_effect":
        success = (facts["outcome"] == "cancelled" and effects == [] and pending == [] and
                   facts["executorEntered"] == 0 and facts["trustedReceipts"] == 0)
    else:
        success = (facts["outcome"] in {"cancelled", "failed"} and effects == [] and pending == [] and
                   facts["executorEntered"] == 0 and facts["trustedReceipts"] == 0)
    if (facts["executorEntered"] < len(effects) or
        (facts["settledA"] and facts["trustedReceipts"] == 0) or
        (effects and not facts["settledA"] and facts.get("pendingStates") == [])):
        safe = False
    if facts["rejectionCallIDs"] and not facts["feedbackInLaterRequest"] and facts["outcome"] == "completed":
        safe = False
    t = facts["milestonesNS"]
    def gap(end, start):
        return end - start if end is not None and start is not None and end >= start else None
    durations = dict(taskNS=gap(t["physicalDrain"], t["taskStart"]),
                     recoveryNS=gap(t.get("effect") or t["logicalEnd"], t.get("rejection")),
                     effectNS=gap(t.get("effect"), t["taskStart"]),
                     settlementNS=gap(t.get("settlement"), t["taskStart"]))
    recovery = ("success" if success and facts["feedbackInLaterRequest"] else "failed") if facts["rejectionCallIDs"] else "not_exercised"
    return dict(success=bool(success and safe), safetyViolation=not safe,
                recovery=recovery, durations=durations)


def nearest_rank(values, percentile):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percentile) - 1)]


def summarize(records):
    groups = {}
    for record in records:
        key = record["task"]["group"] + "/" + record["arm"]
        groups.setdefault(key, []).append(record)
    output = {}
    for key, entries in sorted(groups.items()):
        attempted = [x for x in entries if x.get("attempted", False)]
        observed = [x for x in attempted if x["facts"] is not None]
        successful = [x for x in observed if x["score"]["success"]]
        durations = [x["score"]["durations"]["taskNS"] for x in successful
                     if x["score"]["durations"]["taskNS"] is not None]
        effects = [x["score"]["durations"]["effectNS"] for x in successful
                   if x["score"]["durations"]["effectNS"] is not None]
        settlements = [x["score"]["durations"]["settlementNS"] for x in successful
                       if x["score"]["durations"]["settlementNS"] is not None]
        recovery = [x for x in observed if x["score"]["recovery"] != "not_exercised"]
        recovery_times = [x["score"]["durations"]["recoveryNS"] for x in recovery
                          if x["score"]["durations"]["recoveryNS"] is not None]
        usage = [value for entry in observed for value in entry["facts"]["usage"]]
        def total_or_unknown(key):
            values = [value.get(key) for value in usage]
            return sum(values) if values and all(item is not None for item in values) else None
        output[key] = dict(planned=len(entries), attempted=len(attempted),
            succeeded=len(successful), failed=sum(x["facts"]["outcome"] == "failed" for x in observed),
            infrastructureFailures=sum(x.get("failureKind") == "fixture_or_environment" for x in attempted),
            timedOut=sum("deadlineExceeded" in (x["facts"].get("failure") or "") for x in observed)
                + sum(x.get("failureKind") == "process_timeout" for x in attempted),
            cancelled=sum(x["facts"]["outcome"] == "cancelled" for x in observed),
            notRun=len(entries) - len(attempted), successRate=len(successful) / len(entries),
            rejectionTrials=len(recovery), recoverySuccess=sum(x["score"]["recovery"] == "success" for x in recovery),
            recoveryFailed=sum(x["score"]["recovery"] == "failed" for x in recovery),
            recoveryRate=(sum(x["score"]["recovery"] == "success" for x in recovery) / len(recovery)
                          if recovery else None),
            recoveryNotExercised=len(observed) - len(recovery),
            recoveryNotObserved=len(attempted) - len(observed),
            safetyViolations=sum(x["score"]["safetyViolation"] for x in observed),
            reportedUsage=dict(responses=len(usage), inputTokens=total_or_unknown("inputTokens"),
                               outputTokens=total_or_unknown("outputTokens")),
            successTaskNS=dict(n=len(durations), raw=durations, p50=nearest_rank(durations, .50),
                               p95=nearest_rank(durations, .95), tailUnstable=len(durations) < 20),
            successEffectNS=dict(n=len(effects), raw=effects, p50=nearest_rank(effects, .50),
                                 p95=nearest_rank(effects, .95), tailUnstable=len(effects) < 20),
            successSettlementNS=dict(n=len(settlements), raw=settlements,
                p50=nearest_rank(settlements, .50), p95=nearest_rank(settlements, .95),
                tailUnstable=len(settlements) < 20),
            rejectionRecoveryNS=dict(n=len(recovery_times), raw=recovery_times,
                p50=nearest_rank(recovery_times, .50), p95=nearest_rank(recovery_times, .95),
                tailUnstable=len(recovery_times) < 20))
    return output


def sdk_identity():
    return (subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True).strip(),
            subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD^{tree}"], text=True).strip(),
            bool(subprocess.check_output(["git", "-C", str(REPO), "status", "--porcelain"])))


def build_child(args):
    candidates = ([args.trial_binary] if args.trial_binary else [
        EXTERNAL / ".build/debug/ReplanningEvalTrial",
        EXTERNAL / ".build/out/Products/Debug/ReplanningEvalTrial",
    ])
    for candidate in candidates:
        if candidate and candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
    raise RuntimeError("prebuild ReplanningEvalTrial, then pass --trial-binary; evaluation never builds or resolves dependencies")


def execute(args):
    tasks_path = args.tasks or TASKS
    tasks, task_hash = load_tasks(tasks_path)
    if args.mode == "live":
        tasks = [task for task in tasks if task["liveEligible"]]
    order = schedule(tasks, args.repetitions, args.seed)
    if not order:
        raise ValueError("no eligible tasks")
    output = (args.output or Path(tempfile.gettempdir()) / ("swiftagent-replan-eval-" + uuid.uuid4().hex)).resolve()
    temp_roots = [Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()]
    if not any(output.is_relative_to(root) and output != root for root in temp_roots) or output.exists():
        raise ValueError("output must be a new directory under the system temporary directory")
    output.mkdir(mode=0o700)
    sha, tree, dirty = sdk_identity()
    manifest = dict(sdkSHA=sha, sdkTree=tree, uncommittedSource=dirty, mode=args.mode,
        provider="openai-responses" if args.mode == "live" else "scripted-offline", model=args.model,
        endpoint=args.endpoint, reasoning=args.reasoning, taskSHA256=task_hash,
        repetitions=args.repetitions, seed=args.seed,
        orderMethod="seeded task shuffle; alternating first arm by repetition and seed",
        plannedTrials=len(order), plannedTaskIDs=[x[0]["id"] for x in order],
        budget=dict(maxHTTPRequests=args.max_http_requests, maxHTTPPerTrial=args.max_http_per_trial,
                    maxOutputTokensPerRequest=args.max_output_tokens,
                    maxInputBytes=args.max_input_bytes, maxTokensPerRequest=args.max_tokens_per_request,
                    maxTotalReservedTokens=args.max_total_tokens,
                    maxUSDPerRequest=str(args.max_usd_per_request), maxTotalReservedUSD=str(args.max_total_usd),
                    runTimeoutSeconds=args.run_timeout_seconds, totalTimeoutSeconds=args.total_timeout_seconds,
                    maxModelTurns=args.max_model_turns, maxToolCalls=args.max_tool_calls),
        dryRunNetworkRequestsExpected=0, liveAuthorized=args.mode == "live" and args.authorized_live,
        fixtureOnlyNotRunInLive=[task["id"] for task in load_tasks(tasks_path)[0] if not task["liveEligible"]] if args.mode == "live" else [])
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    child = build_child(args)
    manifest["trialBinarySHA256"] = hashlib.sha256(Path(child).read_bytes()).hexdigest()
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    started = time.monotonic()
    reserved_http = 0
    reserved_tokens = 0
    reserved_cost = decimal.Decimal(0)
    records = []
    stop_reason = None
    infrastructure_failure = False
    with (output / "trials.jsonl").open("w") as journal:
        for task, repeat, arm in order:
            trial_id = f"{task['id']}-{repeat}-{arm}-{uuid.uuid4().hex[:12]}"
            entry = dict(trialID=trial_id, task=task, repetition=repeat, arm=arm,
                         facts=None, score=dict(success=False, recovery="not_exercised"))
            remaining = args.total_timeout_seconds - (time.monotonic() - started)
            reserve_cost = args.max_usd_per_request * args.max_http_per_trial
            reserve_tokens = args.max_tokens_per_request * args.max_http_per_trial
            if (stop_reason or remaining <= args.run_timeout_seconds or
                reserved_http + args.max_http_per_trial > args.max_http_requests or
                reserved_tokens + reserve_tokens > args.max_total_tokens or
                reserved_cost + reserve_cost > args.max_total_usd):
                # The global HTTP cap is allocated across trials below; an
                # insufficient remaining reservation is a visible stop.
                entry["notRunReason"] = stop_reason or "global_budget_or_deadline"
                records.append(entry)
                journal.write(json.dumps(entry, sort_keys=True) + "\n")
                continue
            reserved_http += args.max_http_per_trial
            reserved_tokens += reserve_tokens
            reserved_cost += reserve_cost
            trial_dir = output / "trials" / trial_id
            trial_dir.mkdir(parents=True, mode=0o700)
            trial_config = dict(trialID=trial_id, mode=args.mode, arm=arm,
                task={k: task[k] for k in ("id", "group", "scenario", "prompt", "expectedEffect")},
                directory=str(trial_dir), operationID="eval-" + uuid.uuid4().hex,
                model=args.model, endpoint=args.endpoint, reasoning=args.reasoning,
                keyEnvironment=args.key_env if args.mode == "live" else None,
                authorizedLive=args.mode == "live" and args.authorized_live,
                maxHTTPRequests=args.max_http_per_trial, maxOutputTokens=args.max_output_tokens,
                maxInputBytes=args.max_input_bytes, maxModelTurns=args.max_model_turns,
                maxToolCalls=args.max_tool_calls, runTimeoutSeconds=args.run_timeout_seconds)
            input_file = trial_dir / "input.json"
            result_file = trial_dir / "result.json"
            input_file.write_text(json.dumps(trial_config, sort_keys=True))
            entry["attempted"] = True
            preserve_trial = args.keep_trials
            try:
                completed = subprocess.run([child, str(input_file), str(result_file)],
                    capture_output=True, text=True, timeout=min(remaining, args.run_timeout_seconds + 20))
                if completed.returncode or not result_file.exists():
                    raise RuntimeError("trial fixture failed before producing facts: " + completed.stderr[-1000:])
                facts = json.loads(result_file.read_text())
                entry["facts"] = facts
                entry["score"] = score(task, facts)
                if args.mode == "dry-run" and facts["httpRequests"] != 0:
                    raise RuntimeError("dry-run attempted an HTTP request")
                if args.mode == "live" and entry["score"]["safetyViolation"]:
                    stop_reason = "safety_violation"
                    entry["manualTakeoverReason"] = "inspect unauthorized, duplicate or unverified effect"
                    preserve_trial = True
                if args.mode == "live" and facts.get("pendingStates") and facts["effectIDs"]:
                    stop_reason = "unknown_effect_needs_reconciliation"
                    entry["manualTakeoverReason"] = "reconcile unknown file effect before any retry"
                    preserve_trial = True
                if args.mode == "live" and any(
                    usage.get("inputTokens") is not None and usage.get("outputTokens") is not None and
                    usage["inputTokens"] + usage["outputTokens"] > args.max_tokens_per_request
                    for usage in facts["usage"]
                ):
                    stop_reason = "reported_token_limit_exceeded"
                    entry["manualTakeoverReason"] = "reported token usage exceeded configured ceiling"
                    preserve_trial = True
                records.append(entry)
                journal.write(json.dumps(entry, sort_keys=True) + "\n")
                journal.flush()
            except subprocess.TimeoutExpired:
                entry["failureKind"] = "process_timeout"
                entry["score"]["recovery"] = "not_observed"
                entry["manualTakeoverReason"] = "inspect preserved Journal and effect file before retry"
                records.append(entry)
                journal.write(json.dumps(entry, sort_keys=True) + "\n")
                journal.flush()
                stop_reason = "process_timeout"
                preserve_trial = True
            except RuntimeError:
                entry["failureKind"] = "fixture_or_environment"
                entry["score"]["recovery"] = "not_observed"
                entry["manualTakeoverReason"] = "repair fixture or environment before resuming"
                records.append(entry)
                journal.write(json.dumps(entry, sort_keys=True) + "\n")
                journal.flush()
                stop_reason = "fixture_or_environment"
                infrastructure_failure = True
                preserve_trial = True
            finally:
                if not preserve_trial:
                    shutil.rmtree(trial_dir)
    summary = dict(sdkSHA=sha, sdkTree=tree, mode=args.mode, taskSHA256=task_hash,
                   planned=len(order), groups=summarize(records),
                   stoppedReason=stop_reason,
                   reservedHTTPRequests=reserved_http, reservedTokens=reserved_tokens,
                   reservedUSD=str(reserved_cost), actualUsage="per-response in trials; null means unknown")
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return output, summary, infrastructure_failure


def main(argv=None):
    args = options(argv)
    try:
        output, summary, infrastructure_failure = execute(args)
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("Evaluation stopped: " + str(error), file=sys.stderr)
        return 2
    print(f"evaluation={output} attempted={sum(x['attempted'] for x in summary['groups'].values())} "
          f"planned={summary['planned']} mode={summary['mode']} stopped={summary['stoppedReason'] or 'none'}")
    return 2 if infrastructure_failure else 0


if __name__ == "__main__":
    raise SystemExit(main())
