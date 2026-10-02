#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck disable=SC1091
. "$root/Scripts/require-toolchain.sh" --apple

run_stage() {
  local stage="$1"
  shift
  python3 "$root/Scripts/ci_stage.py" --stage "$stage" -- "$@"
}

run_stage core-build swift build
run_stage core-tests swift test --disable-sandbox --no-parallel
run_stage core-ios-build swift build --triple arm64-apple-ios16.0
run_stage external-client-tests swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
run_stage strict-replanning-probe swift run --package-path Examples/ExternalClient BoundedReplanningProbe
run_stage replanning-eval-build swift build --package-path Examples/ExternalClient --product ReplanningEvalTrial
run_stage replanning-python python3 -m unittest discover Examples/ExternalClient/ReplanningEvaluation -p 'test_*.py'
run_stage decision-eval-build swift build --package-path Examples/DecisionEvaluation
run_stage decision-eval-regressions python3 -m unittest discover Examples/DecisionEvaluation -p 'test_*.py'
run_stage context-pipeline swift run --package-path Examples/ExternalClient ContextPipelineFixture
run_stage scoped-capability swift run --package-path Examples/ExternalClient ScopedCapabilityFixture
run_stage follow-up-queue swift run --package-path Examples/ExternalClient FollowUpQueueFixture
run_stage durable-run-records swift run --package-path Examples/ExternalClient RunRecordFixture
run_stage provider-qualification swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel
run_stage apple-chat-build swift build --package-path Examples/AppleChatApp
run_stage apple-chat-tests swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
run_stage apple-chat-ios-build swift build --package-path Examples/AppleChatApp --target AppleChatApp --triple arm64-apple-ios16.0
run_stage dynamic-routing-tests swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel
bash Scripts/ci-execution-reporting.sh

mkdir -p .build/ci-logs
run_stage audited-authorization env SWIFTAGENT_AUDIT_TESTS_ALREADY_RUN=1 bash Scripts/ci-audited-authorization.sh 2>&1 | tee .build/ci-logs/audited-authorization.log

bash Scripts/verify-per-call-compatibility.sh

bash Scripts/verify-run-record-compatibility.sh
