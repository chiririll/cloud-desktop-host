#!/bin/bash
# sunshine-prep-gamescope.sh — Запуск Gamescope + Steam -steamos3
# Gamescope работает как вложенный compositor внутри CDH.

set -euo pipefail

GAMESCOPE_BIN="/home/user/cloud-desktop-host/subprojects/gamescope/build/src/gamescope"
LOG="/tmp/prep-gamescope.log"
echo "[prep-gamescope] $(date) Starting..." >> "$LOG"

UID_SELF=$(id -u)
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID_SELF}"
export XDG_RUNTIME_DIR

# ── 1. Thorough cleanup предыдущих процессов ──
# Убиваем ВСЁ что может конфликтовать: KWin, Plasma, Steam, Gamescope, Xwayland
pkill -u "$UID_SELF" -x plasmashell 2>/dev/null || true
pkill -u "$UID_SELF" -x kded6 2>/dev/null || true
pkill -u "$UID_SELF" -x polkit-kde-authentication-agent-1 2>/dev/null || true
pkill -u "$UID_SELF" -x kwin_wayland 2>/dev/null || true
pkill -u "$UID_SELF" -x steam 2>/dev/null || true
pkill -u "$UID_SELF" -f steamwebhelper 2>/dev/null || true
pkill -u "$UID_SELF" -f steam-runtime-launcher-service 2>/dev/null || true
pkill -u "$UID_SELF" -x gamescope 2>/dev/null || true
pkill -u "$UID_SELF" -x gamescope-focus-daemon 2>/dev/null || true
pkill -u "$UID_SELF" -x Xwayland 2>/dev/null || true
sleep 1

# Ждём завершения KWin (может занять время)
for i in $(seq 1 10); do
    pgrep -u "$UID_SELF" -x kwin_wayland >/dev/null 2>&1 || break
    sleep 0.5
done

# Чистим X11 lock файлы
rm -f /tmp/.X0-lock /tmp/.X1-lock /tmp/.X2-lock 2>/dev/null || true
rm -f /tmp/.X11-unix/X0 /tmp/.X11-unix/X1 /tmp/.X11-unix/X2 2>/dev/null || true
sleep 1

echo "[prep-gamescope] Cleanup done" >> "$LOG"

# ── 1.5. SetOutputMode — CDH должен знать целевое разрешение ──
# Без этого CDH output остаётся 1920×1080 (дефолт), и Gamescope
# получит configure 1920×1080 → Xwayland рендерит в неправильном размере
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$UID_SELF/bus}"
export DBUS_SESSION_BUS_ADDRESS

# Разрешение из Sunshine (если есть)
W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
R="${SUNSHINE_CLIENT_FPS:-60}"

echo "[prep-gamescope] SetOutputMode ${W}x${H}@${R}fps" >> "$LOG"
busctl --user call \
    org.gamescope.Input \
    /org/gamescope/Input \
    org.gamescope.InputDeviceManager \
    SetOutputMode uuu \
    "$W" "$H" "$R"

RC=$?
echo "[prep-gamescope] busctl exit code: $RC" >> "$LOG"
[ $RC -ne 0 ] && exit $RC

sleep 0.5

# ── 2. Запуск Gamescope nested (wayland backend) ──
# Gamescope подключается к CDH через WAYLAND_DISPLAY=wayland-cd
# Steam запускается внутри Gamescope с -steamos3

echo "[prep-gamescope] Resolution: ${W}x${H}@${R}" >> "$LOG"
echo "[prep-gamescope] Gamescope: $GAMESCOPE_BIN" >> "$LOG"

# ── 2.5. MangoHud config — совместимость с MangoHud 0.8+ ──
# MangoHud / MangoApp config.
# На реальном Steam Deck конфиг записываемый (644) и Steam дописывает
# preset, fsr_steam_sharpness, no_display и т.д. У нас chmod 444 —
# защита от дописывания Steam'ом "no_display=1" (preset 0), что скрывает overlay.
# Все нужные параметры прописываем заранее.
#
# preset=2  — горизонтальный HUD (как на Deck по умолчанию)
# no_display=0 — явно разрешаем отображение overlay
# fsr_steam_sharpness=5 — значение как на Deck
MANGOHUD_CFG="/tmp/mangohud-gamescope.conf"
rm -f "$MANGOHUD_CFG"
cat > "$MANGOHUD_CFG" << 'EOF'
control=mangohud
preset=2
no_display=0
fsr_steam_sharpness=5
EOF
chmod 444 "$MANGOHUD_CFG"
export MANGOHUD_CONFIGFILE="$MANGOHUD_CFG"
echo "[prep-gamescope] MangoHud config: $MANGOHUD_CFG (read-only)" >> "$LOG"

# GLFW_PLATFORM=x11 — На Fedora 43 glfw-3.4 (универсальная) при наличии
# WAYLAND_DISPLAY автовыбирает Wayland backend → MangoApp создаёт Wayland
# surface вместо X11 window → GAMESCOPE_EXTERNAL_OVERLAY atom не ставится.
# На Steam Deck используется glfw-x11 (only X11), проблемы нет.
WAYLAND_DISPLAY=wayland-cd \
    GLFW_PLATFORM=x11 \
    STEAM_DECK=1 \
    "$GAMESCOPE_BIN" \
    --backend wayland \
    -W "$W" -H "$H" \
    -w "$W" -h "$H" \
    -r "$R" \
    -e \
    --mangoapp \
    --xwayland-count 2 \
    --force-grab-cursor \
    -f \
    -- steam -steamos3 -gamepadui -noverifyfiles \
    >> /tmp/gamescope.log 2>&1 &

GS_PID=$!
echo "[prep-gamescope] Gamescope PID=${GS_PID}" >> "$LOG"
echo "[prep-gamescope] Done" >> "$LOG"
