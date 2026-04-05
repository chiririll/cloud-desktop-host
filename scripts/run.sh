#!/bin/bash
# ─── cloud-desktop-host: полный стек ───────────────────────────
# DBUS → PipeWire → kactivitymanagerd → compositor → KWin →
# → kded6 → Plasma → polkit → Sunshine
#
# Запуск: /home/user/cloud-desktop-host/scripts/run.sh
# Логи:  /tmp/cdhost-logs/
# ────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Параметры ──────────────────────────────────────────────────
HOST_BIN="/home/user/cloud-desktop-host/build/cloud-desktop-host"
LOG_DIR="/tmp/cdhost-logs"
WAIT_SOCKET=15
WAIT_KWIN=20

USER_ID=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$USER_ID"
export QT_QPA_PLATFORMTHEME=kde
export XDG_CURRENT_DESKTOP=KDE

# ── Утилиты ────────────────────────────────────────────────────
add_ts() {
    while IFS= read -r line; do
        printf '[%s] %s\n' "$(date '+%H:%M:%S.%3N')" "$line"
    done
}

log()  { echo "[run.sh] $*"; }
die()  { log "ОШИБКА: $*"; exit 1; }

wait_socket() {
    local name="$1" timeout="$2"
    for i in $(seq 1 "$timeout"); do
        [ -S "$XDG_RUNTIME_DIR/$name" ] && return 0
        sleep 1
    done
    return 1
}

check_pid() {
    local name="$1" pid="$2"
    if kill -0 "$pid" 2>/dev/null; then
        log "   ✅ $name PID=$pid"
        return 0
    else
        log "   ⚠️  $name не запустился"
        return 1
    fi
}

# ── Kill all stack ─────────────────────────────────────────────
kill_all_stack() {
    for proc in sunshine plasmashell kded6 kwin_wayland \
        cloud-desktop-host kactivitymanagerd pipewire-pulse \
        wireplumber pipewire polkit-kde-authentication-agent-1; do
        pkill -u "$USER_ID" -x "$proc" 2>/dev/null || true
    done
    pkill -u "$USER_ID" -f "cloud-desktop-host/build" --signal TERM 2>/dev/null || true
}

# ── Cleanup ────────────────────────────────────────────────────
CLEANED=0
cleanup() {
    [ "$CLEANED" = "1" ] && return
    CLEANED=1
    log "Завершение стека..."
    kill_all_stack
    sleep 1
    kill_all_stack  # повторно — для упрямых
    rm -f "$XDG_RUNTIME_DIR"/wayland-cd* 2>/dev/null || true
    log "Done."
    exit 0
}
trap cleanup EXIT INT TERM

# ── Проверки ───────────────────────────────────────────────────
[ -x "$HOST_BIN" ] || die "$HOST_BIN не найден. Соберите: ninja -C build"
[ -d "$XDG_RUNTIME_DIR" ] || die "XDG_RUNTIME_DIR не существует"

# ── 0. Убить предыдущую сессию ─────────────────────────────────
log "0. Очистка предыдущей сессии"
kill_all_stack
sleep 1
kill_all_stack
sleep 1
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/pipewire-* 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/pulse/native 2>/dev/null || true
mkdir -p "$LOG_DIR"

echo "═══════════════════════════════════════════════"
echo "  cloud-desktop-host"
echo "  $(date)"
echo "═══════════════════════════════════════════════"

# ── 1. D-Bus ───────────────────────────────────────────────────
log "1. D-Bus session"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval $(dbus-launch --sh-syntax)
    export DBUS_SESSION_BUS_ADDRESS
fi
log "   ✅ $DBUS_SESSION_BUS_ADDRESS"

# ── 2. PipeWire (аудио) ───────────────────────────────────────
log "2. PipeWire + WirePlumber"
pipewire > >(add_ts > "$LOG_DIR/pipewire.log") 2>&1 &
PW_PID=$!
sleep 1

wireplumber > >(add_ts > "$LOG_DIR/wireplumber.log") 2>&1 &
WP_PID=$!
sleep 1

pipewire-pulse > >(add_ts > "$LOG_DIR/pipewire-pulse.log") 2>&1 &
PP_PID=$!
sleep 1

if kill -0 "$PW_PID" 2>/dev/null && kill -0 "$PP_PID" 2>/dev/null; then
    log "   ✅ PipeWire=$PW_PID WirePlumber=$WP_PID Pulse=$PP_PID"
else
    log "   ⚠️  Аудио стек не запустился (не критично)"
fi

# ── 3. kactivitymanagerd ───────────────────────────────────────
log "3. kactivitymanagerd"
QT_QPA_PLATFORM=offscreen /usr/libexec/kactivitymanagerd \
    > >(add_ts > "$LOG_DIR/kactivity.log") 2>&1 &
KACT_PID=$!
sleep 1
check_pid "kactivitymanagerd" "$KACT_PID" || true

# ── 4. Compositor ──────────────────────────────────────────────
log "4. cloud-desktop-host"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    "$HOST_BIN" "$@" > >(add_ts > "$LOG_DIR/compositor.log") 2>&1 &
HOST_PID=$!

