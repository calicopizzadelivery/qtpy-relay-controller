#!/usr/bin/env bash
#
# Flash the Jetson over USB recovery.
#
#   ./tools/enter-recovery.py        # first, put the module in APX
#   sudo ./scripts/l4t-flash.sh
#
# This is a Jetson Nano developer kit module (the boot log reports
# BoardID = 3448, SKU = 0x0), so the target is the microSD card: board config
# jetson-nano-devkit, root device mmcblk0p1.
#
# Takes roughly 10-20 minutes and writes the whole card. Everything on it goes.
#
set -euo pipefail

L4T_DIR=${L4T_DIR:-/srv/build/l4t}
TREE="${L4T_DIR}/Linux_for_Tegra"
BOARD=${L4T_BOARD:-jetson-nano-devkit}
TARGET=${L4T_TARGET:-mmcblk0p1}

# Carrier device tree.
#
# flash.sh normally derives this from FAB, read off the module EEPROM:
#   FAB <  "300" -> tegra210-p3448-0000-p3449-0000-a02.dtb
#   FAB >= "300" -> ...-b00.dtb
#
# This unit's EEPROM read fails, so detection falls through to a02 -- wrong for
# this B01 carrier. Overriding FAB does force b00, but it also makes flash.sh
# skip its board-detection path, and that route dies in nvtboot with
# "Error in NvTbootGetTOSBinaryLength: 0x11". DTBFILE overrides the device tree
# directly instead (flash.sh line ~1816, mkfilepath prefers it over the value
# process_board_version computed), leaving detection alone.
#
# Selectable so a02 and b00 can be compared without reinstalling this script.
DEFAULT_DTB=tegra210-p3448-0000-p3449-0000-b00.dtb
DTB=""

# Only --dtb <name> is accepted, and the name is validated against the device
# trees actually present in the root-owned tree. This script is reachable
# passwordless, so an unchecked argument would be a way to point a root-run
# flash at an arbitrary file.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dtb) DTB="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--dtb <name>.dtb]" >&2; exit 2 ;;
  esac
done

DTB="${DTB:-${DEFAULT_DTB}}"
if [[ ! ${DTB} =~ ^[A-Za-z0-9._-]+\.dtb$ ]]; then
  echo "error: --dtb must be a plain .dtb filename, got: ${DTB}" >&2
  exit 2
fi

[[ ${EUID} -eq 0 ]] || { echo "error: run me with sudo" >&2; exit 1; }
[[ -x ${TREE}/flash.sh ]] || {
  echo "error: no flash.sh at ${TREE}. run scripts/l4t-prepare.sh first" >&2
  exit 1; }

# Flashing a module that is not in recovery silently does nothing useful, so
# check before spending twenty minutes on it.
if ! lsusb -d 0955: >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: no NVIDIA device on USB.

The module must be in recovery (APX) mode. Put it there with:
  ./tools/enter-recovery.py
then check with: lsusb -d 0955:
MSG
  exit 1
fi

pid=$(lsusb -d 0955: | head -1 | sed 's/.*0955:\([0-9a-f]*\).*/\1/')
if [[ ${pid} != "7f21" ]]; then
  echo "error: NVIDIA device is 0955:${pid}, not 7f21 (APX)." >&2
  echo "       0955:7020 means the module is booted, not in recovery." >&2
  exit 1
fi

if [[ ! -f ${TREE}/kernel/dtb/${DTB} ]]; then
  echo "error: ${TREE}/kernel/dtb/${DTB} does not exist. available:" >&2
  ls "${TREE}/kernel/dtb/" | grep -E "^tegra210-p3448-0000-p3449-0000-[a-z0-9]+\.dtb$" | sed 's/^/  /' >&2
  exit 1
fi
export DTBFILE="${TREE}/kernel/dtb/${DTB}"

echo "flashing ${BOARD} -> ${TARGET}"
echo "  device tree: ${DTB}"
echo "this erases the microSD card entirely."
cd "${TREE}"
./flash.sh "${BOARD}" "${TARGET}"
