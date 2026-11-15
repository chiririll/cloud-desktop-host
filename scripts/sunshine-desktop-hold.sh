#!/bin/bash
# sunshine-desktop-hold.sh — the "cmd" of Sunshine's Desktop app: does nothing and lives as long as the stream.
# Sunshine ends the stream when it exits; session-action.sh logout stops it (Plasma → Log out).
# Not exec'd into sleep: session-action.sh finds it by this script's name.
trap 'kill "$!" 2>/dev/null; exit 143' TERM INT HUP
sleep infinity &
wait
