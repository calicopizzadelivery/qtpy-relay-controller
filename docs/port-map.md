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

## Channel 6 is the one channel never confirmed by observable effect

Every other channel was proven by watching a specific USB device disappear.
Channel 6 switches no USB device, so it has only ever been identified
indirectly: by elimination, and by its relay indicator lighting when firmware
channel 6 is driven. That is good evidence the relay module's input is being
driven, but it is not proof that the contacts move or that the rail behind them
reaches the module.

If a Jetson on that rail shows no sign of life, confirm the rail directly —
meter across the module's power input while toggling channel 6 — before
concluding the module is at fault.

## Regenerating

```bash
./tools/map-ports.py --channels 1-8 --settle 7 --restore 12 --write docs/port-map.md
```

Narrow `--channels` to keep the sweep away from anything that must not be
power-cycled; on this rig that is channel 6.
