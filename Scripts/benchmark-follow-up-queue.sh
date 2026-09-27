#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
sample_count="${1:-80}"
sample_seed="${2:-20260927}"
bench_root="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-follow-up-bench.XXXXXX")"
trap 'rm -rf "$bench_root"' EXIT

swift build -c release --product FollowUpQueueBenchmark
bench_binary="$(swift build -c release --show-bin-path)/FollowUpQueueBenchmark"
git rev-parse HEAD
swift --version
uname -a
if command -v sysctl >/dev/null 2>&1; then sysctl -n hw.model 2>/dev/null || true; fi
echo "fixture seed: $sample_seed; growth count: $sample_count; new process; OS page cache uncontrolled"
for scenario in target unrelated active; do
  "$bench_binary" "$scenario" "$sample_count" "$bench_root/$scenario" "$sample_seed"
done
