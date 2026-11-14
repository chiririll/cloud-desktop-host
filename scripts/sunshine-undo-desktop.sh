#!/bin/bash
# sunshine-undo-desktop.sh — полная остановка Desktop-сессии при «Stop» в Moonlight.
# Гасит Plasma, KWin, его Xwayland и все GUI-приложения, чтобы в простое
# контейнер не жёг CPU/GPU. CDH, PipeWire и Sunshine остаются работать.
# sunshine-prep-desktop.sh сам поднимет KWin при следующем запуске.

LOG="/tmp/prep-desktop.log"
UID_SELF=$(id -u)

# ── 1. Plasma ───────────────────────────────────────────────────────
pkill -u "$UID_SELF" -x plasmashell 2>/dev/null || true
pkill -u "$UID_SELF" -x kded6 2>/dev/null || true
pkill -u "$UID_SELF" -x polkit-kde-authentication-agent-1 2>/dev/null || true

# ── 2. Steam (переживает потерю дисплея и качает/компилирует шейдеры) ─
pkill -u "$UID_SELF" -x steam 2>/dev/null || true
pkill -u "$UID_SELF" -f steamwebhelper 2>/dev/null || true
pkill -u "$UID_SELF" -f steam-runtime-launcher-service 2>/dev/null || true

# ── 3. KWin: SIGTERM, ждём до 5 с, затем SIGKILL ───────────────────
# Wayland-клиенты KWin и X-клиенты его Xwayland теряют соединение и выходят.
pkill -u "$UID_SELF" -x kwin_wayland 2>/dev/null || true
for _ in $(seq 1 10); do
    pgrep -u "$UID_SELF" -x kwin_wayland >/dev/null 2>&1 || break
    sleep 0.5
done
pkill -KILL -u "$UID_SELF" -x kwin_wayland 2>/dev/null || true

# ── 4. Xwayland, если пережил KWin, и X11 lock/сокеты ───────────────
pkill -u "$UID_SELF" -x Xwayland 2>/dev/null || true
sleep 0.5
rm -f /tmp/.X0-lock /tmp/.X1-lock /tmp/.X2-lock 2>/dev/null || true
rm -f /tmp/.X11-unix/X0 /tmp/.X11-unix/X1 /tmp/.X11-unix/X2 2>/dev/null || true

# ── Idle: CDH сразу перестаёт гнать кадры (иначе авто-idle через 10 с) ──
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$UID_SELF/bus}" \
    busctl --user call org.gamescope.Input /org/gamescope/Input \
    org.gamescope.InputDeviceManager SetIdle b true >/dev/null 2>&1 || true

echo "[undo-desktop] $(date) Desktop session stopped (Plasma + KWin + Xwayland)" >> "$LOG"
