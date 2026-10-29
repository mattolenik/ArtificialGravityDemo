#!/bin/sh
# Runs a driver scene in a Godot instance of its own that stays out of the way of the desktop and of any
# editor: launched hidden and in the background through macOS `open`, its main window made unfocusable and
# parked past the screen's bottom-right corner (Offscreen.apply, on the `--offscreen` user arg), and the app
# that was frontmost handed the focus back a second after launch (Godot activates itself at launch whatever
# `open` is told, so for that second keys go to it). Its output goes to a log file. The rendering device is
# up (headless Godot has only the dummy renderer; a minimized window draws nothing and its readbacks never
# land), so the GPU drivers run as they do windowed at the same frame rate. Usage, from anywhere:
#   sh tests/offscreen.sh res://terrain/tool_run.tscn /abs/path/to/log [user args...]
# DRIVER selects the rendering driver (vulkan, the default, for GPU timings; metal reports zeros). Waits for
# the instance to exit, prints the log's last lines and exits 0 when the log holds the drivers' verdict
# (PASS or BLACKOUT PASS on a line of its own), else 1.
cd "$(dirname "$0")/.." || exit 1
scene=$1
log=$2
shift 2 || { echo "usage: offscreen.sh <scene> </abs/log> [user args...]"; exit 2; }
case "$log" in /*) ;; *) echo "the log path must be absolute"; exit 2;; esac
rm -f "$log"
prev=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
if [ -n "$prev" ]; then
  (sleep 1; osascript -e "tell application \"$prev\" to activate" >/dev/null 2>&1) &
fi
open -n -g -j -W -a /Applications/Godot.app --args --rendering-driver "${DRIVER:-vulkan}" --path "$PWD" \
  --log-file "$log" "$scene" -- --offscreen "$@"
wait
tail -n 3 "$log"
grep -qE '^(BLACKOUT )?PASS$' "$log"
