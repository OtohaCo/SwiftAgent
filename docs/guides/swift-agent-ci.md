# CI stage ownership and finite reproduction

last-verified: 2026-10-07

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

`ci-linux-reporting-repro.sh` runs the reporting-support acceptance test command at
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

A parallel [push run](https://github.com/OtohaCo/SwiftAgent/actions/runs/37594531153/job/112703815497)
on `872273e` failed the backlog application-boundary assertion: the arithmetic
tool fixture's two-second deadline expired while 16 audit facts were individually
persisted behind a test barrier. A controlled 150 ms delay per append reproduces
the exact `backlogExceeded` versus `toolTimedOut` failure. Fixture seeding now
appends the same facts in one transaction; deadlines, backlog assertions and
production authorization remain unchanged.

That attempt also hit the separate 1200-second core-stage watchdog. Its last
test output was buffered, and no debugger was installed, so the hanging test and
stack are unknown. The passing parallel PR run does not erase this failure or
identify its cause. Linux installs `gdb` within a five-minute setup bound so the
existing ten-second, owned-process collector can attempt a stack if it recurs;
permission or sampling failures remain explicit diagnostics. No failing test or
exit code is ignored, and a later pass is not a claimed fix for this unattributed
hang.

## Prebuilt Host CLI acceptance (2026-10-07)

PR #85's [final-head Linux push](https://github.com/OtohaCo/SwiftAgent/actions/runs/37604331672/job/112736047296)
passed core, consumer and routing tests, then `swift run` exited 139 while
planning `HeadlessFailureAfterWrite`. The crashing program was `swift-package`
in libdispatch, before the Host CLI started; this was not a timeout. The prior
Host test log contains the `HeadlessExecutionHostCLI-product` build steps.
Both CLI scenarios now use `swift run --skip-build` after those tests, executing
the built product with the original arguments, assertions, watchdogs and exit
checks. A missing executable still fails; no acceptance case or retry is added
or removed. The five bounded reporting-test attempts remain intact; the later
Linux-only backend adjustment below applies to both acceptance and reproduction.
The [separate planner evidence and follow-up](https://github.com/OtohaCo/SwiftAgent/issues/46#issuecomment-6035891119)
remain distinct from the original unassigned test crash and the historical
core-stage hang. Avoiding this planning pass does not prove an upstream fix.

## Linux reporting-support planner workaround (2026-10-07)

The [merged-main Linux job](https://github.com/OtohaCo/SwiftAgent/actions/runs/37619838596)
on `5d1b7de` exited 139 while planning `ExecutionReportingSupportTests`, before
its test executable ran. The stack names `swift-package`,
`SWBCore/SpecImplementations/Tools/LinkerTools.swift:1981`, `Regex.firstMatch`, and
Swift generic metadata in `libswiftCore`/`libswift_StringProcessing`. Its
[retained artifact](https://github.com/OtohaCo/SwiftAgent/actions/runs/37619838596/artifacts/11481858783)
also contains the five subsequent default-backend attempts that passed. Those
passes establish an intermittent failure; they neither erase the failed
acceptance nor establish its upstream root cause.

Swift 6.4 [changed SwiftPM's default to Swift Build](https://www.swift.org/blog/swift-6.4-released/).
The [SwiftPM maintainer's migration notice](https://forums.swift.org/t/swiftpm-development-update-default-build-system-change/85548)
and the installed toolchain's `swift test --help` identify
`--build-system native` as the available, deprecated previous backend. Reporting
acceptance and its finite reproduction now select it only for
`Examples/ExecutionReportingSupport` on Linux. This avoids the observed Swift
Build linker-discovery path; it is a targeted toolchain workaround, not a claim
that SwiftPM's metadata bug has been fixed. Remove or revisit it when a verified
toolchain change makes the default path reliable; the
[distinct #46 failures](https://github.com/OtohaCo/SwiftAgent/issues/46) remain open.

Both scripts run the same package's complete debug test suite, without a filter,
skip-build, sanitizer or release-mode substitution. The five attempts stop on
the first nonzero/timeout/crash. macOS and other consumer packages keep their
existing backend. The original five reporting acceptance scenarios, 1200-second
watchdogs, evidence directories, acceptance JSON and failure propagation remain
in place. Headless CLI scenarios still require the product built by their
preceding tests; a missing product or a failed assertion is still a failure.
There is no fallback to a passing backend after a failed command and no increase
to job or stage time limits.
