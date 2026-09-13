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
# Board config. jetson-nano-emmc for a production module (P3448-0002, onboard
# eMMC); jetson-nano-devkit for the microSD devkit module (P3448-0000).
DEFAULT_BOARD=jetson-nano-emmc
BOARD=""
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
# "auto" leaves detection alone, which is correct whenever the module and
# carrier are a matched pair: a FAB 300+ module reports itself honestly and
# process_board_version picks b00 for its B01 carrier without help. Overriding
# is only for mismatched parts, and forcing a tree the hardware disagrees with
# is how this went wrong before.
DEFAULT_DTB=auto
DTB=""

# Only --dtb <name> is accepted, and the name is validated against the device
# trees actually present in the root-owned tree. This script is reachable
# passwordless, so an unchecked argument would be a way to point a root-run
# flash at an arbitrary file.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dtb)   DTB="${2:-}"; shift 2 ;;
    --board) BOARD="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--board <name>] [--dtb auto|<name>.dtb]" >&2; exit 2 ;;
  esac
done

DTB="${DTB:-${DEFAULT_DTB}}"
BOARD="${BOARD:-${DEFAULT_BOARD}}"
if [[ ! ${BOARD} =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: --board must be a plain config name, got: ${BOARD}" >&2
  exit 2
fi
if [[ ${DTB} != auto && ! ${DTB} =~ ^[A-Za-z0-9._-]+\.dtb$ ]]; then
  echo "error: --dtb must be auto or a plain .dtb filename, got: ${DTB}" >&2
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

[[ -f ${TREE}/${BOARD}.conf ]] || {
  echo "error: no board config ${TREE}/${BOARD}.conf. available:" >&2
  ls "${TREE}"/jetson-nano*.conf | xargs -n1 basename | sed 's/\.conf$//;s/^/  /' >&2
  exit 1; }

if [[ ${DTB} == auto ]]; then
  unset DTBFILE
else
  if [[ ! -f ${TREE}/kernel/dtb/${DTB} ]]; then
    echo "error: ${TREE}/kernel/dtb/${DTB} does not exist. available:" >&2
    ls "${TREE}/kernel/dtb/" | grep -E "^tegra210-p3448-000[023]-p3449-0000-[a-z0-9]+\.dtb$" | sed 's/^/  /' >&2
    exit 1
  fi
  export DTBFILE="${TREE}/kernel/dtb/${DTB}"
fi

echo "flashing ${BOARD} -> ${TARGET}"
echo "  device tree: ${DTB}$([ "${DTB}" = auto ] && echo "  (detection decides, from the module's own FAB)")"
echo "this erases the microSD card entirely."
cd "${TREE}"
./flash.sh "${BOARD}" "${TARGET}"
