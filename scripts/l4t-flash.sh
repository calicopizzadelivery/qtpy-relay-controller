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

# Carrier revision override.
#
# flash.sh derives the carrier device tree from FAB:
#   process_board_version() in p3448-0000.conf.common
#   FAB < "300" -> tegra210-p3448-0000-p3449-0000-a02.dtb
#   FAB >= "300" -> ...-b00.dtb
#
# It normally reads FAB from the module EEPROM, but this unit's EEPROM read
# fails ("eeprom_init: EEPROM read failed" in every boot log, before and after
# reflashing), so detection falls through to the a02 default. This carrier is a
# B01, whose display wiring differs -- which is why a perfectly healthy board
# booted all the way to the setup wizard with the screen dark.
#
# Setting these explicitly skips the EEPROM path entirely: flash.sh only calls
# get_board_version() when FAB is empty.
BOARDID=${L4T_BOARDID:-3448}
FAB=${L4T_FAB:-300}
BOARDSKU=${L4T_BOARDSKU:-0000}
export BOARDID FAB BOARDSKU

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
echo "  BOARDID=${BOARDID} FAB=${FAB} BOARDSKU=${BOARDSKU}"
echo "  FAB ${FAB} selects the $([ "${FAB}" \< "300" ] && echo a02 || echo b00) carrier device tree"
echo "this erases the microSD card entirely."
cd "${TREE}"
./flash.sh "${BOARD}" "${TARGET}"
