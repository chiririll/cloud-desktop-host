# shellcheck shell=bash
# lib.sh — shared helpers for cloud-desktop-host scripts. Sourced, no side effects on load.
#
#   SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
#   . "$SCRIPT_DIR/lib.sh"
#   cdh_env

# ── Environment ────────────────────────────────────────────────
cdh_env() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    export CDH_LOG_DIR="${CDH_LOG_DIR:-/tmp/cdhost-logs/latest}"
    export CDH_STATE_DIR="$XDG_RUNTIME_DIR/cdh"
    mkdir -p -m 700 "$CDH_STATE_DIR"
    # xdg-open (Electron, GTK apps…) picks kde-open only when these are set
    export QT_QPA_PLATFORMTHEME=kde XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE
    export KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true
}

# Plasma client environment (used as: env "${KDE_ENV[@]}" DISPLAY="$d" cmd)
KDE_ENV=(
    WAYLAND_DISPLAY=wayland-0
    XDG_SESSION_TYPE=wayland
    QT_QPA_PLATFORM=wayland
    QT_QPA_PLATFORMTHEME=kde
    XDG_CURRENT_DESKTOP=KDE
    XDG_SESSION_DESKTOP=KDE
    KDE_SESSION_VERSION=6
    KDE_FULL_SESSION=true
)

STEAM_PROCS=(gamescope-focus-daemon steam '~steamwebhelper' '~steam-runtime-launcher-service' '~steamclient')

