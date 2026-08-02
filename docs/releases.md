# Releases

## Tags

Three OCI tags per build, one GitHub release.

| Tag | Immutable | Points at |
|---|---|---|
| `v1.13.7` | no | the newest build for that Talos version |
| `v1.13.7-2` | yes | build revision 2 of that Talos version |
| `latest` | no | the newest build, any version |

The GitHub release is tagged `v1.13.7-2`, the immutable one.

Two things vary independently, which is why a Talos version can have several builds: the overlay commit and
extension digests move on their own, and `raspberrypi/linux` can be rebased onto a different commit for the
same kernel version. The revision counts those.

**Pin the rolling tag with a digest.** `ghcr.io/yama6a/talos-raspberry-pi5:v1.13.7@sha256:...` means a
rebuild shows up as a digest bump and a Talos upgrade shows up as a tag bump, which is what Renovate's docker
datasource is good at. Pin the immutable tag only when you specifically want to freeze one build.

Renovate consumers tracking the release tag rather than the image need `regex` versioning with a `build`
group, because `v1.13.7-2` is a semver *prerelease* and `config:recommended` skips those:

```json5
{
  matchDepNames: ["yama6a/talos-raspberry-pi5"],
  versioning: "regex:^v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-(?<build>\\d+)$",
}
```

## How the revision is picked

`publish.sh` lists the published releases, takes the highest `N` for this Talos version and adds one. No
counter file, no state.

That works because the release is created last. A run that pushes the image and then dies leaves a tag no
release announced, so the next run picks the same `N` and overwrites it. Nothing can have consumed it. The
build workflow also runs under a `concurrency` group that queues rather than cancels, so two pushes cannot
race for the same number.

## What triggers a build

- A push to `main` touching `versions.env`, `lib/`, `kernel/`, `build/` or the build workflow.
- A manual `workflow_dispatch`, with `force` to build anyway and `dryRun` to build and validate without
  publishing.

Nothing else. There is no scheduled rebuild, and pull requests get static checks only, because a full build
is over an hour of runner time.

Every run resolves the inputs first, then compares the resulting fingerprint against `build-inputs.json` on
the newest release for that Talos version. Identical means the push changed nothing that reaches the image,
and the run stops in under a minute.

The fingerprint covers the resolved upstream refs plus a hash of `lib/build.sh`, `build/Makefile.talos`,
`kernel/pi5-rpi.fragment` and `kernel/patch-skip.txt`. It deliberately excludes the docs, the README, the
workflows and the renovate config. Editing a build script does cut a new revision, which is the honest
answer, since the build script is the build.

## Release contents

| Asset | What it is |
|---|---|
| `metal-arm64-rpi5.raw.xz` | the raw disk image, for the first install |
| `sha256sums.txt` | checksums for every other asset |
| `build-inputs.json` | every resolved upstream ref, and the fingerprint |
| `sbom.spdx.json` | SPDX 2.3, per-component licenses and download locations |
| `kernel-config-arm64.base` | siderolabs/pkgs' stock arm64 kernel config |
| `kernel-config-arm64.fragment` | the Pi 5 fragment layered over it |

The two config halves plus `make olddefconfig` are the complete statement of what was compiled. The
reconciled `.config` only ever exists inside a build stage that ships nothing.

The installer image goes to GHCR under the three tags above.

## Verifying

```
sha256sum -c sha256sums.txt
gh attestation verify oci://ghcr.io/yama6a/talos-raspberry-pi5:v1.13.7-2 --owner yama6a
gh attestation verify metal-arm64-rpi5.raw.xz --owner yama6a
```

Both artifacts carry a signed build-provenance attestation tying them to the workflow run that produced
them. The image's attestation is pushed to the registry alongside it, so `cosign` and other tools can find
it too.

## Cutting a release by hand

```
make build && make validate && make publish && make release
```

`publish` needs `GHCR_TOKEN` with `write:packages`, `release` needs `gh` authenticated. No provenance
attestation: that only exists for CI runs, because it is signed against the workflow's OIDC identity.
