#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck disable=SC1091
. "$root/Scripts/require-toolchain.sh"

swift package clean

for target in AgentModels AgentTools AgentCore AgentProviders; do
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
echo "Core --target builds did not compile WorkspaceAgent or AgentAppleProvider."

echo "swift test"
swift test --disable-sandbox --no-parallel

echo "external client"
swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
