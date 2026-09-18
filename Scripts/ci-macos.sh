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
