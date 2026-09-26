#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
base_sha="5de9e4fd4e69c2da809f78e6a69951b0a2067b4c"
sample_count="${1:-120}"
sample_seed="${2:-20260927}"
bench_root="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-legacy-bench.XXXXXX")"
checkout="$bench_root/source"
cleanup() {
  if [[ -d "$checkout" ]]; then
    git -C "$project_root" worktree remove --force "$checkout" >/dev/null 2>&1 || true
  fi
  rm -rf "$bench_root"
}
trap cleanup EXIT

git -C "$project_root" worktree add --detach "$checkout" "$base_sha" >/dev/null
mkdir -p "$checkout/Sources/LegacyJournalBenchmark"
cp "$project_root/Benchmarks/LegacyJournalBenchmark.swift" "$checkout/Sources/LegacyJournalBenchmark/main.swift"
python3 - "$checkout/Package.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '        .target(name: "AgentCore", dependencies: ["AgentModels", "AgentTools"]),'
assert s.count(needle) == 1
p.write_text(s.replace(needle, needle + '\n        .executableTarget(name: "LegacyJournalBenchmark", dependencies: ["AgentCore", "AgentModels", "AgentTools"]),'))
PY
swift build --package-path "$checkout" -c release --product LegacyJournalBenchmark
legacy_binary="$(swift build --package-path "$checkout" -c release --show-bin-path)/LegacyJournalBenchmark"
echo "legacy SHA: $base_sha"
swift --version
uname -a
if command -v sysctl >/dev/null 2>&1; then sysctl -n hw.model 2>/dev/null || true; fi
echo "synthetic fixture seed: $sample_seed; commits per scenario: $sample_count; new process, OS cache uncontrolled"
for case_name in repeated growing unrelated; do
  "$legacy_binary" "$case_name" "$sample_count" "$bench_root/$case_name.log" "$sample_seed"
done
