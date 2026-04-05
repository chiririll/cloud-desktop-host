#!/bin/bash
# sunshine-prep-cmd.sh — вызывается Sunshine перед стримом.
# Меняет разрешение CDH и заменяет plasmashell через --replace.

LOG="/tmp/prep-cmd.log"
exec >> "$LOG" 2>&1
echo "=== $(date) ==="

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

UID_SELF=$(id -u)
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${UID_SELF}/bus}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID_SELF}}"

# ── 1. SetOutputMode ────────────────────────────────────────────────
echo "[prep-cmd] SetOutputMode ${W}x${H}@${FPS}fps"
busctl --user call \
    org.gamescope.Input \
    /org/gamescope/Input \
    org.gamescope.InputDeviceManager \
    SetOutputMode uuu \
    "$W" "$H" "$FPS"

RC=$?
echo "[prep-cmd] busctl exit code: $RC"
[ $RC -ne 0 ] && exit $RC

# ── 2. Ждём пока KWin применит новый режим ─────────────────────────
sleep 0.5

# ── 3. Найти DISPLAY от Xwayland ───────────────────────────────────
KWIN_XDISPLAY=""
for x in /tmp/.X11-unix/X*; do
    [ -S "$x" ] || continue
    KWIN_XDISPLAY=":${x##*X}"
    break
done

# ── 4. Заменяем plasmashell через --replace ─────────────────────────
# --replace: KDBusService отправляет quit() старому экземпляру и ждёт его
# завершения. sleep 1 даёт время на D-Bus handoff перед возвратом в Sunshine.
echo "[prep-cmd] plasmashell --replace → ${W}x${H}"
DISPLAY="${KWIN_XDISPLAY}" \
WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland \
QT_QPA_PLATFORM=wayland \
QT_QPA_PLATFORMTHEME=kde \
XDG_CURRENT_DESKTOP=KDE \
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
    plasmashell --replace >>/tmp/plasmashell-replace.log 2>&1 &

# Даём --replace время завершить D-Bus handoff (quit старого + регистрация нового)
sleep 1

echo "[prep-cmd] Done: ${W}x${H}@${FPS}fps"
exit 0
