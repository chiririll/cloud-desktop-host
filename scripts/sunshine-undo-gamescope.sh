#!/bin/bash
# sunshine-undo-gamescope.sh — Полная остановка Gamescope + Steam + Xwayland

UID_SELF=$(id -u)

# 1. Steam и все его процессы
pkill -u "$UID_SELF" -x steam 2>/dev/null || true
pkill -u "$UID_SELF" -f steamwebhelper 2>/dev/null || true
pkill -u "$UID_SELF" -f steam-runtime-launcher-service 2>/dev/null || true
pkill -u "$UID_SELF" -f steamclient 2>/dev/null || true

# 2. Gamescope (это убьёт и его child Xwayland)
pkill -u "$UID_SELF" -x gamescope 2>/dev/null || true
sleep 1

# 3. Если Xwayland от gamescope остался — добить
# Gamescope запускает Xwayland на :0 и :1, они могут пережить gamescope
pkill -u "$UID_SELF" -x Xwayland 2>/dev/null || true
sleep 0.5

# 4. Убрать зависшие X11 lock файлы
rm -f /tmp/.X0-lock /tmp/.X1-lock 2>/dev/null || true

# 5. focus-daemon если был
pkill -u "$UID_SELF" -x gamescope-focus-daemon 2>/dev/null || true

echo "[undo-gamescope] $(date) Gamescope+Steam fully cleaned" >> /tmp/prep-gamescope.log
