#!/usr/bin/env python3
"""Capture and classify the Jetson's HDMI output.

The capture dongle is an MS2109 (534d:2109) presenting MJPEG up to 1080p60 over
UVC. It always produces frames: when there is no HDMI source it shows a colour
bar pattern of its own, which is why "a frame arrived" is not the same as "the
Jetson is outputting video". This module tells those apart.

    ./tools/hdmi.py grab                      # one frame -> hdmi.png, classified
    ./tools/hdmi.py grab -o boot.png
    ./tools/hdmi.py watch --count 20 --interval 3   # a series, for watching a boot
    ./tools/hdmi.py status                    # classify without keeping the file

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import glob
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageStat

def find_device() -> str:
    """First V4L2 node that can actually capture.

    The dongle's node number moves whenever USB renumbers -- which every power
    cycle can do -- so hardcoding /dev/video0 produces "Cannot identify device"
    at the worst moment. Each UVC device also exposes a second node for
    metadata, which enumerates formats but yields no frames, so the capability
    bits are checked rather than just taking the lowest number.
    """
    # The udev rule in scripts/host-setup.sh names the capture node; prefer
    # it when present so a host never has to care which videoN it is today.
    if os.path.exists("/dev/hdmi-capture"):
        return "/dev/hdmi-capture"

    import glob as _glob
    for node in sorted(_glob.glob("/sys/class/video4linux/video*"),
                       key=lambda p: int(p.rsplit("video", 1)[1])):
        dev = "/dev/" + os.path.basename(node)
        try:
            with open(os.path.join(node, "index")) as fh:
                if fh.read().strip() != "0":
                    continue          # metadata node of a multi-node device
        except OSError:
            continue
        if os.path.exists(dev):
            return dev
    return "/dev/video0"


DEVICE = None
WIDTH, HEIGHT = 1920, 1080

# The capture device permits only one streaming client. When hdmi-preview.sh
# holds it, frames come from the spool that pipeline tees into instead -- which
# is the only way to watch and grab at the same time.
FRAME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hdmi-frames")
SPOOL_MAX_AGE = 5.0

# The dongle's own no-signal screen: eight vertical bars in these colours,
# left to right. Matching the sequence is far more reliable than matching a
# palette, because a real desktop can easily contain all eight colours.
NO_SIGNAL_BARS = [
    (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
    (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0),
]


def spooled_frame(max_age: float = SPOOL_MAX_AGE):
    """Newest complete frame from the preview's spool, or None."""
    files = sorted(glob.glob(os.path.join(FRAME_DIR, "f*.png")))
    if not files:
        return None
    # The newest may still be being written, so prefer the one behind it and
    # only fall back to the newest when it is all there is.
    for cand in reversed(files[:-1] or files):
        try:
            if time.time() - os.path.getmtime(cand) > max_age:
                return None                      # preview is stalled or dead
            with open(cand, "rb") as fh:
                data = fh.read()
            Image.open(io.BytesIO(data)).verify()   # reject a partial write
            return data
        except Exception:
            continue
    return None


