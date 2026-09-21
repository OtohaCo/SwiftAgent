#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

artifact="${SWIFT_AGENT_ACCEPTANCE_OUTPUT:-$root/.build/execution-reporting-acceptance.json}"
mkdir -p "$(dirname "$artifact")"
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-execution-reporting.XXXXXX")"
trap 'rm -rf "$log_dir"' EXIT

source_sha="$(git rev-parse HEAD)"
source_tree_sha="$(git rev-parse HEAD^{tree})"
dirty=false
if [[ -n "$(git status --porcelain)" ]]; then dirty=true; fi
platform="$(uname -s)-$(uname -m)"
toolchain="$(swift --version | head -n 1 | sed 's/"/\\"/g')"
entries=()
overall=0

run_case() {
    local suite="$1"
    local mode="$2"
    shift 2
    local started ended exit_code result log
    log="$log_dir/${#entries[@]}.log"
    started="$(date +%s)"
    set +e
    "$@" >"$log" 2>&1
    exit_code=$?
    set -e
    ended="$(date +%s)"
    if [[ "$exit_code" -eq 0 ]]; then
        result="pass"
    else
        result="fail"
        overall=1
    fi
    entries+=("{\"suite\":\"$suite\",\"mode\":\"$mode\",\"platform\":\"$platform\",\"toolchain\":\"$toolchain\",\"result\":\"$result\",\"exitCode\":$exit_code,\"durationSeconds\":$((ended - started)),\"modelRequests\":0}")
    if [[ "$exit_code" -ne 0 ]]; then
        printf '%s failed; output: %s\n' "$suite" "$log" >&2
    fi
}

run_case "ExecutionReportingSupportTests" "fixture" \
    swift test --package-path Examples/ExecutionReportingSupport --disable-sandbox --no-parallel
run_case "HeadlessExecutionHostTests" "local-integration" \
    swift test --package-path Examples/HeadlessExecutionHost --disable-sandbox --no-parallel
run_case "HeadlessFailureAfterWrite" "local-integration" \
    swift run --package-path Examples/HeadlessExecutionHost HeadlessExecutionHostCLI failure-after-write
run_case "HeadlessReadOnlyAuthorization" "local-integration" \
    swift run --package-path Examples/HeadlessExecutionHost HeadlessExecutionHostCLI read-only-rejects-write
run_case "AppleChatIntegrationTests" "fixture" \
    swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel

{
    printf '{\n'
    printf '  "repository": "OtohaCo/SwiftAgent",\n'
    printf '  "sourceCommitSHA": "%s",\n' "$source_sha"
    printf '  "sourceTreeSHA": "%s",\n' "$source_tree_sha"
    printf '  "unverifiedWorkspaceChanges": %s,\n' "$dirty"
    printf '  "platform": "%s",\n' "$platform"
    printf '  "toolchain": "%s",\n' "$toolchain"
    printf '  "modelRequests": 0,\n'
    printf '  "cases": [\n'
    for index in "${!entries[@]}"; do
        [[ "$index" -gt 0 ]] && printf ',\n'
        printf '    %s' "${entries[$index]}"
    done
    printf '\n  ]\n}\n'
} >"$artifact"

printf 'Execution reporting acceptance: %s\n' "$artifact"
exit "$overall"
