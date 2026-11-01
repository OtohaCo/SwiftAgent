#!/usr/bin/env bash
# Selects the Apple toolchain with the pinned Swift for the current shell:
#   source Scripts/select-apple-toolchain.sh
# Works from bash and zsh (agents may run commands with zsh and a temporary HOME). Exports
# DEVELOPER_DIR, TOOLCHAINS and PATH; keeps Xcode's SDKs and does not change
# xcode-select globally. The search runs in find-apple-toolchain.sh as a separate bash process,
# so the caller's shell options and variables stay as they were. Returns 1 when no toolchain fits.
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh has no BASH_SOURCE; %x is the file being sourced. eval keeps bash from parsing it.
  eval '_otoha_toolchain_dir="${(%):-%x}"'
else
  _otoha_toolchain_dir="${BASH_SOURCE[0]:-$0}"
fi
_otoha_toolchain_dir="$(cd "$(dirname "$_otoha_toolchain_dir")" && pwd)"
_otoha_toolchain_status=1
if _otoha_toolchain_env="$(/bin/bash "$_otoha_toolchain_dir/find-apple-toolchain.sh")"; then
  eval "$_otoha_toolchain_env"
  export DEVELOPER_DIR TOOLCHAINS PATH
  hash -r
  if "$_otoha_toolchain_dir/require-toolchain.sh" --apple; then
    _otoha_toolchain_status=0
  fi
fi
unset _otoha_toolchain_dir _otoha_toolchain_env
# Expand the status before unsetting it; exit when the file was run instead of sourced.
eval "unset _otoha_toolchain_status; return $_otoha_toolchain_status 2>/dev/null || exit $_otoha_toolchain_status"
