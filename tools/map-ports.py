#!/usr/bin/env python3
"""Map relay channels to USB hub ports by watching what drops off the bus.

Switch each channel off in turn and see which USB device disappears. With
something plugged into every switched port, that yields a channel -> port ->
device map, which is the thing you actually need before writing a script that
cuts power to a named device.

    ./tools/map-ports.py --channels 1-7
    ./tools/map-ports.py --channels 1-7 --write docs/port-map.md

Every channel is restored on the way out, including after an error or a ctrl-c.

Channels are NOT limited by default. Narrow with --channels to keep it away
from anything you do not want power-cycled -- on the Jetson rig, channel 8 is
module power.

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import relayctl  # noqa: E402  (same directory, deliberate)

SYSFS = "/sys/bus/usb/devices"


def _read(base: str, name: str, default: str = "-") -> str:
    try:
        with open(os.path.join(base, name)) as fh:
            return fh.read().strip()
    except OSError:
        return default


def usb_devices() -> dict:
    """Every USB device by its topology path (e.g. 1-8.2.4.1)."""
    out = {}
    for name in sorted(os.listdir(SYSFS)):
        # Interface nodes carry a colon; skip them and the root hubs.
        if ":" in name or not name[0].isdigit():
            continue
        base = os.path.join(SYSFS, name)
        vid = _read(base, "idVendor", "")
        pid = _read(base, "idProduct", "")
        if not vid:
            continue
        out[name] = {
            "id": f"{vid}:{pid}",
            "product": _read(base, "product", "?"),
            "serial": _read(base, "serial", "-"),
            "hub": _read(base, "bDeviceClass") == "09",
        }
    return out


def describe(path: str, info: dict) -> str:
    kind = "hub" if info["hub"] else "device"
    serial = f" serial={info['serial']}" if info["serial"] != "-" else ""
    return f"{path}  {info['product']} [{info['id']}] {kind}{serial}"


def wait_until(predicate, timeout: float, poll: float = 0.15):
    """Poll until predicate(snapshot) is true, or give up. Returns the snapshot."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        snap = usb_devices()
        if predicate(snap):
            return snap
        time.sleep(poll)
    return usb_devices()


def parse_channels(spec: str, maximum: int) -> list:
    picked = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, _, hi = part.partition("-")
            picked.extend(range(int(lo), int(hi) + 1))
        else:
            picked.append(int(part))
    for ch in picked:
        if not 1 <= ch <= maximum:
            sys.exit(f"error: channel {ch} is outside 1-{maximum}")
    return sorted(set(picked))


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port")
    ap.add_argument("-i", "--id", dest="want_id")
    ap.add_argument("-c", "--channels", help="e.g. 1-7 or 1,2,5 (default: all)")
    ap.add_argument("--settle", type=float, default=4.0,
                    help="seconds to wait for a device to drop off (default 4)")
    ap.add_argument("--restore", type=float, default=8.0,
                    help="seconds to wait for it to come back (default 8)")
    ap.add_argument("--write", metavar="FILE", help="also write the map as markdown")
    args = ap.parse_args()

    port = relayctl.resolve_port(args.port, args.want_id, 1.0)
    info = relayctl.probe(port)
    if "_error" in info:
        sys.exit(f"error: {port}: {info['_error']}")

    total = int(info.get("channels", 8))
    channels = parse_channels(args.channels, total) if args.channels \
        else list(range(1, total + 1))

    print(f"board {info.get('id', '?')} on {port}, {total} channels")
    print(f"mapping channels: {', '.join(str(c) for c in channels)}\n")

    sp = relayctl.open_port(port, 1.0)
    results = {}
    baseline = usb_devices()
    print(f"baseline: {len(baseline)} USB devices\n")
    try:
        for ch in channels:
            # A device that failed to come back from the previous channel would
            # otherwise be silently attributed to this one.
            before = wait_until(lambda s: not (set(baseline) - set(s)),
                                args.restore)
            missing = sorted(set(baseline) - set(before))
            if missing:
                print(f"  ! baseline not intact before channel {ch}: "
                      f"missing {', '.join(missing)}")

            reply = relayctl.send(sp, f"OFF {ch}")
            if not any(r.startswith("OK") for r in reply):
                print(f"channel {ch}: refused ({reply})")
                continue

            after = wait_until(lambda s: set(before) - set(s), args.settle)
            gone = sorted(set(before) - set(after))

            relayctl.send(sp, f"ON {ch}")

            restored = wait_until(lambda s: not (set(gone) - set(s)), args.restore)
            still_gone = sorted(set(gone) - set(restored))

            results[ch] = [(p, before[p]) for p in gone]
            if gone:
                # The shortest path is the topmost device; anything longer sits
                # below it and only went away because its hub lost power.
                head = gone[0]
                print(f"channel {ch} -> {describe(head, before[head])}")
                for extra in gone[1:]:
                    print(f"{'':10}   (also lost {describe(extra, before[extra])})")
            else:
                print(f"channel {ch} -> nothing dropped off "
                      f"(empty port, unswitched, or slower than --settle)")
            if still_gone:
                print(f"{'':10}   ! did NOT come back: {', '.join(still_gone)}")
    finally:
        # Never leave a load dark because this fell over part way through.
        print("\nrestoring every mapped channel")
        for ch in channels:
            relayctl.send(sp, f"ON {ch}")
        print(relayctl.send(sp, "STATE")[0] if relayctl.send(sp, "STATE") else "")
        sp.close()

    if args.write:
        lines = [f"# Relay channel to USB port map", "",
                 f"Board `{info.get('id', '?')}`, "
                 f"generated by `tools/map-ports.py`.", "",
                 "| Channel | USB path | Device | Serial |",
                 "|---|---|---|---|"]
        for ch in channels:
            hits = results.get(ch, [])
            if hits:
                path, meta = hits[0]
                lines.append(f"| {ch} | `{path}` | {meta['product']} "
                             f"[{meta['id']}] | `{meta['serial']}` |")
            else:
                lines.append(f"| {ch} | — | nothing detected | — |")
        os.makedirs(os.path.dirname(os.path.abspath(args.write)), exist_ok=True)
        with open(args.write, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"wrote {args.write}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
