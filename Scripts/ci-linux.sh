#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck disable=SC1091
. "$root/Scripts/require-toolchain.sh"

run_stage() {
  local stage="$1"
  shift
  python3 "$root/Scripts/ci_stage.py" --stage "$stage" -- "$@"
}

run_stage core-package-clean swift package clean

for target in AgentModels AgentTools AgentCore AgentCatalog AgentProviders AgentDecisions AgentJevProvider AgentUsage; do
  echo "swift build --target $target"
  run_stage "core-build-$target" swift build --target "$target"
done

if find .build -name 'WorkspaceAgent.swiftmodule' | grep -q .; then
  echo "WorkspaceAgent must not be compiled by the Core --target builds." >&2
  find .build -name 'WorkspaceAgent.swiftmodule' >&2
  exit 1
fi
if find .build -name 'AgentAppleProvider.swiftmodule' | grep -q .; then
  echo "AgentAppleProvider must not be compiled by the Core --target builds." >&2
  find .build -name 'AgentAppleProvider.swiftmodule' >&2
  exit 1
fi
echo "Portable --target builds did not compile WorkspaceAgent or AgentAppleProvider."

echo "swift test"
run_stage core-tests swift test --disable-sandbox --no-parallel

echo "external client"
run_stage external-client-tests swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
run_stage strict-replanning-probe swift run --package-path Examples/ExternalClient BoundedReplanningProbe
run_stage replanning-eval-build swift build --package-path Examples/ExternalClient --product ReplanningEvalTrial
run_stage replanning-python python3 -m unittest discover Examples/ExternalClient/ReplanningEvaluation -p 'test_*.py'
run_stage decision-eval-build swift build --package-path Examples/DecisionEvaluation
run_stage decision-eval-regressions python3 -m unittest discover Examples/DecisionEvaluation -p 'test_*.py'
# external-client-tests already compiled this product. Preserve execution/assertions,
# but avoid another SwiftPM build-plan pass (PR #85 captured a planner SIGSEGV).
run_stage context-pipeline swift run --skip-build --package-path Examples/ExternalClient ContextPipelineFixture
run_stage scoped-capability swift run --package-path Examples/ExternalClient ScopedCapabilityFixture
run_stage follow-up-queue swift run --package-path Examples/ExternalClient FollowUpQueueFixture
run_stage durable-run-records swift run --package-path Examples/ExternalClient RunRecordFixture

echo "provider qualification example"
run_stage provider-qualification swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel

echo "Apple chat integration example"
run_stage apple-chat-tests swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel

echo "dynamic model routing example"
run_stage dynamic-routing-tests swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel

echo "execution reporting support and consumers"
bash Scripts/ci-execution-reporting.sh

mkdir -p .build/ci-logs
run_stage audited-authorization env SWIFTAGENT_AUDIT_TESTS_ALREADY_RUN=1 bash Scripts/ci-audited-authorization.sh 2>&1 | tee .build/ci-logs/audited-authorization.log

bash Scripts/verify-per-call-compatibility.sh

bash Scripts/verify-run-record-compatibility.sh

bash Scripts/verify-image-content-compatibility.sh
