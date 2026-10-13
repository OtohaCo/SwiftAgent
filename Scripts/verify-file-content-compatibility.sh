#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-file-content.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Actual accepted schema-12 reader, before issue #112's opt-in schema 13.
baseline=7085740f92498a2cbe6aad0423074e8cf41d2e12
if ! git -C "$root" cat-file -e "$baseline^{commit}" 2>/dev/null; then git -C "$root" fetch origin "$baseline"; fi
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/baseline" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
flags=(-Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME -Xswiftc -DIMAGE_CONTENT_RUNTIME -Xswiftc -DNATIVE_CONTEXT_RUNTIME -Xswiftc -DCONTEXT_HANDOFF_RUNTIME)
SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --product JournalReaderCompatibility "${flags[@]}" >"$scratch/old.log" 2>&1 || { tail -80 "$scratch/old.log"; exit 1; }
SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --product JournalReaderCompatibility "${flags[@]}" -Xswiftc -DFILE_CONTENT_RUNTIME >"$scratch/new.log" 2>&1 || { tail -80 "$scratch/new.log"; exit 1; }
old_bin="$(SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --show-bin-path)/JournalReaderCompatibility"
new_bin="$(SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --show-bin-path)/JournalReaderCompatibility"
store_digest() {
python3 - "$1" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); digest=hashlib.sha256()
for path in sorted(root.rglob('*')):
    if path.is_file(): digest.update(str(path.relative_to(root)).encode()); digest.update(path.read_bytes())
print(digest.hexdigest())
PY
}
session=00000000-0000-0000-0000-000000000013
"$old_bin" create-default "$scratch/legacy" "$session"
"$new_bin" inspect "$scratch/legacy" "$session"
"$new_bin" append "$scratch/legacy" "$session"
echo "schema13 reader on schema 3: readable, appendable"
"$old_bin" create-handoff-empty "$scratch/schema12" "$session"
"$new_bin" inspect "$scratch/schema12" "$session"
"$new_bin" append "$scratch/schema12" "$session"
echo "schema13 reader on schema 12: readable, appendable"
for mode in create-file-content-empty create-file-content; do
  directory="$scratch/$mode"
  "$new_bin" "$mode" "$directory" "$session"
  for phase in before after; do
    for action in inspect append maintain; do
      original="$(store_digest "$directory")"
      if "$old_bin" "$action" "$directory" "$session" >"$scratch/reject.log" 2>&1; then echo "schema12 reader accepted schema 13"; exit 1; fi
      grep -q unsupportedFormat "$scratch/reject.log"
      [[ "$(store_digest "$directory")" == "$original" ]]
      echo "schema12 reader $action $mode $phase: unsupportedFormat, bytes unchanged"
    done
    "$new_bin" maintain "$directory" "$session"
    if [[ "$mode" == create-file-content ]]; then "$new_bin" inspect-file-content "$directory" "$session"; fi
  done
done
