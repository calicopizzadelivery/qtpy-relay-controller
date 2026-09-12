#!/usr/bin/env python3
"""Drive a Jetson module into USB recovery (APX) mode.

Recovery entry is a two-board sequence, because FORCE_RECOVERY and module power
are on different controllers:

    1. assert FORCE_RECOVERY        (recovery board, normally-open relay)
    2. cut module power             (relay8 board)
    3. wait
    4. restore module power         (FORCE_RECOVERY still asserted -- the pin is
                                     sampled as the module comes up)
    5. keep holding briefly, then release
    6. look for the NVIDIA APX device on USB

    ./tools/enter-recovery.py
    ./tools/enter-recovery.py --off-seconds 5 --wait 25

FORCE_RECOVERY is released and module power restored on every exit path,
including an error or a ctrl-c part way through. Leaving either latched would
strand the module dark or stuck in recovery.

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import relayctl  # noqa: E402

SYSFS = "/sys/bus/usb/devices"
NVIDIA_VID = "0955"

# A module in RCM and the same module booted both sit at the same USB path and
# both answer to NVIDIA's vendor id -- only the product id changes. Diffing by
# path alone therefore misses a successful recovery entry entirely, because the
# device never leaves the bus, it just re-enumerates in place.
RECOVERY_PIDS = {
    "7f21": "T210 - Jetson Nano / TX1",
    "7c18": "T186 - Jetson TX2",
    "7e19": "T194 - Jetson Xavier",
    "7023": "T234 - Jetson Orin",
}
BOOTED_PIDS = {
    "7020": "L4T USB device gadget - module is booted, not in recovery",
}


def in_recovery(devices: dict) -> dict:
    return {path: pid for path, pid in devices.items() if pid in RECOVERY_PIDS}


def nvidia_devices() -> dict:
    """Any NVIDIA USB device present, by topology path -> product id."""
    found = {}
    for name in sorted(os.listdir(SYSFS)):
        if ":" in name or not name[0].isdigit():
            continue
        base = os.path.join(SYSFS, name)
        try:
            with open(os.path.join(base, "idVendor")) as fh:
                if fh.read().strip() != NVIDIA_VID:
                    continue
            with open(os.path.join(base, "idProduct")) as fh:
                found[name] = fh.read().strip()
        except OSError:
            continue
    return found


def open_board(want_id: str, want_profile: str, timeout: float):
    """Resolve a board by identity and refuse if it is not the expected profile.

    Addressing the wrong board here would cut power to a USB device, or assert
    recovery on nothing, so the profile check is not decoration.
    """
    port = relayctl.resolve_port(None, want_id, timeout)
    info = relayctl.probe(port)
    if "_error" in info:
        sys.exit(f"error: {port}: {info['_error']}")
    if info.get("profile") != want_profile:
        sys.exit(f"error: board {want_id!r} on {port} reports profile "
                 f"{info.get('profile')!r}, expected {want_profile!r}")
    return relayctl.open_port(port, timeout), port, info


def say(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--recovery-id", default="recovery")
    ap.add_argument("--recovery-channel", type=int, default=1)
    ap.add_argument("--power-id", default="relay8")
    ap.add_argument("--power-channel", type=int, default=6,
                    help="channel switching Jetson module power (default 6, "
                         "from docs/port-map.md)")
    ap.add_argument("--off-seconds", type=float, default=5.0)
    ap.add_argument("--hold-after", type=float, default=3.0,
                    help="keep FORCE_RECOVERY asserted this long after power-on")
    ap.add_argument("--wait", type=float, default=20.0,
                    help="how long to watch for the APX device after power-on")
    ap.add_argument("--timeout", type=float, default=1.0)
    args = ap.parse_args()

    rec_sp, rec_port, rec_info = open_board(args.recovery_id, "recovery", args.timeout)
    pwr_sp, pwr_port, pwr_info = open_board(args.power_id, "relay8", args.timeout)

    print(f"recovery board : {args.recovery_id} on {rec_port} "
          f"(channel {args.recovery_channel})")
    print(f"power board    : {args.power_id} on {pwr_port} "
          f"(channel {args.power_channel})")

    before = nvidia_devices()
    for path, pid in before.items():
        what = RECOVERY_PIDS.get(pid) or BOOTED_PIDS.get(pid) or "unknown NVIDIA device"
        print(f"before        : {NVIDIA_VID}:{pid} at {path} -- {what}")
    if in_recovery(before):
        print("note: a module is already in recovery; the sequence will "
              "power-cycle it back into recovery")
    print()

    found = {}
    vanished = False
    try:
        say(f"asserting FORCE_RECOVERY on {args.recovery_id} "
            f"channel {args.recovery_channel}")
        reply = relayctl.send(rec_sp, f"ON {args.recovery_channel}")
        say(f"  {reply}")
        if not any(r.startswith("OK") for r in reply):
            sys.exit("error: could not assert FORCE_RECOVERY")

        say(f"cutting module power for {args.off_seconds:g}s")
        reply = relayctl.send(pwr_sp, f"OFF {args.power_channel}")
        say(f"  {reply}")
        if not any(r.startswith("OK") for r in reply):
            sys.exit("error: could not cut module power")

        # Wait for the module to actually leave the bus. Without this the
        # success check below is meaningless: a module that was already in
        # recovery would satisfy it at t+0 without the sequence having done
        # anything. It also catches a power cut that is not reaching the
        # module, which otherwise looks identical to a module that will not
        # enter recovery.
        t_off = time.monotonic()
        while time.monotonic() - t_off < args.off_seconds:
            if not nvidia_devices():
                if not vanished:
                    vanished = True
                    say(f"  module left the bus at "
                        f"t+{time.monotonic() - t_off:.1f}s")
            time.sleep(0.2)
        if not vanished:
            say("  WARNING: the module never left the bus while unpowered")

        say("restoring module power, FORCE_RECOVERY still asserted")
        say(f"  {relayctl.send(pwr_sp, f'ON {args.power_channel}')}")
        power_on = time.monotonic()

        released = False
        deadline = power_on + args.wait
        while time.monotonic() < deadline:
            now = nvidia_devices()
            rcm = in_recovery(now)
            if rcm:
                found = rcm
                say(f"  recovery device at t+{time.monotonic() - power_on:.1f}s: "
                    f"{rcm}")
                break
            if not released and time.monotonic() - power_on >= args.hold_after:
                say(f"  releasing FORCE_RECOVERY at "
                    f"t+{args.hold_after:g}s, still watching")
                relayctl.send(rec_sp, f"OFF {args.recovery_channel}")
                released = True
            time.sleep(0.25)

        if not found:
            say(f"  no NVIDIA device after {args.wait:g}s")
    finally:
        # Neither of these may be left latched.
        relayctl.send(rec_sp, f"OFF {args.recovery_channel}")
        relayctl.send(pwr_sp, f"ON {args.power_channel}")
        say("released FORCE_RECOVERY, module power on")
        print(f"  recovery: {relayctl.send(rec_sp, 'STATE')}")
        print(f"  power:    {relayctl.send(pwr_sp, 'STATE')}")
        rec_sp.close()
        pwr_sp.close()

    print()
    if found and not vanished:
        print("INCONCLUSIVE: a module is in recovery, but it never left the bus "
              "during the power cut, so this run did not put it there.")
        for path, pid in found.items():
            print(f"  {NVIDIA_VID}:{pid} at {path} -- {RECOVERY_PIDS[pid]}")
        print(f"  check that channel {args.power_channel} really switches "
              f"module power.")
        return 2

    if found:
        for path, pid in found.items():
            print(f"SUCCESS: {NVIDIA_VID}:{pid} at {path} -- "
                  f"{RECOVERY_PIDS[pid]} in recovery")
        print("  flash it with the L4T flash.sh from a Linux_for_Tegra tree.")
        return 0

    after = nvidia_devices()
    print("FAILED: the module never appeared in recovery.")
    for path, pid in after.items():
        what = BOOTED_PIDS.get(pid) or "unknown NVIDIA device"
        print(f"  it is on the bus as {NVIDIA_VID}:{pid} at {path} -- {what}")
    if any(pid in BOOTED_PIDS for pid in after.values()):
        print("  so power and the USB link are fine; FORCE_RECOVERY is not "
              "reaching the module, or is not held across power-on.")
    elif not after:
        print(f"  nothing NVIDIA on the bus at all: check a module is fitted, "
              f"that channel {args.power_channel} is its power rail, and that "
              f"the carrier's USB device port is cabled to this host.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
