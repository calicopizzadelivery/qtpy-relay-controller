#!/usr/bin/env bash
#
# Install arduino-cli into ~/.local/bin and add the SAMD cores. No root needed.
#
set -euo pipefail

BINDIR="${HOME}/.local/bin"
URL=https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_64bit.tar.gz

mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"

if ! command -v arduino-cli >/dev/null; then
  echo "fetching arduino-cli into ${BINDIR}"
  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP}"' EXIT
  curl -fsSL "${URL}" -o "${TMP}/acli.tgz"
  tar xzf "${TMP}/acli.tgz" -C "${TMP}" arduino-cli
  mv -f "${TMP}/arduino-cli" "${BINDIR}/"
fi

arduino-cli version

arduino-cli config init --overwrite >/dev/null 2>&1 || true
arduino-cli config add board_manager.additional_urls \
  https://adafruit.github.io/arduino-board-index/package_adafruit_index.json
arduino-cli core update-index
arduino-cli core install arduino:samd
arduino-cli core install adafruit:samd
arduino-cli core list

# The sketch's only library dependency, for the onboard RGB heartbeat.
arduino-cli lib install "Adafruit NeoPixel"

echo
echo "done. if ${BINDIR} is not on your PATH, add it to your shell profile."
