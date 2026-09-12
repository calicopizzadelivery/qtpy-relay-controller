#!/usr/bin/env bash
#
# Compile and run the host-side firmware tests for both board profiles.
# No hardware involved.
#
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

OUT=$(mktemp -d)
trap 'rm -rf "${OUT}"' EXIT

for t in test_relay test_recovery; do
  echo "=== ${t} ==="
  g++ -std=c++17 -Wall -Wextra -O1 -x c++ "${t}.cpp" -o "${OUT}/${t}"
  "${OUT}/${t}"
  echo
done
