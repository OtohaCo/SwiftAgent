#!/usr/bin/env bash
set -euo pipefail

required="${SWIFT_AGENT_REQUIRED_SWIFT:-6.4}"
root="$(cd "$(dirname "$0")" && pwd)"

if command -v swift >/dev/null 2>&1 && "$root/require-toolchain.sh"; then
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

swiftly install "$required" || true
swiftly use "$required" || true
if ! "$root/require-toolchain.sh"; then
  echo "Swift ${required} release toolchain was not usable; trying ${required}.x-snapshot."
  swiftly install "${required}.x-snapshot" || true
  swiftly use "${required}.x-snapshot" || true
fi

if [[ -n "${GITHUB_PATH:-}" ]] && command -v swift >/dev/null 2>&1; then
  dirname "$(command -v swift)" >> "$GITHUB_PATH"
fi

# Keep the toolchain on PATH for later scripts in the same shell (local Docker).
if command -v swift >/dev/null 2>&1; then
  echo "SWIFT_BIN=$(command -v swift)"
fi

"$root/require-toolchain.sh"
