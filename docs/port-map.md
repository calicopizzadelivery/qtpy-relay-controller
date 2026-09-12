# Relay channel → USB hub port map

Board `relay8`, mapped 2026-09-11 with `tools/map-ports.py --channels 1-7`,
by switching each channel off and watching which device left the bus.

The switched hub is the `1-8` cascade: a 4-port RTS5411 (`1-8.2`) whose fourth
port feeds a second RTS5411 (`1-8.2.4`), giving seven switchable positions.

| Channel | Pad | USB path | Device | Serial |
|---|---|---|---|---|
| 1 | A0 | `1-8.2.2` | PNY USB 3.2.1 FD [154b:1006] | `0721250DA1000263` |
| 2 | A1 | `1-8.2.4.1` | Flash Drive [090c:1000] | `0374021030005357` |
| 3 | A2 | `1-8.2.3` | ASolid USB [24a9:205a] | `88492104` |
| 4 | A3 | `1-8.2.1` | Corsair Flash Voyager [1b1c:1ab1] | `3596a233be026f` |
| 5 | MOSI | `1-8.2.4.4` | SG Flash [23a9:ef18] | `004FE27E1AF7DFB0` |
| 6 | MISO | **not switching** — see below | — | — |
| 7 | SCK | `1-8.2.4.2` | Flash Drive [090c:1000] | `0325922100006289` |
| 8 | RX | *not mapped* — Jetson module power, deliberately excluded | — | — |

Note the channel order does not follow the physical port order. Channel 1 lands
on hub port 2, channel 4 on hub port 1, and the two hub tiers interleave. This
is exactly why the map is worth generating rather than assuming.

## Channel 6 does not switch anything

Channel 6 was held off for 8 seconds with every drive staying on the bus.
One drive is unaccounted for — `1-8.2.4.3`, a Type-C stick, serial
`0376221080002091` — so by elimination that is the port channel 6 should own.

This looks like hardware rather than firmware:

- The firmware drives the right pin. `PINS` reports `PIN 6 MISO D9`, matching
  the documented map, and the host tests assert that table.
- The pin is not stolen by a peripheral. `Serial1.begin()` and `SPI.begin()`
  are never called, so D9 stays a plain GPIO — and channel 7 on the adjacent
  SPI pin (SCK, D8) switches correctly.
- `OFF 6` is accepted and `STATE` tracks it, so the firmware believes it is
  driving the pin low.

That leaves the relay itself, the wiring from that relay to the hub port, or
that port simply not being on the switched rail. The decisive test is whether
the channel-6 relay clicks or its indicator changes when toggled: if it does,
the fault is downstream of the relay; if it does not, it is the relay or its
drive signal.

## Regenerating

```bash
./tools/map-ports.py --channels 1-7 --write docs/port-map.md
```

Narrow `--channels` to keep the sweep away from anything you do not want
power-cycled; channel 8 is Jetson module power on this rig.
