#!/bin/bash
# sunshine-undo-gamescope.sh — full stop of Gamescope + Steam + Xwayland.

set -u
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$SCRIPT_DIR/lib.sh"
cdh_env
mkdir -p "$CDH_LOG_DIR"
exec >>"$CDH_LOG_DIR/prep-gamescope.log" 2>&1

stop_deck
set_idle true
log "Gamescope + Steam cleaned in ${SECONDS}s"
exit 0
