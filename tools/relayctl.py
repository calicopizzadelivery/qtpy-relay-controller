#!/usr/bin/env python3
"""Drive the QT Py relay controller from the host.

    relayctl.py state
    relayctl.py on 3
    relayctl.py off all
    relayctl.py toggle 5
    relayctl.py pulse 2 500          # invert for 500 ms
    relayctl.py pulse 2 off 500      # force off for 500 ms
    relayctl.py raw "PULSE ALL 250"  # send a literal line
    relayctl.py console              # interactive

ON means the attached device is powered (pin low, normally-closed contacts
left closed). OFF cuts power.

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import glob
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    sys.exit("error: pyserial missing. install with: pip install pyserial")

# Opening a SAMD21 native-USB port at 1200 baud is the bootloader-entry
# handshake, not a normal open. Never use it here.
BAUD = 115200
PORT_GLOBS = ("/dev/qtpy-relay", "/dev/serial/by-id/usb-Adafruit_QT_Py_M0*")


def find_port() -> str:
    for pattern in PORT_GLOBS:
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[0]
    sys.exit("error: no QT Py found. is it plugged in, and has "
             "scripts/host-setup.sh been run?")


def open_port(port: str, timeout: float) -> "serial.Serial":
    try:
        return serial.Serial(port, BAUD, timeout=timeout)
    except serial.SerialException as exc:
        sys.exit(f"error: cannot open {port}: {exc}")


def drain(sp: "serial.Serial", settle: float = 0.15) -> list:
    """Collect whatever the board says until it goes quiet."""
    lines = []
    deadline = time.monotonic() + settle
    while time.monotonic() < deadline:
        raw = sp.readline()
        if raw:
            text = raw.decode("utf-8", "replace").strip()
            if text:
                lines.append(text)
                deadline = time.monotonic() + settle
    return lines


def send(sp: "serial.Serial", line: str) -> list:
    sp.reset_input_buffer()
    sp.write((line + "\n").encode("ascii", "replace"))
    sp.flush()
    return drain(sp)


def cmd_console(sp: "serial.Serial") -> int:
    print("connected. type HELP, or ctrl-d to quit.")
    for reply in send(sp, "STATE"):
        print(reply)
    while True:
        try:
            line = input("relay> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if line.lower() in ("quit", "exit"):
            return 0
        if not line:
            continue
        for reply in send(sp, line):
            print(reply)


def build_command(args: argparse.Namespace) -> str:
    verb = args.verb.lower()

    if verb in ("state", "status"):
        return "STATE"
    if verb in ("help", "pins", "version"):
        return verb.upper()
    if verb == "raw":
        if not args.rest:
            sys.exit("error: raw needs a line to send")
        return " ".join(args.rest)

    if verb in ("on", "off", "toggle", "get"):
        if len(args.rest) != 1:
            sys.exit(f"error: {verb} takes exactly one channel (1-8 or all)")
        return f"{verb.upper()} {args.rest[0].upper()}"

    if verb == "pulse":
        # pulse <target> <ms>  |  pulse <target> <on|off> <ms>
        if len(args.rest) == 2:
            target, ms = args.rest
            return f"PULSE {target.upper()} {ms}"
        if len(args.rest) == 3:
            target, state, ms = args.rest
            return f"PULSE {target.upper()} {state.upper()} {ms}"
        sys.exit("error: pulse takes <channel> [on|off] <milliseconds>")

    sys.exit(f"error: unknown command {args.verb!r}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port", help="serial port (default: autodetect)")
    ap.add_argument("-t", "--timeout", type=float, default=1.0,
                    help="per-read timeout in seconds (default 1.0)")
    ap.add_argument("verb", help="state, on, off, toggle, get, pulse, "
                                 "pins, version, raw, console")
    ap.add_argument("rest", nargs="*", help="arguments for the command")
    args = ap.parse_args()

    port = args.port or find_port()
    sp = open_port(port, args.timeout)

    try:
        if args.verb.lower() == "console":
            return cmd_console(sp)

        line = build_command(args)
        replies = send(sp, line)
        if not replies:
            print(f"warning: no reply to {line!r}", file=sys.stderr)
            return 1
        for reply in replies:
            print(reply)
        # The firmware answers ERR ... for anything it refused.
        return 1 if any(r.startswith("ERR") for r in replies) else 0
    finally:
        sp.close()


if __name__ == "__main__":
    sys.exit(main())
