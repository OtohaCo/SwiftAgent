#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck disable=SC1091
. "$root/Scripts/require-toolchain.sh" --apple

echo "Apple provider tests are compile + fixture only. Do not set SWIFT_AGENT_APPLE_LIVE."
swift test --filter AgentAppleProviderTests --disable-sandbox --no-parallel
