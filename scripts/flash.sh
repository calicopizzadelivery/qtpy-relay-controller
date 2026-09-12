#!/usr/bin/env bash
#
# Flash the firmware to the QT Py.
#
#   ./scripts/flash.sh --profile recovery          # pick the method for you
#   ./scripts/flash.sh --profile relay8 --uf2      # force drag-drop
#   ./scripts/flash.sh --profile relay8 --serial   # force serial upload
#
# --profile is mandatory. The two profiles drive different pins with opposite
# polarity, so flashing the wrong one leaves a board's relays undriven and
# floating -- which on the normally-closed 8-channel board can drop power to
# its loads.
#
# --serial needs read/write on the board's tty (run scripts/host-setup.sh once).
# --uf2 needs no permissions at all: the desktop automounts the bootloader
# volume. If the board is running a sketch rather than sitting in its
# bootloader, double-tap the reset button to get there.
#
set -euo pipefail

FQBN=adafruit:samd:adafruit_qtpy_m0
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SKETCH="${REPO_ROOT}/firmware/relay-controller"
METHOD=auto
PROFILE=

export PATH="${HOME}/.local/bin:${PATH}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uf2)     METHOD=uf2; shift ;;
    --serial)  METHOD=serial; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    *) echo "usage: $0 --profile relay8|recovery [--uf2|--serial]" >&2; exit 2 ;;
  esac
done

case "${PROFILE}" in
  relay8|recovery) ;;
  "") echo "error: --profile is required (relay8 or recovery)" >&2; exit 2 ;;
  *)  echo "error: unknown profile ${PROFILE}" >&2; exit 2 ;;
esac

OUT_DIR="${REPO_ROOT}/build/${PROFILE}"
UF2="${OUT_DIR}/relay-controller.uf2"

[[ -f ${UF2} ]] || {
  echo "error: ${UF2} missing. run ./scripts/build.sh --profile ${PROFILE}" >&2
  exit 1
}
echo "profile: ${PROFILE}"

find_boot_volume() {
  # The QT Py M0's UF2 bootloader mounts as QTPY_BOOT. Accept the other
  # Adafruit M0 labels too, in case this gets reused on a sibling board.
  local mp
  for mp in /media/"${USER}"/* /run/media/"${USER}"/* /mnt/*; do
    [[ -d ${mp} ]] || continue
    if [[ -f ${mp}/INFO_UF2.TXT ]]; then
      echo "${mp}"
      return 0
    fi
  done
  return 1
}

find_port() {
  local p
  for p in /dev/qtpy-relay /dev/serial/by-id/usb-Adafruit_QT_Py_M0*; do
    [[ -e ${p} ]] && { echo "${p}"; return 0; }
  done
  return 1
}

flash_uf2() {
  local vol
  if ! vol=$(find_boot_volume); then
    cat >&2 <<'MSG'
error: no UF2 bootloader volume mounted.

Double-tap the QT Py's reset button (two quick presses). The onboard NeoPixel
turns green and a QTPY_BOOT volume appears, then run this again.
MSG
    exit 1
  fi

  echo "copying $(basename "${UF2}") to ${vol}"
  cp "${UF2}" "${vol}/"
  sync
  echo "done. the board reboots into the new firmware on its own."
}

flash_serial() {
  local port
  if ! port=$(find_port); then
    echo "error: no QT Py serial port found" >&2
    exit 1
  fi
  if [[ ! -r ${port} || ! -w ${port} ]]; then
    echo "error: no read/write on ${port}. run: sudo ./scripts/host-setup.sh" >&2
    exit 1
  fi
  # bossac takes the device name and does not follow symlinks, so hand it the
  # real tty rather than our /dev/qtpy-relay alias. The board also re-enumerates
  # under its bootloader PID during the 1200-baud touch, which is why the alias
  # disappears mid-upload.
  port=$(readlink -f "${port}")
  echo "uploading to ${port}"
  # --input-dir pins the upload to the artifact build.sh produced, rather than
  # whatever happens to be in arduino-cli's build cache.
  arduino-cli upload --fqbn "${FQBN}" --port "${port}" \
    --input-dir "${OUT_DIR}" "${SKETCH}"
}

case "${METHOD}" in
  uf2)    flash_uf2 ;;
  serial) flash_serial ;;
  auto)
    if find_boot_volume >/dev/null; then
      flash_uf2
    elif port=$(find_port) && [[ -r ${port} && -w ${port} ]]; then
      flash_serial
    else
      cat >&2 <<'MSG'
error: nothing to flash to.

Either double-tap reset to expose the QTPY_BOOT volume and use --uf2,
or run "sudo ./scripts/host-setup.sh" to get serial access and use --serial.
MSG
      exit 1
    fi
    ;;
esac
