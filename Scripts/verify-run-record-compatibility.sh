#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-run-records.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
baseline=d3a8ef964aecd440934d51b7cd00f6552fe22002
if ! git -C "$root" cat-file -e "$baseline^{commit}" 2>/dev/null; then git -C "$root" fetch origin "$baseline"; fi
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/baseline" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME >"$scratch/old.log" 2>&1 || { tail -80 "$scratch/old.log"; exit 1; }
SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME >"$scratch/new.log" 2>&1 || { tail -80 "$scratch/new.log"; exit 1; }
old_bin="$(SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --show-bin-path)/JournalReaderCompatibility"
new_bin="$(SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --show-bin-path)/JournalReaderCompatibility"
store_digest() {
python3 - "$1" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]);digest=hashlib.sha256()
for path in sorted(root.rglob('*')):
    if path.is_file(): digest.update(str(path.relative_to(root)).encode());digest.update(path.read_bytes())
print(digest.hexdigest())
PY
}
session=00000000-0000-0000-0000-000000000075
"$old_bin" create-per-call "$scratch/legacy" "$session"
"$new_bin" inspect-per-call "$scratch/legacy" "$session"
if "$new_bin" inspect-run-records "$scratch/legacy" "$session" >"$scratch/unsupported.log" 2>&1; then echo "old format fabricated Run-query support"; exit 1; fi
grep -q unsupportedFormat "$scratch/unsupported.log"
for mode in create-run-records-empty create-run-records; do
  directory="$scratch/$mode"
  "$new_bin" "$mode" "$directory" "$session"
  for phase in before after; do
    for action in inspect append maintain; do
      original="$(store_digest "$directory")"
      if "$old_bin" "$action" "$directory" "$session" >"$scratch/reject.log" 2>&1; then echo "old reader accepted schema 9"; exit 1; fi
      grep -q unsupportedFormat "$scratch/reject.log"
      [[ "$(store_digest "$directory")" == "$original" ]]
      echo "schema8 reader $action $mode $phase: unsupportedFormat, bytes unchanged"
    done
    "$new_bin" maintain "$directory" "$session"
    if [[ "$mode" == create-run-records ]]; then "$new_bin" inspect-run-records "$directory" "$session"; fi
  done
done
