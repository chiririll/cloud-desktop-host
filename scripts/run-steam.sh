#!/bin/bash
# ─── cloud-desktop-host: Steam GamepadUI standalone ─────────────
# Steam Big Picture (GamepadUI) запускается напрямую в CDH.
# KWin и Plasma не используются — Steam подключается к wayland-cd.
#
# Использование:
#   ./run-steam.sh          — Steam GamepadUI
#   ./run-steam.sh debug    — Steam GamepadUI + verbose CDH логи
# ────────────────────────────────────────────────────────────────

set -euo pipefail

HOST_BIN="/home/user/cloud-desktop-host/build/cloud-desktop-host"
USER_ID=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$USER_ID"

STEAM_XDISPLAY=":0"

kill_all_stack() {
    for proc in sunshine steam Xwayland kwin_wayland \
        plasmashell kded6 cloud-desktop-host kactivitymanagerd \
        pipewire-pulse wireplumber pipewire; do
        pkill -u "$USER_ID" -x "$proc" 2>/dev/null || true
    done
    pkill -u "$USER_ID" -f "cloud-desktop-host/build" --signal TERM 2>/dev/null || true
}

cleanup() {
    echo "[steam] Завершение..."
    kill_all_stack
    sleep 1
    kill_all_stack
    rm -f "$XDG_RUNTIME_DIR"/wayland-cd* 2>/dev/null || true
    rm -f /tmp/.X11-unix/X${STEAM_XDISPLAY#:} 2>/dev/null || true
    echo "[steam] Done."
    exit 0
}
trap cleanup EXIT INT TERM

# 0. Убить предыдущую сессию
kill_all_stack
sleep 1
kill_all_stack
sleep 1
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/pipewire-* 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/pulse/native 2>/dev/null || true

# 1. D-Bus
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval $(dbus-launch --sh-syntax)
    export DBUS_SESSION_BUS_ADDRESS
fi
echo "[steam] D-Bus OK"

# 2. PipeWire
pipewire &>/dev/null &
sleep 1
wireplumber &>/dev/null &
sleep 1
pipewire-pulse &>/dev/null &
sleep 1
echo "[steam] PipeWire OK"

# 3. kactivitymanagerd
QT_QPA_PLATFORM=offscreen /usr/libexec/kactivitymanagerd &>/dev/null &
sleep 1

# 4. CDH compositor — --no-auto-lock: не отправляем виртуальный RCTRL Steam-у
HOST_ARGS=("--no-auto-lock")
for _arg in "$@"; do
    case "$_arg" in
        debug) HOST_ARGS+=("--debug") ;;
        --debug|-d) HOST_ARGS+=("$_arg") ;;
    esac
done

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    "$HOST_BIN" "${HOST_ARGS[@]}" &>/tmp/cdh-steam.log 2>&1 &
HOST_PID=$!

for i in $(seq 1 15); do
    [ -S "$XDG_RUNTIME_DIR/wayland-cd" ] && break
    sleep 1
done
[ -S "$XDG_RUNTIME_DIR/wayland-cd" ] || { echo "FAIL: no wayland-cd"; exit 1; }
echo "[steam] Compositor OK (PID=$HOST_PID)"

# 5. Xwayland в fullscreen-режиме — подключён к wayland-cd.
# Создаёт один xdg_toplevel (fullscreen окно) в CDH — это и есть desktop_surface.
# Steam рендерит X11 контент в это окно. CDH стримит его через Sunshine.
echo "[steam] Starting Xwayland fullscreen (DISPLAY=${STEAM_XDISPLAY})..."
WAYLAND_DISPLAY=wayland-cd \
    Xwayland "${STEAM_XDISPLAY}" -ac -noreset \
    &>/tmp/xwayland-steam.log 2>&1 &

for i in $(seq 1 10); do
    [ -S "/tmp/.X11-unix/X${STEAM_XDISPLAY#:}" ] && break
    sleep 1
done
if [ -S "/tmp/.X11-unix/X${STEAM_XDISPLAY#:}" ]; then
    echo "[steam] Xwayland OK (DISPLAY=${STEAM_XDISPLAY})"
else
    echo "[steam] WARNING: Xwayland socket not found"
fi

# 6. D-Bus environment
dbus-update-activation-environment \
    DISPLAY="${STEAM_XDISPLAY}" \
    XDG_SESSION_TYPE=x11 \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    2>/dev/null || true

# 7. Steam GamepadUI
# DISPLAY=${STEAM_XDISPLAY}: Xwayland fullscreen — Xwayland является desktop_toplevel в CDH.
# Steam рендерит всё через X11. Не используем -steamos3 (gamescope code path).
# -noverifyfiles: пропускаем верификацию при старте
echo "[steam] Starting Steam GamepadUI..."
DISPLAY="${STEAM_XDISPLAY}" \
XDG_SESSION_TYPE=x11 \
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
XDG_CURRENT_DESKTOP=steamos \
    steam -gamepadui -noverifyfiles &>/tmp/steam.log 2>&1 &
STEAM_PID=$!
echo "[steam] Steam PID=${STEAM_PID}"

# 8. Sunshine
if command -v sunshine &>/dev/null; then
    WAYLAND_DISPLAY=wayland-cd \
    PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native \
        sunshine &>/dev/null &
    sleep 3
    echo "[steam] Sunshine OK"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  Cloud Desktop — Steam GamepadUI mode"
echo "  DISPLAY=${STEAM_XDISPLAY} (Xwayland fullscreen → CDH)"
echo "  Логи: /tmp/steam.log  /tmp/cdh-steam.log"
echo "  Ctrl+C для остановки"
echo "═══════════════════════════════════════════════"

wait "$HOST_PID" 2>/dev/null
