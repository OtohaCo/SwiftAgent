#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. "$root/Scripts/require-toolchain.sh"
# Match reporting acceptance's package, debug configuration and Linux backend.
# This is the narrowed planner workaround, not a fix for SwiftPM's crash.
reporting_test_command=(swift test --package-path Examples/ExecutionReportingSupport --disable-sandbox --no-parallel)
if [[ "$(uname -s)" == "Linux" ]]; then
  reporting_test_command+=(--build-system native)
fi
# Predeclared finite experiment: at most five identical commands; stop at first
# nonzero/timeout/crash. No retry-until-green and no sanitizer/release conflation.
for attempt in 1 2 3 4 5; do
  python3 Scripts/ci_stage.py --stage "linux-reporting-repeat-$attempt" \
    --timeout 300 --log-dir .ci-logs/linux-reporting-reproduction -- \
    "${reporting_test_command[@]}"
done