if ! wait_socket "wayland-cd" "$WAIT_SOCKET"; then
    log "   Compositor не создал сокет. Лог:"
    tail -20 "$LOG_DIR/compositor.log"
    die "Compositor socket timeout"
fi
log "   ✅ PID=$HOST_PID socket=wayland-cd"

# ── 5. KWin ────────────────────────────────────────────────────
log "5. KWin"
WAYLAND_DISPLAY=wayland-cd \
XDG_SESSION_TYPE=wayland \
QT_QPA_PLATFORM=wayland \
    kwin_wayland --no-lockscreen --no-global-shortcuts \
    --width 1920 --height 1080 --xwayland \
    > >(add_ts > "$LOG_DIR/kwin.log") 2>&1 &
KWIN_PID=$!

if ! wait_socket wayland-0 "$WAIT_KWIN"; then
    log "   KWin не создал wayland-0. Лог:"
    tail -20 "$LOG_DIR/kwin.log"
    die "KWin timeout"
fi
log "   ✅ PID=$KWIN_PID socket=wayland-0"

# Автоопределение XWayland DISPLAY от KWin
sleep 3
KWIN_XDISPLAY=""
for i in $(seq 1 10); do
    for x in /tmp/.X11-unix/X*; do
        [ -S "$x" ] || continue
        xnum="${x##*X}"
        KWIN_XDISPLAY=":$xnum"
        break 2
    done
    sleep 1
done
if [ -n "$KWIN_XDISPLAY" ]; then
    log "   ✅ XWayland DISPLAY=$KWIN_XDISPLAY"
else
    log "   ⚠️  XWayland не обнаружен"
fi

# ── 6. D-Bus activation environment ───────────────────────────
log "6. dbus-update-activation-environment"
dbus-update-activation-environment \
    DISPLAY="${KWIN_XDISPLAY}" \
    WAYLAND_DISPLAY=wayland-0 \
    XDG_SESSION_TYPE=wayland \
    QT_QPA_PLATFORM=wayland \
    QT_QPA_PLATFORMTHEME=kde \
    XDG_CURRENT_DESKTOP=KDE \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    2>/dev/null || true

# GTK button layout
/usr/bin/gsettings set org.gnome.desktop.wm.preferences button-layout \
    'appmenu:minimize,maximize,close' 2>/dev/null || true
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
for gtkver in gtk-3.0 gtk-4.0; do
    ini="$HOME/.config/$gtkver/settings.ini"
    if ! grep -q 'gtk-decoration-layout' "$ini" 2>/dev/null; then
        echo -e '[Settings]\ngtk-decoration-layout=appmenu:minimize,maximize,close' > "$ini"
    fi
done
log "   ✅ D-Bus env + GTK layout"

# ── 7. kded6 ───────────────────────────────────────────────────
log "7. kded6"
DISPLAY="${KWIN_XDISPLAY}" \
WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland \
QT_QPA_PLATFORM=wayland \
    kded6 > >(add_ts > "$LOG_DIR/kded6.log") 2>&1 &
KDED_PID=$!
sleep 2
check_pid "kded6" "$KDED_PID" || true

# ── 8. Plasma shell ───────────────────────────────────────────
log "8. Plasma shell"
DISPLAY="${KWIN_XDISPLAY}" \
WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland \
QT_QPA_PLATFORM=wayland \
    plasmashell > >(add_ts > "$LOG_DIR/plasma.log") 2>&1 &
PLASMA_PID=$!
sleep 5
if ! check_pid "plasmashell" "$PLASMA_PID"; then
    tail -10 "$LOG_DIR/plasma.log"
fi

# Polkit
DISPLAY="${KWIN_XDISPLAY}" \
WAYLAND_DISPLAY=wayland-0 \
XDG_SESSION_TYPE=wayland \
QT_QPA_PLATFORM=wayland \
    /usr/libexec/kf6/polkit-kde-authentication-agent-1 \
    > >(add_ts > "$LOG_DIR/polkit.log") 2>&1 &
POLKIT_PID=$!
sleep 1
check_pid "polkit-agent" "$POLKIT_PID" || true

# ── 9. Sunshine ────────────────────────────────────────────────
if command -v sunshine &>/dev/null; then
    log "9. Sunshine"
    WAYLAND_DISPLAY=wayland-cd \
    PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native \
        sunshine > >(add_ts > "$LOG_DIR/sunshine.log") 2>&1 &
    SUNSHINE_PID=$!
    sleep 3
    check_pid "Sunshine" "$SUNSHINE_PID" || true
else
    log "9. Sunshine не найден — пропускаем"
fi

# ── Готово ─────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  ✅ Cloud Desktop Host запущен!"
echo "  Compositor: wayland-cd (PID $HOST_PID)"
echo "  KWin:       wayland-0  (PID $KWIN_PID)"
echo "  XWayland:   ${KWIN_XDISPLAY:-N/A}"
echo "  Логи:       $LOG_DIR/"
echo "  Moonlight → $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "  Ctrl+C для остановки"
echo "═══════════════════════════════════════════════"

# ── Ожидание ───────────────────────────────────────────────────
wait "$HOST_PID" 2>/dev/null
log "Compositor завершился"
