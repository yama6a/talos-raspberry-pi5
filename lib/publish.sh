#!/usr/bin/env bash
# Pushes the validated installer to GHCR and stages the release assets. Creating the release is lib/release.sh,
# so a run that dies here leaves an orphan image tag that no release announced and the next run overwrites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- state ----
# GHCR_USER is deliberately NOT pre-declared: it may come from the environment, and an empty default here
# would make the ${GHCR_USER:-...} fallback below always win.
RELEASE_TAG=""    # set by resolve_build_revision
CREATED=""        # set by stage_assets
REPO_URL=""
DIGEST=""         # set by push_installer

# ---- functions ----

assert_image_built() {
  [ -f "$IMAGE_FILE" ] || die "missing ${IMAGE_FILE}, run: make build"
}

assert_ghcr_token() {
  : "${GHCR_TOKEN:=${GITHUB_TOKEN:-}}"
  [ -n "$GHCR_TOKEN" ] || die "GHCR_TOKEN (or GITHUB_TOKEN) is empty. Needs a token with write:packages for ${IMAGE_REPO}"
  GHCR_USER="${GHCR_USER:-${GITHUB_REPOSITORY%%/*}}"
}

# The next free build revision for this Talos version, read off the published releases. Stateless, no counter
# file. A previous run that pushed an image but never released reuses and overwrites its own N, which is safe
# because nothing could have consumed a tag no release announced.
resolve_build_revision() {
  local auth=() releases existing revision
  say "resolving the build revision"
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  releases="$(curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases?per_page=100" 2>/dev/null || true)"
  # All in jq: `... | grep | sort | tail` exits 1 when nothing matches, the NORMAL case for the first release
  # of a Talos version, and pipefail turns that into a silent build failure.
  existing="$(printf '%s' "$releases" | jq -r --arg t "$TALOS_VERSION" \
    '[.[]?.tag_name // empty | select(startswith($t + "-")) | ltrimstr($t + "-")
      | select(test("^[0-9]+$")) | tonumber] | max // 0' 2>/dev/null || echo 0)"
  [ -n "$existing" ] || existing=0
  revision=$(( existing + 1 ))
  RELEASE_TAG="${TALOS_VERSION}-${revision}"
  if [ "$existing" -eq 0 ]; then echo "   ${RELEASE_TAG}  (first release for ${TALOS_VERSION})"
  else echo "   ${RELEASE_TAG}  (previous: ${TALOS_VERSION}-${existing})"; fi
}

