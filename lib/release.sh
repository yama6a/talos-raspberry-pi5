#!/usr/bin/env bash
# Creates the GitHub release from what publish.sh staged. Last step on purpose: the release is what makes a
# build revision real, so nothing before it can strand a tag someone might pin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require gh jq
load_inputs
[ -f "${OUT_DIR}/release.env" ] || die "missing ${OUT_DIR}/release.env, run: make publish"
# shellcheck disable=SC1090
source "${OUT_DIR}/release.env"

gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 \
  && die "release ${RELEASE_TAG} already exists; publish.sh should have picked the next revision"

say "creating release ${RELEASE_TAG}"
gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --title "$RELEASE_TAG" --notes-file "${OUT_DIR}/release-notes.md" \
  "${OUT_DIR}/${IMAGE_NAME}" \
  "${OUT_DIR}/sha256sums.txt" \
  "${OUT_DIR}/sbom.spdx.json" \
  "${OUT_DIR}/build-inputs.json" \
  "${OUT_DIR}/kernel-config-arm64.base" \
  "${OUT_DIR}/kernel-config-arm64.fragment"

say "RELEASED"
echo "   https://github.com/${GITHUB_REPOSITORY}/releases/tag/${RELEASE_TAG}"
