#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# Actual immutable schema-6 reader; no patched schema checks.
baseline=e8ef319857ce651002504d6d3592fdcba7574172
if ! git cat-file -e "$baseline^{commit}" 2>/dev/null; then git fetch origin "$baseline"; fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-compact-readers.XXXXXX")"
cleanup() { python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
bash Scripts/checkout-reader-baseline.sh "$root" "$scratch/schema6" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
for reader in old new; do
  sdk="$root"
  flags=(-Xswiftc -DNEW_RUNTIME -Xswiftc -DAUDIT_RUNTIME -Xswiftc -DNO_EFFECT_RUNTIME)
  if [[ "$reader" == old ]]; then sdk="$scratch/schema6"; else flags+=(-Xswiftc -DCOMPACT_NO_EFFECT_RUNTIME); fi
  SWIFTAGENT_SDK_PATH="$sdk" swift build --package-path "$package" --scratch-path "$scratch/$reader-build" --product JournalReaderCompatibility "${flags[@]}" >"$scratch/$reader-build.log" 2>&1 || { cat "$scratch/$reader-build.log" >&2; exit 1; }
done
old_bin="$(SWIFTAGENT_SDK_PATH="$scratch/schema6" swift build --package-path "$package" --scratch-path "$scratch/old-build" --show-bin-path)"
new_bin="$(SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new-build" --show-bin-path)"
python3 Tests/JournalReaderCompatibility/verify_compact_no_effect.py "$scratch/schema6" "$root" "$old_bin/JournalReaderCompatibility" "$new_bin/JournalReaderCompatibility"