# ── Logging ────────────────────────────────────────────────────
_SELF=${0##*/}
log() { echo "[$_SELF] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# Fork-free timestamp filter: "[HH:MM:SS.mmm] line"
add_ts() {
    local line us
    while IFS= read -r line; do
        us=${EPOCHREALTIME#*[.,]}
        printf '[%(%H:%M:%S)T.%s] %s\n' -1 "${us:0:3}" "$line"
    done
}

# spawn <logname> <cmd...> — background with timestamped log; sets SPAWNED_PID.
# CDH_NO_LOG=1 sends output to /dev/null.
spawn() {
    local name=$1; shift
    if [ "${CDH_NO_LOG:-0}" = 1 ]; then
        "$@" >/dev/null 2>&1 &
    else
        mkdir -p "$CDH_LOG_DIR"
        "$@" > >(add_ts >>"$CDH_LOG_DIR/$name.log") 2>&1 &
    fi
    SPAWNED_PID=$!
}

# ── Waiting / stopping ─────────────────────────────────────────
wait_for() {   # wait_for <seconds> <command...>
    local deadline=$((SECONDS + $1)); shift
    until "$@" 2>/dev/null; do
        if ((SECONDS >= deadline)); then return 1; fi
        sleep 0.1
    done
}

# Names are matched against the kernel comm (15 chars). A "~pattern" entry matches the full command line.
_sig_procs() {   # _sig_procs <signal> <name...>
    local sig=$1 n; shift
    for n in "$@"; do
        if [[ $n == '~'* ]]; then
            pkill "-$sig" -u "$UID" -f -- "${n#\~}" 2>/dev/null || true
        else
            pkill "-$sig" -u "$UID" -x -- "${n:0:15}" 2>/dev/null || true
        fi
    done
}
_all_gone() {
    local n
    for n in "$@"; do
        if [[ $n == '~'* ]]; then
            if pgrep -u "$UID" -f -- "${n#\~}" >/dev/null; then return 1; fi
        else
            if pgrep -u "$UID" -x -- "${n:0:15}" >/dev/null; then return 1; fi
        fi
    done
    return 0
}
stop_procs() {   # stop_procs [-t seconds] <name...>: SIGTERM, wait, SIGKILL the rest
    local timeout=5
    if [ "${1:-}" = -t ]; then timeout=$2; shift 2; fi
    _sig_procs TERM "$@"
    wait_for "$timeout" _all_gone "$@" && return 0
    _sig_procs KILL "$@"
    wait_for 2 _all_gone "$@"
}

# ── X displays ─────────────────────────────────────────────────
x_displays() {
    local s
    for s in /tmp/.X11-unix/X*; do
        if [ -S "$s" ]; then echo "${s##*X}"; fi
    done
}
wait_new_x_display() {   # $1 = displays before (space separated), $2 = timeout in seconds
    local before=" $1 " n i
    for ((i = 0; i < $2 * 10; i++)); do
        for n in $(x_displays); do
            if [[ $before != *" $n "* ]]; then echo ":$n"; return 0; fi
        done
        sleep 0.1
    done
    return 1
}
# Remove X lock files (and sockets) whose owner process is dead
clean_stale_x() {
    local lock n pid
    for lock in /tmp/.X*-lock; do
        [ -e "$lock" ] || continue
        n=${lock#/tmp/.X}; n=${n%-lock}
        pid=$(tr -d ' \n' <"$lock" 2>/dev/null)
        if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
            rm -f "$lock" "/tmp/.X11-unix/X$n" 2>/dev/null || true
        fi
    done
}

# ── gamescope-compatible D-Bus ─────────────────────────────────
set_output_mode() {   # set_output_mode <w> <h> <fps>
    log "SetOutputMode $1x$2@$3"
    busctl --user call org.gamescope.Input /org/gamescope/Input \
        org.gamescope.InputDeviceManager SetOutputMode uuu "$1" "$2" "$3" || {
        local rc=$?
        log "SetOutputMode failed (exit $rc)"
        return "$rc"
    }
    sleep 0.5   # no cheap signal that the mode was applied
}
set_idle() {   # set_idle true|false; failure is not an error (auto-idle covers it)
    busctl --user call org.gamescope.Input /org/gamescope/Input \
        org.gamescope.InputDeviceManager SetIdle b "$1" >/dev/null 2>&1 || true
}

# ── Stop lists ─────────────────────────────────────────────────
stop_deck() {   # gamescope + Steam (+ their Xwayland when KWin is not using one)
    stop_procs "${STEAM_PROCS[@]}" gamescope
    if ! pgrep -u "$UID" -x kwin_wayland >/dev/null; then
        stop_procs Xwayland
        clean_stale_x
    fi
}
stop_desktop() {   # Plasma, Steam, KWin (5 s grace), Xwayland
    stop_procs plasmashell kded6 polkit-kde-authentication-agent-1
    stop_procs "${STEAM_PROCS[@]}" kwin_wayland Xwayland
    rm -f "$CDH_STATE_DIR/kwin-display" "$XDG_RUNTIME_DIR"/wayland-0 "$XDG_RUNTIME_DIR"/wayland-0.lock
    clean_stale_x
}
stop_base() {
    stop_procs sunshine cloud-desktop-host kactivitymanagerd pipewire-pulse wireplumber pipewire
}

# ── Plasma ─────────────────────────────────────────────────────
set_gtk_layout() {
    local layout='appmenu:minimize,maximize,close' v ini
    /usr/bin/gsettings set org.gnome.desktop.wm.preferences button-layout "$layout" 2>/dev/null || true
    for v in gtk-3.0 gtk-4.0; do
        mkdir -p "$HOME/.config/$v"
        ini="$HOME/.config/$v/settings.ini"
        if [ ! -e "$ini" ]; then
            printf '[Settings]\ngtk-decoration-layout=%s\n' "$layout" >"$ini"
        elif ! grep -q 'gtk-decoration-layout' "$ini"; then
            if grep -q '^\[Settings\]' "$ini"; then
                sed -i "/^\[Settings\]/a gtk-decoration-layout=$layout" "$ini"
            else
                printf '\n[Settings]\ngtk-decoration-layout=%s\n' "$layout" >>"$ini"
            fi
        fi
    done
}

# start_desktop <w> <h>: KWin (if not running), activation env, kded6, plasmashell, polkit.
# Sets KWIN_XDISPLAY.
start_desktop() {
    local w=$1 h=$2 before
    KWIN_XDISPLAY=""
    if ! pgrep -u "$UID" -x kwin_wayland >/dev/null; then
        clean_stale_x
        before=$(x_displays | tr '\n' ' ')
        spawn kwin env WAYLAND_DISPLAY=wayland-cd XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland \
            kwin_wayland --no-lockscreen --width "$w" --height "$h" --xwayland
        log "KWin PID=$SPAWNED_PID"
        wait_for 20 test -S "$XDG_RUNTIME_DIR/wayland-0" || { log "KWin did not create wayland-0"; return 1; }
        KWIN_XDISPLAY=$(wait_new_x_display "$before" 10) || KWIN_XDISPLAY=""
        if [ -n "$KWIN_XDISPLAY" ]; then echo "$KWIN_XDISPLAY" >"$CDH_STATE_DIR/kwin-display"; fi
    else
        KWIN_XDISPLAY=$(cat "$CDH_STATE_DIR/kwin-display" 2>/dev/null) || KWIN_XDISPLAY=""
        if [ -z "$KWIN_XDISPLAY" ]; then
            KWIN_XDISPLAY=$(x_displays | head -n1)
            if [ -n "$KWIN_XDISPLAY" ]; then KWIN_XDISPLAY=":$KWIN_XDISPLAY"; fi
        fi
    fi
    log "DISPLAY=${KWIN_XDISPLAY:-N/A}"

    dbus-update-activation-environment \
        "${KDE_ENV[@]}" DISPLAY="$KWIN_XDISPLAY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" 2>/dev/null || true
    set_gtk_layout

    spawn kded6 env "${KDE_ENV[@]}" DISPLAY="$KWIN_XDISPLAY" kded6
    wait_for 5 busctl --user status org.kde.kded6 || log "kded6 not on D-Bus yet"
    spawn plasmashell env "${KDE_ENV[@]}" DISPLAY="$KWIN_XDISPLAY" plasmashell --replace
    wait_for 15 busctl --user status org.kde.plasmashell || log "plasmashell not on D-Bus yet"
    spawn polkit env "${KDE_ENV[@]}" DISPLAY="$KWIN_XDISPLAY" /usr/libexec/kf6/polkit-kde-authentication-agent-1
}
