#!/usr/bin/env bash
#
# Compile the firmware and emit a .bin and a drag-drop .uf2 per board profile.
#
#   ./scripts/build.sh                     # both profiles
#   ./scripts/build.sh --profile recovery  # just the one
#
# Artifacts land in build/<profile>/, so the two can never be confused for one
# another at flash time.
#
# Needs arduino-cli on PATH plus the adafruit:samd core and the Adafruit
# NeoPixel library; run ./scripts/install-toolchain.sh if you have neither.
#
set -euo pipefail

FQBN=adafruit:samd:adafruit_qtpy_m0
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SKETCH="${REPO_ROOT}/firmware/relay-controller"
PROFILES=(relay8 recovery)

# Flash layout. The application is linked at 0x2000, above the bootloader; the
# identity row is the last 256 bytes of the 256 KB part. An image reaching that
# far would be erased over the stored identity on the next flash, so refuse it.
APP_BASE=$((0x2000))
FLASH_END=$((0x40000))
ID_ROW=$((FLASH_END - 256))
MAX_IMAGE=$((ID_ROW - APP_BASE))

export PATH="${HOME}/.local/bin:${PATH}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      case "${2:-}" in
        relay8|recovery) PROFILES=("$2") ;;
        all)             PROFILES=(relay8 recovery) ;;
        *) echo "error: --profile must be relay8, recovery or all" >&2; exit 2 ;;
      esac
      shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--profile relay8|recovery|all]" >&2; exit 2 ;;
  esac
done

command -v arduino-cli >/dev/null || {
  echo "error: arduino-cli not on PATH. run ./scripts/install-toolchain.sh" >&2
  exit 1
}

profile_id() {
  case "$1" in
    relay8)   echo 1 ;;
    recovery) echo 2 ;;
  esac
}

for profile in "${PROFILES[@]}"; do
  out="${REPO_ROOT}/build/${profile}"
  mkdir -p "${out}"
  echo "=== ${profile} ==="

  arduino-cli compile \
    --fqbn "${FQBN}" \
    --warnings all \
    --output-dir "${out}" \
    --build-property "compiler.cpp.extra_flags=-DBOARD_PROFILE=$(profile_id "${profile}")" \
    "${SKETCH}"

  bin="${out}/relay-controller.ino.bin"
  uf2="${out}/relay-controller.uf2"

  size=$(stat -c%s "${bin}")
  if (( size > MAX_IMAGE )); then
    printf 'error: %s image is %d bytes, reaching the identity row at %#x.\n' \
      "${profile}" "${size}" "${ID_ROW}" >&2
    exit 1
  fi

  python3 "${REPO_ROOT}/tools/bin2uf2.py" --base 0x2000 "${bin}" "${uf2}"
  printf '  %s: %d of %d bytes below the identity row\n\n' \
    "${profile}" "${size}" "${MAX_IMAGE}"
done
