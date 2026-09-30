# DecisionEvaluation

Shared Host-side evaluation with a real public `AgentJevProvider` consumer.
No AgentCore dependency, execution authority, new SDK product, Journal format,
automatic retry, vendor fallback or paid request in ordinary CI.

This implementation delivers common evaluation and Jev integration. Native
OpenAI Decisions remains **BLOCKED_PROTOCOL**, not an implemented provider.
See [public protocol findings](native-protocol.md). `openai-native-decisions`
is an explicit unsupported evaluation label, never an endpoint or fallback.
Ordinary Responses + Structured Outputs is not implemented as a substitute.

## Offline commands

From the repository root, with Python 3.10+ and Swift 6.4:

```sh
# No executable, credentials or network; no implicit live activation from env.
python3 Examples/DecisionEvaluation/evaluation.py \
  --provider jev --output /tmp/decision-dry-run-unique

# Real public SDK / URLSession, only a bounded loopback fixture.
swift build --package-path Examples/DecisionEvaluation
bin=$(swift build --package-path Examples/DecisionEvaluation --show-bin-path)
python3 -m unittest discover Examples/DecisionEvaluation -p 'test_*.py'
python3 Examples/DecisionEvaluation/evaluation.py \
  --mode fixture --provider jev --executable "$bin/DecisionEvalTrial" \
  --seed 73 --repetitions 2 --max-requests 48 --max-seconds 60 \
  --output /tmp/decision-http-fixture-unique
```

Output directories must be new: prior attempts are never overwritten. These
temporary directories are evaluation artifacts, not production Journal paths.
The CLI does not download URLs, read image paths, run OCR, or inspect keys in
dry-run/fixture mode. Media datasets are rejected before dispatch. This dataset
does not claim image evaluation or parity with native vision APIs.

`plan.json` freezes dataset/prompt version, SHA-256 of canonical dataset JSON,
seed, input, candidates, predeclared allowed answers, scoring, permutations,
repetitions and execution order. `trials.jsonl` writes and fsyncs a `started`
record before dispatch and then a paired `finished` record. `summary.json`
contains metrics and qualification labels. Original task IDs, exact candidate
identity, language, input byte length and question count are retained.

The versioned dataset uses synthetic English, Chinese and Japanese cases:
simple and nearby classes, negation, correction, unresolved conflict, missing
information, paraphrase and repetition. `clarify` is declared before execution,
not invented after seeing an answer. Each request has one Choice question.
Original and deterministic non-identity candidate permutations are repeated;
the complete plan is shuffled using the fixed seed. Dataset mutations change
the hash. Jev criteria are a keyed JSON object: ordered candidates are also
rendered in versioned instructions; object key order is not represented as a
service guarantee.

`(evaluationID, trialID)` identifies a record across attempts; the evaluation
UUID is separate from the deterministic plan. Mixed configurations and
duplicate completions fail read-only recovery. Planned repetitions are charged
new trials, not retries after an error. SIGTERM/Ctrl-C holds the local process
owner through reaping; an interrupted `started` record stays unknown.

## Result meaning

| Qualification | Evidence | This delivery's status |
| --- | --- | --- |
| Protocol / fixture | Actual Jev SDK over loopback and contract/safety tests | PASS after running tests |
| Real service/account eligibility | Not tested by a loopback service | NOT RUN |
| Real model quality / latency / cost | Not measured by an oracle | NOT RUN |
| Native OpenAI protocol | No authoritative native schema established | BLOCKED_PROTOCOL |

Fixture probabilities and usage are literal synthetic transport data. Fixture
accuracy is an oracle/runner consistency check, not a quality leaderboard.
There is no Jev/OpenAI speed or vision-quality conclusion.

Failure/timeout/unknown results stay in the registered trial denominator.
Unsupported labels have zero dispatched attempts and are not model errors.
The report separates registered trials, attempts, status rates, per-class
precision/recall, per-language accuracy, exact-repeat and order consistency.
Failure makes its repeat group inconsistent. Allowed answer sets are scored as
declared; ambiguous truths do not produce calibration targets.

Brier and ten-bin ECE use only *reported probabilities* with finite in-range
values, exact candidate membership and a sum within `1e-6`; this is an evaluator
eligibility rule, not a new Jev protocol constraint. It never normalizes data,
turns confidence into a probability, fills missing values, or promises
calibration. Jev's existing Noul/Choice/Score API and values are unchanged; this
first common dataset evaluates Choice only. Noul probability is not a boolean;
Score's expected value is not a discrete grade.

Successful p50/p95 show `n` and interpolate ordered samples. Latency begins at
the actual public SDK `decide` dispatch and ends after complete typed answer
validation, not first token; process/build overhead is excluded. Each trial
starts a new process and ephemeral URLSession. OS caches are uncontrolled;
there is no cold/hot connection comparison. Failures are excluded only from
successful latency quantiles, never silently from the trial denominator.
Jev has no distinct model-refusal result in this contract: `refusalRate` is
absent; HTTP permission denial is reported separately. Usage is only reported
when present; missing usage and all unverified monetary cost remain unknown.

