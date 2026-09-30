"""Host-side evaluation, not an SDK executor or authorization source.

Only public, synthetic dataset fields and controlled result projections enter
the ledger. No raw transport diagnostics, endpoints, credentials or media.
"""
import argparse
import hashlib
import json
import math
import os
import random
import re
import signal
import subprocess
import tempfile
import time
import uuid
from collections import Counter
from decimal import Decimal
from pathlib import Path


class SafeFailure(Exception):
    """SDK/runner-owned fixed diagnostics only."""


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def data_hash(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def identity(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,96}", value) is not None


def load_dataset(path):
    if path.stat().st_size > 256 * 1024:
        raise SafeFailure("dataset_too_large")
    d = json.loads(path.read_text())
    if d.get("schema") != 1 or not identity(d.get("version")) or not identity(d.get("promptVersion")):
        raise SafeFailure("invalid_dataset")
    tasks = d.get("tasks", [])
    seen = set()
    if not 1 <= len(tasks) <= 100:
        raise SafeFailure("invalid_dataset")
    for t in tasks:
        if not identity(t.get("id")) or t["id"] in seen or t.get("language") not in ("en", "zh", "ja"):
            raise SafeFailure("invalid_task")
        seen.add(t["id"])
        if t.get("modality") != "text" or t.get("kind") != "choice":
            raise SafeFailure("unsupported_dataset_modality_or_question")
        if not isinstance(t.get("input"), str) or len(t["input"].encode()) > 8192:
            raise SafeFailure("invalid_task")
        candidates = t.get("candidates", [])
        names = [c.get("id") for c in candidates]
        if not 2 <= len(names) <= 20 or not all(identity(n) for n in names) or len(set(names)) != len(names):
            raise SafeFailure("invalid_candidates")
        if not all(isinstance(c.get("description"), str) and len(c["description"].encode()) <= 2048 for c in candidates):
            raise SafeFailure("invalid_candidates")
        if not t.get("allowed") or not set(t["allowed"]) <= set(names) or t.get("scoring") != "exact_allowed":
            raise SafeFailure("invalid_scoring")
    if not isinstance(d.get("instructions"), str) or len(d["instructions"].encode()) > 8192:
        raise SafeFailure("invalid_prompt")
    return d


def plan(dataset, repetitions, seed):
    if not 1 <= repetitions <= 20:
        raise SafeFailure("invalid_repetitions")
    rng = random.Random(seed)
    trials = []
    for t in dataset["tasks"]:
        for variant in ("original", "permuted"):
            task = dict(t)
            task["candidates"] = list(t["candidates"])
            if variant == "permuted":
                # A deterministic non-identity permutation, independent of answers.
                offset = rng.randrange(1, len(task["candidates"]))
                task["candidates"] = task["candidates"][offset:] + task["candidates"][:offset]
            task["repeatGroup"] = t["id"] + "." + variant
            for rep in range(repetitions):
                trials.append(dict(trialID=f'{t["id"]}.{variant}.{rep}', task=task,
                                   variant=variant, repetition=rep))
    rng.shuffle(trials)
    return trials


class Budget:
    def __init__(self, requests, tokens, seconds, usd, per_request_tokens, per_request_usd, clock=time.monotonic):
        if not isinstance(requests, int) or not 1 <= requests <= 4000 or not isinstance(tokens, int) or tokens <= 0:
            raise SafeFailure("invalid_budget")
        if not math.isfinite(seconds) or seconds <= 0 or not math.isfinite(usd) or usd <= 0:
            raise SafeFailure("invalid_budget")
        self.requests, self.tokens, self.usd = requests, tokens, Decimal(str(usd))
        self.token_bound = per_request_tokens
        self.cost_bound = None if per_request_usd is None else Decimal(str(per_request_usd))
        self.clock = clock
        self.deadline = clock() + seconds
        self.used = self.reserved_tokens = 0
        self.reserved_usd = 0.0
        self._usd = Decimal(0)

    def remaining(self):
        return max(0, self.deadline - self.clock())

    def reserve(self, live):
        if self.used >= self.requests or self.remaining() <= 0:
            raise SafeFailure("budget_exhausted")
        if live:
            if (not isinstance(self.token_bound, int) or self.token_bound <= 0 or
                    self.cost_bound is None or not self.cost_bound.is_finite() or self.cost_bound <= 0):
                raise SafeFailure("unknown_request_upper_bound")
            if self.reserved_tokens + self.token_bound > self.tokens or self._usd + self.cost_bound > self.usd:
                raise SafeFailure("budget_exhausted")
            self.reserved_tokens += self.token_bound
            self._usd += self.cost_bound
            self.reserved_usd = float(self._usd)
        self.used += 1


def append_record(path, record):
    with path.open("a", encoding="utf8") as f:
        f.write(canonical(record) + "\n")
        f.flush()
        os.fsync(f.fileno())


def read_trials(path):
    """Read-only recovery. An unfinished dispatch remains unknown, never resend."""
    starts, finishes = {}, {}
    scope = None
    with path.open() as f:
        while True:
            line = f.readline(256 * 1024 + 1)
            if not line:
                break
            if len(line) > 256 * 1024:
                raise SafeFailure("oversize_ledger_record")
            try:
                row = json.loads(line)
                tid = row["trialID"]
                if row["event"] == "started" and tid not in starts:
                    candidate_scope = tuple(row.get(k) for k in ("evaluationID", "datasetHash", "provider", "deployment"))
                    if scope is not None and candidate_scope != scope:
                        raise SafeFailure("ledger_configuration_mismatch")
                    scope = candidate_scope
                    starts[tid] = row
                elif row["event"] == "finished" and tid in starts and tid not in finishes:
                    if row.get("evaluationID") != starts[tid].get("evaluationID"):
                        raise SafeFailure("ledger_configuration_mismatch")
                    finishes[tid] = row
                else:
                    raise SafeFailure("duplicate_or_unpaired_ledger_record")
            except (ValueError, KeyError):
                raise SafeFailure("invalid_ledger") from None
    return [dict(start, **finishes.get(tid, {"status": "unknown"})) for tid, start in starts.items()]


def percentile(values, percentile):
    values = sorted(values)
    at = (len(values) - 1) * percentile
    lo, hi = math.floor(at), math.ceil(at)
    return values[lo] + (values[hi] - values[lo]) * (at - lo)


def summarize(trials, mode):
    correct = 0
    latencies, briers, calibration_samples = [], [], []
    repeats, classes, languages, orders = {}, {}, {}, {}
    tokens = 0
    usage_n = 0
    for r in trials:
        t = r["task"]
        success = r["status"] == "success"
        chosen = r.get("selected") if success else None
        right = success and chosen in t["allowed"]
        correct += int(right)
        lang = languages.setdefault(t.get("language", "unspecified"), {"trials": 0, "correct": 0})
        lang["trials"] += 1
        lang["correct"] += int(right)
        orders.setdefault(t["id"], []).append(chosen)
        if success:
            latencies.append(r["latencyMs"])
        if len(t["allowed"]) == 1:
            expected = t["allowed"][0]
            c = classes.setdefault(expected, {"expected": 0, "truePositive": 0, "predicted": 0})
            c["expected"] += 1
            c["truePositive"] += int(right)
            if chosen is not None:
                classes.setdefault(chosen, {"expected": 0, "truePositive": 0, "predicted": 0})["predicted"] += 1
            p = r.get("probabilities")
            names = {x["id"] for x in t["candidates"]}
            # No normalization, no use of generated confidence as probability.
            if success and isinstance(p, dict) and set(p) == names and all(
                    isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1 for v in p.values()
            ) and abs(sum(p.values()) - 1) <= 1e-6:
                briers.append(sum((p[n] - int(n == expected)) ** 2 for n in names))
                calibration_samples.append((max(p.values()), int(max(p, key=p.get) == expected)))
        repeats.setdefault(t.get("repeatGroup", t["id"]), []).append(chosen)
        u = r.get("usage")
        if u is not None:
            tokens += u["inputTokens"] + u["outputTokens"]
            usage_n += 1
    for c in classes.values():
        c["recall"] = c["truePositive"] / c["expected"] if c["expected"] else None
        c["precision"] = c["truePositive"] / c["predicted"] if c["predicted"] else None
    for lang in languages.values():
        lang["accuracy"] = lang["correct"] / lang["trials"]
    groups = [v for v in repeats.values() if len(v) >= 2]
    ece = None
    if calibration_samples:
        ece = 0
        for bucket in range(10):
            samples = [(p, a) for p, a in calibration_samples if min(9, int(p * 10)) == bucket]
            if samples:
                ece += len(samples) / len(calibration_samples) * abs(
                    sum(p for p, _ in samples) / len(samples) - sum(a for _, a in samples) / len(samples))
    statuses = Counter(r["status"] for r in trials)
    dispatched = sum(n for s, n in statuses.items() if s not in ("dry_run", "unsupported", "budget_exhausted"))
    return dict(schema=1, mode=mode, totalTrials=len(trials), attempts=dispatched, correct=correct,
                accuracy=correct / len(trials) if trials else None, perClass=classes, perLanguage=languages, statuses=dict(statuses),
                failureRate=(dispatched - statuses["success"]) / dispatched if dispatched else None,
                timeoutRate=(statuses["timeout"] + statuses["deadline_exceeded"]) / dispatched if dispatched else None,
                refusalRate=None, refusalAvailability="Jev has no distinct model-refusal result in this contract",
                permissionDeniedRate=statuses["permission_denied"] / dispatched if dispatched else None,
                latencySuccessful=dict(n=len(latencies), p50Ms=percentile(latencies, .5) if latencies else None,
                                       p95Ms=percentile(latencies, .95) if latencies else None),
                repeatConsistency=dict(groups=len(groups), consistentGroups=sum(None not in v and len(set(v)) == 1 for v in groups)),
                candidateOrderConsistency=dict(tasks=len(orders), consistentTasks=sum(None not in v and len(set(v)) == 1 for v in orders.values())),
                calibration=dict(n=len(briers), meanBrier=sum(briers) / len(briers) if briers else None, ece10=ece,
                                 source="provider_reported_probabilities; not a calibration guarantee"),
                usage=dict(observedTrials=usage_n, observedTokens=tokens if usage_n else None,
                           unreportedTrials=dispatched - usage_n), actualCostUSD=None,
                qualityQualification="LIVE_DATA" if mode == "live" else "NOT_RUN")


def result_view(value, payload):
    statuses = ("success", "authentication", "permission_denied", "invalid_request", "rate_limited",
                "unavailable", "transport", "invalid_response", "deadline_exceeded", "cancelled", "invalid_configuration")
    if not isinstance(value, dict) or value.get("status") not in statuses:
        raise ValueError()
    if value["status"] != "success":
        return dict(status=value["status"])  # Never reflect error text or extensions.
    names = {c["id"] for c in payload["candidates"]}
    latency = value.get("latencyMs")
    if value.get("selected") not in names or not isinstance(latency, (float, int)) or not math.isfinite(latency) or latency < 0:
        raise ValueError()
    view = dict(status="success", selected=value["selected"], latencyMs=latency,
                actualModel=value.get("actualModel") if identity(value.get("actualModel")) else "redacted",
                actualModelRedacted=bool(value.get("actualModelRedacted")) or not identity(value.get("actualModel")),
                providerAdapter="jev", valueSource="provider_reported", protocolVersion="systemone-existing-sdk")
    for name in ("confidence", "probabilities", "usage"):
        x = value.get(name)
        if x is None:
            continue  # Missing is absent, never synthesize zero or a distribution.
        if name == "confidence" and (isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) or not 0 <= x <= 1):
            raise ValueError()
        if name == "probabilities" and (not isinstance(x, dict) or set(x) != names or not all(
                isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1 for v in x.values())):
            raise ValueError()
        if name == "usage":
            if not isinstance(x, dict) or set(x) != {"inputTokens", "outputTokens"} or not all(type(v) is int and v >= 0 for v in x.values()):
                raise ValueError()
        view[name] = x
    return view


