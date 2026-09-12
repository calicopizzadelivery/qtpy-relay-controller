#!/usr/bin/env bash
#
# Compile and run the host-side firmware tests. No hardware involved.
#
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

OUT=$(mktemp -d)
trap 'rm -rf "${OUT}"' EXIT

g++ -std=c++17 -Wall -Wextra -O1 -x c++ test_relay.cpp -o "${OUT}/test_relay"
"${OUT}/test_relay"
