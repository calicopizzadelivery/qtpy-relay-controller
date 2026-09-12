#!/usr/bin/env bash
#
# Unpack an L4T BSP into a flashable Linux_for_Tegra tree.
#
#   sudo ./scripts/l4t-prepare.sh
#
# Root is needed for two reasons, neither optional: the sample rootfs must be
# extracted with -p to keep its setuid bits and ownership, and apply_binaries.sh
# installs NVIDIA's userspace into that rootfs.
#
# Run this once. Flashing afterwards is scripts/l4t-flash.sh.
#
set -euo pipefail

L4T_DIR=${L4T_DIR:-/srv/build/l4t}
REL=${L4T_RELEASE:-R32.7.6}
BSP="${L4T_DIR}/Jetson-210_Linux_${REL}_aarch64.tbz2"
RFS="${L4T_DIR}/Tegra_Linux_Sample-Root-Filesystem_${REL}_aarch64.tbz2"
TREE="${L4T_DIR}/Linux_for_Tegra"

[[ ${EUID} -eq 0 ]] || { echo "error: run me with sudo" >&2; exit 1; }
for f in "${BSP}" "${RFS}"; do
  [[ -f ${f} ]] || { echo "error: missing $(basename "${f}")" >&2; exit 1; }
done

if [[ -d ${TREE} ]]; then
  echo "${TREE} already exists; remove it to start clean."
else
  echo "unpacking the driver package"
  tar -xf "${BSP}" -C "${L4T_DIR}"
fi

if [[ -z $(ls -A "${TREE}/rootfs" 2>/dev/null | grep -v '^README' || true) ]]; then
  echo "unpacking the sample rootfs (this is the slow part, ~1.3 GB)"
  tar -xpf "${RFS}" -C "${TREE}/rootfs"
else
  echo "rootfs already populated, skipping"
fi

if [[ ! -f ${TREE}/rootfs/usr/lib/aarch64-linux-gnu/tegra/libnvbuf_utils.so ]]; then
  echo "applying NVIDIA binaries"
  cd "${TREE}"
  ./apply_binaries.sh
else
  echo "NVIDIA binaries already applied, skipping"
fi

echo
echo "ready. tree at ${TREE}"
echo "next: put the board in recovery, then sudo ./scripts/l4t-flash.sh"
