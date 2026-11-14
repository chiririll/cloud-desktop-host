#!/bin/bash
# ─── cloud-desktop-host: base stack ────────────────────────────
# D-Bus → PipeWire → kactivitymanagerd → compositor → Sunshine
# KWin + Plasma / gamescope are started by the Sunshine prep scripts.
#
# Usage: run.sh [--no-log] [--steam] [hud] [debug] [-- <compositor arguments>]
#   --no-log  children write to /dev/null (compositor log is still kept)
#   --steam   standalone Steam GamepadUI on a fullscreen Xwayland, no KWin
#   hud, debug  shorthands for --hud / --debug
# Env: CDH_BIN (compositor binary), CDH_FORCE=1 (allow running inside a graphical session)
# Logs: /tmp/cdhost-logs/<timestamp>/ (newest 5 kept), /tmp/cdhost-logs/latest
# ────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$SCRIPT_DIR/lib.sh"

# ── Arguments ──────────────────────────────────────────────────
STEAM_MODE=0
HOST_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-log) export CDH_NO_LOG=1 ;;
        --steam)  STEAM_MODE=1; HOST_ARGS+=(--no-auto-lock) ;;
        hud)      HOST_ARGS+=(--hud) ;;
        debug)    HOST_ARGS+=(--debug) ;;
        --)       shift; HOST_ARGS+=("$@"); break ;;
        *)        HOST_ARGS+=("$1") ;;
    esac
    shift
done

HOST_BIN="${CDH_BIN:-$(command -v cloud-desktop-host || echo "$SCRIPT_DIR/../build/cloud-desktop-host")}"

# ── Guards ─────────────────────────────────────────────────────
# The stop lists kill every pipewire/kwin of this user: never run inside a live desktop.
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && [ "${CDH_FORCE:-0}" != 1 ]; then
    die "WAYLAND_DISPLAY/DISPLAY is set: this looks like a graphical session. Set CDH_FORCE=1 to run anyway."
fi
_DBUS_ORIG="${DBUS_SESSION_BUS_ADDRESS:-}"   # before cdh_env adds its fallback
cdh_env
[ -x "$HOST_BIN" ] || die "$HOST_BIN not found. Build: ninja -C build"
[ -d "$XDG_RUNTIME_DIR" ] || die "XDG_RUNTIME_DIR does not exist"

