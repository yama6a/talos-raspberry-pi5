#!/usr/bin/env bash
# Applies one kernel patch to the tree in the working directory, behind a dry-run: apply what applies, skip only
# what kernel/patch-skip.txt names, fail on anything else. A patch from kernel/patches is never skipped.
#
# Runs in two places. The build copies it into pkgs' kernel recipe and calls it once per patch inside the
# toolchain container. Preflight calls it on the files the patches touch. So both apply the same rule.
#
# Usage: patch_gate.sh <patch> <skip slugs> <local slugs>. The slug lists are space-separated.
set -euo pipefail

patch="$1"
skip="$2"
local_slugs="$3"

slug=$(basename "$patch" .patch)
case "$slug" in [0-9]*-*) slug=${slug#*-} ;; esac

if patch -p1 -N --dry-run --silent < "$patch" > /dev/null 2>&1; then
  patch -p1 -N < "$patch"
  echo "Applied patch $slug"
elif echo "$local_slugs" | tr ' ' '\n' | grep -qxF "$slug"; then
  echo "FAILED: kernel/patches patch does not apply to raspberrypi/linux: $slug"
  echo "  rebase it onto the kernel commit in .cache/build-inputs.json, or drop it if the rpi tree has it now"
  exit 1
elif echo "$skip" | tr ' ' '\n' | grep -qxF "$slug"; then
  echo "Skipped patch $slug (kernel/patch-skip.txt)"
else
  echo "FAILED: pkgs patch does not apply to raspberrypi/linux: $slug"
  echo "  pkgs patches target kernel.org, we build the rpi fork, so collisions are expected"
  echo "  fix already in the rpi tree -> add '$slug' to kernel/patch-skip.txt"
  echo "  fix genuinely missing       -> rebase the patch onto the rpi tree, or skip it deliberately"
  exit 1
fi
