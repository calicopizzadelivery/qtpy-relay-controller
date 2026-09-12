#!/usr/bin/env bash
#
# One-time root setup for the QT Py relay controller.
#
#   sudo ./scripts/host-setup.sh
#
# Installs a udev rule that:
#   - gives the desktop user access to the board's serial port without a
#     relogin, via the uaccess tag (an ACL for the active seat)
#   - also sets group dialout, for ssh sessions and headless use
#   - creates a stable /dev/qtpy-relay symlink, so the port does not move
#     when other ACM devices come and go
#   - tells ModemManager to leave the board alone. Without this, MM probes
#     new ACM devices with AT commands, which at best litters the parser with
#     junk and at worst collides with the 1200-baud upload handshake.
#
set -euo pipefail

RULE=/etc/udev/rules.d/99-qtpy-relay.rules
VID=239a
PID_APP=80cb   # running sketch
PID_BOOT=00cb  # UF2 bootloader

if [[ ${EUID} -ne 0 ]]; then
  echo "error: run me with sudo" >&2
  exit 1
fi

TARGET_USER=${SUDO_USER:-}
if [[ -z ${TARGET_USER} ]]; then
  echo "warning: SUDO_USER unset, skipping the dialout group add" >&2
fi

echo "writing ${RULE}"
cat > "${RULE}" <<RULES
# Adafruit QT Py M0 running qtpy-relay-controller
SUBSYSTEM=="tty", ATTRS{idVendor}=="${VID}", ATTRS{idProduct}=="${PID_APP}", \\
  SYMLINK+="qtpy-relay", GROUP="dialout", MODE="0660", TAG+="uaccess", \\
  ENV{ID_MM_DEVICE_IGNORE}="1"

# Same board sitting in its UF2 bootloader after a double-tap reset
SUBSYSTEM=="tty", ATTRS{idVendor}=="${VID}", ATTRS{idProduct}=="${PID_BOOT}", \\
  SYMLINK+="qtpy-relay-boot", GROUP="dialout", MODE="0660", TAG+="uaccess", \\
  ENV{ID_MM_DEVICE_IGNORE}="1"
RULES

echo "reloading udev"
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty --action=add

if [[ -n ${TARGET_USER} ]]; then
  if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx dialout; then
    echo "${TARGET_USER} is already in dialout"
  else
    echo "adding ${TARGET_USER} to dialout"
    usermod -aG dialout "${TARGET_USER}"
    echo "note: the group add needs a new login session to take effect."
    echo "      the uaccess rule above should grant access immediately, so"
    echo "      you probably do not have to log out."
  fi
fi

echo
echo "done. check with:"
echo "  ls -l /dev/qtpy-relay"
echo "  getfacl /dev/qtpy-relay | grep ${TARGET_USER:-\$USER}"
