#!/usr/bin/env bash
set -euo pipefail

required="${SWIFT_AGENT_REQUIRED_SWIFT:-6.4}"

is_required() {
  echo "$1" | grep -Eq "Swift version ${required}([.-]| |$)"
}

current="$(swift --version 2>&1 || true)"
if is_required "$current"; then
  echo "Current swift already satisfies Swift ${required}."
  echo "$current"
  exit 0
fi

echo "Current swift is not ${required}:"
echo "$current"
echo "Searching /Applications for an Xcode that provides Swift ${required}."

shopt -s nullglob
found=""
for app in /Applications/Xcode*.app; do
  candidate="$app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  if [[ ! -x "$candidate" ]]; then
    continue
  fi
  report="$("$candidate" --version 2>&1 || true)"
  echo "$app => $report"
  if is_required "$report"; then
    found="$app"
    break
  fi
done

if [[ -z "$found" ]]; then
  echo "No installed Xcode provides Swift ${required}." >&2
  ls /Applications | grep -i xcode || true
  exit 1
fi

developer="$found/Contents/Developer"
echo "Selecting $developer"
if [[ "$(id -u)" -eq 0 ]]; then
  xcode-select -s "$developer"
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
  sudo xcode-select -s "$developer"
else
  export DEVELOPER_DIR="$developer"
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=$developer" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$developer/usr/bin" >> "$GITHUB_PATH"
  echo "$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" >> "$GITHUB_PATH"
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-$developer}"
export PATH="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$developer/usr/bin:$PATH"
hash -r
swift --version
