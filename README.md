# qtpy-relay-controller

Firmware for an Adafruit QT Py M0 (SAMD21) driving an 8-channel relay board over
USB serial, plus a host-side CLI.

Built to power-cycle and recovery-mode a pile of NVIDIA Jetson Nano boards and
the USB gear hanging off them, but there is nothing Jetson-specific in here —
it is a general relay switch you can talk to from a shell script. Each board
carries a persistent name, so several can share a host without a script ever
having to guess which is which.

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
| `ID` | Report this board's identity |
| `SETID <text>` | Persist a new identity, 1–8 characters |
| `INFO` | Identity, firmware, channel count, chip serial |
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

## Onboard RGB heartbeat

The QT Py's onboard NeoPixel alternates two colours once a second, so a glance
at the board says the firmware is running, its loop is not wedged, and which
profile it carries: **green ↔ blue for `relay8`, green ↔ white for `recovery`**.
It is a liveness indicator only — it does not encode relay state. Period,
brightness and the two colours are at the top of the sketch.

This is the sketch's one library dependency, Adafruit NeoPixel, which
`scripts/install-toolchain.sh` installs.

## Identity

More than one of these boards ends up on the same host, so each carries an
eight-byte name:

```
> SETID relay8
OK SETID relay8
> INFO
OK INFO id=relay8 fw=qtpy-relay-controller ver=1.1.0 channels=8 serial=92A4CF3E50555738332E3120FF172333
```

The name is 1–8 printable ASCII characters with no spaces, and **case is
preserved** even though commands themselves are case-insensitive. An unnamed
board reports `UNSET`.

It persists in the last 256-byte row of flash, which sits deliberately outside
the application image. Neither flash route disturbs it: the UF2 bootloader
writes only the pages a UF2 file covers, and this board uploads through
`bossac18`, whose command line carries no `-e` chip erase. **So the identity
survives a firmware update** — which matters, because otherwise every reflash
would leave both boards answering to the same name and a script could cut power
to the wrong machine. `build.sh` refuses to link an image large enough to reach
that row.

The record is checksummed, so a half-written row after a power cut reads back as
`UNSET` rather than as a corrupted name.

`INFO` also reports the SAMD21's factory serial. That is the same value the core
hashes into the USB serial string, so it ties a console session to a specific
`/dev/serial/by-id/` path.

## Board profiles

Two different boards run this firmware. They differ in more than channel count,
so the profile is chosen **at build time** and reported by `INFO`.

| | `relay8` | `recovery` |
|---|---|---|
| Channels | 8 — A0–A3, MOSI, MISO, SCK, RX | 1 — TX (pin 6) |
| Relay contacts | normally **closed** | normally **open** |
| `ON` means | load powered — pin **LOW** | FORCE_RECOVERY asserted — pin **HIGH** |
| Boots | all `ON` (never silently drop power) | `OFF` (never silently enter recovery) |
| Heartbeat | green ↔ blue | green ↔ white |

Both speak the same wire protocol: **`ON` means the thing the board exists to
do is happening.** The polarity inversion lives in one place in the firmware
(`ON_LEVEL`/`OFF_LEVEL`), so nothing downstream — scripts included — has to
know which way the contacts are wired.

The `recovery` board grounds the Jetson's FORCE_RECOVERY pin so the module can
be flashed:

```
ON 1                  # hold FORCE_RECOVERY grounded
PULSE 1 ON 5000       # hold it for five seconds, then release
OFF 1                 # release
```

Its boot state is the important half. A normally-open relay that came up
asserted would put the Jetson into recovery on every reset of the *controller*,
so the recovery profile boots released and the sketch loads the output register
LOW before enabling the pin driver.

> **Flash the matching profile.** `flash.sh` requires `--profile` for this
> reason. The wrong firmware leaves a board's relays undriven and floating —
> harmless on the recovery board, but on the normally-closed 8-channel board
> the relay module's own input bias then decides whether your loads keep power.

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

## Deployment: the Jetson bring-up rig

On the bench this drives a USB hub whose per-port power is relay-switched:

| Channel | Switches |
|---|---|
| 1–5, 7, 8 | Power to one USB device on the hub |
| **6** | **Power to the Jetson module**, for a hard power cycle of the carrier board |

