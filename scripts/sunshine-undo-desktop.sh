#!/bin/bash
# sunshine-undo-desktop.sh — full stop of the Desktop session on «Stop» in Moonlight.
# Stops Plasma, KWin, its Xwayland and all GUI apps so the idle container burns no CPU/GPU.
# CDH, PipeWire and Sunshine keep running; sunshine-prep-desktop.sh restarts KWin next time.

set -u
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$SCRIPT_DIR/lib.sh"
cdh_env
mkdir -p "$CDH_LOG_DIR"
exec >>"$CDH_LOG_DIR/prep-desktop.log" 2>&1

stop_desktop
set_idle true   # CDH stops producing frames at once instead of after the 10 s auto-idle
log "Desktop session stopped (Plasma + KWin + Xwayland) in ${SECONDS}s"
exit 0
