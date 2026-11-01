#!/usr/bin/env bash
# Finds the Apple toolchain that provides the pinned Swift and prints the shell assignments
# select-apple-toolchain.sh exports (DEVELOPER_DIR, TOOLCHAINS, PATH). Runs as its own
# bash process so the caller's shell (bash or zsh) keeps its options and variables.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$root/toolchain-version.sh"

# Sandboxed agents may give commands a temporary HOME, so toolchains the user installed are
# looked up in the account's real home first. SWIFT_AGENT_REAL_HOME overrides the lookup (tests).
real_home() {
  local user home=""
  if [[ -n "${SWIFT_AGENT_REAL_HOME:-}" ]]; then
    echo "$SWIFT_AGENT_REAL_HOME"
    return
  fi
  user="$(id -un)"
  home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' || true)"
  if [[ -z "$home" && "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
    eval "home=~$user"
    [[ "$home" == "~$user" ]] && home=""
  fi
  echo "${home:-$HOME}"
}

shopt -s nullglob
found=""
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
select_installed() {
  local toolchain report app home homes=("$(real_home)")
  [[ "${HOME:-}" != "${homes[0]}" && -n "${HOME:-}" ]] && homes+=("$HOME")
  local candidates=()
  for home in "${homes[@]}"; do
    candidates+=("$home"/Library/Developer/Toolchains/*.xctoolchain)
  done
  for toolchain in "${candidates[@]}" /Library/Developer/Toolchains/*.xctoolchain; do
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
  # stdout carries the assignments; progress goes to stderr.
  echo "Installing official Swift ${required} alongside the selected Xcode." >&2
  swiftly_bin="${SWIFTLY_BIN_DIR:-$(real_home)/.swiftly/bin}/swiftly"
  if [[ ! -x "$swiftly_bin" ]]; then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL https://download.swift.org/swiftly/darwin/swiftly.pkg -o "$work/swiftly.pkg"
    pkgutil --check-signature "$work/swiftly.pkg" >&2
    installer -pkg "$work/swiftly.pkg" -target CurrentUserHomeDirectory >&2
  fi
  "$swiftly_bin" init --assume-yes --no-modify-profile --skip-install --quiet-shell-followup >&2
  "$swiftly_bin" install "$required" --assume-yes >&2
  select_installed
fi

if [[ -z "$found" ]]; then
  echo "No installed Apple toolchain provides Swift ${required}." >&2
  exit 1
fi

identifier="$(toolchain_identifier "$found")"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=$developer" >> "$GITHUB_ENV"
  echo "TOOLCHAINS=$identifier" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$developer/usr/bin" >> "$GITHUB_PATH"
  echo "$found/usr/bin" >> "$GITHUB_PATH"
fi
printf 'DEVELOPER_DIR=%q\nTOOLCHAINS=%q\nPATH=%q\n' \
  "$developer" "$identifier" "$found/usr/bin:$developer/usr/bin:$PATH"