def capture(device: str, width: int, height: int, settle: float,
            direct: bool = False) -> bytes:
    """Return the PNG bytes of one frame, taken after the dongle has locked.

    This dongle emits its own colour-bar test pattern for about a second after
    the stream opens, then locks onto the HDMI input and passes real video. A
    short grab therefore returns the test pattern and looks exactly like "no
    signal" -- which is wrong, and was wrong for a long time here.

    So the stream is held open past the lock, throttled to 1 fps so only a
    handful of files are written, and the LAST frame is kept. This is what the
    GNOME camera app is doing implicitly by simply continuing to display.
    """
    if not direct:
        live = spooled_frame()
        if live is not None:
            return live

    tmp = tempfile.mkdtemp(prefix="hdmi-")
    try:
        # num-buffers counts source frames, so seconds * source fps. videorate
        # then drops to 1 fps, keeping the file count small while the stream
        # itself stays open long enough to lock.
        src_fps = 30
        nbuf = max(int(settle * src_fps), src_fps)
        pipeline = [
            "gst-launch-1.0", "-q",
            "v4l2src", f"device={device}", f"num-buffers={nbuf}",
            "!", f"image/jpeg,width={width},height={height},framerate={src_fps}/1",
            "!", "jpegdec", "!", "videoconvert",
            "!", "videorate", "!", "video/x-raw,framerate=1/1",
            "!", "pngenc",
            "!", "multifilesink", f"location={tmp}/f%03d.png",
        ]
        res = subprocess.run(pipeline, capture_output=True, text=True,
                             timeout=max(60, settle * 4))
        frames = sorted(glob.glob(f"{tmp}/f*.png"))
        if not frames:
            if "busy" in res.stderr.lower():
                sys.exit(f"error: {device} is busy and the preview spool at "
                         f"{FRAME_DIR} is empty or stale.\n"
                         f"       is hdmi-preview.sh running but wedged? check "
                         f"its status, or pass --direct after stopping it.")
            sys.exit(f"error: no frames from {device}\n{res.stderr.strip()}")
        with open(frames[-1], "rb") as fh:
            return fh.read()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def near(a, b, tol=40) -> bool:
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def classify(im: Image.Image) -> tuple:
    """Return (state, detail). State is one of no-signal, blank, active."""
    rgb = im.convert("RGB")
    w, h = rgb.size
    stat = ImageStat.Stat(rgb)
    mean = [round(v, 1) for v in stat.mean]
    spread = round(max(stat.stddev), 1)

    # Sample the middle row at the centre of each of eight equal columns. On the
    # no-signal screen those land squarely inside the bars.
    row = h // 2
    sampled = [rgb.getpixel((int((i + 0.5) * w / 8), row)) for i in range(8)]
    if all(near(got, want) for got, want in zip(sampled, NO_SIGNAL_BARS)):
        return "no-signal", ("dongle colour bars after the settle period: "
                             "nothing driving the HDMI input. If the source is "
                             "definitely live, raise --settle -- the bars are "
                             "also what it shows before locking.")

    if spread < 6:
        shade = "black" if mean[0] < 24 else f"uniform rgb{tuple(int(v) for v in mean)}"
        return "blank", f"flat {shade}: source present but painting nothing"

    colours = rgb.getcolors(maxcolors=2_000_000)
    ncol = len(colours) if colours else ">2M"
    return "active", f"{ncol} distinct colours, mean rgb{tuple(int(v) for v in mean)}, spread {spread}"


def grab_and_classify(args) -> tuple:
    png = capture(args.device, args.width, args.height, args.settle, args.direct)
    path = args.output
    with open(path, "wb") as fh:
        fh.write(png)
    state, detail = classify(Image.open(path))
    return path, state, detail


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("grab", "watch", "status"))
    ap.add_argument("-o", "--output", default="hdmi.png")
    ap.add_argument("-d", "--device", default=None,
                    help="capture node (default: autodetect)")
    ap.add_argument("--width", type=int, default=WIDTH)
    ap.add_argument("--height", type=int, default=HEIGHT)
    ap.add_argument("--settle", type=float, default=4.0,
                    help="seconds to hold the stream open before keeping a "
                         "frame; the dongle shows its own colour bars for "
                         "about a second before locking (default 4)")
    ap.add_argument("--direct", action="store_true",
                    help="always open the capture device, ignoring the "
                         "preview spool (needs the preview stopped)")
    ap.add_argument("--count", type=int, default=10, help="watch: how many frames")
    ap.add_argument("--interval", type=float, default=3.0,
                    help="watch: seconds between frames")
    args = ap.parse_args()
    if args.device is None:
        args.device = find_device()

    if args.mode in ("grab", "status"):
        path, state, detail = grab_and_classify(args)
        print(f"{state.upper():<10} {detail}")
        if args.mode == "status":
            os.unlink(path)
        else:
            print(f"           saved {path}")
        return 0 if state == "active" else 1

    # watch: a numbered series, so a boot can be followed frame by frame
    base, ext = os.path.splitext(args.output)
    t0 = time.monotonic()
    last = None
    for n in range(1, args.count + 1):
        args.output = f"{base}{n:03d}{ext}"
        path, state, detail = grab_and_classify(args)
        change = "" if state == last else "   <-- changed"
        print(f"t+{time.monotonic() - t0:6.1f}s  {state.upper():<10} "
              f"{os.path.basename(path)}  {detail}{change}", flush=True)
        last = state
        if n < args.count:
            time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
