#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-native-context.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# The last reader before opt-in native-context schema 11: RC6 candidate main.
baseline=34103af09baf0ecadfb27389803126ad0dd8f4ac
if ! git -C "$root" cat-file -e "$baseline^{commit}" 2>/dev/null; then git -C "$root" fetch origin "$baseline"; fi
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/baseline" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME -Xswiftc -DIMAGE_CONTENT_RUNTIME >"$scratch/old.log" 2>&1 || { tail -80 "$scratch/old.log"; exit 1; }
SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME -Xswiftc -DIMAGE_CONTENT_RUNTIME -Xswiftc -DNATIVE_CONTEXT_RUNTIME -Xswiftc -DCONTEXT_HANDOFF_RUNTIME >"$scratch/new.log" 2>&1 || { tail -80 "$scratch/new.log"; exit 1; }
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
# Default legacy format remains readable and appendable without native capability.
"$old_bin" create-default "$scratch/legacy" "$session"
"$new_bin" inspect "$scratch/legacy" "$session"
"$new_bin" append "$scratch/legacy" "$session"
if "$new_bin" inspect-native-context "$scratch/legacy" "$session" >"$scratch/legacy-native.log" 2>&1; then echo "schema 3 claimed native support"; exit 1; fi
echo "schema11 reader on schema 3: readable, appendable, no native context support"
for mode in create-native-context-empty create-native-context; do
  directory="$scratch/$mode"
  "$new_bin" "$mode" "$directory" "$session"
  for phase in before after; do
    for action in inspect append maintain; do
      original="$(store_digest "$directory")"
      if "$old_bin" "$action" "$directory" "$session" >"$scratch/reject.log" 2>&1; then echo "old reader accepted schema 11"; exit 1; fi
      grep -q unsupportedFormat "$scratch/reject.log"
      [[ "$(store_digest "$directory")" == "$original" ]]
      echo "schema10 reader $action $mode $phase: unsupportedFormat, bytes unchanged"
    done
    "$new_bin" maintain "$directory" "$session"
    if [[ "$mode" == create-native-context ]]; then "$new_bin" inspect-native-context "$directory" "$session"; fi
  done
done

# The actual schema-11 reader must refuse schema 12 before any writes.
native_baseline=8b896eae05b5fd838e61e67a6cb69ca7c0e78458
if ! git -C "$root" cat-file -e "$native_baseline^{commit}" 2>/dev/null; then git -C "$root" fetch origin "$native_baseline"; fi
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/native-baseline" "$native_baseline"
SWIFTAGENT_SDK_PATH="$scratch/native-baseline" swift build --package-path "$package" --scratch-path "$scratch/native-old" --product JournalReaderCompatibility -Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME -Xswiftc -DIMAGE_CONTENT_RUNTIME -Xswiftc -DNATIVE_CONTEXT_RUNTIME >"$scratch/native-old.log" 2>&1 || { tail -80 "$scratch/native-old.log"; exit 1; }
native_old_bin="$(SWIFTAGENT_SDK_PATH="$scratch/native-baseline" swift build --package-path "$package" --scratch-path "$scratch/native-old" --show-bin-path)/JournalReaderCompatibility"
for mode in create-handoff-empty create-handoff upgrade-handoff; do
  directory="$scratch/$mode"
  if [[ "$mode" == upgrade-handoff ]]; then "$native_old_bin" create-native-context "$directory" "$session"; fi
  "$new_bin" "$mode" "$directory" "$session"
  if [[ "$mode" != create-handoff-empty ]]; then "$new_bin" retire-handoff "$directory" "$session"; fi
  for phase in before after; do
    for action in inspect append maintain; do
      original="$(store_digest "$directory")"
      if "$native_old_bin" "$action" "$directory" "$session" >"$scratch/reject.log" 2>&1; then echo "schema11 reader accepted schema 12"; exit 1; fi
      grep -q unsupportedFormat "$scratch/reject.log"
      [[ "$(store_digest "$directory")" == "$original" ]]
      echo "schema11 reader $action $mode $phase: unsupportedFormat, bytes unchanged"
    done
    "$new_bin" maintain "$directory" "$session"
    if [[ "$mode" != create-handoff-empty ]]; then "$new_bin" inspect-handoff "$directory" "$session"; fi
  done
done
