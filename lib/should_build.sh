#!/usr/bin/env bash
# Answers whether the resolved inputs differ from the newest published build of this Talos version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
should_build.sh
  prints  build=true|false  plus a reason, and appends both to \$GITHUB_OUTPUT when CI set it
  FORCE=true  always answer true
EOF
}

# ---- state ----
AUTH=()   # set by use_github_token, read by gh_get

# ---- functions ----

use_github_token() {
  [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  return 0
}

gh_get() { curl -fsSL --retry 3 ${AUTH[@]+"${AUTH[@]}"} "$@"; }

decide() {
  printf 'build=%s\n' "$1"
  printf '%s\n' "$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf 'build=%s\nreason=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  exit 0
}

newest_release_tag() {
  local releases
  releases="$(gh_get "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases?per_page=100" 2>/dev/null || true)"
  printf '%s' "$releases" | jq -r --arg t "$TALOS_VERSION" \
    '[.[]?.tag_name | select(startswith($t + "-"))] | sort_by(ltrimstr($t + "-") | tonumber) | last // ""' 2>/dev/null
}

published_fingerprint() {
  gh_get "https://github.com/${GITHUB_REPOSITORY}/releases/download/${1}/build-inputs.json" 2>/dev/null \
    | jq -r '.fingerprint // ""' 2>/dev/null || true
}

# ---- main ----

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

require curl jq
load_inputs
use_github_token

[ "${FORCE:-false}" = "true" ] && decide true "forced"

LATEST="$(newest_release_tag)"
[ -n "$LATEST" ] || decide true "no release exists for ${TALOS_VERSION} yet"

PREV="$(published_fingerprint "$LATEST")"
[ -n "$PREV" ] || decide true "${LATEST} has no readable build-inputs.json to compare against"

[ "$PREV" = "$FINGERPRINT" ] \
  && decide false "inputs are identical to ${LATEST} (fingerprint ${PREV:0:12})" \
  || decide true "inputs differ from ${LATEST} (${PREV:0:12} -> ${FINGERPRINT:0:12})"
