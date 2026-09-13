#!/usr/bin/env python3
"""Power-cycle the Jetson, cutting USB back-feed first.

Anything externally powered that is plugged into the Jetson's USB ports can
back-feed 5V into its rail, so switching the Jetson's own channel off does not
actually de-power it. On this bench the FRDM-K64F does exactly that: its OpenSDA
port is powered from the host, and its device port feeds the Jetson.

The symptom is nasty because it does not look like a power problem -- the board
half-dies, the serial console goes silent, and a boot that never completes looks
like a dead module. So the cut channels are cut first and restored last.

    ./tools/jetson-power.py cycle
    ./tools/jetson-power.py cycle --off-seconds 10
    ./tools/jetson-power.py off ; ./tools/jetson-power.py on

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import relayctl  # noqa: E402


def apply(sp, verb, channels, label):
    if not channels:
        return
    for ch in channels:
        reply = relayctl.send(sp, f"{verb} {ch}")
        ok = any(r.startswith("OK") for r in reply)
        print(f"  {verb} {ch:<2} {label:<22} {'ok' if ok else reply}")
        if not ok:
            sys.exit(f"error: {verb} {ch} refused: {reply}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=("cycle", "off", "on"))
    ap.add_argument("-i", "--id", dest="want_id", default="relay8")
    ap.add_argument("-p", "--port")
    ap.add_argument("--power-channel", type=int, default=6,
                    help="Jetson module power (default 6)")
    ap.add_argument("--cut", type=int, action="append", default=None,
                    metavar="CH",
                    help="channel feeding a back-feed source; repeatable "
                         "(default: 8, the FRDM-K64F)")
    ap.add_argument("--off-seconds", type=float, default=8.0)
    ap.add_argument("--hdmi-channel", type=int, default=5, metavar="CH",
                    help="channel feeding the HDMI capture dongle; cycled and "
                         "allowed to settle BEFORE the Jetson is powered "
                         "(default 5, 0 to skip)")
    ap.add_argument("--hdmi-settle", type=float, default=12.0,
                    help="seconds to let the dongle come up before the Jetson "
                         "boots (default 12)")
    ap.add_argument("--settle", type=float, default=15.0,
                    help="wait after power-on before restoring the cut "
                         "channels, so the Jetson is up before USB returns")
    args = ap.parse_args()

    cut = args.cut if args.cut is not None else [8]
    port = relayctl.resolve_port(args.port, args.want_id, 1.0)
    sp = relayctl.open_port(port, 1.0)

    try:
        hdmi = [args.hdmi_channel] if args.hdmi_channel else []

        if args.action in ("cycle", "off"):
            apply(sp, "OFF", cut, "(back-feed source)")
            apply(sp, "OFF", hdmi, "(HDMI sink)")
            apply(sp, "OFF", [args.power_channel], "(Jetson module)")

        if args.action == "cycle":
            time.sleep(args.off_seconds)

        if args.action in ("cycle", "on"):
            # The sink comes up first and is given time to settle. The Jetson
            # samples hotplug and reads EDID once, early in the bootloader: a
            # dongle still enumerating at that moment leaves the board booting
            # with "hdmi cable not connected", and nothing recovers it short of
            # another reboot. These dongles also wedge -- enumerated and
            # apparently healthy while doing nothing -- which a power cycle
            # clears, the same way it does for the console adapter.
            if hdmi:
                apply(sp, "ON", hdmi, "(HDMI sink)")
                print(f"  waiting {args.hdmi_settle:g}s for the sink to settle "
                      f"before powering the Jetson")
                time.sleep(args.hdmi_settle)

            apply(sp, "ON", [args.power_channel], "(Jetson module)")
            if args.settle > 0:
                time.sleep(args.settle)
            apply(sp, "ON", cut, "(back-feed source)")

        state = relayctl.send(sp, "STATE")
        print(f"\n{state[0] if state else '(no reply)'}")
    finally:
        sp.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