## Live is explicit and conditional

This task did not authorize live requests. A Host with separate account,
data-export and billing authorization may explicitly run a finite batch. It
must supply provider, HTTPS endpoint, model, dataset, deployment label,
repetition count, request/token/time/USD caps, key environment name, consent,
and a reference to its independently established per-request token and cost
upper bounds. Bounds are **Host attestation**, not authenticated SDK pricing.
Do not use guessed numbers, model prices from another provider, or unknown
cost as zero. Without bounds the runner refuses before key access/dispatch.

```sh
# Template only. Replace bounds with authorized, independently verified values.
python3 Examples/DecisionEvaluation/evaluation.py --mode live --provider jev \
  --consent-live --endpoint "$AUTHORIZED_JEV_ENDPOINT" --model "$AUTHORIZED_MODEL" \
  --deployment authorized-test --dataset Examples/DecisionEvaluation/dataset-v1.json \
  --key-environment AUTHORIZED_TEST_API_KEY --executable "$bin/DecisionEvalTrial" \
  --repetitions 1 --max-requests 24 --max-tokens "$TOTAL_TOKEN_LIMIT" \
  --max-seconds 60 --max-usd "$TOTAL_USD_LIMIT" \
  --request-token-upper-bound "$VERIFIED_REQUEST_TOKEN_BOUND" \
  --request-usd-upper-bound "$VERIFIED_REQUEST_USD_BOUND" \
  --host-bound-reference authorized-pricing-v1 --output /tmp/decision-live-unique
```

Every attempt, including failure, early SDK refusal and uncertain receipt by
the server, consumes a reservation; no refund or automatic retry. The original
absolute Host time budget never resets. The SDK per-request deadline is capped
by remaining budget; the parent enforces the total deadline and ignores late
success. The SDK has no server-billing transaction or server token-output cap:
the runner cannot guarantee a hard fee limit if Host bounds are wrong, usage is
unknown, or the server continues after cancellation. The report deliberately
does not equate reservations with actual cost or claim a server-bill guarantee.

## Lifecycle and privacy

One owner holds/reaps each process. Cancellation/deadline retains ownership
until actual local exit; forced process termination is recorded as
`forced_reaped` with remote consumption unknown. It is not normal SDK physical
drain or proof the service stopped. The noncooperative loopback server retains
its own worker until released, with explicit entry/exit barriers. SDK transport
cancellation and late completion regressions also remain in AgentJevProvider
tests. Process isolation prevents a previous answer reaching the next trial.

Only a controlled result projection enters the ledger: exact selected
candidate, reported probabilities/confidence/usage, safe model identity and
stable status. Endpoint, key, arbitrary extensions, private error/body text,
request IDs and raw transport stderr are excluded. Model aliases and actual
returned model are separate; unsafe returned identity is explicitly redacted.
The dataset itself is public synthetic material; a Host changing it owns
authorization and privacy review. Local temporary process output is deleted.

Input is bounded to 64 KiB; dataset to 256 KiB, 100 tasks, 2–20 candidates,
8 KiB state; output and ledger records to 256 KiB. These are evaluator limits,
not native/vendor advertised limits. The inherited Jev URLSession transport
currently collects the HTTP response as Data: the runner's output limit does
**not** cap that transport allocation. This existing SDK limit remains a
separate concern, not disguised as native-provider completion.

Read-only recovery is `evaluation.read_trials(path)`: an orphan `started`
trial becomes `unknown`. Duplicate or unpaired records fail closed. There is
no resume/retry dispatch from a ledger. Exported evaluation JSONL is neither
an authorization record nor a recoverable Journal backup. SDK Evidence,
requiredAudit Host authorization, Receipt, intent, reconciliation and schema
3/4/5 stay on the ordinary execution path.

## Minimal Host integration

The compiling package-outside-SDK consumer is
[DecisionEvalTrial](Sources/DecisionEvalTrial/main.swift). Its integration uses:

```swift
import AgentDecisions
import AgentJevProvider
import AgentModels
import Foundation

func classify(endpoint: URL, hostKey: String) async throws -> DecisionResponse {
    let provider: any DecisionProvider = try JevDecisionProvider(
        apiKey: hostKey, endpoint: endpoint, model: "jev-latest")
    let request = try DecisionRequest(state: .string("Synthetic duplicate charge"),
        choices: ["route": try .init(criteria: [
            .init(name: "billing"), .init(name: "clarify")])],
        deadline: ContinuousClock.now.advanced(by: .seconds(10)))
    return try await provider.decide(request)
}
```

This result is advice. Host routing and policy select providers; later effects
must enter Agent/Session/Run, Evidence and enterprise authorization normally.
Even `allow`, `approve`, confidence 1 and forged approval/Receipt extensions
cannot create SDK authorization, an intent, Receipt or settlement.