The surveyed channel-to-port map is in [docs/port-map.md](docs/port-map.md).
Two things it records are worth repeating here: the relay board's *printed*
channel numbers do not match the firmware's — its eighth relay is wired to MISO,
which the console calls channel 6 — and the channel order does not follow
physical hub port order. Generate the map with `tools/map-ports.py`; do not
assume it.

So a hard power cycle of the Jetson is one command:

```
PULSE 6 OFF 5000
```

Five seconds dark, then power restored — and because pulses do not block, the
console stays responsive the whole time and the revert happens even if the host
has wandered off.

### Do not let the board switch its own supply

If the QT Py is plugged into one of the switched hub ports, turning that channel
off cuts the board's own power. It drops off the bus mid-command, and only a
physical re-plug brings it back. `OFF ALL` does this unconditionally, and so
does any script that sweeps every channel.

**Plug the QT Py into an unswitched port, upstream of the relays.** The
firmware cannot defend against this on its own: it has no way to know which
port it is powered from.

## Build and flash

```bash
./scripts/install-toolchain.sh              # arduino-cli, SAMD cores, NeoPixel
./scripts/build.sh                          # both profiles -> build/<profile>/
./scripts/build.sh --profile recovery       # just the one
./scripts/flash.sh --profile recovery       # UF2 drag-drop or serial upload
```

Artifacts land in `build/<profile>/` so the two can never be confused at flash
time, and `--profile` is mandatory when flashing.

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
./tools/relayctl.py list               # every attached board and its identity
./tools/relayctl.py setid relay8       # name this board
./tools/relayctl.py --id relay8 off 3  # address one board by name
./tools/relayctl.py state
./tools/relayctl.py pulse 2 500        # invert for 500 ms
./tools/relayctl.py pulse 2 off 500    # force off for 500 ms
./tools/relayctl.py console            # interactive
```

Needs `pyserial`. It autodetects `/dev/qtpy-relay`, falling back to
`/dev/serial/by-id/usb-Adafruit_QT_Py_M0*`. Exit status is non-zero when the
firmware answers `ERR`, so it composes in shell scripts.

**With more than one board attached, every command except `list` requires
`--id` or `--port`.** It will not pick one for you — guessing risks cutting
power to the wrong machine. `list` is also how you tell a permissions problem
from an unresponsive board; the two look identical otherwise and point at
opposite fixes.

**Never open this port at 1200 baud.** On a SAMD21 with native USB that is the
bootloader-entry handshake, not a normal open — the sketch will drop out from
under you. `relayctl.py` always uses 115200.

## Tests

```bash
./test/run-tests.sh
```

159 checks, run once per board profile. The sketch is built against a small
Arduino shim and exercised natively — no hardware needed.

Covers the channel map, pulse revert semantics including a `millis()` rollover,
pulse cancellation, identity round-trips across a simulated reboot, case
preservation, rejection of a corrupted identity row, heartbeat colours and
period, and rejection of malformed input generally.

Two assertions are there to catch the mistakes that would be expensive on real
hardware: that `setup()` loads each output register *before* enabling the pin
driver, which is what keeps the relays from glitching at boot; and that the
`recovery` profile comes up **released**, with its pin LOW, since a
normally-open relay booting asserted would drop the Jetson into recovery on
every reset of the controller.

## Layout

```
firmware/relay-controller/   the sketch, both profiles
scripts/install-toolchain.sh arduino-cli + SAMD cores + NeoPixel, no root
scripts/build.sh             compile per profile, guard the identity row
scripts/flash.sh             UF2 drag-drop or serial upload, --profile required
scripts/host-setup.sh        one-time root: udev rule, dialout, stable symlink
tools/relayctl.py            host CLI
tools/map-ports.py           map channels to USB hub ports empirically
tools/enter-recovery.py      two-board FORCE_RECOVERY + power-cycle sequence
tools/blink-channel.py       toggle one channel on a cadence you can meter
tools/bin2uf2.py             raw .bin -> UF2 container
test/test_relay.cpp          relay8 profile tests
test/test_recovery.cpp       recovery profile tests
docs/port-map.md             the surveyed bench wiring
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
