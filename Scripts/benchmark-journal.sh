#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
sample_count="${1:-240}"
sample_seed="${2:-20260927}"
sample_policy="${3:-default}"
bench_root="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-journal-bench.XXXXXX")"
trap 'rm -rf "$bench_root"' EXIT

swift build -c release --product JournalBenchmark
bench_binary="$(swift build -c release --show-bin-path)/JournalBenchmark"
git rev-parse HEAD
swift --version
uname -a
if command -v sysctl >/dev/null 2>&1; then sysctl -n hw.model 2>/dev/null || true; fi
echo "fixture seed: $sample_seed; commits per scenario: $sample_count; policy: $sample_policy; new process, OS cache uncontrolled"
for case_name in repeated growing unrelated; do
  "$bench_binary" "$case_name" "$sample_count" "$bench_root/$case_name" "$sample_seed" "$sample_policy"
done
