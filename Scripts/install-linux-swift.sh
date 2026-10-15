#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$root/toolchain-version.sh"

publish_compiler() {
  # Swiftly proxies consult the working directory. Reader checkouts must keep
  # this compiler even when their own .swift-version selects another release.
  local swift_bin
  if command -v swiftly >/dev/null 2>&1; then
    swift_bin="$(swiftly run "+${required}" /bin/sh -c 'command -v swift')"
  else
    swift_bin="$(command -v swift)"
  fi
  export PATH="$(dirname "$swift_bin"):$PATH"
  hash -r
  "$root/require-toolchain.sh"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    dirname "$(command -v swift)" >> "$GITHUB_PATH"
  fi
  echo "SWIFT_BIN=$(command -v swift)"
}

if command -v swift >/dev/null 2>&1 && "$root/require-toolchain.sh"; then
  publish_compiler
  exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "install-linux-swift.sh is for Linux CI hosts." >&2
  exit 1
fi

apt_get() {
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get "$@"
  else
    sudo apt-get "$@"
  fi
}

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt_get update
  apt_get install -y --no-install-recommends \
    binutils ca-certificates curl git gnupg2 \
    libc6-dev libcurl4-openssl-dev libedit-dev libicu-dev \
    libncurses-dev libpython3-dev libsqlite3-dev libxml2-dev \
    libgcc-13-dev libstdc++-13-dev libz3-dev \
    pkg-config tzdata unzip uuid-dev zlib1g-dev
fi

arch="$(uname -m)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-${arch}.tar.gz" -o "$work/swiftly.tar.gz"
tar -xzf "$work/swiftly.tar.gz" -C "$work"
"$work/swiftly" init --assume-yes --quiet-shell-followup --skip-install
# shellcheck disable=SC1090
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
hash -r

swiftly install "$required" --assume-yes
publish_compiler
