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
Stack collection shares one ten-second budget for listings, identity checks and
sampling the root plus at most two active descendants, ordered by actual ancestry.
The cumulative historical PID set remains evidence, never a sampling candidate
list. Each debugger attempt records exit/timeout/unavailable status in
`sampling.json`; pre-attach checks reject vanished or changed identities using
parent/group/start-time/command observations. A detected post-attach race is
marked unavailable, not certified as an owned-process stack. External debuggers
attach by PID: these best-effort checks are not atomic identity pinning, and the
OS-reported start time has finite precision. The collector does not claim to
eliminate that race. Child termination/reaping can extend elapsed collection
time; cleanup ownership is retained rather than abandoned at the budget boundary.
Core-report collection has its own bounded budget. Only owned process groups are stopped and
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

## PR #85 Linux acceptance adjustments (2026-10-07)

GitHub's prior job annotations explicitly reported the 30-minute total job cap
expiring during reader compatibility builds. Linux now has a bounded 60-minute
job budget; every stage and its existing 1200-second bound remains intact.

A subsequent [Linux attempt](https://github.com/OtohaCo/SwiftAgent/actions/runs/37591989184/job/112695430919)
passed core and ExternalClient tests, then exited 139 inside `swift-run` during
build pre-planning (`SWBTaskConstruction`/`libdispatch`), before the Context
fixture started. The earlier ExternalClient test log shows the Context product
was compiled already. That stage now uses `swift run --skip-build` to execute
the built fixture with all assertions and exit-status checks. A missing product
or failed fixture still fails acceptance; there is no fallback or retry.
This avoids redundant planning, not a proven fix for the underlying toolchain
crash. It must not be conflated with the older, differently located #46 crash.
