#!/bin/bash
# sunshine-prep-gamescope.sh — start Gamescope + Steam -steamos3.
# Gamescope runs as a nested compositor inside CDH.

set -u
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$SCRIPT_DIR/lib.sh"
cdh_env
stream_active_set
mkdir -p "$CDH_LOG_DIR"
exec >>"$CDH_LOG_DIR/prep-gamescope.log" 2>&1
printf '=== %(%F %T)T ===\n' -1

# $GAMESCOPE_BIN → gamescope from PATH (dnf package) → submodule build
GAMESCOPE_BIN="${GAMESCOPE_BIN:-$(command -v gamescope || echo "$SCRIPT_DIR/../subprojects/gamescope/build/src/gamescope")}"
# Check BEFORE stopping KWin, otherwise a failure leaves an empty screen
[ -x "$GAMESCOPE_BIN" ] || die "gamescope not found ($GAMESCOPE_BIN). dnf install gamescope"
command -v steam >/dev/null || die "steam not found. dnf install steam (rpmfusion-nonfree)"

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
R="${SUNSHINE_CLIENT_FPS:-60}"

stop_desktop
stop_deck

# CDH must know the target resolution, otherwise Gamescope gets a 1920x1080 configure
set_output_mode "$W" "$H" "$R" || exit $?

# MangoHud config. On a real Deck Steam appends preset/no_display to it; we keep it
# read-only so Steam cannot write "no_display=1" (which hides the overlay).
MANGOHUD_CFG="$CDH_STATE_DIR/mangohud-gamescope.conf"
rm -f "$MANGOHUD_CFG"
cat > "$MANGOHUD_CFG" << 'CFG'
control=mangohud
preset=2
no_display=0
fsr_steam_sharpness=5
CFG
chmod 444 "$MANGOHUD_CFG"

# --mangoapp only if MangoHud is installed (dnf install mangohud)
MANGOAPP_ARG=()
if command -v mangoapp >/dev/null; then MANGOAPP_ARG=(--mangoapp); fi

# GLFW_PLATFORM=x11: with WAYLAND_DISPLAY set, Fedora's glfw picks Wayland and MangoApp
# never sets the GAMESCOPE_EXTERNAL_OVERLAY atom.
log "Gamescope: $GAMESCOPE_BIN ${W}x${H}@${R}"
spawn gamescope env WAYLAND_DISPLAY=wayland-cd GLFW_PLATFORM=x11 STEAM_DECK=1 \
    MANGOHUD_CONFIGFILE="$MANGOHUD_CFG" \
    "$GAMESCOPE_BIN" --backend wayland \
    -W "$W" -H "$H" -w "$W" -h "$H" -r "$R" \
    -e "${MANGOAPP_ARG[@]}" --xwayland-count 2 --force-grab-cursor -f \
    -- steam -steamos3 -gamepadui -noverifyfiles
GS_PID=$SPAWNED_PID
sleep 1
kill -0 "$GS_PID" 2>/dev/null || die "gamescope exited right away, see $CDH_LOG_DIR/gamescope.log"
log "Done: gamescope PID=$GS_PID in ${SECONDS}s"
exit 0
