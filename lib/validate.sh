#!/usr/bin/env bash
# Checks the built image offline: partition layout, Pi 5 boot bits, kernel label, baked extensions.
# No `set -e`: every check runs and the summary reports all failures at once.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
# renovate: datasource=docker
ALPINE_IMAGE="alpine:3.24"     # macOS cannot loop-mount Linux filesystems, so the checks run in here
MIN_BYTES=50000000             # a plausible compressed image is between these two
MAX_BYTES=600000000

# ---- state ----
UKI_DIR=""   # set by extract_uki, read by check_kernel_and_extensions

# ---- functions ----

assert_image_built() {
  [ -f "$IMAGE_FILE" ] || die "missing ${IMAGE_FILE}, run: make build"
}

# The installer's boot binary is a UKI: one EFI file holding the kernel, initrd and cmdline together.
extract_uki() {
  UKI_DIR="$BUILD_DIR/uki"; rm -rf "$UKI_DIR"; mkdir -p "$UKI_DIR"
  if ! docker pull -q "$INSTALLER_IMG" >/dev/null 2>&1; then
    bad "cannot pull ${INSTALLER_IMG} (is the local registry container still running?)"
    return 1
  fi
  local cid
  cid="$(docker create "$INSTALLER_IMG" sh)"
  docker cp "$cid:/usr/install/arm64/vmlinuz.efi" "$UKI_DIR/vmlinuz.efi" >/dev/null 2>&1
  docker rm "$cid" >/dev/null
  chmod 644 "$UKI_DIR/vmlinuz.efi" 2>/dev/null
  return 0
}

check_raw_image() {
  if docker run --rm --privileged -e IMAGE_NAME="$IMAGE_NAME" -e MIN="$MIN_BYTES" -e MAX="$MAX_BYTES" \
       -v "$OUT_DIR:/work" -v /dev:/dev "$ALPINE_IMAGE" sh -c '
  set -e; apk add -q util-linux xz >/dev/null 2>&1; cd /work; F="$IMAGE_NAME"; RAW="${IMAGE_NAME%.xz}"
  fail=0
  xz -t "$F" && echo "  integrity (xz -t)" || { echo "  FAILED integrity"; fail=1; }
  sz=$(stat -c%s "$F"); [ "$sz" -gt "$MIN" ] && [ "$sz" -lt "$MAX" ] && echo "  size ($sz bytes)" || { echo "  FAILED size $sz"; fail=1; }
  xz -dkf "$F"; LOOP=$(losetup -fP --show "$RAW")
  for lbl in EFI BOOT META; do lsblk -no PARTLABEL "$LOOP" | grep -qx "$lbl" && echo "  partition $lbl" || { echo "  FAILED partition $lbl"; fail=1; }; done
  mkdir -p /e; mount "${LOOP}p1" /e
  for f in config.txt u-boot.bin bcm2712-rpi-5-b.dtb overlays/disable-wifi.dtbo overlays/disable-bt.dtbo; do
    [ -e "/e/$f" ] && echo "  boot bit $f" || { echo "  FAILED boot bit $f"; fail=1; }
  done
  grep -q "dtoverlay=disable-wifi" /e/config.txt && grep -q "dtoverlay=disable-bt" /e/config.txt \
    && echo "  config.txt disables wifi+bt" || { echo "  FAILED config.txt overlays"; fail=1; }
  umount /e; losetup -d "$LOOP"; rm -f "$RAW"
  exit $fail
'; then ok "raw image: integrity, size, partition layout, Pi 5 boot bits"
  else bad "raw image validation failed (see above)"
  fi
}

# The UKI's .uname section is the version LABEL, written from Talos's DefaultKernelVersion rather than from
# our kernel, so cross-check it against what we actually compiled. A mismatch means a mislabeled image.
check_kernel_and_extensions() {
  if docker run --rm -e KVER="$KVER" -e WANT="$KERNEL_VERSION" -v "$UKI_DIR:/w" "$ALPINE_IMAGE" sh -c '
  apk add -q python3 xz zstd >/dev/null 2>&1
  python3 - <<PY
import struct
d=open("/w/vmlinuz.efi","rb").read(); pe=struct.unpack_from("<I",d,0x3c)[0]
nsec=struct.unpack_from("<H",d,pe+6)[0]; optsz=struct.unpack_from("<H",d,pe+20)[0]; st=pe+24+optsz
sec={}
for i in range(nsec):
    o=st+i*40; n=d[o:o+8].rstrip(b"\x00").decode("latin1"); _,_,rsz,roff=struct.unpack_from("<IIII",d,o+8); sec[n]=(roff,rsz)
for s in (".uname",".initrd"):
    o,z=sec[s]; open("/tmp/"+s,"wb").write(d[o:o+z])
PY
  uname=$(cat /tmp/.uname)
  case "$uname" in "$WANT"*) echo "  kernel $uname";; *) echo "  FAILED kernel $uname, expected $WANT*"; exit 1;; esac
  [ "$uname" = "$KVER" ] && echo "  UKI label matches the built kernel ($KVER)" \
    || { echo "  FAILED UKI .uname ($uname) != built kernel ($KVER): image mislabeled"; exit 1; }
  ext=$( (zstd -dc /tmp/.initrd 2>/dev/null; xz -dc /tmp/.initrd 2>/dev/null) | strings | grep -ioE "iscsi-tools|util-linux-tools" | sort -u )
  echo "$ext" | grep -qx iscsi-tools && echo "  extension iscsi-tools" || { echo "  FAILED iscsi-tools not baked in"; exit 1; }
  echo "$ext" | grep -qx util-linux-tools && echo "  extension util-linux-tools" || { echo "  FAILED util-linux-tools not baked in"; exit 1; }
'; then ok "installer: kernel label matches the built kernel, both extensions baked in"
  else bad "installer/kernel validation failed (see above)"
  fi
}

print_result() {
  say "VALIDATION PASSED"
  echo "   image:     ${IMAGE_FILE}"
  echo "   installer: ${INSTALLER_IMG}"
  echo "   next:      make publish"
}

# ---- main ----

require docker jq
load_inputs
load_meta
assert_image_built

say "OFFLINE VALIDATION"
extract_uki
check_raw_image
check_kernel_and_extensions

summary || die "VALIDATION FAILED"
print_result
