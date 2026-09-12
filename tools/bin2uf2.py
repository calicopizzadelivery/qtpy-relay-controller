#!/usr/bin/env python3
"""Convert a raw .bin into a UF2 the Adafruit bootloader will accept.

The UF2 container is a flat run of 512-byte blocks, each carrying at most 256
bytes of payload plus the absolute address it loads at. Format reference:
https://github.com/microsoft/uf2

Defaults target the SAMD21: family 0x68ed2b88, application base 0x2000 (the
first 8 KB holds the UF2 bootloader itself).

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import struct
import sys

UF2_MAGIC_START0 = 0x0A324655  # "UF2\n"
UF2_MAGIC_START1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FLAG_FAMILY_ID = 0x00002000

FAMILY_SAMD21 = 0x68ED2B88
PAYLOAD = 256
BLOCK = 512


def convert(data: bytes, base: int, family: int) -> bytes:
    # Pad to a whole payload so the final block is not short.
    if len(data) % PAYLOAD:
        data += b"\x00" * (PAYLOAD - len(data) % PAYLOAD)

    num_blocks = len(data) // PAYLOAD
    out = bytearray()

    for i in range(num_blocks):
        chunk = data[i * PAYLOAD:(i + 1) * PAYLOAD]
        header = struct.pack(
            "<IIIIIIII",
            UF2_MAGIC_START0,
            UF2_MAGIC_START1,
            UF2_FLAG_FAMILY_ID,
            base + i * PAYLOAD,
            PAYLOAD,
            i,
            num_blocks,
            family,
        )
        # 32 B header + 476 B data area + 4 B trailing magic = 512.
        block = header + chunk + b"\x00" * (BLOCK - 32 - PAYLOAD - 4)
        block += struct.pack("<I", UF2_MAGIC_END)
        assert len(block) == BLOCK
        out += block

    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="raw .bin produced by the compiler")
    ap.add_argument("output", help=".uf2 to write")
    ap.add_argument("--base", default="0x2000",
                    help="load address of the first byte (default 0x2000)")
    ap.add_argument("--family", default=hex(FAMILY_SAMD21),
                    help="UF2 family id (default SAMD21)")
    args = ap.parse_args()

    base = int(args.base, 0)
    family = int(args.family, 0)

    with open(args.input, "rb") as fh:
        data = fh.read()
    if not data:
        print(f"error: {args.input} is empty", file=sys.stderr)
        return 1

    uf2 = convert(data, base, family)
    with open(args.output, "wb") as fh:
        fh.write(uf2)

    print(f"{args.input}: {len(data)} B -> {args.output}: "
          f"{len(uf2)} B ({len(uf2) // BLOCK} blocks) at {base:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
