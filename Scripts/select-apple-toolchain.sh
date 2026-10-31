#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$root/toolchain-version.sh"

shopt -s nullglob
found=""
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
select_installed() {
  local toolchain report app
  for toolchain in "$HOME"/Library/Developer/Toolchains/*.xctoolchain /Library/Developer/Toolchains/*.xctoolchain; do
    [[ -x "$toolchain/usr/bin/swift" ]] || continue
    report="$("$toolchain/usr/bin/swift" --version 2>&1 || true)"
    if is_required "$report"; then
      found="$toolchain"
      return
    fi
  done
  for app in /Applications/Xcode*.app; do
    toolchain="$app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
    [[ -x "$toolchain/usr/bin/swift" ]] || continue
    report="$("$toolchain/usr/bin/swift" --version 2>&1 || true)"
    if is_required "$report"; then
      found="$toolchain"
      developer="$app/Contents/Developer"
      return
    fi
  done
}

select_installed
if [[ -z "$found" ]]; then
  echo "Installing official Swift ${required} alongside the selected Xcode."
  swiftly_bin="${SWIFTLY_BIN_DIR:-$HOME/.swiftly/bin}/swiftly"
  if [[ ! -x "$swiftly_bin" ]]; then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL https://download.swift.org/swiftly/darwin/swiftly.pkg -o "$work/swiftly.pkg"
    pkgutil --check-signature "$work/swiftly.pkg"
    installer -pkg "$work/swiftly.pkg" -target CurrentUserHomeDirectory
  fi
  "$swiftly_bin" init --assume-yes --no-modify-profile --skip-install --quiet-shell-followup
  "$swiftly_bin" install "$required" --assume-yes
  select_installed
fi

if [[ -z "$found" ]]; then
  echo "No installed Apple toolchain provides Swift ${required}." >&2
  exit 1
fi

# Keep Xcode's SDKs; select the same compiler for CLI, xcrun and xcodebuild.
# Selection is local to this shell/CI job and does not change xcode-select globally.
identifier="$(toolchain_identifier "$found")"
export DEVELOPER_DIR="$developer"
export TOOLCHAINS="$identifier"
export PATH="$found/usr/bin:$developer/usr/bin:$PATH"
hash -r
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=$developer" >> "$GITHUB_ENV"
  echo "TOOLCHAINS=$identifier" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$developer/usr/bin" >> "$GITHUB_PATH"
  echo "$found/usr/bin" >> "$GITHUB_PATH"
fi
"$root/require-toolchain.sh" --apple
