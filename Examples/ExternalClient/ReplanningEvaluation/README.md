# Bounded replanning evaluation

This package-external runner uses the final SDK Session/Run path, generic
offline read tools, a temporary-file mutation and a new schema-4 Journal for
**each** trial. It never connects to MusicKit, a player, mail or a production
Host. It tests whether a real model, if explicitly authorized, uses runtime
feedback; the existing `BoundedReplanningProbe` remains the deterministic
mechanism regression.

Run the no-network suite first:

```sh
swift build --package-path Examples/ExternalClient --product ReplanningEvalTrial
python3 Examples/ExternalClient/ReplanningEvaluation/run.py --mode dry-run
python3 -m unittest discover Examples/ExternalClient/ReplanningEvaluation -p 'test_*.py'
```

Build is a separate preparation step and may need Swift package dependencies.
The dry-run command itself uses an existing binary and makes no network
request or dependency resolution. Use `--trial-binary /absolute/path/to/ReplanningEvalTrial`
when the binary is outside the package's usual build directory.

The first command prints a new result directory beneath the system temporary
directory. `manifest.json` fixes the SDK SHA/tree, task-file SHA-256, seed,
interleaved order and budget **before** trial execution. `trials.jsonl` retains
every planned trial, including failures, cancellations and stopped trials;
`summary.json` has separate natural, controlled-error and safety groups. Trial
stores and effect files are deleted only after a completed, safe trial unless
`--keep-trials` is supplied. A process timeout, fixture fault or safety
violation preserves the corresponding directory for inspection. The runner
never deletes a pre-existing output directory.

The committed [task set](tasks.json) fixes success rules in advance. Natural
trials do not steer the model toward an error: one requires an actual A write
and settled Receipt/output, and one explicitly forbids a write. The controlled
task lists X in test data but signs Evidence only for A/B. The real model may
choose A immediately; that trial counts toward overall task success and is
`not_exercised` for post-rejection recovery. If it proposes X, only the SDK's
real Evidence check can produce the denial. The model must propose any
correction or second search itself in the same Run. Dry-run safety cases cover
authorization denial, revoke and cancel interfaces, a settled effect followed
by provider failure, and an unknown file effect reopened with the same
operationID and store. That last case deliberately has two Runs and is scored
only as a no-replay safety control. No Host retry participates in natural or
controlled trials.

For every natural/controlled task and repetition, disabled and enabled arms
use identical task data, tool definitions, model/endpoint/reasoning settings,
schema-4 format and per-Run budget. A seeded task shuffle and alternating arm
order are recorded. Independent trials have separate directories, Session IDs
and operationIDs; within a trial, the operationID is stable. There is no
cross-trial Evidence or settled replay. The dry-run provider is scripted and
validates the actual rejection feedback before its correction. It proves the
runner and SDK mechanism, **not** real-model correction.

Only an operator with explicit authorization for the named endpoint, account,
model and finite budget should invoke live mode. No credential is read in
dry-run; live reads only the explicitly selected environment variable after
all live flags validate. This first version supports the existing OpenAI
Responses adapter. It does not fall back to a fixture on live errors.

```sh
python3 Examples/ExternalClient/ReplanningEvaluation/run.py \
  --mode live --authorized-live \
  --tasks Examples/ExternalClient/ReplanningEvaluation/tasks.json \
  --repetitions 2 --model YOUR_AUTHORIZED_MODEL \
  --endpoint https://YOUR_AUTHORIZED_ENDPOINT/v1/responses \
  --reasoning none --key-env YOUR_AUTHORIZED_KEY_ENV \
  --max-http-requests 72 --max-http-per-trial 6 \
  --max-output-tokens 256 --max-input-bytes 8192 \
  --max-tokens-per-request 16384 --max-total-tokens 1179648 \
  --max-usd-per-request 0.01 --max-total-usd 0.72 \
  --max-model-turns 6 --max-tool-calls 6 \
  --run-timeout-seconds 30 --total-timeout-seconds 600
```

The sample values are placeholders, **not** an authorized budget or a model
price quote. Supply values approved for the actual service; live mode requires
every listed field, including the task file and repetitions. The per-request
USD amount is an operator-supplied worst-case reservation, not a provider
invoice or a guarantee of billing. The token reservation uses a bounded model
request in UTF-8 bytes plus configured maximum output tokens; provider-side
overhead and unreported usage can differ. The HTTP adapter enforces a per-trial
request cap; the orchestrator reserves global requests, tokens and USD before
each trial and stops when the next reservation or total deadline cannot fit.
If reported token usage exceeds the configured ceiling, it stops before the
next trial. Missing provider usage remains `null`/unknown. Safety violations
or process timeouts stop live execution and preserve the trial store. These
limits do not replace service-side billing controls.

`score.success` depends on the temporary file, executor count, validated
Receipt, Journal settlement/output and pending state, according to the task's
predeclared rule. Model final text never proves an effect. Only a real
`toolAdmissionRejected` event enters the post-rejection recovery denominator;
the next actual Provider request must contain its linked error. Trials with no
denial remain `not_exercised`, not a recovery success. Timed-out attempted
trials count in the planned success denominator, with unknown recovery marked
`not_observed`; stopped trials remain visible as `not_run`.

Each trial records monotonic task start, candidate, rejection, linked feedback
request, file effect, trusted settlement, logical end and physical drain.
The summary keeps all raw durations and reports successful-sample p50/p95 with
`n`; `tailUnstable` is true below 20 successful samples. Failures, timeouts
and cancellations remain in the overall task denominator. These durations
measure generic file settlement, not music playback latency. Safety controls
marked `liveEligible: false` run in dry-run only and are explicitly listed as
not run in the live manifest. Real LLM behavior, device playback, recommendation
quality and production Host integration remain separate assessments.
