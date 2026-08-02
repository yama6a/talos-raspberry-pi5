#!/usr/bin/env bash
# Removes build scratch. With no args, only the CURRENT build's dir (the one the resolved inputs point at),
# so other cached builds survive. With --all, the whole .cache tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [ "${1:-}" = "--all" ]; then
  say "removing ${CACHE_DIR}"
  rm -rf "${CACHE_DIR}"
  exit 0
fi

require jq
load_inputs
say "removing ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
echo "   other cached builds kept; use 'make distclean' to remove them too"