# SPDX 2.3, hand-built from the resolved inputs rather than scanned out of the image: a filesystem scan cannot
# tell you which raspberrypi/linux commit the kernel came from, and that pointer is what makes the GPL-2.0
# source offer in NOTICE checkable.
write_sbom() {
  jq -n --arg created "$CREATED" --arg tag "$RELEASE_TAG" --arg repo "$REPO_URL" \
    --arg kver "$KVER" --arg talos_tag "$TALOS_TAG" --arg pkgs_tag "$PKGS_TAG" \
    --slurpfile in "$INPUTS_FILE" '
  ($in[0]) as $i |
  {spdxVersion: "SPDX-2.3", dataLicense: "CC0-1.0", SPDXID: "SPDXRef-DOCUMENT",
   name: ("talos-raspberry-pi5-" + $tag),
   documentNamespace: ($repo + "/releases/tag/" + $tag),
   creationInfo: {created: $created, creators: ["Tool: talos-raspberry-pi5", ("Organization: " + $repo)]},
   packages: [
     {SPDXID: "SPDXRef-image", name: "talos-raspberry-pi5", versionInfo: $tag,
      downloadLocation: ($repo + "/releases/tag/" + $tag), filesAnalyzed: false,
      licenseDeclared: "NOASSERTION", licenseConcluded: "NOASSERTION",
      comment: "Aggregate of the packages below; see NOTICE in the source repository."},
     {SPDXID: "SPDXRef-kernel", name: "linux", versionInfo: $kver,
      downloadLocation: ("https://github.com/raspberrypi/linux/archive/" + $i.kernel_commit + ".tar.gz"),
      filesAnalyzed: false, licenseDeclared: "GPL-2.0-only", licenseConcluded: "GPL-2.0-only",
      externalRefs: [{referenceCategory: "SECURITY", referenceType: "cpe23Type",
                      referenceLocator: ("cpe:2.3:o:linux:linux_kernel:" + $i.kernel_version + ":*:*:*:*:*:*:*")}],
      comment: ("Patched with siderolabs/pkgs " + $i.pkgs_describe + " kernel/build/patches, minus the entries in kernel/patch-skip.txt.")},
     {SPDXID: "SPDXRef-talos", name: "talos", versionInfo: $talos_tag,
      downloadLocation: ("https://github.com/siderolabs/talos/tree/" + $i.talos),
      filesAnalyzed: false, licenseDeclared: "MPL-2.0", licenseConcluded: "MPL-2.0"},
     {SPDXID: "SPDXRef-pkgs", name: "pkgs", versionInfo: $pkgs_tag,
      downloadLocation: ("https://github.com/siderolabs/pkgs/tree/" + $i.pkgs_ref),
      filesAnalyzed: false, licenseDeclared: "MPL-2.0", licenseConcluded: "MPL-2.0"},
     {SPDXID: "SPDXRef-overlay", name: "sbc-raspberrypi5", versionInfo: $i.overlay,
      downloadLocation: $i.overlay_url, filesAnalyzed: false,
      licenseDeclared: "MPL-2.0", licenseConcluded: "MPL-2.0",
      comment: "Ships u-boot (GPL-2.0-or-later) and raspberrypi device trees and overlays (GPL-2.0 OR MIT)."},
     {SPDXID: "SPDXRef-iscsi-tools", name: "iscsi-tools", versionInfo: ($i.iscsi_ext | split(":")[1] | split("@")[0]),
      downloadLocation: "https://github.com/siderolabs/extensions", filesAnalyzed: false,
      licenseDeclared: "MPL-2.0", licenseConcluded: "MPL-2.0",
      externalRefs: [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl",
                      referenceLocator: ("pkg:oci/iscsi-tools@" + ($i.iscsi_ext | split("@")[1])
                                         + "?repository_url=ghcr.io/siderolabs&tag=" + ($i.iscsi_ext | split(":")[1] | split("@")[0]))}]},
     {SPDXID: "SPDXRef-util-linux-tools", name: "util-linux-tools", versionInfo: ($i.util_ext | split(":")[1] | split("@")[0]),
      downloadLocation: "https://github.com/siderolabs/extensions", filesAnalyzed: false,
      licenseDeclared: "MPL-2.0", licenseConcluded: "MPL-2.0",
      externalRefs: [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl",
                      referenceLocator: ("pkg:oci/util-linux-tools@" + ($i.util_ext | split("@")[1])
                                         + "?repository_url=ghcr.io/siderolabs&tag=" + ($i.util_ext | split(":")[1] | split("@")[0]))}]}
   ],
   relationships: ([{spdxElementId: "SPDXRef-DOCUMENT", relationshipType: "DESCRIBES", relatedSpdxElement: "SPDXRef-image"}]
     + (["SPDXRef-kernel","SPDXRef-talos","SPDXRef-pkgs","SPDXRef-overlay","SPDXRef-iscsi-tools","SPDXRef-util-linux-tools"]
        | map({spdxElementId: "SPDXRef-image", relationshipType: "CONTAINS", relatedSpdxElement: .})))}' \
    > "${OUT_DIR}/sbom.spdx.json"
}

