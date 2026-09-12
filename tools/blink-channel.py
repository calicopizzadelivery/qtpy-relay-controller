#!/usr/bin/env python3
"""Toggle one channel on a fixed, announced cadence so it can be metered.

Some channels switch nothing a host can observe -- a bare power rail, for
instance. The only way to confirm those is to put a meter on them, which needs
a predictable pattern rather than a one-off flick.

    ./tools/blink-channel.py --id relay8 --channel 6
    ./tools/blink-channel.py --id relay8 --channel 6 --period 10 --cycles 6

Starts ON, so there is time to get the probes on, then alternates. The channel
is restored ON on every exit path, including ctrl-c.

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import relayctl  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-i", "--id", dest="want_id", default="relay8")
    ap.add_argument("-p", "--port")
    ap.add_argument("-c", "--channel", type=int, required=True)
    ap.add_argument("--period", type=float, default=8.0,
                    help="seconds per state (default 8)")
    ap.add_argument("--cycles", type=int, default=4,
                    help="number of off-pulses (default 4)")
    ap.add_argument("--restore", choices=("on", "off"), default="on",
                    help="state to leave the channel in (default on)")
    args = ap.parse_args()

    port = relayctl.resolve_port(args.port, args.want_id, 1.0)
    info = relayctl.probe(port)
    if "_error" in info:
        sys.exit(f"error: {port}: {info['_error']}")

    ch = args.channel
    total = args.period * (2 * args.cycles + 1)
    print(f"board {info.get('id', '?')} ({info.get('profile', '?')}) on {port}")
    print(f"channel {ch}, {args.period:g}s per state, {args.cycles} off-pulses, "
          f"{total:g}s total\n")

    sp = relayctl.open_port(port, 1.0)
    t0 = time.monotonic()

    def mark(state: str) -> None:
        print(f"  t+{time.monotonic() - t0:5.1f}s  {state}", flush=True)

    try:
        relayctl.send(sp, f"ON {ch}")
        mark("ON   (rail live -- get the probes on)")
        time.sleep(args.period)

        for n in range(1, args.cycles + 1):
            relayctl.send(sp, f"OFF {ch}")
            mark(f"OFF  (rail dead)   pulse {n}/{args.cycles}")
            time.sleep(args.period)
            relayctl.send(sp, f"ON {ch}")
            mark("ON   (rail live)")
            time.sleep(args.period)
    finally:
        relayctl.send(sp, f"{args.restore.upper()} {ch}")
        mark(f"{args.restore.upper()}   (restored)")
        state = relayctl.send(sp, "STATE")
        print(f"\nfinal: {state[0] if state else '(no reply)'}")
        sp.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
