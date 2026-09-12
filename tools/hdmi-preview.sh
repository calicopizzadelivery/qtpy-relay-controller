#!/usr/bin/env bash
#
# Live preview window of the Jetson's HDMI output, on this machine's display.
#
#   ./tools/hdmi-preview.sh start
#   ./tools/hdmi-preview.sh status
#   ./tools/hdmi-preview.sh stop
#
# Runs detached, so it survives the shell that started it. A clock is overlaid
# on the image: if it is ticking the feed is live, which distinguishes a frozen
# pipeline from a genuinely static screen -- the two look identical otherwise.
#
# The capture device only permits one streaming client, so the pipeline tees:
# one branch to the window, one writing a frame per second into a spool
# directory. tools/hdmi.py reads from that spool while the preview holds the
# device, which is what lets you watch and grab at the same time.
#
set -euo pipefail

DEVICE=${HDMI_DEVICE:-/dev/video0}
CAP_W=${HDMI_CAP_W:-1920}
CAP_H=${HDMI_CAP_H:-1080}
WIN_W=${HDMI_WIN_W:-960}
WIN_H=${HDMI_WIN_H:-540}
RUN=${XDG_RUNTIME_DIR:-/tmp}
PIDFILE="${RUN}/hdmi-preview.pid"
LOGFILE="${RUN}/hdmi-preview.log"
FRAMEDIR="${RUN}/hdmi-frames"

running() {
  [[ -f ${PIDFILE} ]] || return 1
  local pid; pid=$(cat "${PIDFILE}" 2>/dev/null) || return 1
  [[ -n ${pid} ]] && kill -0 "${pid}" 2>/dev/null
}

case "${1:-status}" in
  start)
    if running; then
      echo "already running as pid $(cat "${PIDFILE}")"
      exit 0
    fi
    [[ -e ${DEVICE} ]] || { echo "error: ${DEVICE} not present" >&2; exit 1; }
    : "${DISPLAY:?error: no DISPLAY set, cannot open a window}"

    rm -rf "${FRAMEDIR}"; mkdir -p "${FRAMEDIR}"

    # setsid detaches from this shell's session so the window outlives it.
    # The queues are leaky=downstream: if either branch stalls it drops frames
    # rather than backing up and stalling the other one.
    setsid gst-launch-1.0 -q \
      v4l2src device="${DEVICE}" \
      ! image/jpeg,width="${CAP_W}",height="${CAP_H}" \
      ! jpegdec ! videoconvert ! tee name=t \
      t. ! queue leaky=downstream max-size-buffers=4 \
         ! videoscale ! video/x-raw,width="${WIN_W}",height="${WIN_H}" \
         ! timeoverlay halignment=left valignment=top font-desc="Sans 16" \
         ! videoconvert ! ximagesink sync=false \
      t. ! queue leaky=downstream max-size-buffers=4 \
         ! videorate ! video/x-raw,framerate=1/1 \
         ! pngenc ! multifilesink location="${FRAMEDIR}/f%05d.png" max-files=4 \
      >"${LOGFILE}" 2>&1 &

    echo $! > "${PIDFILE}"
    sleep 2
    if running; then
      echo "preview started as pid $(cat "${PIDFILE}") on ${DISPLAY}"
      echo "  ${CAP_W}x${CAP_H} captured, shown at ${WIN_W}x${WIN_H}"
      echo "  frame spool: ${FRAMEDIR} (1/s, for tools/hdmi.py)"
      echo "  log: ${LOGFILE}"
    else
      echo "error: preview failed to start" >&2
      sed 's/^/  /' "${LOGFILE}" >&2
      rm -f "${PIDFILE}"
      exit 1
    fi
    ;;

  stop)
    if running; then
      pid=$(cat "${PIDFILE}")
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
      rm -f "${PIDFILE}"
      rm -rf "${FRAMEDIR}"
      echo "stopped"
    else
      echo "not running"
      rm -f "${PIDFILE}"
    fi
    ;;

  status)
    if running; then
      echo "running as pid $(cat "${PIDFILE}") on device ${DEVICE}"
      newest=$(ls -t "${FRAMEDIR}"/f*.png 2>/dev/null | head -1 || true)
      if [[ -n ${newest} ]]; then
        echo "  newest spooled frame: $(basename "${newest}") "\
             "($(( $(date +%s) - $(stat -c %Y "${newest}") ))s old)"
      else
        echo "  warning: no frames spooled yet"
      fi
    else
      echo "not running"
      exit 1
    fi
    ;;

  *)
    echo "usage: $0 {start|stop|status}" >&2
    exit 2
    ;;
esac