# ── Logs: one directory per start ──────────────────────────────
LOG_ROOT=/tmp/cdhost-logs
mkdir -p "$LOG_ROOT"
CDH_LOG_DIR="$LOG_ROOT/$(printf '%(%Y%m%d-%H%M%S)T' -1)"
export CDH_LOG_DIR
mkdir -p "$CDH_LOG_DIR"
if [ ! -L "$LOG_ROOT/latest" ]; then rm -rf "$LOG_ROOT/latest"; fi
ln -sfn "$CDH_LOG_DIR" "$LOG_ROOT/latest"
_old=("$LOG_ROOT"/[0-9]*)
if ((${#_old[@]} > 5)); then
    rm -rf "${_old[@]:0:${#_old[@]}-5}"
fi

# ── Cleanup ────────────────────────────────────────────────────
DBUS_LAUNCHED=0
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    log "Stopping the stack (exit code $rc)..."
    stop_desktop
    stop_deck
    stop_base
    rm -f "$XDG_RUNTIME_DIR"/wayland-cd*
    if [ "$DBUS_LAUNCHED" = 1 ] && [ -n "${DBUS_SESSION_BUS_PID:-}" ]; then
        kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
    fi
    log "Done."
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 0' INT TERM   # a requested stop is a success

echo "═══════════════════════════════════════════════"
echo "  cloud-desktop-host"
echo "  $(date)"
echo "═══════════════════════════════════════════════"

# ── 0. Previous session ────────────────────────────────────────
log "0. Cleaning up the previous session"
stop_desktop
stop_deck
stop_base
# Remove sockets only now that their owners are gone
rm -f "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/pipewire-* "$XDG_RUNTIME_DIR"/pulse/native

# ── 1. D-Bus ───────────────────────────────────────────────────
log "1. D-Bus session"
if [ -z "$_DBUS_ORIG" ]; then
    eval "$(dbus-launch --sh-syntax)"
    export DBUS_SESSION_BUS_ADDRESS
    DBUS_LAUNCHED=1
fi
log "   ✅ $DBUS_SESSION_BUS_ADDRESS"

# ── 2. PipeWire ────────────────────────────────────────────────
log "2. PipeWire + WirePlumber"
spawn pipewire pipewire; PW_PID=$SPAWNED_PID
wait_for 5 test -S "$XDG_RUNTIME_DIR/pipewire-0" || log "   ⚠️  pipewire-0 socket missing"
spawn wireplumber wireplumber
spawn pipewire-pulse pipewire-pulse; PP_PID=$SPAWNED_PID
wait_for 5 test -S "$XDG_RUNTIME_DIR/pulse/native" || log "   ⚠️  pulse socket missing (audio not critical)"
log "   PipeWire=$PW_PID Pulse=$PP_PID"

# ── 3. kactivitymanagerd ───────────────────────────────────────
log "3. kactivitymanagerd"
spawn kactivity env QT_QPA_PLATFORM=offscreen /usr/libexec/kactivitymanagerd

# ── 4. Compositor ──────────────────────────────────────────────
log "4. cloud-desktop-host"
mkdir -p "$CDH_LOG_DIR"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    "$HOST_BIN" "${HOST_ARGS[@]}" > >(add_ts >"$CDH_LOG_DIR/compositor.log") 2>&1 &
HOST_PID=$!
if ! wait_for 15 test -S "$XDG_RUNTIME_DIR/wayland-cd"; then
    tail -20 "$CDH_LOG_DIR/compositor.log" || true
    die "compositor did not create wayland-cd"
fi
# prep scripts need the D-Bus name
wait_for 5 busctl --user status org.gamescope.Input || log "   ⚠️  org.gamescope.Input not on D-Bus yet"
log "   ✅ PID=$HOST_PID socket=wayland-cd"

# ── 4b. Steam standalone ───────────────────────────────────────
if [ "$STEAM_MODE" = 1 ]; then
    STEAM_XDISPLAY=":0"
    log "4b. Xwayland fullscreen ($STEAM_XDISPLAY) + Steam GamepadUI"
    spawn xwayland env WAYLAND_DISPLAY=wayland-cd Xwayland "$STEAM_XDISPLAY" -ac -noreset
    wait_for 10 test -S "/tmp/.X11-unix/X${STEAM_XDISPLAY#:}" || log "   ⚠️  Xwayland socket not found"
    dbus-update-activation-environment DISPLAY="$STEAM_XDISPLAY" XDG_SESSION_TYPE=x11 \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" 2>/dev/null || true
    # No -steamos3: that is the gamescope code path
    spawn steam env DISPLAY="$STEAM_XDISPLAY" XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=steamos \
        steam -gamepadui -noverifyfiles
fi

# ── 5. Sunshine ────────────────────────────────────────────────
WATCH=("$HOST_PID")
if command -v sunshine &>/dev/null; then
    log "5. Sunshine"
    spawn sunshine env WAYLAND_DISPLAY=wayland-cd PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native" sunshine
    SUNSHINE_PID=$SPAWNED_PID
    sleep 1
    kill -0 "$SUNSHINE_PID" 2>/dev/null || die "Sunshine exited right away, see $CDH_LOG_DIR/sunshine.log"
    WATCH+=("$SUNSHINE_PID")
else
    log "5. Sunshine not found — skipping"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  ✅ Cloud Desktop Host started in ${SECONDS}s"
echo "  Compositor: wayland-cd (PID $HOST_PID)"
echo "  Logs:       $CDH_LOG_DIR/"
echo "  Moonlight → $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "  Ctrl+C to stop"
echo "═══════════════════════════════════════════════"

# ── Supervision: compositor or Sunshine dying restarts the whole stack ──
rc=0
wait -n -p dead "${WATCH[@]}" || rc=$?
log "PID $dead exited with status $rc; stopping the stack"
exit $(( rc ? rc : 1 ))
