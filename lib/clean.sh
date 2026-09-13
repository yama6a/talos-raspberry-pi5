#!/usr/bin/env bash
# Removes build scratch: the current build's dir, or the whole .cache tree with --all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- functions ----

clean_every_build() {
  say "removing ${CACHE_DIR}"
  rm -rf "${CACHE_DIR}"
}

clean_current_build() {
  require jq
  load_inputs
  say "removing ${BUILD_DIR}"
  rm -rf "${BUILD_DIR}"
  echo "   other cached builds kept; use 'make distclean' to remove them too"
}

# ---- main ----

if [ "${1:-}" = "--all" ]; then
  clean_every_build
else
  clean_current_build
fi
