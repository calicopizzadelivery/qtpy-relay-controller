#!/usr/bin/env bash
#
# Compile the firmware and emit both a .bin and a drag-drop .uf2 into build/.
#
#   ./scripts/build.sh
#
# Needs arduino-cli on PATH plus the adafruit:samd core; run
# ./scripts/install-toolchain.sh first if you have neither.
#
set -euo pipefail

FQBN=adafruit:samd:adafruit_qtpy_m0
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SKETCH="${REPO_ROOT}/firmware/relay-controller"
OUT="${REPO_ROOT}/build"

export PATH="${HOME}/.local/bin:${PATH}"

command -v arduino-cli >/dev/null || {
  echo "error: arduino-cli not on PATH. run ./scripts/install-toolchain.sh" >&2
  exit 1
}

mkdir -p "${OUT}"
arduino-cli compile \
  --fqbn "${FQBN}" \
  --warnings all \
  --output-dir "${OUT}" \
  "${SKETCH}"

BIN="${OUT}/relay-controller.ino.bin"
UF2="${OUT}/relay-controller.uf2"

python3 "${REPO_ROOT}/tools/bin2uf2.py" --base 0x2000 "${BIN}" "${UF2}"

echo
echo "built:"
ls -lh "${BIN}" "${UF2}" | sed 's/^/  /'