def run_child(executable, payload, deadline, clock=time.monotonic):
    """One owner reaps each attempt. A killed process is an unknown remote effect.

    Temp pipes are bounded by observation, not a server response-body size limit.
    Process isolation prevents a late output from contaminating the next trial.
    """
    if clock() >= deadline:
        return dict(status="timeout", remoteConsumption="not_dispatched", physicalExit="not_started")
    with tempfile.TemporaryFile() as inp, tempfile.TemporaryFile() as out:
        inp.write(canonical(payload).encode()); inp.seek(0)
        child = subprocess.Popen([str(executable)], stdin=inp, stdout=out, stderr=subprocess.DEVNULL,
                                 start_new_session=True, env={k: v for k, v in os.environ.items()
                                 if k in ("PATH", "TMPDIR", "HOME", payload.get("keyEnvironment", ""))})
        outcome = None
        try:
            while child.poll() is None:
                if os.fstat(out.fileno()).st_size > 256 * 1024:
                    outcome = "output_limit"; break
                remaining = deadline - clock()
                if remaining <= 0:
                    outcome = "timeout"; break
                try:
                    child.wait(timeout=min(.05, remaining))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if child.poll() is None:
                # Only this owned session. Keep owner until actual wait/reap.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass  # Exit raced cancellation; the same owner still reaps.
                child.wait()
        if outcome:
            return dict(status=outcome, remoteConsumption="unknown", physicalExit="forced_reaped")
        if clock() >= deadline:
            return dict(status="timeout", remoteConsumption="unknown", physicalExit="exited_late_result_ignored")
        out.seek(0)
        body = out.read(256 * 1024 + 1)
        if len(body) > 256 * 1024 or child.returncode != 0:
            return dict(status="process_failure", remoteConsumption="unknown")
        try:
            return result_view(json.loads(body), payload)
        except (ValueError, KeyError, TypeError):
            return dict(status="invalid_response", remoteConsumption="unknown")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Synthetic Decision evaluation. Dry-run is the default.")
    parser.add_argument("--mode", choices=["dry-run", "fixture", "live"], default="dry-run")
    parser.add_argument("--provider", choices=["jev", "openai-native-decisions"], required=True)
    parser.add_argument("--dataset", type=Path, default=Path(__file__).with_name("dataset-v1.json"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--model")
    parser.add_argument("--endpoint")
    parser.add_argument("--deployment", default="local-fixture")
    parser.add_argument("--key-environment")
    parser.add_argument("--consent-live", action="store_true")
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--repetitions", type=int, default=2)
    parser.add_argument("--max-requests", type=int, default=200)
    parser.add_argument("--max-tokens", type=int, default=20000)
    parser.add_argument("--max-seconds", type=float, default=60)
    parser.add_argument("--max-usd", type=float, default=.1)
    parser.add_argument("--request-token-upper-bound", type=int)
    parser.add_argument("--request-usd-upper-bound", type=float)
    parser.add_argument("--host-bound-reference")
    args = parser.parse_args(argv)
    if not identity(args.deployment) or (args.model is not None and not identity(args.model)):
        raise SafeFailure("invalid_deployment_label")
    dataset = load_dataset(args.dataset)
    trials = plan(dataset, args.repetitions, args.seed)
    # No endpoint/model is guessed for an undocumented protocol.
    if args.mode == "live":
        if args.provider != "jev":
            raise SafeFailure("native_protocol_unavailable")
        if not (args.consent_live and args.endpoint and args.model and args.key_environment and
                identity(args.host_bound_reference) and args.deployment != "local-fixture"):
            raise SafeFailure("explicit_live_configuration_required")
        probe = Budget(args.max_requests, args.max_tokens, args.max_seconds, args.max_usd,
                       args.request_token_upper_bound, args.request_usd_upper_bound)
        probe.reserve(live=True)  # Validate before mkdir, transport or reading a key.
    if args.mode != "dry-run" and args.provider == "jev" and (args.executable is None or not args.executable.is_file()):
        raise SafeFailure("build_public_sdk_trial_first")
    args.output.mkdir(parents=True, exist_ok=False)  # Never overwrite another attempt.
    config = dict(schema=1, datasetVersion=dataset["version"], datasetHash=data_hash(dataset),
                  evaluationID=str(uuid.uuid4()),
                  promptVersion=dataset["promptVersion"], seed=args.seed, provider=args.provider,
                  mode=args.mode, deployment=args.deployment, requestedModel=(args.model if args.mode == "live" else "fixture-jev") if args.provider == "jev" else None,
                  endpoint="host_supplied_redacted" if args.mode == "live" else "none_or_loopback",
                  questionCountPerRequest=1, concurrency=1, connection="new process and ephemeral URLSession per trial; OS cache uncontrolled",
                  criteriaAdaptation="Jev keyed criteria object; ordered list additionally rendered in versioned instructions",
                  costBoundSource=args.host_bound_reference, costBoundVerifiedBySDK=False)
    (args.output / "plan.json").write_text(canonical(dict(configuration=config, trials=trials)) + "\n")
    budget = Budget(args.max_requests, args.max_tokens, args.max_seconds, args.max_usd,
                    args.request_token_upper_bound, args.request_usd_upper_bound)
    from contextlib import nullcontext
    if args.mode == "fixture" and args.provider == "jev":
        from http_fixture import FixtureServer
        context = FixtureServer()
    else:
        context = nullcontext(None)
    records = []
    ledger = args.output / "trials.jsonl"
    with context as server:
        for trial in trials:
            started = dict(event="started", **trial, evaluationID=config["evaluationID"], datasetHash=config["datasetHash"], provider=args.provider,
                           requestedModel=config["requestedModel"], deployment=args.deployment,
                           inputUTF8Bytes=len(trial["task"]["input"].encode()),
                           candidateCount=len(trial["task"]["candidates"]), questionCount=1)
            if args.provider != "jev":
                result = dict(status="unsupported", reasonCode="native_protocol_unavailable")
            elif args.mode == "dry-run":
                result = dict(status="dry_run")
            else:
                try:
                    budget.reserve(live=args.mode == "live")
                except SafeFailure:
                    result = dict(status="budget_exhausted")
                else:
                    # Durable start precedes dispatch. Failed/unknown attempts stay reserved.
                    append_record(ledger, started)
                    t = trial["task"]
                    payload = dict(mode=args.mode, endpoint=server.endpoint if server else args.endpoint,
                                   model=config["requestedModel"], keyEnvironment=args.key_environment,
                                   timeoutSeconds=min(10, budget.remaining()), state=t["input"],
                                   candidates=t["candidates"], instructions=dataset["instructions"],
                                   promptVersion=dataset["promptVersion"])
                    result = run_child(args.executable.resolve(), payload, budget.deadline)
                    append_record(ledger, dict(event="finished", evaluationID=config["evaluationID"], trialID=trial["trialID"], **result))
                    records.append(dict(started, **result))
                    continue
            append_record(ledger, started)
            append_record(ledger, dict(event="finished", evaluationID=config["evaluationID"], trialID=trial["trialID"], **result))
            records.append(dict(started, **result))
    summary = summarize(records, args.mode)
    summary["configuration"] = config
    summary["budget"] = dict(reservedRequests=budget.used, reservedTokens=budget.reserved_tokens,
                             reservedUSD=budget.reserved_usd, serverBillGuarantee=False,
                             note="Host-attested bounds only; SDK cannot authenticate pricing or remote consumption. Unknown cost remains unknown.")
    summary["protocolQualification"] = "FIXTURE_DATA" if args.mode == "fixture" and args.provider == "jev" else "NOT_RUN"
    summary["serviceQualification"] = "LIVE_DATA" if args.mode == "live" else "NOT_RUN"
    (args.output / "summary.json").write_text(canonical(summary) + "\n")
    print(canonical(summary))
    return 0


if __name__ == "__main__":
    def cancel_owned_work(_signal, _frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, cancel_owned_work)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except (SafeFailure, OSError, ValueError, KeyError):
        raise SystemExit("Decision evaluation failed closed; inspect configuration without publishing secrets.") from None
