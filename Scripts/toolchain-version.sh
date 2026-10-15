#!/usr/bin/env bash
# Shared by compiler verification and Apple toolchain selection.
required="${SWIFT_AGENT_REQUIRED_SWIFT:-$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.swift-version")}"

is_required() {
  local pattern="${required//./\\.}"
  echo "$1" | grep -Eq "Swift version ${pattern}( |$)"
}
