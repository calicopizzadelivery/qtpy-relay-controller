#!/usr/bin/env python3
"""Drive the QT Py relay controller from the host.

    relayctl.py list                 # every attached board, with its identity
    relayctl.py info
    relayctl.py state
    relayctl.py on 3
    relayctl.py off all
    relayctl.py toggle 5
    relayctl.py pulse 2 500          # invert for 500 ms
    relayctl.py pulse 2 off 500      # force off for 500 ms
    relayctl.py setid relay8         # persist an identity
    relayctl.py --id relay8 off 3    # address one board by identity
    relayctl.py raw "PULSE ALL 250"  # send a literal line
    relayctl.py console              # interactive

ON means the attached device is powered (pin low, normally-closed contacts
left closed). OFF cuts power.

With more than one board attached, every command except `list` requires --id
or --port. Guessing would risk power-cycling the wrong machine.

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import glob
import os
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    sys.exit("error: pyserial missing. install with: pip install pyserial")

# Opening a SAMD21 native-USB port at 1200 baud is the bootloader-entry
# handshake, not a normal open. Never use it here.
BAUD = 115200
PORT_GLOBS = ("/dev/qtpy-relay*", "/dev/serial/by-id/usb-Adafruit_QT_Py_M0*")


def candidate_ports() -> list:
    """Every attached QT Py, deduplicated across the symlink farms."""
    found, seen = [], set()
    for pattern in PORT_GLOBS:
        for hit in sorted(glob.glob(pattern)):
            real = os.path.realpath(hit)
            if real not in seen:
                seen.add(real)
                found.append(hit)
    return found


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


def parse_info(line: str) -> dict:
    """`OK INFO id=relay8 fw=... ver=... channels=8 serial=...` -> dict."""
    if not line.startswith("OK INFO "):
        return {}
    fields = {}
    for part in line[len("OK INFO "):].split():
        key, _, value = part.partition("=")
        if value:
            fields[key] = value
    return fields


def probe(port: str, timeout: float = 0.6) -> dict:
    """Ask one board who it is.

    Returns the parsed INFO fields, or a dict carrying only `_error` when the
    board could not be reached. Keeping the reason is what separates "denied by
    permissions" from "firmware too old to answer INFO" -- the two look
    identical from the caller otherwise, and point at opposite fixes.
    """
    try:
        with serial.Serial(port, BAUD, timeout=timeout) as sp:
            for line in send(sp, "INFO"):
                info = parse_info(line)
                if info:
                    return info
    except (serial.SerialException, OSError) as exc:
        if isinstance(exc, PermissionError) or "Permission denied" in str(exc):
            return {"_error": "permission denied -- run: "
                              "sudo ./scripts/host-setup.sh"}
        return {"_error": str(exc)}
    return {"_error": "no reply to INFO (firmware predates the INFO command, "
                      "or this is not a relay controller)"}


def resolve_port(explicit: str, want_id: str, timeout: float) -> str:
    if explicit:
        return explicit

    ports = candidate_ports()
    if not ports:
        sys.exit("error: no QT Py found. is it plugged in, and has "
                 "scripts/host-setup.sh been run?")

    if want_id:
        for port in ports:
            if probe(port, timeout).get("id") == want_id:
                return port
        sys.exit(f"error: no attached board reports id {want_id!r}. "
                 f"try: {os.path.basename(sys.argv[0])} list")

    if len(ports) == 1:
        return ports[0]

    # Several boards and nothing to tell them apart by. Refusing beats
    # switching the wrong one off.
    lines = [f"error: {len(ports)} boards attached, so --id or --port is required:"]
    for port in ports:
        info = probe(port, timeout)
        if "_error" in info:
            lines.append(f"  {port}  unreachable: {info['_error']}")
        else:
            lines.append(f"  {port}  id={info.get('id', '?')} "
                         f"channels={info.get('channels', '?')}")
    sys.exit("\n".join(lines))


def cmd_list(timeout: float) -> int:
    ports = candidate_ports()
    if not ports:
        print("no QT Py boards found", file=sys.stderr)
        return 1
    failed = 0
    for port in ports:
        info = probe(port, timeout)
        if "_error" in info:
            print(f"{port}\n    unreachable: {info['_error']}")
            failed += 1
        else:
            print(f"{port}\n    id       {info.get('id', '?')}\n"
                  f"    channels {info.get('channels', '?')}\n"
                  f"    firmware {info.get('fw', '?')} {info.get('ver', '?')}\n"
                  f"    serial   {info.get('serial', '?')}")
    return 1 if failed else 0


def cmd_console(sp: "serial.Serial") -> int:
    print("connected. type HELP, or ctrl-d to quit.")
    for reply in send(sp, "INFO"):
        print(reply)
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
    if verb in ("help", "pins", "version", "info", "id"):
        return verb.upper()
    if verb == "raw":
        if not args.rest:
            sys.exit("error: raw needs a line to send")
        return " ".join(args.rest)

    if verb == "setid":
        if len(args.rest) != 1:
            sys.exit("error: setid takes one value, 1-8 characters, no spaces")
        return f"SETID {args.rest[0]}"          # case is preserved on purpose

    if verb in ("on", "off", "toggle", "get"):
        if len(args.rest) != 1:
            sys.exit(f"error: {verb} takes exactly one channel (a number or all)")
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
    ap.add_argument("-i", "--id", dest="want_id",
                    help="address the board with this identity")
    ap.add_argument("-t", "--timeout", type=float, default=1.0,
                    help="per-read timeout in seconds (default 1.0)")
    ap.add_argument("verb", help="list, info, id, setid, state, on, off, "
                                 "toggle, get, pulse, pins, version, raw, console")
    ap.add_argument("rest", nargs="*", help="arguments for the command")
    args = ap.parse_args()

    if args.verb.lower() == "list":
        return cmd_list(args.timeout)

    port = resolve_port(args.port, args.want_id, args.timeout)
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
