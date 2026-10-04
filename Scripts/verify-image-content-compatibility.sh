#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-image-content.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# The last reader before format schema 10 (images kept by digest): main after #78.
baseline=3ad52332e71290abde108007a7ce34e7054b7bde
if ! git -C "$root" cat-file -e "$baseline^{commit}" 2>/dev/null; then git -C "$root" fetch origin "$baseline"; fi
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/baseline" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME >"$scratch/old.log" 2>&1 || { tail -80 "$scratch/old.log"; exit 1; }
SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME -Xswiftc -DIMAGE_CONTENT_RUNTIME >"$scratch/new.log" 2>&1 || { tail -80 "$scratch/new.log"; exit 1; }
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
session=00000000-0000-0000-0000-000000000012
# A schema-9 store written by the old reader stays readable and writable, and claims no images.
"$old_bin" create-run-records "$scratch/legacy" "$session"
"$new_bin" inspect-run-records "$scratch/legacy" "$session"
"$new_bin" append "$scratch/legacy" "$session"
if "$new_bin" inspect-image-content "$scratch/legacy" "$session" >"$scratch/legacy-images.log" 2>&1; then echo "schema 9 claimed image support"; exit 1; fi
echo "schema10 reader on schema 9: readable, appendable, no image support"
for mode in create-image-content-empty create-image-content; do
  directory="$scratch/$mode"
  "$new_bin" "$mode" "$directory" "$session"
  for phase in before after; do
    for action in inspect append maintain; do
      original="$(store_digest "$directory")"
      if "$old_bin" "$action" "$directory" "$session" >"$scratch/reject.log" 2>&1; then echo "old reader accepted schema 10"; exit 1; fi
      grep -q unsupportedFormat "$scratch/reject.log"
      [[ "$(store_digest "$directory")" == "$original" ]]
      echo "schema9 reader $action $mode $phase: unsupportedFormat, bytes unchanged"
    done
    "$new_bin" maintain "$directory" "$session"
    if [[ "$mode" == create-image-content ]]; then "$new_bin" inspect-image-content "$directory" "$session"; fi
  done
done
