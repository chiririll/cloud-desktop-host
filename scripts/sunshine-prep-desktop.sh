#!/bin/bash
# sunshine-prep-desktop.sh — switch to Desktop (Plasma).
# Called by Sunshine when «Desktop» is chosen in Moonlight.
# Starts KWin + Plasma at the client's resolution.
# No `set -e`: Sunshine cancels the launch on a non-zero exit, so only real failures return one.

set -u
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cdh_env
stream_active_set
mkdir -p "$CDH_LOG_DIR"
exec >>"$CDH_LOG_DIR/prep-desktop.log" 2>&1
printf '=== %(%F %T)T ===\n' -1

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

stop_deck
set_output_mode "$W" "$H" "$FPS" || exit $?
start_desktop "$W" "$H" || exit 1

log "Done: ${W}x${H}@${FPS}fps in ${SECONDS}s"
exit 0
