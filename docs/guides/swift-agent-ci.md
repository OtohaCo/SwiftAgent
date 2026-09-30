# CI stage ownership and finite reproduction

Core build/test, cross-build and public fixtures in `ci-macos.sh`/`ci-linux.sh`
use the same bounded child owner as execution reporting (`Scripts/ci_stage.py`).
The default per-stage limit is 1200 seconds; Host test jobs can explicitly set
`SWIFT_AGENT_CI_CASE_TIMEOUT_SECONDS`. Timeout exits 124 and cannot count as PASS.
These are CI process bounds, not shortened product deadlines, drain or leases.

Each stage creates a new evidence directory under `.ci-logs/stages`, with
checkout SHA/tree, workspace state, toolchain, run/attempt, PID, process tree
observations, duration, child/owner exit codes and complete output. Last observed
test lines may be buffered: they are not claimed to identify the current test.
Collection commands have separate bounds (ten-second stack/core budget plus a
two-second process listing bound). Only owned process groups are stopped and
reaped; unrelated processes/reports are not collected or killed. Missing debugger,
core access or a process that vanished before sampling is recorded as unavailable.
Crash output can establish a test-child failure even when SwiftPM returns 1;
compiler vs SwiftPM vs test attribution still needs the actual process/log evidence.
Execution-reporting attempts also retain separate directories rather than erase
prior logs, with an immutable copy of each acceptance summary. Evidence lives
outside `.build` so `swift package clean` cannot erase its own running stage.
Hosted artifacts keep these records for 30 days.
The upload explicitly includes hidden files only within the three declared CI
evidence paths (`.ci-logs`, legacy `.build/ci-logs`, and the acceptance JSON).
It does not upload the workspace root or arbitrary hidden credentials.

`ci-linux-reporting-repro.sh` runs the original reporting-support test command at
most five times in Swift 6.4 Linux, stopping at the first nonzero, timeout or crash.
The reproduction step can run after an unrelated earlier stage failure, but
does not start after job cancellation. Each attempt has independent evidence; compilation/toolchain, process tree and
any available core metadata stay separate. This is a bounded reproduction
experiment, not retry-until-green. Debug/sanitizer runs, if any, are separate from
normal acceptance. A pass means that attempt did not reproduce the old crash.

These changes improve evidence for #45/#46. They do not establish or fix the
historical macOS hang or Linux segfault root cause; the issues remain open. No
paid live Provider requests or user-store operations are part of these scripts.
