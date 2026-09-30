#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck disable=SC1091
. "$root/Scripts/require-toolchain.sh"

swift package clean

for target in AgentModels AgentTools AgentCore AgentCatalog AgentProviders AgentDecisions AgentJevProvider AgentUsage; do
  echo "swift build --target $target"
  swift build --target "$target"
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
swift test --disable-sandbox --no-parallel

echo "external client"
swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
swift run --package-path Examples/ExternalClient BoundedReplanningProbe
swift build --package-path Examples/ExternalClient --product ReplanningEvalTrial
python3 -m unittest discover Examples/ExternalClient/ReplanningEvaluation -p 'test_*.py'
swift run --package-path Examples/ExternalClient ContextPipelineFixture
swift run --package-path Examples/ExternalClient ScopedCapabilityFixture
swift run --package-path Examples/ExternalClient FollowUpQueueFixture

echo "provider qualification example"
swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel

echo "Apple chat integration example"
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel

echo "dynamic model routing example"
swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel

echo "execution reporting support and consumers"
bash Scripts/ci-execution-reporting.sh

SWIFTAGENT_AUDIT_TESTS_ALREADY_RUN=1 bash Scripts/ci-audited-authorization.sh 2>&1 | tee .build/ci-logs/audited-authorization.log
