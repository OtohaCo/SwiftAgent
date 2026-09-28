#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: bash Scripts/verify-pr27-compatibility.sh RC4_CHECKOUT CANDIDATE_CHECKOUT" >&2
  exit 64
fi

rc4_checkout="$(cd "$1" && pwd)"
candidate_checkout="$(cd "$2" && pwd)"
candidate_package="$candidate_checkout/Tests/JournalReaderCompatibility"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-pr27-readers.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT

SWIFTAGENT_SDK_PATH="$rc4_checkout" swift build --package-path "$candidate_package" \
  --scratch-path "$scratch_dir/rc4" --product JournalReaderCompatibility \
  >"$scratch_dir/rc4-build.log" 2>&1 || {
    cat "$scratch_dir/rc4-build.log" >&2
    exit 1
  }
SWIFTAGENT_SDK_PATH="$candidate_checkout" swift build --package-path "$candidate_package" \
  --scratch-path "$scratch_dir/candidate" --product JournalReaderCompatibility \
  -Xswiftc -DNEW_RUNTIME >"$scratch_dir/candidate-build.log" 2>&1 || {
    cat "$scratch_dir/candidate-build.log" >&2
    exit 1
  }

rc4_bin_path="$(SWIFTAGENT_SDK_PATH="$rc4_checkout" swift build --package-path "$candidate_package" \
  --scratch-path "$scratch_dir/rc4" --show-bin-path)"
candidate_bin_path="$(SWIFTAGENT_SDK_PATH="$candidate_checkout" swift build --package-path "$candidate_package" \
  --scratch-path "$scratch_dir/candidate" --show-bin-path)"
python3 "$candidate_package/verify.py" "$rc4_checkout" "$candidate_checkout" \
  "$rc4_bin_path/JournalReaderCompatibility" \
  "$candidate_bin_path/JournalReaderCompatibility"
