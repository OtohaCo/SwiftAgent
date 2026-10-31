#!/usr/bin/env bash
# Shared by compiler verification and Apple toolchain selection.
required="${SWIFT_AGENT_REQUIRED_SWIFT:-$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.swift-version")}"

is_required() {
  local pattern="${required//./\\.}"
  echo "$1" | grep -Eq "Swift version ${pattern}( |$)"
}

# The identifier TOOLCHAINS takes: a standalone toolchain keeps it in Info.plist,
# Xcode's own toolchain in ToolchainInfo.plist.
toolchain_identifier() {
  if [[ -f "$1/Info.plist" ]]; then
    plutil -extract CFBundleIdentifier raw "$1/Info.plist"
  else
    plutil -extract Identifier raw "$1/ToolchainInfo.plist"
  fi
}
