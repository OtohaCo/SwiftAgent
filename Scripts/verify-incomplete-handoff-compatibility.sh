#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-incomplete-handoff.XXXXXX")"
evidence="$root/.ci-logs/issue108/readers-$(basename "$scratch")"
cleanup() { mkdir -p "$evidence"; for log in "$scratch"/*.log; do [[ ! -f "$log" ]] || cp "$log" "$evidence/"; done; rm -rf "$scratch"; }
trap cleanup EXIT
# Actual immutable RC6 schema-13 reader, with completed-turn handoff only.
baseline=a7940ae0286c7accef4aef8647919c57c042b8b9
if ! git -C "$root" cat-file -e "$baseline^{commit}" 2>/dev/null; then git -C "$root" fetch origin "$baseline"; fi
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/baseline" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
flags=(-Xswiftc -DPER_CALL_RUNTIME -Xswiftc -DRUN_RECORD_RUNTIME -Xswiftc -DIMAGE_CONTENT_RUNTIME -Xswiftc -DNATIVE_CONTEXT_RUNTIME -Xswiftc -DCONTEXT_HANDOFF_RUNTIME -Xswiftc -DFILE_CONTENT_RUNTIME)
SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --product JournalReaderCompatibility "${flags[@]}" >"$scratch/old.log" 2>&1 || { tail -80 "$scratch/old.log"; exit 1; }
SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --product JournalReaderCompatibility "${flags[@]}" -Xswiftc -DINCOMPLETE_CONTEXT_HANDOFF_RUNTIME >"$scratch/new.log" 2>&1 || { tail -80 "$scratch/new.log"; exit 1; }
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
session=00000000-0000-0000-0000-000000000014
for mode in create-default create-handoff-empty create-file-content; do
  directory="$scratch/old-$mode"
  "$old_bin" "$mode" "$directory" "$session"
  "$new_bin" inspect "$directory" "$session"
  if [[ "$mode" == create-file-content ]]; then
    "$new_bin" append-file-content "$directory" "$session"
    "$new_bin" inspect-file-content "$directory" "$session"
  else
    "$new_bin" append "$directory" "$session"
  fi
  echo "schema14 reader $mode: readable, appendable"
done
for mode in create-incomplete-handoff-empty create-incomplete-handoff upgrade12 upgrade13; do
  directory="$scratch/$mode"
  if [[ "$mode" == upgrade12 || "$mode" == upgrade13 ]]; then
    source_mode=create-handoff-empty
    [[ "$mode" != upgrade13 ]] || source_mode=create-file-content
    "$old_bin" "$source_mode" "$directory" "$session"
    "$new_bin" upgrade-incomplete-handoff "$directory" "$session"
  else
    "$new_bin" "$mode" "$directory" "$session"
  fi
  if [[ "$mode" == create-incomplete-handoff ]]; then "$new_bin" retire-incomplete-handoff "$directory" "$session"; fi
  for phase in before after; do
    for action in inspect append maintain; do
      original="$(store_digest "$directory")"
      if "$old_bin" "$action" "$directory" "$session" >"$scratch/reject-$mode-$phase-$action.log" 2>&1; then echo "RC6 reader accepted schema14"; exit 1; fi
      grep -q unsupportedFormat "$scratch/reject-$mode-$phase-$action.log"
      [[ "$(store_digest "$directory")" == "$original" ]]
      echo "RC6 schema13 reader $action $mode $phase: unsupportedFormat, bytes unchanged"
    done
    "$new_bin" maintain "$directory" "$session"
    if [[ "$mode" == create-incomplete-handoff ]]; then "$new_bin" inspect-incomplete-handoff "$directory" "$session"; fi
  done
done
