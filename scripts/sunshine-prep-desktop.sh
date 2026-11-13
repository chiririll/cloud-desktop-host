#!/bin/bash
# sunshine-prep-desktop.sh — переключение в Desktop (Plasma).
# Вызывается Sunshine при выборе приложения «Desktop» в Moonlight.
#
# Если KWin не запущен (после Deck Mode) — запускает его.

LOG="/tmp/prep-desktop.log"
exec >> "$LOG" 2>&1
echo "=== $(date) ==="

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

UID_SELF=$(id -u)
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${UID_SELF}/bus}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID_SELF}}"
export XDG_SESSION_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true

# ── 1. Cleanup предыдущих режимов ──────────────────────────────────
echo "[prep-desktop] Cleanup..."
# Gamescope и Steam (после Deck Mode)
pkill -u "$UID_SELF" -x gamescope 2>/dev/null || true
pkill -u "$UID_SELF" -x steam 2>/dev/null || true
pkill -u "$UID_SELF" -f steamwebhelper 2>/dev/null || true
pkill -u "$UID_SELF" -f steam-runtime-launcher-service 2>/dev/null || true
pkill -u "$UID_SELF" -x gamescope-focus-daemon 2>/dev/null || true
sleep 1

# Если gamescope оставил Xwayland — убить ТОЛЬКО если KWin не запущен
# (KWin тоже использует Xwayland, его нельзя трогать)
if ! pgrep -u "$UID_SELF" -x kwin_wayland >/dev/null 2>&1; then
    pkill -u "$UID_SELF" -x Xwayland 2>/dev/null || true
    rm -f /tmp/.X0-lock /tmp/.X1-lock /tmp/.X2-lock 2>/dev/null || true
    sleep 0.5
fi

# ── 2. SetOutputMode ───────────────────────────────────────────────
echo "[prep-desktop] SetOutputMode ${W}x${H}@${FPS}fps"
busctl --user call \
    org.gamescope.Input \
    /org/gamescope/Input \
    org.gamescope.InputDeviceManager \
    SetOutputMode uuu \
    "$W" "$H" "$FPS"

RC=$?
echo "[prep-desktop] busctl exit code: $RC"
[ $RC -ne 0 ] && exit $RC

sleep 0.5

# ── 3. Убедиться что KWin запущен ─────────────────────────────────
if ! pgrep -u "$UID_SELF" -x kwin_wayland >/dev/null 2>&1; then
    echo "[prep-desktop] KWin not running, starting..."
    WAYLAND_DISPLAY=wayland-cd \
    XDG_SESSION_TYPE=wayland \
    QT_QPA_PLATFORM=wayland \
        kwin_wayland --no-lockscreen \
        --width "$W" --height "$H" --xwayland \
        &>/dev/null &
    echo "[prep-desktop] KWin PID=$!"
    # Ждём Xwayland socket
    for i in $(seq 1 20); do
        [ -S /tmp/.X11-unix/X* ] 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
fi

# ── 4. Найти DISPLAY от KWin Xwayland ─────────────────────────────
KWIN_XDISPLAY=""
for x in /tmp/.X11-unix/X*; do
    [ -S "$x" ] || continue
    KWIN_XDISPLAY=":${x##*X}"
    break
done
echo "[prep-desktop] DISPLAY=${KWIN_XDISPLAY:-N/A}"

# ── 5. Обновить D-Bus окружение ───────────────────────────────────────
dbus-update-activation-environment \
    DISPLAY="${KWIN_XDISPLAY}" \
    WAYLAND_DISPLAY=wayland-0 \
    XDG_SESSION_TYPE=wayland \
    QT_QPA_PLATFORM=wayland \
    QT_QPA_PLATFORMTHEME=kde \
    XDG_CURRENT_DESKTOP=KDE \
    XDG_SESSION_DESKTOP=KDE \
    KDE_SESSION_VERSION=6 \
    KDE_FULL_SESSION=true \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    2>/dev/null || true

# ── 6. Kill старый Steam если был ─────────────────────────────────
pkill -u "$UID_SELF" -x steam 2>/dev/null || true
pkill -u "$UID_SELF" -f "steam -gamepadui" 2>/dev/null || true
sleep 0.5

# ── 6. Start Plasma stack ─────────────────────────────────────────
echo "[prep-desktop] Starting Plasma..."

# kded6
DISPLAY="${KWIN_XDISPLAY}" WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland \
QT_QPA_PLATFORMTHEME=kde XDG_CURRENT_DESKTOP=KDE \
    kded6 &>/dev/null &
sleep 1

# plasmashell
DISPLAY="${KWIN_XDISPLAY}" WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland \
QT_QPA_PLATFORMTHEME=kde XDG_CURRENT_DESKTOP=KDE \
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
    plasmashell --replace >>/tmp/plasmashell-replace.log 2>&1 &
sleep 2

# polkit
DISPLAY="${KWIN_XDISPLAY}" WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland \
    /usr/libexec/kf6/polkit-kde-authentication-agent-1 &>/dev/null &

echo "[prep-desktop] Done: ${W}x${H}@${FPS}fps"
exit 0
