#!/usr/bin/env bash
# Shared by compiler verification and Apple toolchain selection. Works when sourced from bash or zsh.
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh has no BASH_SOURCE; %x is the file being sourced. eval keeps bash from parsing it.
  eval '_otoha_version_script="${(%):-%x}"'
else
  _otoha_version_script="${BASH_SOURCE[0]}"
fi
required="${SWIFT_AGENT_REQUIRED_SWIFT:-$(cat "$(cd "$(dirname "$_otoha_version_script")/.." && pwd)/.swift-version")}"
unset _otoha_version_script

is_required() {
  local pattern="${required//./\\.}"
  echo "$1" | grep -Eq "Swift version ${pattern}( |$)"
}

# The identifier TOOLCHAINS takes: a standalone toolchain keeps it in Info.plist,
# Xcode's own toolchain in ToolchainInfo.plist.
toolchain_identifier() {
  if [ -f "$1/Info.plist" ]; then
    plutil -extract CFBundleIdentifier raw "$1/Info.plist"
  else
    plutil -extract Identifier raw "$1/ToolchainInfo.plist"
  fi
}
