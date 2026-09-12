#!/usr/bin/env bash
#
# Compile the firmware and emit both a .bin and a drag-drop .uf2 into build/.
#
#   ./scripts/build.sh                # default 8-channel build
#   ./scripts/build.sh --channels 1   # variant for the 1-channel board
#
# Needs arduino-cli on PATH plus the adafruit:samd core; run
# ./scripts/install-toolchain.sh first if you have neither.
#
set -euo pipefail

FQBN=adafruit:samd:adafruit_qtpy_m0
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SKETCH="${REPO_ROOT}/firmware/relay-controller"
OUT="${REPO_ROOT}/build"
CHANNELS=

# Flash layout. The application is linked at 0x2000, above the bootloader; the
# identity row is the last 256 bytes of the 256 KB part. An image that reached
# that far would be erased over the stored identity on the next flash, so
# refuse to ship one.
APP_BASE=$((0x2000))
FLASH_END=$((0x40000))
ID_ROW=$((FLASH_END - 256))
MAX_IMAGE=$((ID_ROW - APP_BASE))

export PATH="${HOME}/.local/bin:${PATH}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channels) CHANNELS="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *)          echo "usage: $0 [--channels N]" >&2; exit 2 ;;
  esac
done

command -v arduino-cli >/dev/null || {
  echo "error: arduino-cli not on PATH. run ./scripts/install-toolchain.sh" >&2
  exit 1
}

declare -a EXTRA=()
if [[ -n ${CHANNELS} ]]; then
  [[ ${CHANNELS} =~ ^[1-8]$ ]] || { echo "error: --channels must be 1-8" >&2; exit 2; }
  # compiler.cpp.extra_flags is additive; build.extra_flags would clobber the
  # board's own -D flags.
  EXTRA+=(--build-property "compiler.cpp.extra_flags=-DRELAY_CHANNELS=${CHANNELS}")
fi

mkdir -p "${OUT}"
arduino-cli compile \
  --fqbn "${FQBN}" \
  --warnings all \
  --output-dir "${OUT}" \
  "${EXTRA[@]}" \
  "${SKETCH}"

BIN="${OUT}/relay-controller.ino.bin"
UF2="${OUT}/relay-controller.uf2"

SIZE=$(stat -c%s "${BIN}")
if (( SIZE > MAX_IMAGE )); then
  printf 'error: image is %d bytes, which reaches the identity row at %#x.\n' \
    "${SIZE}" "${ID_ROW}" >&2
  printf '       keep it under %d bytes, or move ID_STORAGE_ADDR.\n' "${MAX_IMAGE}" >&2
  exit 1
fi

python3 "${REPO_ROOT}/tools/bin2uf2.py" --base 0x2000 "${BIN}" "${UF2}"

echo
echo "built${CHANNELS:+ (${CHANNELS}-channel)}:"
ls -lh "${BIN}" "${UF2}" | sed 's/^/  /'
printf '  %d of %d bytes available below the identity row\n' "${SIZE}" "${MAX_IMAGE}"
