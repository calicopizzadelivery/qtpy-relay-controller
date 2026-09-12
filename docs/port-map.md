# Relay channel → USB hub port map

Board `relay8`, surveyed 2026-09-11 with
`tools/map-ports.py --channels 1-8 --settle 7 --restore 12`, by switching each
channel off and watching which device left the bus. Baseline was verified
intact before and after every channel, and every drive returned.

The switched hub is the `1-8` cascade: a 4-port RTS5411 (`1-8.2`) whose fourth
port feeds a second RTS5411 (`1-8.2.4`), giving seven switchable positions.

| Channel | Pad | Pin | Controls | Serial |
|---|---|---|---|---|
| 1 | A0 | D0 | `1-8.2.2` PNY USB 3.2.1 FD | `0721250DA1000263` |
| 2 | A1 | D1 | `1-8.2.4.1` Flash Drive | `0374021030005357` |
| 3 | A2 | D2 | `1-8.2.3` ASolid USB | `88492104` |
| 4 | A3 | D3 | `1-8.2.1` Corsair Flash Voyager | `3596a233be026f` |
| 5 | MOSI | D10 | `1-8.2.4.4` SG Flash | `004FE27E1AF7DFB0` |
| **6** | **MISO** | **D9** | **Jetson module power** | — |
| 7 | SCK | D8 | `1-8.2.4.2` Flash Drive | `0325922100006289` |
| 8 | RX | D7 | `1-8.2.4.3` Type-C | `0376221080002091` |

Seven USB ports plus the Jetson rail accounts for all eight channels.

## Two traps worth knowing

**The relay board's printed channel numbers do not match these.** The board's
own channel 8 indicator lights when *firmware* channel 6 is driven, so its
eighth relay is wired to MISO rather than RX. Anything that scripts this rig
must use the firmware numbering above, which is what the console speaks.

**Channel 6 is Jetson module power, not channel 8.** It is the one channel that
switches no USB device, so a survey that only watches for disappearing drives
will report it as dead. It is not: it is the hard power-cycle rail.

```
PULSE 6 OFF 5000      # hard power cycle the Jetson carrier board
```

Channel order also does not follow physical port order — channel 1 lands on hub
port 2, channel 4 on hub port 1, and the two hub tiers interleave. Generate the
map, do not assume it.

## Current occupants (2026-09-12)

The flash drives above were mapping loads and have been removed. What is on the
switched hub now:

| Path | Channel | Device |
|---|---|---|
| `1-8.2.1` | 1 | CP2102N USB-UART — the Jetson's serial console, `/dev/ttyUSB0` |
| `1-8.2.3` | 3 | the **recovery** QT Py controller |
| `1-8.2.4.4` | 5 | USB Video — HDMI capture |

> **The recovery controller is on a switched port.** `OFF 3` cuts power to the
> board that holds FORCE_RECOVERY, and `OFF ALL` includes it. The `relay8`
> controller itself is safely on the root hub at `1-1`, but this one is not.
> Move it upstream of the relays, or keep channel 3 out of any sweep.

Note that channel 1 now switches the console adapter: cutting it mid-flash
would drop the UART, and channel 5 drops the HDMI capture.

## Channel 6, confirmed

Channel 6 switches no USB device, so unlike every other channel it could not be
proven by watching something leave the bus. It was confirmed directly instead,
on 2026-09-12: toggling it on a fixed cadence with `tools/blink-channel.py`
visibly cuts the Jetson carrier's power LED and RGB fan. The relay, its wiring
and the rail are all good.

Worth being precise about what that does and does not show. The LED and fan run
from the carrier board's own 5 V rail, so they prove the **carrier** is powered.
They say nothing about whether the **module** boots.

## USB back-feed defeats a naive power cycle

Anything externally powered plugged into the Jetson's USB ports feeds 5V back
into its rail, so cutting channel 6 alone does not de-power the module. On this
bench the FRDM-K64F does it: its OpenSDA port is powered from the host and its
device port is plugged into the Jetson.

The symptom is misleading. The module half-dies rather than resetting: the
serial console goes completely silent, `usb=` on the injector stays `ready` for
about 90 seconds after power-off, and the boot never completes — all of which
reads as a dead module rather than a power problem.

The FRDM's OpenSDA happens to sit on **channel 8**, so the fix is in software:
cut the back-feed channel first, restore it last.

```bash
./tools/jetson-power.py cycle            # cuts ch8, then ch6, then restores
./tools/enter-recovery.py                # does the same before its power cut
```

Both take `--cut CH` (repeatable) if something else is ever plugged into the
Jetson's USB ports while externally powered.

## Regenerating

```bash
./tools/map-ports.py --channels 1-8 --settle 7 --restore 12 --write docs/port-map.md
```

Narrow `--channels` to keep the sweep away from anything that must not be
power-cycled; on this rig that is channel 6.

## Verified recovery entry (2026-09-12)

`tools/enter-recovery.py` puts the Nano into USB recovery, confirmed by an A/B
against the same power cycle with FORCE_RECOVERY left released:

| FORCE_RECOVERY | Result |
|---|---|
| asserted across power-on | `0955:7f21` APX, console silent |
| released | `0955:7020` L4T gadget, full boot log to `nano-1 login:` |

Two things about detection are worth knowing, because both produced a wrong
answer before they were understood.

**The module never leaves its USB path.** Booted it is `0955:7020`, in recovery
`0955:7f21`, both at the same address. Diffing by USB path alone reports a
successful recovery entry as "no change". Compare product ids.

**Presence alone does not prove causality.** A module already in recovery
satisfies "is an RCM device on the bus" at t+0, so the tool waits for the module
to actually leave the bus during the power cut before accepting a later
appearance as its own doing. Without that it returns a confident false positive,
and it exits 2 for INCONCLUSIVE if the module never left the bus — which is also
how a power cut that is not reaching the module presents.
