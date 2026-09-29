#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

artifact="${SWIFT_AGENT_ACCEPTANCE_OUTPUT:-$root/.build/execution-reporting-acceptance.json}"
mkdir -p "$(dirname "$artifact")"
# Logs outlive the script: CI uploads this directory and a failed case keeps its evidence.
log_dir="${SWIFT_AGENT_CI_LOG_DIR:-$root/.build/ci-logs/execution-reporting}"
rm -rf "$log_dir"
mkdir -p "$log_dir"
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

descendants() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        echo "$child"
        descendants "$child"
    done
}

# Best-effort process and thread evidence for a case that did not finish in time.
collect_stacks() {
    local pid="$1" evidence="$2" each
    mkdir -p "$evidence"
    ps -o pid,ppid,pgid,stat,etime,command -p "$pid" $(descendants "$pid" | sed 's/^/-p /') \
        >"$evidence/processes.txt" 2>&1 || true
    for each in "$pid" $(descendants "$pid"); do
        if command -v sample >/dev/null 2>&1; then
            sample "$each" 3 -file "$evidence/sample-$each.txt" >/dev/null 2>&1 || true
        elif command -v gdb >/dev/null 2>&1; then
            gdb -p "$each" -batch -ex "thread apply all bt" >"$evidence/gdb-$each.txt" 2>&1 || true
        else
            echo "no sample or gdb; stacks unavailable" >"$evidence/stacks-unavailable.txt"
        fi
    done
}

# Crash reports written while the case ran (macOS), or what Linux exposes without privileges.
collect_crashes() {
    local marker="$1" evidence="$2" reports="$HOME/Library/Logs/DiagnosticReports"
    mkdir -p "$evidence"
    if [[ -d "$reports" ]]; then
        find "$reports" -type f -newer "$marker" -exec cp {} "$evidence/" \; 2>/dev/null || true
    fi
    if command -v coredumpctl >/dev/null 2>&1; then
        coredumpctl info --no-pager --since "-30min" >"$evidence/coredumpctl.txt" 2>&1 || true
    fi
    echo "ulimit -c: $(ulimit -c)" >"$evidence/core-limit.txt"
}

# Runs one case in its own process group with a bounded wall-clock time. Returns the case's exit
# status, or 124 after a timeout once evidence is collected and the group is stopped.
run_bounded() {
    local log="$1" evidence="$2"
    shift 2
    set -m
    "$@" >"$log" 2>&1 &
    local pid=$!
    set +m
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= case_timeout )); then
            printf '[%s] timeout after %ss; collecting process state\n' "$(timestamp)" "$case_timeout" | tee -a "$log"
            collect_stacks "$pid" "$evidence"
            kill -TERM -- "-$pid" 2>/dev/null || true
            sleep 5
            kill -KILL -- "-$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
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
        if [[ "$exit_code" -gt 128 && "$exit_code" -ne 124 ]]; then
            collect_crashes "$marker" "$evidence"
        fi
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
