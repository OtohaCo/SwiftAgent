#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

artifact="${SWIFT_AGENT_ACCEPTANCE_OUTPUT:-$root/.build/execution-reporting-acceptance.json}"
mkdir -p "$(dirname "$artifact")"
# Logs outlive the script: CI uploads this directory and a failed case keeps its evidence.
log_dir="${SWIFT_AGENT_CI_LOG_DIR:-$root/.build/ci-logs/execution-reporting}"
mkdir -p "$log_dir"
log_dir="$(mktemp -d "$log_dir/attempt-XXXXXXXX")"
case_timeout="${SWIFT_AGENT_CI_CASE_TIMEOUT_SECONDS:-1200}"

source_sha="$(git rev-parse HEAD)"
source_tree_sha="$(git rev-parse HEAD^{tree})"
dirty=false
if [[ -n "$(git status --porcelain)" ]]; then dirty=true; fi
platform="$(uname -s)-$(uname -m)"
toolchain="$(swift --version | head -n 1 | sed 's/"/\\"/g')"
entries=()
overall=0

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Reuse the same bounded owner as the earlier core stages. It records source,
# process tree and bounded evidence before stopping only its own process group.
run_bounded() {
    local log="$1" evidence="$2"
    shift 2
    python3 "$root/Scripts/ci_stage.py" --stage "$(basename "$log" .log)" \
        --log-dir "$evidence" --timeout "$case_timeout" -- "$@" >"$log" 2>&1
}

run_case() {
    local suite="$1"
    local mode="$2"
    shift 2
    local index="${#entries[@]}"
    local log="$log_dir/$index-$suite.log"
    local evidence="$log_dir/$index-$suite-evidence"
    local marker="$log_dir/.$index-started"
    local started ended exit_code result
    touch "$marker"
    started="$(date +%s)"
    printf '[%s] start %s (%s): %s\n' "$(timestamp)" "$suite" "$mode" "$*"
    set +e
    run_bounded "$log" "$evidence" "$@"
    exit_code=$?
    set -e
    ended="$(date +%s)"
    if [[ "$exit_code" -eq 0 ]]; then
        result="pass"
    else
        result="fail"
        overall=1
    fi
    rm -f "$marker"
    printf '[%s] end %s: exit=%s result=%s seconds=%s log=%s\n' \
        "$(timestamp)" "$suite" "$exit_code" "$result" "$((ended - started))" "$log"
    if [[ "$exit_code" -ne 0 ]]; then
        if [[ "$exit_code" -gt 128 && "$exit_code" -ne 124 ]]; then
            printf '%s ended by signal %s; evidence: %s\n' "$suite" "$((exit_code - 128))" "$evidence" >&2
        fi
        printf '%s failed; last 200 lines of %s:\n' "$suite" "$log" >&2
        tail -n 200 "$log" >&2 || true
    fi
    entries+=("{\"suite\":\"$suite\",\"mode\":\"$mode\",\"platform\":\"$platform\",\"toolchain\":\"$toolchain\",\"result\":\"$result\",\"exitCode\":$exit_code,\"durationSeconds\":$((ended - started)),\"modelRequests\":0}")
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
    printf '  "logDirectory": "%s",\n' "$log_dir"
    printf '  "cases": [\n'
    for index in "${!entries[@]}"; do
        [[ "$index" -gt 0 ]] && printf ',\n'
        printf '    %s' "${entries[$index]}"
    done
    printf '\n  ]\n}\n'
} >"$artifact"

printf 'Execution reporting acceptance: %s (logs kept in %s)\n' "$artifact" "$log_dir"
exit "$overall"
