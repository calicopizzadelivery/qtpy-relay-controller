#!/usr/bin/env bash
#
# Write a raw SD card image to a removable card reader.
#
#   sudo ./scripts/sd-write.sh                      # auto-detect the reader
#   sudo ./scripts/sd-write.sh --device /dev/sda
#
# Streams straight out of the zip, so it needs no room for a 14 GB temp file.
#
# This is the most destructive thing in this repo: it overwrites a whole block
# device. Every guard below exists because getting the device wrong once is
# unrecoverable -- the candidate must be removable, on USB, not hold a mounted
# filesystem belonging to this host, and not be an NVMe or the root disk.
#
set -euo pipefail

IMAGE=${SD_IMAGE:-/srv/build/l4t-sdimage/jetson-nano-jp461-sd-card-image.zip}
MEMBER=${SD_MEMBER:-sd-blob-b01.img}
DEVICE=""

[[ ${EUID} -eq 0 ]] || { echo "error: run me with sudo" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --image)  IMAGE="${2:-}";  shift 2 ;;
    *) echo "usage: $0 [--device /dev/sdX] [--image file.zip]" >&2; exit 2 ;;
  esac
done

[[ -f ${IMAGE} ]] || { echo "error: ${IMAGE} not found" >&2; exit 1; }

# Auto-detect: exactly one removable USB disk, or refuse to guess.
if [[ -z ${DEVICE} ]]; then
  mapfile -t cands < <(lsblk -dno NAME,RM,TRAN,SIZE | awk '$2==1 && $3=="usb" && $4 ~ /G$/ {print "/dev/"$1}')
  if [[ ${#cands[@]} -eq 0 ]]; then
    echo "error: no removable USB disk found. pass --device explicitly." >&2; exit 1
  elif [[ ${#cands[@]} -gt 1 ]]; then
    echo "error: ${#cands[@]} removable USB disks found; pass --device:" >&2
    printf '  %s\n' "${cands[@]}" >&2; exit 1
  fi
  DEVICE="${cands[0]}"
fi

[[ -b ${DEVICE} ]] || { echo "error: ${DEVICE} is not a block device" >&2; exit 1; }

# lsblk pads single-column output, so every one of these is trimmed before
# comparison. An untrimmed " 1" compares unequal to "1" and the guard rejects a
# perfectly good device -- which is the failure mode you want from a guard, but
# it is still a bug.
trim() { tr -d '[:space:]'; }
name=$(basename "${DEVICE}")
rm_flag=$(lsblk -dno RM   "${DEVICE}" 2>/dev/null | trim || echo 0)
tran=$(lsblk -dno TRAN    "${DEVICE}" 2>/dev/null | trim || echo "")
size=$(lsblk -bdno SIZE   "${DEVICE}" 2>/dev/null | trim)

[[ ${name} == nvme* ]] && { echo "error: refusing to write to an NVMe device" >&2; exit 1; }
[[ ${rm_flag} == 1 ]] || { echo "error: ${DEVICE} is not removable" >&2; exit 1; }
[[ ${tran} == usb ]]  || { echo "error: ${DEVICE} is not on USB (tran=${tran})" >&2; exit 1; }
(( size > 4000000000 )) || { echo "error: ${DEVICE} is only $((size/1000000000))GB" >&2; exit 1; }

# Refuse if anything on it is mounted somewhere that matters to this host.
while read -r part mnt; do
  [[ -z ${mnt} ]] && continue
  case "${mnt}" in
    /|/boot*|/home|/srv*|/var*|/usr*)
      echo "error: ${part} is mounted at ${mnt} -- that is a system mount" >&2; exit 1 ;;
  esac
done < <(lsblk -nro NAME,MOUNTPOINT "${DEVICE}" | tail -n +2 | awk '{print "/dev/"$1, $2}')

echo "target : ${DEVICE}  ($((size/1000000000))GB, removable, usb)"
echo "image  : ${IMAGE}  (member ${MEMBER})"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "${DEVICE}" | sed 's/^/  /'
echo

# Unmount anything the desktop auto-mounted, or dd will write under a live fs.
while read -r part mnt; do
  [[ -z ${mnt} ]] && continue
  echo "unmounting ${part} from ${mnt}"
  umount "${part}" || { echo "error: could not unmount ${part}" >&2; exit 1; }
done < <(lsblk -nro NAME,MOUNTPOINT "${DEVICE}" | tail -n +2 | awk '{print "/dev/"$1, $2}')

echo "writing (this takes a while; the image is ~14 GB uncompressed)"
unzip -p "${IMAGE}" "${MEMBER}" | dd of="${DEVICE}" bs=4M conv=fsync status=progress
sync
echo
echo "written. partition table now:"
partprobe "${DEVICE}" 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,LABEL "${DEVICE}" | sed 's/^/  /'
