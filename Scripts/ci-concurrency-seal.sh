#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
cd "$package_dir"

test_list="$(swift test list)"

require_suite_count() {
  local suite="$1"
  local expected="$2"
  local actual

  actual="$(printf '%s\n' "$test_list" | awk -v prefix="${suite}/" 'index($0, prefix) == 1 { count += 1 } END { print count + 0 }')"
  if [[ "$actual" -ne "$expected" ]]; then
    echo "Expected ${expected} discovered tests in ${suite}; found ${actual}." >&2
    exit 1
  fi
}

require_suite_count "AgentToolsTests.ToolResourceCoordinatorTests" 11
require_suite_count "AgentCoreTests.AgentCompletionCommitTests" 3

swift test --filter ToolResourceCoordinatorTests --disable-sandbox --no-parallel
swift test --filter AgentCompletionCommitTests --disable-sandbox --no-parallel
