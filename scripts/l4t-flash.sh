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

echo "flashing ${BOARD} -> ${TARGET}"
echo "this erases the microSD card entirely."
cd "${TREE}"
./flash.sh "${BOARD}" "${TARGET}"
