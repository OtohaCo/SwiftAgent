#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: bash Scripts/verify-rc6-compatibility.sh RC5_CHECKOUT CANDIDATE_CHECKOUT [PRE_NO_EFFECT_CHECKOUT]" >&2
  exit 64
fi
baseline="$(cd "$1" && pwd)"
candidate="$(cd "$2" && pwd)"
package="$candidate/Tests/JournalReaderCompatibility"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-rc6-readers.XXXXXX")"
cleanup() { python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
SWIFTAGENT_SDK_PATH="$baseline" swift build --package-path "$package" --scratch-path "$scratch/old" \
  --product JournalReaderCompatibility -Xswiftc -DNEW_RUNTIME >"$scratch/old-build.log" 2>&1 || { cat "$scratch/old-build.log" >&2; exit 1; }
SWIFTAGENT_SDK_PATH="$candidate" swift build --package-path "$package" --scratch-path "$scratch/new" \
  --product JournalReaderCompatibility -Xswiftc -DNEW_RUNTIME -Xswiftc -DAUDIT_RUNTIME -Xswiftc -DNO_EFFECT_RUNTIME >"$scratch/new-build.log" 2>&1 || { cat "$scratch/new-build.log" >&2; exit 1; }
old_bin="$(SWIFTAGENT_SDK_PATH="$baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --show-bin-path)"
new_bin="$(SWIFTAGENT_SDK_PATH="$candidate" swift build --package-path "$package" --scratch-path "$scratch/new" --show-bin-path)"
reader_args=("$baseline" "$candidate" "$old_bin/JournalReaderCompatibility" "$new_bin/JournalReaderCompatibility")
if [[ $# -eq 3 ]]; then
  pre_feature="$(cd "$3" && pwd)"
  SWIFTAGENT_SDK_PATH="$pre_feature" swift build --package-path "$package" --scratch-path "$scratch/schema5" \
    --product JournalReaderCompatibility -Xswiftc -DNEW_RUNTIME -Xswiftc -DAUDIT_RUNTIME >"$scratch/schema5-build.log" 2>&1 || { cat "$scratch/schema5-build.log" >&2; exit 1; }
  schema5_bin="$(SWIFTAGENT_SDK_PATH="$pre_feature" swift build --package-path "$package" --scratch-path "$scratch/schema5" --show-bin-path)"
  reader_args+=("$pre_feature" "$schema5_bin/JournalReaderCompatibility")
fi
python3 "$package/verify_audit.py" "${reader_args[@]}"
