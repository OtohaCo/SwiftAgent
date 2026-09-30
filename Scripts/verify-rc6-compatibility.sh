#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: bash Scripts/verify-rc6-compatibility.sh RC5_CHECKOUT CANDIDATE_CHECKOUT" >&2
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
  --product JournalReaderCompatibility -Xswiftc -DNEW_RUNTIME -Xswiftc -DAUDIT_RUNTIME >"$scratch/new-build.log" 2>&1 || { cat "$scratch/new-build.log" >&2; exit 1; }
old_bin="$(SWIFTAGENT_SDK_PATH="$baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --show-bin-path)"
new_bin="$(SWIFTAGENT_SDK_PATH="$candidate" swift build --package-path "$package" --scratch-path "$scratch/new" --show-bin-path)"
python3 "$package/verify_audit.py" "$baseline" "$candidate" "$old_bin/JournalReaderCompatibility" "$new_bin/JournalReaderCompatibility"