stage_assets() {
  say "staging release assets in ${OUT_DIR}"
  cp "$INPUTS_FILE" "${OUT_DIR}/build-inputs.json"
  CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
  write_sbom
  ( cd "$OUT_DIR" && sha256 ./*.raw.xz ./kernel-config-* ./build-inputs.json ./sbom.spdx.json > sha256sums.txt )
}

push_installer() {
  local t
  say "pushing ${IMAGE_REPO}"
  printf '%s' "$GHCR_TOKEN" | docker login "$GHCR_SERVER" -u "$GHCR_USER" --password-stdin >/dev/null \
    || die "docker login ${GHCR_SERVER} failed (is the token write:packages for ${GHCR_USER}?)"
  # In CI the runner is thrown away, and the provenance attestation step needs the session to push the
  # attestation to the registry, so only a real machine logs out.
  [ -z "${GITHUB_ACTIONS:-}" ] && trap 'docker logout "$GHCR_SERVER" >/dev/null 2>&1 || true' EXIT

  docker pull -q "$INSTALLER_IMG" >/dev/null || die "cannot pull ${INSTALLER_IMG} from the local registry"
  for t in "$RELEASE_TAG" "$TALOS_VERSION" latest; do
    docker tag "$INSTALLER_IMG" "${IMAGE_REPO}:${t}"
    docker push -q "${IMAGE_REPO}:${t}" >/dev/null || die "docker push ${IMAGE_REPO}:${t} failed"
    echo "   ${IMAGE_REPO}:${t}"
  done
  DIGEST="$(docker buildx imagetools inspect "${IMAGE_REPO}:${RELEASE_TAG}" --format '{{.Manifest.Digest}}')"
}

# Generated, not hand-written: every pin that produced this image, so a reader can reproduce it or check the
# GPL source pointer without cloning anything.
write_release_notes() {
  local image_sha skipped kernel_commit_short kernel_url overlay_short overlay_url
  image_sha="$(sha256hex "$IMAGE_FILE")"
  # Precomputed rather than inlined below: backtick handling inside an unquoted heredoc's command
  # substitution is not portable.
  skipped="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/kernel/patch-skip.txt" | sed 's/^/`/;s/$/`/' | paste -sd' ' -)"
  kernel_commit_short="${KERNEL_COMMIT:0:12}"
  kernel_url="$(jq -r '.kernel_url' "$INPUTS_FILE")"
  overlay_short="${SBCOVERLAY_VERSION:0:12}"
  overlay_url="$(jq -r '.overlay_url' "$INPUTS_FILE")"
cat > "${OUT_DIR}/release-notes.md" <<EOF
Talos ${TALOS_VERSION} for the Raspberry Pi 5, on a raspberrypi/linux ${KVER} kernel.

## Install

\`\`\`
xz -d ${IMAGE_NAME}
sudo dd if=${IMAGE_NAME%.xz} of=/dev/<your-disk> bs=4M status=progress conv=fsync
\`\`\`

## Upgrade an existing node

\`\`\`
talosctl upgrade --nodes <node-ip> --image ${IMAGE_REPO}:${RELEASE_TAG}
\`\`\`

Pin \`${IMAGE_REPO}:${TALOS_VERSION}@${DIGEST}\` to track rebuilds of this Talos version by digest.

## What went into it

| Input | Pinned at |
|---|---|
| Talos | [\`${TALOS_VERSION}\`](https://github.com/siderolabs/talos/releases/tag/${TALOS_VERSION}) |
| Kernel | ${KVER}, from [raspberrypi/linux@\`${kernel_commit_short}\`](${kernel_url}) (resolved via ${KERNEL_SOURCE}) |
| siderolabs/pkgs | [\`${PKGS_TAG}\`](https://github.com/siderolabs/pkgs/tree/${PKGS_REF}) |
| Pi 5 overlay | [\`${overlay_short}\`](${overlay_url}) |
| iscsi-tools | \`${ISCSI_EXT}\` |
| util-linux-tools | \`${UTIL_EXT}\` |
| Skipped pkgs patches | ${skipped} |

Image digest \`${DIGEST}\`, \`${IMAGE_NAME}\` sha256 \`${image_sha}\`.

Licenses and the GPL-2.0 source pointer: see [NOTICE](${REPO_URL}/blob/${RELEASE_TAG}/NOTICE).
EOF
}

write_release_env() {
cat > "${OUT_DIR}/release.env" <<EOF
RELEASE_TAG="${RELEASE_TAG}"
IMAGE_DIGEST="${DIGEST}"
IMAGE_REF="${IMAGE_REPO}:${RELEASE_TAG}"
EOF
  # Same facts, unquoted, for the workflow's attestation and release steps.
  [ -n "${GITHUB_OUTPUT:-}" ] && printf 'RELEASE_TAG=%s\nIMAGE_DIGEST=%s\nIMAGE_REF=%s\n' \
    "$RELEASE_TAG" "$DIGEST" "${IMAGE_REPO}:${RELEASE_TAG}" >> "$GITHUB_OUTPUT"
  return 0
}

print_result() {
  say "PUBLISHED ${IMAGE_REPO}:${RELEASE_TAG}"
  echo "   digest:  ${DIGEST}"
  echo "   assets:  ${OUT_DIR}"
  echo "   next:    make release   (creates the GitHub release; CI attests first)"
}

# ---- main ----

require docker jq curl
load_inputs
load_meta
assert_image_built
assert_ghcr_token
resolve_build_revision
stage_assets
push_installer
write_release_notes
write_release_env
print_result
