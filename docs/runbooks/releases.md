# Releases runbook

The tag scheme and what triggers a build are in [releases.md](../releases.md).

## Verify a release

1. Download the release assets, then check them:

   ```
   sha256sum -c sha256sums.txt
   gh attestation verify oci://ghcr.io/yama6a/talos-raspberry-pi5:vX.Y.Z-N --owner yama6a
   gh attestation verify metal-arm64-rpi5.raw.xz --owner yama6a
   ```

   Expected: every checksum `OK`, and both attestations verified.

## Cut a release by hand

1. Export a token with `write:packages` as `GHCR_TOKEN`, and log `gh` in.
2. Build, check, publish and release:

   ```
   make build && make validate && make publish && make release
   ```

   Expected: `RELEASED` and the release URL.

A hand-cut release has no provenance attestation. The attestation is signed against the CI workflow's OIDC
identity, so only a CI run can make one.
