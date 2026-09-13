#!/usr/bin/env bash
#
# Let the bench automation run the L4T steps without a password prompt.
#
#   sudo ./scripts/grant-automation.sh
#   sudo ./scripts/grant-automation.sh --revoke
#
# A NOPASSWD rule pointing at a file the invoking user can write is not a
# privilege boundary -- it is unrestricted root with extra steps. So this does
# not grant anything against the copies in this repo. It installs root-owned
# copies under /usr/local/sbin, pins their configuration so the environment
# cannot redirect them, and takes ownership of the L4T tree and the source
# tarballs, which are extracted and executed as root and are therefore just as
# sensitive as the scripts themselves.
#
# What this deliberately does NOT do is grant general root. The rule names two
# absolute paths and forbids arguments.
#
set -euo pipefail

SUDOERS=/etc/sudoers.d/jetson-bench
SBIN=/usr/local/sbin
L4T_DIR=/srv/build/l4t
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

PREPARE="${SBIN}/jetson-l4t-prepare"
FLASH="${SBIN}/jetson-l4t-flash"

[[ ${EUID} -eq 0 ]] || { echo "error: run me with sudo" >&2; exit 1; }

TARGET_USER=${SUDO_USER:-}
[[ -n ${TARGET_USER} ]] || { echo "error: SUDO_USER unset; run via sudo" >&2; exit 1; }

if [[ ${1:-} == --revoke ]]; then
  rm -f "${SUDOERS}" "${PREPARE}" "${FLASH}"
  echo "revoked: removed ${SUDOERS} and the installed scripts"
  echo "note: ${L4T_DIR} is left owned by root; chown it back if you want to"
  echo "      manage that tree as ${TARGET_USER} again."
  exit 0
fi

install_pinned() {
  local src=$1 dst=$2
  # Pin the configuration. sudo's env_reset already strips these, but relying
  # on a sudoers default for a privilege boundary is a thin thread -- if the
  # environment could redirect L4T_DIR, it could point the root-run script at a
  # tree the user controls.
  sed -e "s|^L4T_DIR=.*|L4T_DIR=${L4T_DIR}|" \
      -e 's|^REL=.*|REL=R32.7.6|' \
      -e 's|^DEFAULT_BOARD=.*|DEFAULT_BOARD=jetson-nano-emmc|' \
      -e 's|^TARGET=.*|TARGET=mmcblk0p1|' \
      -e 's|^DEFAULT_DTB=.*|DEFAULT_DTB=auto|' \
      "${src}" > "${dst}.tmp"
  bash -n "${dst}.tmp" || { echo "error: ${dst} failed syntax check" >&2; exit 1; }
  install -o root -g root -m 0755 "${dst}.tmp" "${dst}"
  rm -f "${dst}.tmp"
  echo "installed ${dst}"
}

install_pinned "${REPO_ROOT}/scripts/l4t-prepare.sh" "${PREPARE}"
install_pinned "${REPO_ROOT}/scripts/l4t-flash.sh"   "${FLASH}"

# The tree and tarballs are extracted and executed as root, so leaving them
# writable by the user would re-open exactly the hole the root-owned scripts
# close.
if [[ -d ${L4T_DIR} ]]; then
  chown -R root:root "${L4T_DIR}"
  chmod 0755 "${L4T_DIR}"
  echo "took ownership of ${L4T_DIR} (readable, not writable, by ${TARGET_USER})"
fi

# Validate before installing. A malformed sudoers file can lock you out of
# sudo entirely, and /etc/sudoers.d is parsed on every invocation.
tmp=$(mktemp); trap 'rm -f "${tmp}"' EXIT
cat > "${tmp}" <<RULE
# Jetson bench automation. Two exact commands, no arguments permitted.
# Installed by qtpy-relay-controller/scripts/grant-automation.sh
# Remove with: sudo ./scripts/grant-automation.sh --revoke
${TARGET_USER} ALL=(root) NOPASSWD: ${PREPARE} "", ${FLASH}
RULE

if ! visudo -cqf "${tmp}"; then
  echo "error: generated sudoers file is invalid; nothing installed" >&2
  exit 1
fi

install -o root -g root -m 0440 "${tmp}" "${SUDOERS}"
visudo -cqf "${SUDOERS}" || { rm -f "${SUDOERS}"; echo "error: rolled back" >&2; exit 1; }

cat <<MSG

granted. ${TARGET_USER} can now run, without a password:
  ${PREPARE}
  ${FLASH}

verify with:   sudo -l -U ${TARGET_USER} | grep jetson
revoke with:   sudo ${REPO_ROOT}/scripts/grant-automation.sh --revoke

Re-run this script after changing scripts/l4t-*.sh in the repo -- the installed
copies are snapshots, and that is the point: editing the repo does not change
what runs as root.
MSG
