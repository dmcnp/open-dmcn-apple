#!/usr/bin/env bash
# The open-dmcn checkout this repository mirrors its core schema from, at the tag
# OPEN_DMCN_VERSION pins.
#
#   dev/open-dmcn.sh path        print the checkout's path, cloning it at the pin if needed
#   dev/open-dmcn.sh sync        copy the pinned proto/*.proto into proto/ (then `make proto`)
#   dev/open-dmcn.sh check       fail if proto/ differs from the pinned schema by one byte
#
# OPEN_DMCN names an existing checkout (default: ../open-dmcn when it exists, else a shallow
# clone under .build/open-dmcn). An existing checkout must be exactly at the pin with nothing
# uncommitted, so the mirror can only ever come from a tagged release.
set -euo pipefail
cd "$(dirname "$0")/.."

PIN=$(tr -d '[:space:]' < OPEN_DMCN_VERSION)
REMOTE=${OPEN_DMCN_REMOTE:-https://github.com/dmcnp/open-dmcn.git}

checkout() {
  local dir=${OPEN_DMCN:-}
  if [ -z "$dir" ] && [ -d ../open-dmcn/.git ]; then dir=../open-dmcn; fi
  if [ -z "$dir" ]; then
    dir=.build/open-dmcn
    if [ ! -d "$dir/.git" ] || [ "$(git -C "$dir" describe --tags --exact-match 2>/dev/null)" != "$PIN" ]; then
      rm -rf "$dir"
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PIN" "$REMOTE" "$dir" >&2
    fi
  fi
  local at
  at=$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo "an untagged commit")
  if [ "$at" != "$PIN" ]; then
    echo "open-dmcn at $dir is at $at, not the pin $PIN (OPEN_DMCN_VERSION)" >&2
    exit 1
  fi
  if [ -n "$(git -C "$dir" status --porcelain -- proto)" ]; then
    echo "open-dmcn at $dir has uncommitted changes under proto/" >&2
    exit 1
  fi
  echo "$dir"
}

case "${1:-}" in
  path)
    checkout
    ;;
  sync)
    src=$(checkout)
    rm -f proto/*.proto
    cp "$src"/proto/*.proto proto/
    echo "proto/ now mirrors open-dmcn $PIN; run make proto to regenerate"
    ;;
  check)
    src=$(checkout)
    if ! diff -r -q -x README.md "$src/proto" proto >/dev/null; then
      diff -r -q -x README.md "$src/proto" proto >&2 || true
      echo "proto/ is not a byte-identical mirror of open-dmcn $PIN: run make proto-sync" >&2
      exit 1
    fi
    ;;
  *)
    sed -n '2,13p' "$0" >&2
    exit 2
    ;;
esac
