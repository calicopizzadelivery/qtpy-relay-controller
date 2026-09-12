# qtpy-relay-controller

Firmware for an Adafruit QT Py M0 (SAMD21) driving an 8-channel relay board over
USB serial, plus a host-side CLI.

Built to power-cycle and recovery-mode a pile of NVIDIA Jetson Nano boards and
the USB gear hanging off them, but there is nothing Jetson-specific in here —
it is a general 8-channel switch you can talk to from a shell script.

## The command set

Connect at 115200 baud (the rate is ignored; it is a USB CDC port) and send one
ASCII command per line. `\n` and `\r\n` both work, and parsing is
case-insensitive.

| Command | Effect |
|---|---|
| `ON <n>` / `OFF <n>` | Power channel *n* on or off |
| `ON ALL` / `OFF ALL` | All eight at once |
| `ALL ON` / `ALL OFF` | Same, other word order |
| `RELAY <n> ON\|OFF\|TOGGLE` | Verbose form |
| `TOGGLE <n>\|ALL` | Flip the current state |
| `PULSE <n>\|ALL <ms>` | Invert for *ms*, then revert |
| `PULSE <n>\|ALL ON\|OFF <ms>` | Hold that state for *ms*, then revert |
| `GET <n>` | Report one channel |
| `STATE` | Report all channels |
| `PINS` | Report the channel-to-pad map |
| `VERSION` | Firmware name and version |
| `HELP` | Command summary |

Channels are 1–8. Pulses are 1–3600000 ms. Every command answers with a single
line starting `OK` or `ERR`; a blank line is ignored silently.

```
> OFF 3
OK OFF 3
> PULSE 3 ON 500
OK PULSE 3 ON 500
> STATE
STATE 1=ON 2=ON 3=ON(pulse 480ms) 4=ON 5=ON 6=ON 7=ON 8=ON
```

Pulses are non-blocking. Several can run at once, and the console stays
responsive throughout. A pulse reverts to whatever the channel was set to
beforehand, so `PULSE 3 ON 500` on a channel that was off returns it to off.
Setting a channel outright cancels any pulse still running on it.

## Wiring and polarity

| Channel | QT Py pad | Arduino pin |
|---|---|---|
| 1 | A0 | 0 |
| 2 | A1 | 1 |
| 3 | A2 | 2 |
| 4 | A3 | 3 |
| 5 | MOSI | 10 |
| 6 | MISO | 9 |
| 7 | SCK | 8 |
| 8 | RX | 7 |

The relay modules are **normally closed**: driving a channel HIGH energises the
coil, opens the contacts and cuts power. This firmware speaks in terms of the
load rather than the coil, so the inversion stays out of your scripts:

- `ON` → pin LOW → contacts closed → **device powered**
- `OFF` → pin HIGH → contacts open → **device unpowered**

All channels come up `ON`, so a reset or a reflash never silently drops power to
anything. Note that the pins float for a few hundred milliseconds during
bootloader startup before `setup()` runs; what the relays do in that window is
decided by the relay board's own input bias, not by this firmware.

Channel 8 sits on the `Serial1` RX pin. The sketch never calls `Serial1.begin()`,
so the pin stays a plain GPIO — but do not add a hardware UART to this sketch
without remapping that channel first.

## Build and flash

```bash
./scripts/install-toolchain.sh   # arduino-cli + SAMD cores into ~/.local/bin
./scripts/build.sh               # -> build/relay-controller.{bin,uf2}
./scripts/flash.sh               # UF2 drag-drop or serial upload
```

`flash.sh` picks whichever route is available. Force one with `--uf2` or
`--serial`.

The UF2 route needs no permissions: double-tap the QT Py's reset button, wait
for the `QTPY_BOOT` volume to mount, and run `./scripts/flash.sh --uf2`. This
works with the stock Adafruit bootloader exactly as shipped.

The serial route uses the 1200-baud touch handshake and needs read/write on the
board's tty — see below.

## Serial port access

By default the port is `root:dialout 0660`, which a desktop user is usually not
in. One-time fix:

```bash
sudo ./scripts/host-setup.sh
```

That installs a udev rule which grants the active seat user access immediately
via `uaccess` (no logout needed), adds you to `dialout` for headless use, pins a
stable `/dev/qtpy-relay` symlink so the port cannot wander between `ttyACM*`
numbers, and marks the device `ID_MM_DEVICE_IGNORE` so ModemManager stops
probing it with AT commands.

## Host CLI

```bash
./tools/relayctl.py state
./tools/relayctl.py off 3
./tools/relayctl.py on all
./tools/relayctl.py pulse 2 500        # invert for 500 ms
./tools/relayctl.py pulse 2 off 500    # force off for 500 ms
./tools/relayctl.py console            # interactive
```

Needs `pyserial`. It autodetects `/dev/qtpy-relay`, falling back to
`/dev/serial/by-id/usb-Adafruit_QT_Py_M0*`. Exit status is non-zero when the
firmware answers `ERR`, so it composes in shell scripts.

**Never open this port at 1200 baud.** On a SAMD21 with native USB that is the
bootloader-entry handshake, not a normal open — the sketch will drop out from
under you. `relayctl.py` always uses 115200.

## Tests

```bash
./test/run-tests.sh
```

Compiles the sketch against a small Arduino shim and exercises the parser and
pulse engine natively — no hardware needed. Covers the channel map, pulse
revert semantics including a `millis()` rollover, pulse cancellation, and
rejection of malformed input. It also asserts that `setup()` loads each output
register *before* enabling the pin driver, which is what keeps the relays from
glitching at boot.

## Layout

```
firmware/relay-controller/   the sketch
scripts/install-toolchain.sh arduino-cli + SAMD cores, no root
scripts/build.sh             compile, emit .bin and .uf2
scripts/flash.sh             UF2 drag-drop or serial upload
scripts/host-setup.sh        one-time root: udev rule, dialout, stable symlink
tools/relayctl.py            host CLI
tools/bin2uf2.py             raw .bin -> UF2 container
test/                        host-side tests
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
