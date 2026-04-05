#!/bin/bash
# ─── cloud-desktop-host: быстрый запуск БЕЗ логов ──────────────
# Для теста CPU нагрузки
#
# Использование:
#   ./run-nolog.sh          — без логов, без HUD
#   ./run-nolog.sh hud      — без логов, HUD поверх стрима
#   ./run-nolog.sh hud debug — без логов, HUD + verbose wlroots логи в stderr
# ────────────────────────────────────────────────────────────────

set -euo pipefail

HOST_BIN="/home/user/cloud-desktop-host/build/cloud-desktop-host"
USER_ID=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$USER_ID"
export QT_QPA_PLATFORMTHEME=kde
export XDG_CURRENT_DESKTOP=KDE

kill_all_stack() {
    local self=$$
    for proc in sunshine plasmashell kded6 kwin_wayland \
        cloud-desktop-host kactivitymanagerd pipewire-pulse \
        wireplumber pipewire polkit-kde-authentication-agent-1; do
        pkill -u "$USER_ID" -x "$proc" 2>/dev/null || true
    done
    # По паттерну, исключая себя
    pkill -u "$USER_ID" -f "cloud-desktop-host/build" --signal TERM 2>/dev/null || true
}

cleanup() {
    echo "[nolog] Завершение..."
    kill_all_stack
    sleep 1
    kill_all_stack  # повторно — для упрямых
    rm -f "$XDG_RUNTIME_DIR"/wayland-cd* 2>/dev/null || true
    echo "[nolog] Done."
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
echo "[nolog] D-Bus OK"

# 2. PipeWire
pipewire &>/dev/null &
sleep 1
wireplumber &>/dev/null &
sleep 1
pipewire-pulse &>/dev/null &
sleep 1
echo "[nolog] PipeWire OK"

# 3. kactivitymanagerd
QT_QPA_PLATFORM=offscreen /usr/libexec/kactivitymanagerd &>/dev/null &
sleep 1

# 4. Compositor — собираем аргументы из $@
HOST_ARGS=()
for _arg in "$@"; do
    case "$_arg" in
        hud)   HOST_ARGS+=("--hud")   ;;
        debug) HOST_ARGS+=("--debug") ;;
        --hud|--debug|-d) HOST_ARGS+=("$_arg") ;;
    esac
done

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    "$HOST_BIN" "${HOST_ARGS[@]}" >/tmp/cdh.log 2>&1 &
HOST_PID=$!

for i in $(seq 1 15); do
    [ -S "$XDG_RUNTIME_DIR/wayland-cd" ] && break
    sleep 1
done
[ -S "$XDG_RUNTIME_DIR/wayland-cd" ] || { echo "FAIL: no wayland-cd"; exit 1; }
echo "[nolog] Compositor OK (PID=$HOST_PID)"

# 5. Sunshine — контент (Plasma/Steam) запускается через Sunshine apps prep-cmd
if command -v sunshine &>/dev/null; then
    WAYLAND_DISPLAY=wayland-cd \
    PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native \
        sunshine &>/dev/null &
    sleep 3
    echo "[nolog] Sunshine OK"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  Cloud Desktop (no-log mode)"
echo "  Аргументы compositor: ${HOST_ARGS[*]:-none}"
echo "  Ctrl+C для остановки"
echo "═══════════════════════════════════════════════"

wait "$HOST_PID" 2>/dev/null
