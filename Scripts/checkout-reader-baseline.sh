#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 3 || ! "$3" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: bash Scripts/checkout-reader-baseline.sh SOURCE NEW_CHECKOUT COMMIT_SHA" >&2
  exit 64
fi
reader_source="$1"
reader_checkout="$2"
reader_commit="$3"
git clone --quiet --shared --no-checkout "$reader_source" "$reader_checkout"
# A shallow local clone need not copy objects reachable only from FETCH_HEAD.
# Fetch the immutable reader directly into its owned checkout before checkout.
git -C "$reader_checkout" fetch --quiet --no-tags origin "$reader_commit"
git -C "$reader_checkout" checkout --quiet --detach "$reader_commit"
[[ "$(git -C "$reader_checkout" rev-parse HEAD)" == "$reader_commit" ]]
