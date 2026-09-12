#!/usr/bin/env bash
#
# Flash the firmware to the QT Py.
#
#   ./scripts/flash.sh            # pick whichever method is available
#   ./scripts/flash.sh --uf2      # force drag-drop to the bootloader volume
#   ./scripts/flash.sh --serial   # force arduino-cli upload over the port
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
UF2="${REPO_ROOT}/build/relay-controller.uf2"
METHOD=auto

export PATH="${HOME}/.local/bin:${PATH}"

case "${1:-}" in
  --uf2)    METHOD=uf2 ;;
  --serial) METHOD=serial ;;
  "")       ;;
  *)        echo "usage: $0 [--uf2|--serial]" >&2; exit 2 ;;
esac

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
  [[ -f ${UF2} ]] || { echo "error: ${UF2} missing, run ./scripts/build.sh" >&2; exit 1; }

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
  [[ -f ${REPO_ROOT}/build/relay-controller.ino.bin ]] || {
    echo "error: build/ is empty, run ./scripts/build.sh" >&2; exit 1; }
  # bossac takes the device name and does not follow symlinks, so hand it the
  # real tty rather than our /dev/qtpy-relay alias. The board also re-enumerates
  # under its bootloader PID during the 1200-baud touch, which is why the alias
  # disappears mid-upload.
  port=$(readlink -f "${port}")
  echo "uploading to ${port}"
  # --input-dir pins the upload to the artifact build.sh produced, rather than
  # whatever happens to be in arduino-cli's build cache.
  arduino-cli upload --fqbn "${FQBN}" --port "${port}" \
    --input-dir "${REPO_ROOT}/build" "${SKETCH}"
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
