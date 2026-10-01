#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .build/ci-logs
python3 - <<'PY' > .build/ci-logs/audited-authorization-checkout.json
import json, os, subprocess
print(json.dumps({"checkoutSHA": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
 "checkoutTree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip(),
 "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"), "runID": os.environ.get("GITHUB_RUN_ID", "local"),
 "runner": os.environ.get("RUNNER_OS", "local"), "compiler": subprocess.check_output(["swift", "--version"], text=True).strip()}, indent=2))
PY
# Main CI already runs the full test suite. Standalone acceptance also runs its targeted cases.
if [[ "${SWIFTAGENT_AUDIT_TESTS_ALREADY_RUN:-0}" != "1" ]]; then
  swift test --filter 'Audit|ConfirmedNoEffect|AgentPreAdmissionReplanningTests.requiredAudit' --disable-sandbox --no-parallel
fi
swift run --package-path Examples/ExternalClient EnterpriseAuthorizationFixture
swift run --package-path Examples/ExternalClient ConfirmedNoEffectFixture
swift run -c release AuditAuthorizationBenchmark 20 > .build/ci-logs/audited-authorization-performance.json
cat .build/ci-logs/audited-authorization-performance.json
baseline=24447b8298ccea84f9f8056374857c5c47d8f64c
if ! git cat-file -e "$baseline^{commit}" 2>/dev/null; then
  git fetch origin tag 1.0.0-rc.5
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-audit-baseline.XXXXXX")"
cleanup() { python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
python3 -m unittest discover Scripts -p 'test_reader_checkout.py'
bash Scripts/checkout-reader-baseline.sh "$root" "$scratch/rc5" "$baseline"
# Actual schema-5 runtime, not a reader whose format check was patched for this test.
pre_feature=ffac71407dfaff22cd4480f1c48bb2c73811b36a
if ! git cat-file -e "$pre_feature^{commit}" 2>/dev/null; then
  git fetch origin "$pre_feature"
fi
bash Scripts/checkout-reader-baseline.sh "$root" "$scratch/schema5" "$pre_feature"
bash Scripts/verify-rc6-compatibility.sh "$scratch/rc5" "$root" "$scratch/schema5"

bash Scripts/ci-compact-no-effect.sh
