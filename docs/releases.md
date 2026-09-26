# Releases

Verifying a release and cutting one by hand are in the [releases runbook](runbooks/releases.md).

## Tags

Each build pushes three OCI tags and one GitHub release. The GitHub release uses the immutable tag.

| Tag | Moves | Points at |
|---|---|---|
| `vX.Y.Z` | on every rebuild of that Talos version | the newest build for that Talos version |
| `vX.Y.Z-N` | never | build revision `N` of that Talos version |
| `latest` | on every release | the newest build, any version |

- The same package also holds `kernel-<hash>` tags. They are the build's kernel cache, not release artifacts.
- One Talos version can have several builds. The overlay commit and the extension digests move on their own,
  and `raspberrypi/linux` can be rebased for the same kernel version. The revision `N` counts those.
- Pin the rolling tag with a digest: `ghcr.io/yama6a/talos-raspberry-pi5:vX.Y.Z@sha256:...`. A rebuild then
  shows up as a digest bump and a Talos upgrade as a tag bump, which Renovate's docker datasource handles.
- A Renovate consumer that tracks the release tag, not the image, needs `regex` versioning with a `build`
  group. `vX.Y.Z-N` is a semver prerelease, and `config:recommended` skips those:

  ```json5
  {
    matchDepNames: ["yama6a/talos-raspberry-pi5"],
    versioning: "regex:^v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-(?<build>\\d+)$",
  }
  ```

## Build revision

- `lib/publish.sh` takes the highest published `N` for the Talos version and adds one. No counter file.
- The release comes last. A run that pushes an image and then dies leaves a tag no release announced, and the
  next run reuses and overwrites that `N`.
- `build.yaml` queues runs and never runs two at once, so two pushes cannot race for one `N`.

## What triggers a build

- A push to `main` that touches `versions.env`, `lib/`, `kernel/`, `build/` or the build workflow.
- A manual `workflow_dispatch`. `force` builds anyway, `dryRun` builds and validates without publishing.
- Nothing else. No scheduled rebuild. Pull requests get static checks only, because a build with changed
  kernel inputs costs about 90 minutes of runner time.
- Every run compares its fingerprint with `build-inputs.json` on the newest release for that Talos version.
  Equal means nothing reaching the image changed, and the run stops in under a minute.
- The fingerprint covers the resolved upstream refs and the recipe files: `lib/build.sh`, `lib/preflight.sh`,
  `build/Makefile.talos`, `kernel/pi5-rpi.fragment` and `kernel/patch-skip.txt`. So an edit to any of those,
  comments included, cuts a new revision. An edit to the fragment or the skip list also misses the kernel
  cache and costs a full kernel compile.

## Release contents

| Asset | What it is |
|---|---|
| `metal-arm64-rpi5.raw.xz` | the raw disk image, for the first install |
| `sha256sums.txt` | checksums for every other asset |
| `build-inputs.json` | every resolved upstream ref, and the fingerprint |
| `sbom.spdx.json` | SPDX 2.3, per-component licenses and download locations |
| `kernel-config-arm64.base` | siderolabs/pkgs' stock arm64 kernel config |
| `kernel-config-arm64.fragment` | the Pi 5 fragment layered over it |

- The two config halves plus `make olddefconfig` state exactly what was compiled. The reconciled `.config`
  exists only inside a build stage that ships nothing.
- CI signs a build-provenance attestation for the image and the raw disk image. The image's attestation sits
  in the registry beside it, so `cosign` can find it too.
