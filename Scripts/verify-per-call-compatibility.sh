#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/swiftagent-per-call.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
baseline=27ceea564740bca8deac841b9e8c0231c2cd13ef
bash "$root/Scripts/checkout-reader-baseline.sh" "$root" "$scratch/baseline" "$baseline"
package="$root/Tests/JournalReaderCompatibility"
for reader in old new; do
  sdk="$root"
  flags=(-Xswiftc -DNEW_RUNTIME)
  if [[ "$reader" == old ]]; then sdk="$scratch/baseline"; else flags=(-Xswiftc -DPER_CALL_RUNTIME); fi
  SWIFTAGENT_SDK_PATH="$sdk" swift build --package-path "$package" --scratch-path "$scratch/$reader" --product JournalReaderCompatibility "${flags[@]}" >"$scratch/$reader.log" 2>&1 || { tail -80 "$scratch/$reader.log"; exit 1; }
done
old_bin="$(SWIFTAGENT_SDK_PATH="$scratch/baseline" swift build --package-path "$package" --scratch-path "$scratch/old" --show-bin-path)/JournalReaderCompatibility"
new_bin="$(SWIFTAGENT_SDK_PATH="$root" swift build --package-path "$package" --scratch-path "$scratch/new" --show-bin-path)/JournalReaderCompatibility"
session=00000000-0000-0000-0000-000000000074
"$old_bin" create-default "$scratch/legacy" "$session"
"$new_bin" inspect "$scratch/legacy" "$session"
"$new_bin" create-per-call "$scratch/capable" "$session"
# Actual unmodified old reader, before and after candidate maintenance.
for phase in before after; do
  for action in inspect append maintain; do
    if "$old_bin" "$action" "$scratch/capable" "$session" >"$scratch/reject.log" 2>&1; then echo "old reader accepted schema 8"; exit 1; fi
    grep -q unsupportedFormat "$scratch/reject.log"
    echo "old $action $phase: unsupportedFormat"
  done
  "$new_bin" maintain "$scratch/capable" "$session"
  "$new_bin" inspect-per-call "$scratch/capable" "$session"
done
