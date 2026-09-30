#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. "$root/Scripts/require-toolchain.sh"
# Predeclared finite experiment: at most five original commands; stop at first
# nonzero/timeout/crash. No retry-until-green and no sanitizer/release conflation.
for attempt in 1 2 3 4 5; do
  python3 Scripts/ci_stage.py --stage "linux-reporting-repeat-$attempt" \
    --timeout 300 --log-dir .build/ci-logs/linux-reporting-reproduction -- \
    swift test --package-path Examples/ExecutionReportingSupport --disable-sandbox --no-parallel
done
