#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck disable=SC1091
. "$root/Scripts/require-toolchain.sh" --apple

swift build
swift test --disable-sandbox --no-parallel
swift build --triple arm64-apple-ios16.0
swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
swift run --package-path Examples/ExternalClient BoundedReplanningProbe
swift build --package-path Examples/ExternalClient --product ReplanningEvalTrial
python3 -m unittest discover Examples/ExternalClient/ReplanningEvaluation -p 'test_*.py'
swift run --package-path Examples/ExternalClient ContextPipelineFixture
swift run --package-path Examples/ExternalClient ScopedCapabilityFixture
swift run --package-path Examples/ExternalClient FollowUpQueueFixture
swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel
swift build --package-path Examples/AppleChatApp
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
swift build --package-path Examples/AppleChatApp --target AppleChatApp --triple arm64-apple-ios16.0
swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel
bash Scripts/ci-execution-reporting.sh

SWIFTAGENT_AUDIT_TESTS_ALREADY_RUN=1 bash Scripts/ci-audited-authorization.sh 2>&1 | tee .build/ci-logs/audited-authorization.log
