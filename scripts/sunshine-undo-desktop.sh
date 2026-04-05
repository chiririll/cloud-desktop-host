#!/bin/bash
# sunshine-undo-desktop.sh — очистка при отключении от Desktop.
# Убивает Plasma стек, чтобы при следующем подключении начать с чистого листа.

UID_SELF=$(id -u)
pkill -u "$UID_SELF" -x plasmashell 2>/dev/null || true
pkill -u "$UID_SELF" -x kded6 2>/dev/null || true
pkill -u "$UID_SELF" -x polkit-kde-authentication-agent-1 2>/dev/null || true
echo "[undo-desktop] $(date) Plasma killed" >> /tmp/prep-desktop.log
