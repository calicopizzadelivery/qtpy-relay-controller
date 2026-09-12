# HDMI as a debug interface

The Jetson's HDMI output goes to an MS2109 USB capture dongle (`534d:2109`) at
`1-8.2.4.4`, which is **relay channel 5**. That gives both a live window on
thebe and a way to read the Jetson's screen programmatically.

```bash
./tools/hdmi-preview.sh start      # live window, plus a 1/s frame spool
./tools/hdmi.py grab -o shot.png   # one frame, classified
./tools/hdmi.py status             # classify without keeping the file
./tools/hdmi.py watch --count 20 --interval 3
./tools/hdmi-preview.sh stop
```

## The device only allows one streaming client

`v4l2src` on `/dev/video0` is exclusive: a grab attempted while the preview is
running fails with `Device or resource busy`. A preview that blocked grabs would
make the debug interface useless exactly when you want it, so the preview
pipeline tees instead — one branch to the window, one writing a PNG per second
into `$XDG_RUNTIME_DIR/hdmi-frames`. `hdmi.py` reads that spool when it is fresh
and opens the device directly otherwise, so watching and grabbing work together.

`--direct` forces opening the device, for when the preview is stopped.

Of the two nodes the dongle exposes, `/dev/video0` is the capture and
`/dev/video1` is metadata (`not a capture device`).

## A frame is not a signal

The dongle always produces frames. With no HDMI source it shows its own colour
bar pattern, so "a frame arrived" says nothing about the Jetson. `hdmi.py`
classifies each frame:

| State | Meaning |
|---|---|
| `no-signal` | the dongle's eight colour bars — nothing driving its input |
| `blank` | uniform frame; a source is present but painting nothing |
| `active` | real content |

The no-signal test samples the midpoint of each of eight columns and matches the
bar sequence, rather than matching a palette — a real desktop can easily contain
all eight colours, but not in that order.

## Power the dongle before booting the Jetson

Discovered the hard way. The Jetson decides whether it has a display during
bootloader, from HPD and EDID. Power-cycling the dongle on channel 5 leaves it
not presenting as a sink until it has settled, and a Jetson booted in that
window comes up with **no display init at all** — the boot log simply has no
`hdmi cable connected` line, and nothing will ever appear.

So the order matters:

1. dongle powered and streaming, settled
2. *then* boot the Jetson

A boot log with a working display path contains:

```
[0000.938] Display board id is not available
[0002.496] display console init
[0002.508] hdmi cable connected
[0002.523] edid read success
[0002.705] dc_hdmi_enable, starting HDMI initialisation
[0002.712] dc_hdmi_enable, HDMI initialisation complete
[0004.134] display bmp image done
```

Grepping the serial console for `hdmi cable connected` is the quickest way to
tell a display problem from a capture problem: if that line is absent, the fault
is upstream of the dongle's USB side entirely.

## Open: splash reported but never captured

As of 2026-09-12 the two halves do not meet. With the ordering above the Jetson
reports a full display init and `display bmp image done`, yet the dongle reports
`no-signal` throughout, including when sampling the spool every 250 ms across
the whole boot. The capture chain is known good — it reliably reports the
dongle's own colour bars, and the spool stays fresh — and the Jetson is known to
boot (`0955:7020`, login prompt on serial).

That leaves the HDMI link itself: the sink supplying EDID may not be this
dongle, or the dongle's receiver is not locking onto the mode the Jetson picks.
The cheapest way to separate those is to point the dongle at a known-good HDMI
source and confirm `hdmi.py status` reports `active`.
