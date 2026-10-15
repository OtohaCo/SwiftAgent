#!/usr/bin/env bash
set -euo pipefail

if ! command -v swift >/dev/null 2>&1; then
  env_file="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    . "$env_file"
    hash -r
  fi
fi

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain-version.sh"
report="$(swift --version 2>&1 || true)"
echo "swift --version:"
echo "$report"

if ! is_required "$report"; then
  echo "Required Swift ${required}. Refusing to continue with this compiler." >&2
  echo "swift-tools-version in Package.swift is the minimum manifest API, not the CI compiler." >&2
  exit 1
fi

if [[ "${1:-}" == "--apple" ]]; then
  apple_report="$(xcrun swift --version 2>&1 || true)"
  echo "xcrun swift --version:"
  echo "$apple_report"
  if ! is_required "$apple_report"; then
    echo "xcrun must select the same Swift ${required} compiler (set TOOLCHAINS)." >&2
    exit 1
  fi
  echo "xcodebuild -version:"
  xcodebuild -version
  echo "macosx SDK: $(xcrun --sdk macosx --show-sdk-version)"
  echo "iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unavailable)"
  echo "iphonesimulator SDK: $(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || echo unavailable)"
  echo "DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo unset)}"
fi
